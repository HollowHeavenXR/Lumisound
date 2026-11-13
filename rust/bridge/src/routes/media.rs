//! Search, streaming and downloads (route group 1).

use crate::auth::{ApiKey, User, account_token_user_id};
use crate::error::{ApiResult, AppError};
use crate::extract::{Q, check_range, invalid};
use crate::files;
use crate::probe;
use crate::state::AppState;
use crate::ytdlp::{self, ARIA2_ARGS, MUXED_ITAGS, RunError, generic_failure_summary, is_permanent_failure, parse_track};
use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/search", get(search))
        .route("/api/stream", get(stream))
        .route("/api/stream/ticket", get(stream_ticket))
        .route("/api/stream/proxy", get(stream_proxy))
        .route("/api/download/relay", get(download_relay))
        .route("/api/download", get(download))
        .route("/api/download/status", get(download_status))
        .route("/api/download/result", get(download_result))
        .route("/api/download/pending", get(download_pending))
        .route("/api/download/batch", post(batch_download))
        .route("/api/download/batch/status", get(batch_status))
        .route("/api/track", get(track_metadata))
        .route("/api/resolve", get(resolve))
        .route("/api/spotify/resolve", get(spotify_resolve))
        .route("/api/playlist/expand", get(playlist_expand))
        .route("/api/playlist/links", get(playlist_links))
        .route("/api/radio", get(radio))
        .route("/api/motion-artwork", get(motion_artwork))
}

const IPHONE_UA: &str = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
const RELAY_INCOMPATIBLE: &[&str] = &["mp3", "flac", "opus", "wav", "best"];
const STREAM_URL_TTL_SECS: i64 = 21600;
const CHUNK: u64 = 2 * 1024 * 1024;

fn lower(s: &Option<String>, d: &str) -> String {
    s.as_deref().unwrap_or(d).to_lowercase()
}

fn uid(st: &AppState, h: &HeaderMap) -> Option<String> {
    account_token_user_id(st, h)
}

fn timeout_err(e: RunError, detail: &str) -> AppError {
    match e {
        RunError::Timeout => AppError::new(408, detail),
        RunError::Spawn(e) => {
            tracing::error!("yt-dlp spawn failed: {e}");
            AppError::new(503, "Downloader unavailable")
        }
    }
}

/// `_reject_ssrf_targets`.
pub async fn reject_ssrf(url: &str) -> ApiResult<()> {
    let parsed = url::Url::parse(url).map_err(|_| AppError::bad_request("URL must be http or https"))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(AppError::bad_request("URL must be http or https"));
    }
    let host = parsed.host_str().filter(|h| !h.is_empty()).ok_or_else(|| AppError::bad_request("URL is missing a host"))?;
    let host = host.trim_start_matches('[').trim_end_matches(']').to_string();
    let addrs: Vec<std::net::IpAddr> = match host.parse::<std::net::IpAddr>() {
        Ok(ip) => vec![ip],
        Err(_) => tokio::net::lookup_host((host.as_str(), 0))
            .await
            .map_err(|_| AppError::bad_request("Could not resolve URL host"))?
            .map(|a| a.ip())
            .collect(),
    };
    for ip in addrs {
        let bad = match ip {
            std::net::IpAddr::V4(v) => {
                v.is_private() || v.is_loopback() || v.is_link_local() || v.is_multicast() || v.is_unspecified() || v.is_broadcast()
                    || v.octets()[0] >= 240 || (v.octets()[0] == 100 && (v.octets()[1] & 0xC0) == 64) || v.octets()[0] == 0
            }
            std::net::IpAddr::V6(v) => {
                v.is_loopback() || v.is_multicast() || v.is_unspecified() || (v.segments()[0] & 0xfe00) == 0xfc00
                    || (v.segments()[0] & 0xffc0) == 0xfe80
                    || v.to_ipv4_mapped().is_some_and(|m| m.is_private() || m.is_loopback() || m.is_link_local())
            }
        };
        if bad {
            return Err(AppError::bad_request("URL host resolves to a disallowed address"));
        }
    }
    Ok(())
}

async fn target_for(source: &str, id: &str, url: &Option<String>) -> ApiResult<String> {
    if source == "soundcloud" || source == "bandcamp" {
        let u = url.clone().filter(|u| !u.is_empty()).ok_or_else(|| AppError::bad_request(format!("url parameter required for {source} source")))?;
        reject_ssrf(&u).await?;
        Ok(u)
    } else {
        Ok(format!("https://youtube.com/watch?v={id}"))
    }
}

impl AppState {
    /// `_user_inventory_source_ids` (30 s cache).
    pub async fn inventory_ids(&self, user_id: Option<&str>) -> Arc<HashSet<String>> {
        let Some(u) = user_id else { return Arc::new(HashSet::new()) };
        if let Some(v) = self.inventory.get(&u.to_string()) {
            return v;
        }
        match sqlx::query_scalar::<_, String>("SELECT source_id FROM ios_user_library_inventory WHERE user_id = $1").bind(u).fetch_all(&self.db).await {
            Ok(ids) => {
                let set = Arc::new(ids.into_iter().collect::<HashSet<_>>());
                self.inventory.set(u.to_string(), set.clone());
                set
            }
            Err(e) => {
                tracing::warn!("inventory lookup failed for {u}: {e}");
                Arc::new(HashSet::new())
            }
        }
    }

    async fn log_stream(&self, user_id: Option<String>, source: &str, id: &str, status: &str, err: Option<String>, ms: u128) {
        self.log_attempt("ios_stream_log", user_id, source, id, None, status, err, ms).await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn log_attempt(&self, table: &str, user_id: Option<String>, source: &str, id: &str, title: Option<String>, status: &str, err: Option<String>, ms: u128) {
        let sql = format!(
            "INSERT INTO {table} (user_id, source, source_id, title, status, error_message, duration_ms, completed_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, CURRENT_TIMESTAMP)"
        );
        let r = sqlx::query(&sql)
            .bind(user_id)
            .bind(source)
            .bind(id)
            .bind(title)
            .bind(status)
            .bind(err)
            .bind(ms.min(i32::MAX as u128) as i32)
            .execute(&self.db)
            .await;
        if let Err(e) = r {
            tracing::error!("Failed to record {table} entry for {source}:{id} (status={status}): {e}");
        }
    }

    fn spawn_log_stream(&self, user_id: Option<String>, source: &str, id: &str, status: &'static str, err: Option<String>, ms: u128) {
        let st = self.clone();
        let (s, i) = (source.to_string(), id.to_string());
        tokio::spawn(async move { st.log_stream(user_id, &s, &i, status, err, ms).await });
    }

    /// Cached raw URL for (source, id, format), resolving with yt-dlp on a miss.
    /// Returns (url, freshly_resolved).
    async fn resolve_stream_url(&self, source: &str, id: &str, format: &str, target: &str, user_id: Option<&str>) -> ApiResult<(String, bool)> {
        let key = format!("{source}:{id}:{format}");
        if let Some(u) = self.stream_urls.get(&key) {
            return Ok((u, false));
        }
        if let Some((code, d)) = self.stream_failures.get(&key) {
            return Err(AppError::new(code, d));
        }
        // AVPlayer/AVURLAsset open a stream with a burst of range requests;
        // without this every one of them ran its own yt-dlp (one song was
        // resolved 342 times in two days, 35-85 s each behind the limiter).
        let lock = self.stream_resolving.entry(key.clone()).or_default().clone();
        let _guard = lock.lock().await;
        if let Some(u) = self.stream_urls.get(&key) {
            return Ok((u, false));
        }
        if let Some((code, d)) = self.stream_failures.get(&key) {
            return Err(AppError::new(code, d));
        }
        let start = Instant::now();
        let res = self.ytdlp.raw_url(target, ytdlp::format_flag(format), user_id).await;
        let ms = start.elapsed().as_millis();
        let out = match res {
            Err(e) => {
                let err = timeout_err(e, "Stream URL fetch timed out");
                let detail = err.detail.as_str().unwrap_or("Stream URL fetch timed out").to_string();
                self.stream_failures.set_ttl(key.clone(), (err.status.as_u16(), detail), Duration::from_secs(15));
                Err(err)
            }
            Ok((Some(u), _)) => {
                self.stream_resolved_at.set(key.clone(), Instant::now());
                self.stream_urls.set(key.clone(), u.clone());
                self.spawn_log_stream(user_id.map(str::to_string), source, id, "success", None, ms);
                Ok((u, true))
            }
            Ok((None, reason)) => {
                // A known reason (unavailable, private, sign-in) won't change
                // in seconds; an unexplained miss gets a short memory only.
                let ttl = if reason.is_some() { 300 } else { 30 };
                let d = reason.unwrap_or_else(|| "No stream URL found".into());
                self.stream_failures.set_ttl(key.clone(), (404, d.clone()), Duration::from_secs(ttl));
                self.spawn_log_stream(user_id.map(str::to_string), source, id, "failed", Some(d.clone()), ms);
                Err(AppError::not_found(d))
            }
        };
        drop(_guard);
        self.stream_resolving.remove_if(&key, |_, l| Arc::strong_count(l) <= 2);
        out
    }
}

// ---- search ---------------------------------------------------------------------------------

#[derive(Deserialize)]
struct SearchQ {
    q: Option<String>,
    limit: Option<i64>,
    source: Option<String>,
}

async fn search(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(p): Q<SearchQ>) -> ApiResult<Json<Value>> {
    let q = p.q.ok_or_else(|| invalid("q", "Field required"))?;
    if q.is_empty() || q.chars().count() > 200 {
        return Err(invalid("q", "String should have between 1 and 200 characters"));
    }
    let limit = p.limit.unwrap_or(20);
    check_range("limit", limit, 1, 50)?;
    let source = lower(&p.source, "youtube");
    if source != "youtube" && source != "soundcloud" {
        return Err(AppError::bad_request("source must be 'youtube' or 'soundcloud'"));
    }
    {
        let (st, q, s) = (st.clone(), q.clone(), source.clone());
        tokio::spawn(async move {
            let _ = sqlx::query("INSERT INTO ios_search_log (query, source) VALUES ($1, $2)")
                .bind(crate::db::truncate(q.trim(), 255))
                .bind(s)
                .execute(&st.db)
                .await;
        });
    }
    let key = format!("{source}:{limit}:{}", q.trim().to_lowercase());
    if let Some(v) = st.search_cache.get(&key) {
        tracing::info!("Cache hit for query {q:?}");
        return Ok(Json(v));
    }
    let user = uid(&st, &headers);
    if source == "youtube" {
        if let Some(u) = &user {
            let api_key = st.yt.key_for_user(&st.db, u, st.cfg.youtube_api_key.as_deref()).await;
            if st.yt.search_allowed(&api_key) {
                if let Some(tracks) = st.yt.search(&q, limit as usize, &api_key).await {
                    tracing::info!("Search via YouTube Data API: {} result(s) for {q:?}", tracks.len());
                    let v = Value::Array(tracks);
                    st.search_cache.set(key, v.clone());
                    return Ok(Json(v));
                }
            }
        }
    }
    let prefix = if source == "youtube" { "ytsearch" } else { "scsearch" };
    let args = st.ytdlp.listing_args(&format!("{prefix}{limit}:{q}"), &source, user.as_deref()).await;
    let entries = match st.ytdlp.run_json(&args, Duration::from_secs(30)).await {
        Ok(e) => e,
        Err(e) => {
            tracing::warn!("yt-dlp search failed for {q:?}: {e}");
            return Ok(Json(json!([])));
        }
    };
    let v = Value::Array(entries.iter().map(|e| parse_track(e, &source)).collect());
    st.search_cache.set(key, v.clone());
    Ok(Json(v))
}

// ---- streaming ------------------------------------------------------------------------------

#[derive(Deserialize)]
struct StreamQ {
    id: Option<String>,
    source: Option<String>,
    url: Option<String>,
    format: Option<String>,
    ticket: Option<String>,
    title: Option<String>,
    existing_ids: Option<String>,
}

async fn stream(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(p): Q<StreamQ>) -> ApiResult<Json<Value>> {
    let id = p.id.clone().ok_or_else(|| invalid("id", "Field required"))?;
    let source = lower(&p.source, "youtube");
    let format = lower(&p.format, "m4a");
    let target = target_for(&source, &id, &p.url).await?;
    let user = uid(&st, &headers);
    let (url, _) = st.resolve_stream_url(&source, &id, &format, &target, user.as_deref()).await?;
    Ok(Json(json!({"url": url, "expires_in": STREAM_URL_TTL_SECS})))
}

async fn stream_ticket(State(st): State<AppState>, user: User) -> Json<Value> {
    use rand::Rng;
    let bytes: [u8; 24] = rand::rng().random();
    let ticket = base64_url(&bytes);
    st.stream_tickets.set(ticket.clone(), user.id);
    Json(json!({"ticket": ticket, "expires_in": STREAM_URL_TTL_SECS}))
}

pub fn base64_url(b: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(b.len() * 4 / 3 + 2);
    for c in b.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        let chars = [(n >> 18) & 63, (n >> 12) & 63, (n >> 6) & 63, n & 63];
        for (i, ch) in chars.iter().enumerate() {
            if i <= c.len() {
                out.push(T[*ch as usize] as char);
            }
        }
    }
    out
}

fn describe_auth_scheme(h: &str) -> Option<String> {
    if h.is_empty() {
        return None;
    }
    let first = h.split(' ').next().unwrap_or("");
    Some(if ["bearer", "basic", "digest", "token", "apikey"].contains(&first.to_lowercase().as_str()) { first.to_string() } else { "malformed".into() })
}

async fn stream_proxy(State(st): State<AppState>, headers: HeaderMap, Q(p): Q<StreamQ>) -> ApiResult<Response> {
    let id = p.id.clone().ok_or_else(|| invalid("id", "Field required"))?;
    let mut source = lower(&p.source, "youtube");
    let account_token = headers.get("x-account-token").and_then(|v| v.to_str().ok()).unwrap_or("");
    let token_ok = !account_token.is_empty() && st.keys.decode(account_token).is_some();
    let ticket_ok = p.ticket.as_deref().filter(|t| !t.is_empty()).is_some_and(|t| st.stream_tickets.get(&t.to_string()).is_some());
    if !token_ok && !ticket_ok {
        let auth = headers.get("authorization").and_then(|v| v.to_str().ok()).unwrap_or("");
        let rejected = if st.cfg.api_key.is_empty() {
            None
        } else if !auth.starts_with("Bearer ") {
            Some((401, "Missing Authorization header"))
        } else if &auth[7..] != st.cfg.api_key {
            Some((403, "Invalid API key"))
        } else {
            None
        };
        if let Some((code, msg)) = rejected {
            let detail = json!({
                "source": source, "status_code": code,
                "had_auth_header": !auth.is_empty(),
                "had_account_token": !account_token.is_empty(),
                "account_token_valid": token_ok,
                "user_agent": crate::db::truncate(headers.get("user-agent").and_then(|v| v.to_str().ok()).unwrap_or(""), 80),
                "has_range": headers.contains_key("range"),
                "auth_scheme": describe_auth_scheme(auth),
            });
            let st2 = st.clone();
            tokio::spawn(async move { crate::db::log_event(&st2.db, "streaming", "stream_proxy_auth_rejected", None, "error", msg, Some(detail)).await });
            return Err(AppError::new(code, msg));
        }
    }
    let mut format = lower(&p.format, "m4a");
    if source == "youtube" && RELAY_INCOMPATIBLE.contains(&format.as_str()) {
        tracing::info!("stream_proxy: coercing unplayable stream format {format:?} to m4a for {id}");
        format = "m4a".into();
    }
    source = source.to_string();
    let target = target_for(&source, &id, &p.url).await?;
    let user = uid(&st, &headers);
    let (raw_url, _fresh) = st.resolve_stream_url(&source, &id, &format, &target, user.as_deref()).await?;
    let cache_key = format!("{source}:{id}:{format}");
    // googlevideo 403s a URL fetched the instant it was resolved — that
    // holds for every request sharing the URL, not just the one that ran
    // yt-dlp (the others used to fail with 502 and evict it).
    if let Some(at) = st.stream_resolved_at.get(&cache_key) {
        let wait = Duration::from_secs(3).saturating_sub(at.elapsed());
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
    }
    let mut req = st.cdn.get(&raw_url).header("User-Agent", IPHONE_UA);
    if let Some(r) = headers.get("range") {
        req = req.header("Range", r.clone());
    }
    let upstream = match req.timeout(Duration::from_secs(30)).send().await.and_then(|r| r.error_for_status()) {
        Ok(r) => r,
        Err(e) => {
            st.stream_urls.remove(&cache_key);
            tracing::warn!("stream_proxy upstream open failed for {cache_key}: {e}");
            st.spawn_log_stream(user, &source, &id, "failed", Some(format!("upstream fetch: {e}")), 0);
            return Err(AppError::new(502, "Upstream stream fetch failed"));
        }
    };
    let status = upstream.status().as_u16();
    let uh = upstream.headers().clone();
    let expected: u64 = uh.get("content-length").and_then(|v| v.to_str().ok()?.parse().ok()).unwrap_or(0);
    let content_range = uh.get("content-range").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
    let range_start: u64 = content_range.strip_prefix("bytes ").and_then(|r| r.split('-').next()?.parse().ok()).unwrap_or(0);
    let supports_ranges = uh.get("accept-ranges").and_then(|v| v.to_str().ok()).is_some_and(|v| v.to_lowercase().contains("bytes"));
    let media_type = uh.get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("audio/mp4").to_string();

    let mut res = Response::builder().status(status).header(header::CONTENT_TYPE, media_type);
    for h in ["content-length", "content-range", "accept-ranges"] {
        if let Some(v) = uh.get(h) {
            res = res.header(h, v.clone());
        }
    }
    if !uh.contains_key("accept-ranges") {
        res = res.header("accept-ranges", "bytes");
    }

    let cdn = st.cdn.clone();
    let st2 = st.clone();
    let body = async_stream::stream! {
        let started = Instant::now();
        let mut streamed: u64 = 0;
        let mut error: Option<String> = None;
        if !supports_ranges {
            let mut s = upstream.bytes_stream();
            while let Some(c) = s.next().await {
                match c {
                    Ok(b) => { streamed += b.len() as u64; yield Ok::<_, std::io::Error>(b); }
                    Err(e) => { error = Some(e.to_string()); break; }
                }
            }
        } else {
            // YouTube throttles long single requests; pull 2 MB ranges and keep
            // the next range's request in flight while this one streams.
            drop(upstream);
            let end = if expected > 0 { Some(range_start + expected - 1) } else { None };
            let fetch = |from: u64| {
                let cdn = cdn.clone();
                let url = raw_url.clone();
                let stop = end.map_or(from + CHUNK - 1, |e| (from + CHUNK - 1).min(e));
                tokio::spawn(async move {
                    cdn.get(&url).header("User-Agent", IPHONE_UA).header("Range", format!("bytes={from}-{stop}"))
                        .timeout(Duration::from_secs(30)).send().await
                })
            };
            let mut offset = range_start;
            let mut pending = Some(fetch(offset));
            'outer: while let Some(h) = pending.take() {
                let resp = match h.await { Ok(Ok(r)) => r, Ok(Err(e)) => { error = Some(e.to_string()); break } Err(e) => { error = Some(e.to_string()); break } };
                let chunk_end = end.map_or(offset + CHUNK - 1, |e| (offset + CHUNK - 1).min(e));
                if end.is_none_or(|e| chunk_end < e) {
                    pending = Some(fetch(chunk_end + 1));
                }
                let mut got: u64 = 0;
                let mut s = resp.bytes_stream();
                while let Some(c) = s.next().await {
                    match c {
                        Ok(b) => { got += b.len() as u64; streamed += b.len() as u64; yield Ok(b); }
                        Err(e) => { error = Some(e.to_string()); break 'outer; }
                    }
                }
                if got == 0 { break; }
                offset += got;
                if end.is_some_and(|e| offset > e) { break; }
            }
            if let Some(p) = pending { p.abort(); }
        }
        let elapsed = started.elapsed().as_secs_f64();
        let truncated = expected > 0 && streamed < expected;
        if error.is_some() || truncated {
            tracing::warn!("stream_proxy body incomplete for {cache_key}: {streamed}/{expected} bytes in {elapsed:.1}s{}", error.map(|e| format!(" ({e})")).unwrap_or_default());
            if streamed == 0 { st2.stream_urls.remove(&cache_key); }
        } else {
            tracing::info!("stream_proxy streamed {streamed} bytes in {elapsed:.1}s ({:.0} KB/s) for {cache_key}", streamed as f64 / 1024.0 / elapsed.max(0.001));
        }
    };
    Ok(res.body(Body::from_stream(body)).unwrap())
}

fn safe_title(title: &Option<String>, id: &str) -> String {
    let t = title.clone().filter(|t| !t.is_empty()).unwrap_or_else(|| id.to_string()).replace(['/', ':'], "-");
    let mut end = t.len().min(240);
    while !t.is_char_boundary(end) {
        end -= 1;
    }
    t[..end].to_string()
}

fn owned(inv: &HashSet<String>, existing: &Option<String>, key: &str) -> bool {
    inv.contains(key) || existing.as_deref().is_some_and(|e| e.split(',').map(str::trim).any(|s| s == key))
}

async fn download_relay(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(p): Q<StreamQ>) -> ApiResult<Response> {
    let id = p.id.clone().ok_or_else(|| invalid("id", "Field required"))?;
    let source = lower(&p.source, "youtube");
    let format = lower(&p.format, "m4a");
    let start = Instant::now();
    if RELAY_INCOMPATIBLE.contains(&format.as_str()) {
        return Err(AppError::bad_request(format!("format={format} requires server-side transcoding; use /api/download instead")));
    }
    let target = target_for(&source, &id, &p.url).await?;
    let user = uid(&st, &headers);
    let key = format!("{source}:{id}");
    if owned(&*st.inventory_ids(user.as_deref()).await, &p.existing_ids, &key) {
        tracing::info!("download_relay: skipping {key} — already owned (manifest/inventory)");
        return Ok(StatusCode::NO_CONTENT.into_response());
    }
    let cache_key = format!("{source}:{id}:{format}");
    let raw_url = match st.stream_urls.get(&cache_key) {
        Some(u) => u,
        None => {
            let (u, reason) = st.ytdlp.raw_url(&target, ytdlp::format_flag(&format), user.as_deref()).await.map_err(|e| timeout_err(e, "Stream URL fetch timed out"))?;
            let u = u.ok_or_else(|| AppError::not_found(reason.unwrap_or_else(|| "No stream URL found".into())))?;
            st.stream_urls.set(cache_key.clone(), u.clone());
            tokio::time::sleep(Duration::from_secs(3)).await;
            u
        }
    };
    let upstream = match st.cdn.get(&raw_url).header("User-Agent", IPHONE_UA).timeout(Duration::from_secs(30)).send().await.and_then(|r| r.error_for_status()) {
        Ok(r) => r,
        Err(e) => {
            st.stream_urls.remove(&cache_key);
            tracing::warn!("download_relay: upstream open failed for {cache_key} after {:.2}s: {e}", start.elapsed().as_secs_f64());
            return Err(AppError::new(502, "Upstream fetch failed"));
        }
    };
    let status = upstream.status().as_u16();
    let media_type = upstream.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("audio/mp4").to_string();
    let mut res = Response::builder().status(status).header(header::CONTENT_TYPE, media_type);
    if let Some(cl) = upstream.headers().get("content-length") {
        res = res.header(header::CONTENT_LENGTH, cl.clone());
    }
    let disp = format!("attachment; filename=\"{}.m4a\"", safe_title(&p.title, &id));
    if let Ok(v) = HeaderValue::from_str(&disp) {
        res = res.header(header::CONTENT_DISPOSITION, v);
    }
    let body = upstream.bytes_stream().map(|r| r.map_err(std::io::Error::other));
    Ok(res.body(Body::from_stream(body)).unwrap())
}

// ---- downloads ------------------------------------------------------------------------------

#[derive(Clone)]
pub enum JobState {
    Pending,
    Done { tmp_dir: PathBuf, file: PathBuf, media_type: String, filename: String },
    Error { code: u16, detail: Value, permanent: bool },
}

pub struct Job {
    pub created: Instant,
    pub state: JobState,
}

#[derive(Deserialize, Clone)]
struct DownloadQ {
    id: Option<String>,
    source: Option<String>,
    url: Option<String>,
    format: Option<String>,
    title: Option<String>,
    full_title: Option<String>,
    artist: Option<String>,
    thumbnail: Option<String>,
    duration: Option<i64>,
    destination_folder: Option<String>,
    existing_ids: Option<String>,
    use_aria2: Option<bool>,
    throttle_seconds: Option<i64>,
    concurrent_fragments: Option<i64>,
}

fn sweep_jobs(st: &AppState) {
    let now = Instant::now();
    let mut stale = Vec::new();
    st.download_jobs.retain(|_, j| {
        let keep = now.duration_since(j.created) < Duration::from_secs(900);
        if !keep {
            if let JobState::Done { tmp_dir, .. } = &j.state {
                stale.push(tmp_dir.clone());
            }
        }
        keep
    });
    for d in stale {
        tokio::spawn(async move { let _ = tokio::fs::remove_dir_all(d).await; });
    }
    let last = st.last_pending_sweep.load(std::sync::atomic::Ordering::Relaxed);
    let now_s = chrono::Utc::now().timestamp();
    if now_s - last >= 3600 {
        st.last_pending_sweep.store(now_s, std::sync::atomic::Ordering::Relaxed);
        let st = st.clone();
        tokio::spawn(async move { sweep_pending_downloads(&st).await });
    }
}

async fn sweep_pending_downloads(st: &AppState) {
    let rows: Result<Vec<Option<String>>, _> = sqlx::query_scalar(
        "DELETE FROM ios_pending_downloads WHERE created_at < NOW() - make_interval(days => 30) RETURNING file_path",
    )
    .fetch_all(&st.db)
    .await;
    match rows {
        Ok(paths) => {
            for p in paths.into_iter().flatten() {
                remove_file_and_parent(Path::new(&p)).await;
            }
        }
        Err(e) => tracing::warn!("sweep_stale_pending_downloads: failed: {e}"),
    }
}

async fn remove_file_and_parent(p: &Path) {
    let _ = tokio::fs::remove_file(p).await;
    if let Some(parent) = p.parent() {
        let _ = tokio::fs::remove_dir_all(parent).await;
    }
}

async fn download(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(p): Q<DownloadQ>) -> ApiResult<Response> {
    let id = p.id.clone().ok_or_else(|| invalid("id", "Field required"))?;
    if let Some(t) = p.throttle_seconds {
        check_range("throttle_seconds", t, 0, 60)?;
    }
    if let Some(c) = p.concurrent_fragments {
        check_range("concurrent_fragments", c, 1, 16)?;
    }
    sweep_jobs(&st);
    let source = lower(&p.source, "youtube");
    let format = lower(&p.format, "m4a");
    let user = uid(&st, &headers);
    let key = format!("{source}:{id}");
    if owned(&*st.inventory_ids(user.as_deref()).await, &p.existing_ids, &key) {
        tracing::info!("download_track: skipping {key} — already owned (manifest/inventory)");
        return Ok(StatusCode::NO_CONTENT.into_response());
    }
    let target = target_for(&source, &id, &p.url).await?;
    let job_id = uuid::Uuid::new_v4().simple().to_string();
    st.download_jobs.insert(job_id.clone(), Job { created: Instant::now(), state: JobState::Pending });
    let st2 = st.clone();
    let jid = job_id.clone();
    tokio::spawn(async move { run_download_job(st2, jid, source, id, target, format, p, user).await });
    Ok((StatusCode::ACCEPTED, Json(json!({"job_id": job_id}))).into_response())
}

#[allow(clippy::too_many_arguments)]
async fn run_download_job(st: AppState, job_id: String, source: String, id: String, target: String, format: String, p: DownloadQ, user: Option<String>) {
    let start = Instant::now();
    let display = p.full_title.clone().filter(|s| !s.is_empty()).or_else(|| p.title.clone().filter(|s| !s.is_empty())).unwrap_or_else(|| id.clone());
    let r = do_download_job(&st, &job_id, &source, &id, &target, &format, &p, user.as_deref(), &display).await;
    if let Err((code, detail, permanent)) = r {
        if let Some(mut j) = st.download_jobs.get_mut(&job_id) {
            j.state = JobState::Error { code, detail: Value::String(detail.clone()), permanent };
        }
        let ms = start.elapsed().as_millis();
        st.log_attempt("ios_download_log", user, &source, &id, Some(display), "failed", Some(detail), ms).await;
    }
}

type JobErr = (u16, String, bool);

#[allow(clippy::too_many_arguments)]
async fn do_download_job(
    st: &AppState,
    job_id: &str,
    source: &str,
    id: &str,
    target: &str,
    format: &str,
    p: &DownloadQ,
    user: Option<&str>,
    display: &str,
) -> Result<(), JobErr> {
    let yt = &st.ytdlp;
    let max_attempts = 3;
    let (extra, expected_ext) = ytdlp::download_format_args(format);
    let is_transcode = extra.contains(&"-x");
    let safe = safe_title(&p.title, id);
    let use_aria2 = p.use_aria2.unwrap_or(false);
    let throttle = p.throttle_seconds.unwrap_or(5);
    let fragments = p.concurrent_fragments.unwrap_or(8);
    let expected_duration = p.duration.filter(|d| *d > 0).map(|d| d as f64);
    let mut cookies = yt.cookie_args(user, false).await;
    let mut forced_global = false;
    // Set when YouTube asked for age verification: the remaining attempts use
    // the fallback client, which still serves these, instead of failing twice more.
    let mut age_fallback = false;
    let job_start = Instant::now();
    let mut found: Option<(PathBuf, PathBuf, String, Vec<u8>, &'static str)> = None;

    for attempt in 1..=max_attempts {
        let tmp_dir = std::env::temp_dir().join(format!("dl_{}", uuid::Uuid::new_v4().simple()));
        tokio::fs::create_dir_all(&tmp_dir).await.map_err(|e| (500, e.to_string(), false))?;
        let template = tmp_dir.join(format!("{safe}.%(ext)s")).to_string_lossy().into_owned();
        let aria2 = use_aria2 && attempt < max_attempts;
        let mut cmd: Vec<String> = yt.network_args().to_vec();
        if attempt == max_attempts || age_fallback {
            cmd.extend(["--extractor-args".into(), format!("youtube:player_client={}", st.cfg.ytdlp_fallback_client)]);
        }
        cmd.extend(["--no-playlist", "--embed-metadata", "--embed-thumbnail"].map(String::from));
        if fragments > 1 {
            cmd.extend(["-N".into(), fragments.to_string()]);
            if !aria2 {
                cmd.extend(["--http-chunk-size".into(), "10M".into()]);
            }
        }
        if aria2 {
            cmd.extend(ARIA2_ARGS.iter().map(|s| s.to_string()));
        }
        cmd.extend(["-o".into(), template]);
        cmd.extend(cookies.iter().cloned());
        cmd.extend(extra.iter().map(|s| s.to_string()));
        cmd.push(target.into());
        let downloader = if aria2 { "aria2c" } else { "native" };
        tracing::info!("Download cmd (attempt {attempt}/{max_attempts}, downloader={downloader}): yt-dlp {}", cmd.join(" "));
        let timeout = Duration::from_secs(if is_transcode { 240 } else { 140 });
        let floor = if throttle <= 0 { 0.0 } else { throttle as f64 / st.cfg.ytdlp_max.max(1) as f64 };
        let paced = yt.pacer.wait(floor).await;
        let proc_start = Instant::now();
        let out = {
            let _slot = yt.limiter.slot().await;
            let _t = if is_transcode { Some(yt.transcode.slot().await) } else { None };
            yt.run("yt-dlp", &cmd, timeout).await
        };
        let out = match out {
            Ok(o) => o,
            Err(RunError::Timeout) => {
                let _ = tokio::fs::remove_dir_all(&tmp_dir).await;
                tracing::warn!("yt-dlp timed out after {}s (attempt {attempt}/{max_attempts}, downloader={downloader}, transcode={is_transcode}): {safe}", timeout.as_secs());
                return Err((408, "Download timed out".into(), false));
            }
            Err(RunError::Spawn(e)) => {
                let _ = tokio::fs::remove_dir_all(&tmp_dir).await;
                return Err((500, e.to_string(), false));
            }
        };
        let elapsed = proc_start.elapsed().as_secs_f64();
        if out.status != Some(0) {
            yt.flag_cookies_stale_if_needed(&out.stderr);
            yt.penalise_if_rate_limited(&out.stderr);
            let err_text = ytdlp::tail(&String::from_utf8_lossy(&out.stderr), 500);
            tracing::error!("yt-dlp download failed (attempt {attempt}/{max_attempts}, downloader={downloader}, elapsed={elapsed:.1}s, exit={:?}): {err_text}", out.status);
            let _ = tokio::fs::remove_dir_all(&tmp_dir).await;
            if !forced_global && attempt < max_attempts && err_text.to_lowercase().contains("no longer valid") {
                forced_global = true;
                let forced = yt.cookie_args(user, true).await;
                if forced != cookies {
                    tracing::info!("Retrying download job with global cookie fallback (user {user:?} own cookies stale)");
                    cookies = forced;
                }
            }
            if !age_fallback && attempt < max_attempts && ytdlp::needs_age_fallback(&out.stderr) {
                age_fallback = true;
                tracing::info!("Age-restricted ({safe}): retrying with the {} client", st.cfg.ytdlp_fallback_client);
                continue;
            }
            // A removed/private/Premium-only video fails the same way every time.
            if attempt == max_attempts || is_permanent_failure(&out.stderr) {
                let detail = yt.auth_failure_reason(&out.stderr).unwrap_or_else(|| generic_failure_summary(&out.stderr));
                return Err((404, detail, is_permanent_failure(&out.stderr)));
            }
            continue;
        }
        tracing::info!(
            "yt-dlp download succeeded (attempt {attempt}/{max_attempts}, downloader={downloader}, elapsed={elapsed:.1}s, paced={:.1}s, spacing={:.1}s): {safe}",
            paced.as_secs_f64(),
            yt.pacer.interval()
        );
        let candidate = pick_output(&tmp_dir).await;
        let Some(cand) = candidate else {
            let _ = tokio::fs::remove_dir_all(&tmp_dir).await;
            if attempt == max_attempts {
                return Err((404, "Downloaded file not found".into(), false));
            }
            continue;
        };
        if !probe::verify_audio(&cand, expected_duration).await {
            tracing::warn!("Downloaded file failed ffprobe integrity check (attempt {attempt}/{max_attempts}): {}", cand.display());
            let _ = tokio::fs::remove_dir_all(&tmp_dir).await;
            if attempt == max_attempts {
                return Err((502, "Downloaded file failed integrity check".into(), false));
            }
            continue;
        }
        let ext = cand.extension().and_then(|e| e.to_str()).filter(|e| !e.is_empty()).unwrap_or(expected_ext).to_string();
        found = Some((tmp_dir, cand, ext, out.stdout, downloader));
        break;
    }
    let Some((tmp_dir, mut output, ext, ytdlp_stdout, downloader)) = found else {
        return Err((404, "Downloaded file not found".into(), false));
    };
    warn_if_muxed(st, &ytdlp_stdout, &safe, downloader);

    // Tag LUMISOUND_ID + display title/artist with a stream-copy remux.
    let source_id = format!("{source}:{id}");
    let stem = output.file_stem().and_then(|s| s.to_str()).unwrap_or("track").to_string();
    let tagged = tmp_dir.join(format!("{stem}_tagged.{ext}"));
    let mut tag: Vec<String> = vec!["-y".into(), "-i".into(), output.to_string_lossy().into(), "-map_metadata".into(), "0".into(), "-c".into(), "copy".into()];
    if matches!(ext.as_str(), "m4a" | "mp4" | "mov") {
        tag.extend(["-movflags".into(), "+faststart+use_metadata_tags".into()]);
    }
    tag.extend(["-metadata".into(), format!("LUMISOUND_ID={source_id}")]);
    if !display.is_empty() {
        tag.extend(["-metadata".into(), format!("title={display}")]);
    }
    if let Some(a) = p.artist.as_deref().filter(|a| !a.is_empty()) {
        tag.extend(["-metadata".into(), format!("artist={a}")]);
    }
    if let Some(t) = p.thumbnail.as_deref().filter(|t| !t.is_empty()) {
        tag.extend(["-metadata".into(), format!("LUMISOUND_THUMBNAIL={t}")]);
    }
    tag.push(tagged.to_string_lossy().into());
    match yt.run("ffmpeg", &tag, Duration::from_secs(60)).await {
        Ok(o) if o.status == Some(0)
            && tokio::fs::metadata(&tagged).await.map(|m| m.len() > 0).unwrap_or(false)
            && probe::verify_audio(&tagged, expected_duration).await =>
        {
            let _ = tokio::fs::remove_file(&output).await;
            output = tagged;
        }
        _ => {
            tracing::warn!("LUMISOUND_ID tagging failed or produced an unplayable file for {}, serving untagged file", output.display());
            let _ = tokio::fs::remove_file(&tagged).await;
        }
    }

    let artist = p.artist.clone().unwrap_or_default();
    if let Some(u) = user {
        let r = sqlx::query(
            "INSERT INTO ios_download_history (id, user_id, source, source_id, title, artist, thumbnail_url, duration_seconds, format) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) \
             ON CONFLICT (user_id, source, source_id) DO UPDATE SET \
               title = EXCLUDED.title, artist = EXCLUDED.artist, thumbnail_url = EXCLUDED.thumbnail_url, \
               duration_seconds = EXCLUDED.duration_seconds, format = EXCLUDED.format, \
               download_count = ios_download_history.download_count + 1, last_downloaded_at = CURRENT_TIMESTAMP",
        )
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(u)
        .bind(source)
        .bind(id)
        .bind(display)
        .bind(&artist)
        .bind(p.thumbnail.clone().unwrap_or_default())
        .bind(p.duration.unwrap_or(0) as i32)
        .bind(&ext)
        .execute(&st.db)
        .await;
        if let Err(e) = r {
            tracing::error!("Failed to record download history for user {u}: {e}");
        }
        let (st2, u2, data) = (st.clone(), u.to_string(), json!({"source": source, "source_id": id, "title": display, "artist": artist}));
        tokio::spawn(async move { st2.fire_user_webhooks(&u2, "download_complete", data).await });
    }
    {
        let (st2, u2, s, i, d, ms) = (st.clone(), user.map(str::to_string), source.to_string(), id.to_string(), display.to_string(), job_start.elapsed().as_millis());
        tokio::spawn(async move { st2.log_attempt("ios_download_log", u2, &s, &i, Some(d), "success", None, ms).await });
    }
    if p.full_title.as_deref().is_some_and(|s| !s.is_empty()) || p.title.as_deref().is_some_and(|s| !s.is_empty()) {
        let (st2, t, a, d) = (st.clone(), display.to_string(), artist.clone(), p.duration);
        tokio::spawn(async move { st2.fetch_and_cache_lyrics(&t, &a, d).await });
    }
    let media_type = match ext.as_str() {
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "flac" => "audio/flac",
        "opus" | "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        "webm" => "audio/webm",
        _ => "application/octet-stream",
    }
    .to_string();
    let filename = format!("{safe}.{ext}");
    let size = tokio::fs::metadata(&output).await.map(|m| m.len()).unwrap_or(0);
    tracing::info!(
        "download_track complete: job={job_id} source={source}:{id} ext={ext} size={size} bytes elapsed={:.1}s aria2_requested={use_aria2}",
        job_start.elapsed().as_secs_f64()
    );
    if let Some(mut j) = st.download_jobs.get_mut(job_id) {
        j.state = JobState::Done { tmp_dir: tmp_dir.clone(), file: output.clone(), media_type: media_type.clone(), filename: filename.clone() };
    }
    if let Some(u) = user {
        // Durable copy so the download survives the app being closed.
        let (st2, u, jid) = (st.clone(), u.to_string(), job_id.to_string());
        let (display, artist, dest_folder) = (display.to_string(), artist, p.destination_folder.clone());
        tokio::spawn(async move {
            let Some(_) = persist_finished(&st2, &jid, &u, &source_id, &display, &artist, &output, &media_type, &filename, dest_folder).await else { return };
            st2.download_jobs.remove(&jid);
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(5)).await;
                let _ = tokio::fs::remove_dir_all(tmp_dir).await;
            });
            match st2.notify_download_ready(&u, &display, &jid, &source_id).await {
                Ok(_) => tracing::info!("notify_download_ready: job={jid} user={u} notification sent"),
                Err(e) => tracing::error!("Failed to send download_ready notification for job {jid}: {e}"),
            }
        });
    }
    Ok(())
}

/// The finished file in a yt-dlp output dir (skipping partials and sidecar images).
async fn pick_output(dir: &Path) -> Option<PathBuf> {
    let mut rd = tokio::fs::read_dir(dir).await.ok()?;
    let mut best: Option<(PathBuf, u64)> = None;
    while let Ok(Some(e)) = rd.next_entry().await {
        let p = e.path();
        let ext = p.extension().and_then(|x| x.to_str()).unwrap_or("").to_lowercase();
        if matches!(ext.as_str(), "part" | "ytdl" | "webp" | "jpg" | "jpeg" | "png" | "json" | "temp") {
            continue;
        }
        let len = e.metadata().await.map(|m| m.len()).unwrap_or(0);
        if best.as_ref().is_none_or(|(_, l)| len > *l) {
            best = Some((p, len));
        }
    }
    best.map(|b| b.0)
}

fn warn_if_muxed(st: &AppState, stdout: &[u8], title: &str, downloader: &str) {
    let text = String::from_utf8_lossy(stdout);
    let Some(chosen) = st.re_chosen_format.captures(&text).and_then(|c| c.get(1)).map(|m| m.as_str().to_string()) else { return };
    if chosen.contains('+') || !MUXED_ITAGS.contains(&chosen.as_str()) {
        return;
    }
    tracing::warn!("yt-dlp fell back to muxed format {chosen} for {title:?} (client offered no audio-only stream)");
    let st = st.clone();
    let d = json!({"format": chosen, "attempt": 0, "downloader": downloader});
    tokio::spawn(async move { crate::db::log_event(&st.db, "download", "muxed_format_fallback", None, "warn", &format!("format {chosen}"), Some(d)).await });
}

#[allow(clippy::too_many_arguments)]
async fn persist_finished(
    st: &AppState,
    job_id: &str,
    user_id: &str,
    source_track_id: &str,
    title: &str,
    artist: &str,
    output: &Path,
    media_type: &str,
    filename: &str,
    dest_folder: Option<String>,
) -> Option<PathBuf> {
    let dir = Path::new(&st.cfg.pending_downloads_dir).join(job_id);
    let dest = dir.join(filename);
    if let Err(e) = async {
        tokio::fs::create_dir_all(&dir).await?;
        tokio::fs::copy(output, &dest).await.map(|_| ())
    }
    .await
    {
        tracing::warn!("persist_finished_job: failed to durably store job {job_id}: {e}");
        return None;
    }
    let r = sqlx::query(
        "INSERT INTO ios_pending_downloads (job_id, user_id, source_track_id, title, artist, file_path, media_type, filename, destination_folder) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
    )
    .bind(job_id)
    .bind(user_id)
    .bind(source_track_id)
    .bind(title)
    .bind(artist)
    .bind(dest.to_string_lossy().as_ref())
    .bind(media_type)
    .bind(filename)
    .bind(dest_folder)
    .execute(&st.db)
    .await;
    if let Err(e) = r {
        tracing::warn!("persist_finished_job: failed to record job {job_id} in DB: {e}");
        let _ = tokio::fs::remove_file(&dest).await;
        return None;
    }
    tracing::info!("persist_finished_job: job={job_id} user={user_id} source={source_track_id} durably stored at {}", dest.display());
    Some(dest)
}

#[derive(Deserialize)]
struct JobQ {
    job_id: Option<String>,
}

async fn pending_row(st: &AppState, job_id: &str, user: Option<&str>) -> Option<(String, String, String)> {
    let u = user?;
    sqlx::query_as("SELECT file_path, media_type, filename FROM ios_pending_downloads WHERE job_id = $1 AND user_id = $2")
        .bind(job_id)
        .bind(u)
        .fetch_optional(&st.db)
        .await
        .ok()
        .flatten()
}

async fn download_status(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(q): Q<JobQ>) -> ApiResult<Json<Value>> {
    let job_id = q.job_id.ok_or_else(|| invalid("job_id", "Field required"))?;
    if let Some(j) = st.download_jobs.get(&job_id) {
        return Ok(Json(match &j.state {
            JobState::Error { code, detail, permanent } => json!({"status": "error", "code": code, "detail": detail, "permanent": permanent}),
            JobState::Pending => json!({"status": "pending"}),
            JobState::Done { .. } => json!({"status": "done"}),
        }));
    }
    if pending_row(&st, &job_id, uid(&st, &headers).as_deref()).await.is_some() {
        return Ok(Json(json!({"status": "done"})));
    }
    Err(AppError::not_found("Unknown job_id"))
}

async fn download_result(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(q): Q<JobQ>) -> ApiResult<Response> {
    let job_id = q.job_id.ok_or_else(|| invalid("job_id", "Field required"))?;
    let state = st.download_jobs.get(&job_id).map(|j| j.state.clone());
    match state {
        None => {
            let user = uid(&st, &headers).ok_or_else(|| AppError::not_found("Unknown job_id"))?;
            let mut tx = st.db.begin().await?;
            let row: Option<(String, String, String)> = sqlx::query_as(
                "DELETE FROM ios_pending_downloads WHERE job_id = $1 AND user_id = $2 RETURNING file_path, media_type, filename",
            )
            .bind(&job_id)
            .bind(&user)
            .fetch_optional(&mut *tx)
            .await?;
            tx.commit().await?;
            let (path, media_type, filename) = row.ok_or_else(|| AppError::not_found("Unknown job_id"))?;
            let p = PathBuf::from(&path);
            let cleanup = p.clone();
            Ok(files::serve(
                &p,
                &media_type,
                Some(&filename),
                &headers,
                Some(Box::new(move || {
                    tokio::spawn(async move { remove_file_and_parent(&cleanup).await });
                })),
            )
            .await)
        }
        Some(JobState::Pending) => Ok((StatusCode::ACCEPTED, Json(json!({"status": "pending"}))).into_response()),
        Some(JobState::Error { code, detail, .. }) => {
            st.download_jobs.remove(&job_id);
            Err(AppError::with_value(code, detail))
        }
        Some(JobState::Done { tmp_dir, file, media_type, filename }) => {
            st.download_jobs.remove(&job_id);
            let (st2, jid) = (st.clone(), job_id.clone());
            tokio::spawn(async move {
                if let Ok(Some(p)) = sqlx::query_scalar::<_, String>("DELETE FROM ios_pending_downloads WHERE job_id = $1 RETURNING file_path")
                    .bind(&jid)
                    .fetch_optional(&st2.db)
                    .await
                {
                    remove_file_and_parent(Path::new(&p)).await;
                }
            });
            Ok(files::serve(
                &file,
                &media_type,
                Some(&filename),
                &headers,
                Some(Box::new(move || {
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_secs(5)).await;
                        let _ = tokio::fs::remove_dir_all(tmp_dir).await;
                    });
                })),
            )
            .await)
        }
    }
}

async fn download_pending(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap) -> ApiResult<Json<Value>> {
    let Some(u) = uid(&st, &headers) else { return Ok(Json(json!({"pending": []}))) };
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('job_id', job_id, 'source_track_id', source_track_id, 'title', title, \
           'artist', artist, 'media_type', media_type, 'filename', filename, 'created_at', created_at, \
           'destination_folder', destination_folder) ORDER BY created_at ASC), '[]'::json) \
         FROM ios_pending_downloads WHERE user_id = $1",
    )
    .bind(&u)
    .fetch_one(&st.db)
    .await?;
    tracing::info!("list_pending_downloads: user={u} returning {} pending job(s)", v.as_array().map_or(0, Vec::len));
    Ok(Json(json!({"pending": v})))
}

// ---- metadata / playlists -------------------------------------------------------------------

#[derive(Deserialize)]
struct UrlQ {
    url: Option<String>,
    limit: Option<i64>,
    existing_ids: Option<String>,
}

async fn track_metadata(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(q): Q<UrlQ>) -> ApiResult<Json<Value>> {
    let url = q.url.ok_or_else(|| invalid("url", "Field required"))?;
    reject_ssrf(&url).await?;
    let mut args: Vec<String> = vec!["--dump-json".into(), "--no-playlist".into()];
    args.extend(st.ytdlp.cookie_args(uid(&st, &headers).as_deref(), false).await);
    args.push(url.clone());
    let entries = st.ytdlp.run_json(&args, Duration::from_secs(20)).await.map_err(|e| match e {
        RunError::Timeout => AppError::new(408, "Metadata fetch timed out"),
        _ => AppError::not_found("Could not fetch track metadata"),
    })?;
    let e = entries.first().ok_or_else(|| AppError::not_found("Track not found"))?;
    let mut t = parse_track(e, ytdlp::source_from_url(&url));
    t["description"] = json!(e["description"].as_str().unwrap_or(""));
    Ok(Json(t))
}

fn filter_existing(tracks: &Value, source: &str, existing: &Option<String>, inv: &HashSet<String>) -> Value {
    let mut have: HashSet<&str> = inv.iter().map(String::as_str).collect();
    if let Some(e) = existing {
        have.extend(e.split(',').map(str::trim).filter(|s| !s.is_empty()));
    }
    if have.is_empty() {
        return tracks.clone();
    }
    Value::Array(
        tracks
            .as_array()
            .map(|a| {
                a.iter()
                    .filter(|t| {
                        let id = match &t["id"] {
                            Value::String(s) => s.clone(),
                            Value::Null => "None".into(),
                            v => v.to_string(),
                        };
                        !have.contains(format!("{source}:{id}").as_str())
                    })
                    .cloned()
                    .collect()
            })
            .unwrap_or_default(),
    )
}

async fn resolve(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(q): Q<UrlQ>) -> ApiResult<Json<Value>> {
    let url = q.url.clone().ok_or_else(|| invalid("url", "Field required"))?;
    let limit = q.limit.unwrap_or(100);
    check_range("limit", limit, 1, 1000)?;
    reject_ssrf(&url).await?;
    let source = ytdlp::source_from_url(&url);
    let user = uid(&st, &headers);
    let inv = st.inventory_ids(user.as_deref()).await;
    let done = |v: &Value| Json(filter_existing(v, source, &q.existing_ids, &inv));
    if source == "youtube" {
        let api_key = match &user {
            Some(u) => st.yt.key_for_user(&st.db, u, st.cfg.youtube_api_key.as_deref()).await,
            None => st.cfg.youtube_api_key.clone().unwrap_or_default(),
        };
        if !api_key.is_empty() {
            if let Some(pid) = crate::youtube::extract_playlist_id(&url) {
                let key = format!("resolve:{pid}:{limit}");
                if let Some(c) = st.search_cache.get(&key) {
                    return Ok(done(&c));
                }
                match st.yt.playlist_items(&pid, limit as usize, &api_key).await {
                    Ok(items) => {
                        let v = Value::Array(items.iter().map(|i| parse_track(i, source)).collect());
                        st.search_cache.set(key, v.clone());
                        return Ok(done(&v));
                    }
                    Err(e) => tracing::warn!("YouTube Data API resolve failed, falling back to yt-dlp: {e}"),
                }
            } else if crate::youtube::channel_url_match(&url).is_some() || url.trim().starts_with('@') {
                let key = format!("resolve_channel:{url}:{limit}");
                if let Some(c) = st.search_cache.get(&key) {
                    return Ok(done(&c));
                }
                match st.yt.resolve_channel(&url, &api_key).await {
                    Ok(info) => match st.yt.channel_uploads(info["channel_id"].as_str().unwrap_or(""), limit as usize, &api_key).await {
                        Ok(t) => {
                            let v = Value::Array(t);
                            st.search_cache.set(key, v.clone());
                            return Ok(done(&v));
                        }
                        Err(e) => tracing::warn!("YouTube Data API channel resolve failed, falling back to yt-dlp: {e}"),
                    },
                    Err((_, d)) => tracing::warn!("YouTube Data API channel resolve failed, falling back to yt-dlp: {d}"),
                }
            }
        }
    }
    let key = format!("resolve_ytdlp:{url}:{limit}");
    if let Some(c) = st.search_cache.get(&key) {
        return Ok(done(&c));
    }
    let args: Vec<String> = if source == "soundcloud" || source == "bandcamp" {
        vec!["--dump-json".into(), url.clone()]
    } else {
        let mut a: Vec<String> = vec!["--dump-json".into(), "--flat-playlist".into(), "--playlist-end".into(), limit.to_string()];
        a.extend(st.ytdlp.cookie_args(user.as_deref(), false).await);
        a.push(url.clone());
        a
    };
    let entries = st.ytdlp.run_json(&args, Duration::from_secs(120)).await.map_err(|e| match e {
        RunError::Timeout => AppError::new(408, "Playlist resolve timed out"),
        _ => AppError::not_found("Could not resolve playlist"),
    })?;
    let v = Value::Array(entries.iter().take(limit as usize).map(|e| parse_track(e, source)).collect());
    st.search_cache.set(key, v.clone());
    Ok(done(&v))
}

fn spotify_ref(url: &str) -> Option<(String, String)> {
    let i = url.find("open.spotify.com/")?;
    let mut rest = &url[i + 17..];
    if let Some(r) = rest.strip_prefix("intl-") {
        if r.len() > 3 && r.as_bytes()[..2].iter().all(u8::is_ascii_lowercase) && r.as_bytes()[2] == b'/' {
            rest = &r[3..];
        }
    }
    for kind in ["track", "album", "playlist"] {
        if let Some(r) = rest.strip_prefix(kind).and_then(|r| r.strip_prefix('/')) {
            let id: String = r.chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
            if !id.is_empty() {
                return Some((kind.to_string(), id));
            }
        }
    }
    None
}

fn spotify_track_query(t: &Value) -> Value {
    let artists: Vec<&str> = t["artists"].as_array().map(|a| a.iter().filter_map(|x| x["name"].as_str().filter(|s| !s.is_empty())).collect()).unwrap_or_default();
    json!({
        "title": t["name"].as_str().filter(|s| !s.is_empty()).unwrap_or("Unknown Title"),
        "artist": if artists.is_empty() { "Unknown Artist".to_string() } else { artists.join(", ") },
        "duration_seconds": t["duration_ms"].as_f64().unwrap_or(0.0) as i64 / 1000,
    })
}

async fn spotify_resolve(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(q): Q<UrlQ>) -> ApiResult<Json<Value>> {
    let url = q.url.clone().ok_or_else(|| invalid("url", "Field required"))?;
    let limit = q.limit.unwrap_or(100);
    check_range("limit", limit, 1, 200)?;
    let (Some(cid), Some(secret)) = (st.cfg.spotify_client_id.clone(), st.cfg.spotify_client_secret.clone()) else {
        return Err(AppError::new(501, "Spotify import isn't configured on this server (SPOTIFY_CLIENT_ID/SPOTIFY_CLIENT_SECRET unset)."));
    };
    let (kind, sid) = spotify_ref(&url).ok_or_else(|| AppError::bad_request("Not a recognized Spotify track/album/playlist URL"))?;
    let user = uid(&st, &headers);
    let inv = st.inventory_ids(user.as_deref()).await;
    let key = format!("spotify:{kind}:{sid}:{limit}");
    if let Some(c) = st.search_cache.get(&key) {
        return Ok(Json(filter_existing(&c, "youtube", &q.existing_ids, &inv)));
    }
    let mut tracks: Vec<Value> = Vec::new();
    if kind == "track" {
        let d = st.yt.spotify_get(&cid, &secret, &format!("tracks/{sid}"), &[]).await.ok_or_else(|| AppError::not_found("Spotify track lookup failed"))?;
        tracks.push(spotify_track_query(&d));
    } else {
        let path = if kind == "playlist" { "playlists" } else { "albums" };
        let mut offset = 0;
        while (tracks.len() as i64) < limit {
            let n = (limit - tracks.len() as i64).min(100);
            let Some(d) = st.yt.spotify_get(&cid, &secret, &format!("{path}/{sid}/tracks"), &[("limit", n.to_string()), ("offset", offset.to_string())]).await else { break };
            let page = d["items"].as_array().cloned().unwrap_or_default();
            if page.is_empty() {
                break;
            }
            for e in &page {
                let t = if kind == "playlist" { &e["track"] } else { e };
                if t.is_null() || !(t["type"].is_null() || t["type"] == "track") {
                    continue;
                }
                tracks.push(spotify_track_query(t));
            }
            if d["next"].is_null() {
                break;
            }
            offset += 100;
        }
        if tracks.is_empty() {
            return Err(AppError::not_found("Spotify playlist/album lookup returned no tracks"));
        }
        tracks.truncate(limit as usize);
    }
    let api_key = match &user {
        Some(u) => st.yt.key_for_user(&st.db, u, st.cfg.youtube_api_key.as_deref()).await,
        None => st.cfg.youtube_api_key.clone().unwrap_or_default(),
    };
    let matched: Vec<Option<Value>> = futures_util::stream::iter(tracks.into_iter())
        .map(|t| {
            let (st, key, user) = (st.clone(), api_key.clone(), user.clone());
            async move { match_spotify(&st, &t, &key, user.as_deref()).await }
        })
        .buffered(5)
        .collect()
        .await;
    let found: Vec<Value> = matched.into_iter().flatten().collect();
    if found.is_empty() {
        return Err(AppError::not_found("Could not match any tracks from this Spotify link"));
    }
    let v = Value::Array(found);
    st.search_cache.set(key, v.clone());
    Ok(Json(filter_existing(&v, "youtube", &q.existing_ids, &inv)))
}

async fn match_spotify(st: &AppState, t: &Value, api_key: &str, user: Option<&str>) -> Option<Value> {
    let query = format!("{} {}", t["artist"].as_str().unwrap_or(""), t["title"].as_str().unwrap_or("")).trim().to_string();
    // No Data API search here: at 100 units a track, one 100-song Spotify
    // playlist used a key's entire daily quota. yt-dlp's search is free; a
    // previous interactive API result is still reused when cached.
    let _ = api_key;
    let key = format!("youtube:1:{}", query.to_lowercase());
    if let Some(first) = st.search_cache.get(&key).and_then(|c| c.as_array().and_then(|a| a.first()).cloned()) {
        return Some(first);
    }
    let args = st.ytdlp.listing_args(&format!("ytsearch1:{query}"), "youtube", user).await;
    let entries = st.ytdlp.run_json(&args, Duration::from_secs(20)).await.ok()?;
    let first = entries.first().map(|e| parse_track(e, "youtube"))?;
    st.search_cache.set(key, Value::Array(vec![first.clone()]));
    Some(first)
}

async fn extract_playlist_items(st: &AppState, headers: &HeaderMap, url: &str, limit: usize) -> ApiResult<(String, Vec<Value>)> {
    reject_ssrf(url).await?;
    let source = ytdlp::source_from_url(url);
    let user = uid(st, headers);
    let mut tracks: Vec<Value> = Vec::new();
    if source == "youtube" {
        let api_key = match &user {
            Some(u) => st.yt.key_for_user(&st.db, u, st.cfg.youtube_api_key.as_deref()).await,
            None => st.cfg.youtube_api_key.clone().unwrap_or_default(),
        };
        if let (false, Some(pid)) = (api_key.is_empty(), crate::youtube::extract_playlist_id(url)) {
            match st.yt.playlist_items(&pid, limit, &api_key).await {
                Ok(items) => tracks = items.iter().map(|i| parse_track(i, source)).collect(),
                Err(e) => tracing::warn!("playlist extract: Data API failed, falling back to yt-dlp: {e}"),
            }
        }
    }
    if tracks.is_empty() {
        let args: Vec<String> = if source == "soundcloud" || source == "bandcamp" {
            vec!["--dump-json".into(), url.into()]
        } else {
            let mut a: Vec<String> = vec!["--dump-json".into(), "--flat-playlist".into()];
            a.extend(st.ytdlp.cookie_args(user.as_deref(), false).await);
            a.push(url.into());
            a
        };
        let entries = st.ytdlp.run_json(&args, Duration::from_secs(120)).await.map_err(|e| match e {
            RunError::Timeout => AppError::new(408, "Playlist extract timed out"),
            _ => AppError::not_found("Could not extract playlist"),
        })?;
        tracks = entries.iter().take(limit).map(|e| parse_track(e, source)).collect();
    }
    let items = tracks
        .iter()
        .filter_map(|t| {
            let id = t["id"].as_str().unwrap_or("");
            let u = t["youtube_url"].as_str().filter(|s| !s.is_empty()).map(str::to_string).or_else(|| {
                if source == "youtube" && !id.is_empty() { Some(format!("https://www.youtube.com/watch?v={id}")) } else { None }
            })?;
            Some(json!({"id": t["id"], "title": t["title"], "url": u}))
        })
        .collect();
    Ok((source.to_string(), items))
}

async fn playlist_expand(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(q): Q<UrlQ>) -> ApiResult<Json<Value>> {
    let url = q.url.ok_or_else(|| invalid("url", "Field required"))?;
    let limit = q.limit.unwrap_or(1000);
    check_range("limit", limit, 1, 5000)?;
    let (source, items) = extract_playlist_items(&st, &headers, &url, limit as usize).await?;
    Ok(Json(json!({"source": source, "count": items.len(), "items": items})))
}

fn write_links_file(st: &AppState, source_url: &str, content: &str) -> PathBuf {
    use sha2::{Digest, Sha256};
    let dir = std::env::var("YTDLP_LINKS_DIR").map(PathBuf::from).unwrap_or_else(|_| Path::new(&st.cfg.ytdlp_cache_dir).join("links"));
    let key = &hex::encode(Sha256::digest(source_url.as_bytes()))[..16];
    let path = dir.join(format!("{key}.txt"));
    if let Err(e) = std::fs::create_dir_all(&dir).and_then(|_| std::fs::write(&path, content)) {
        tracing::warn!("playlist_links: could not persist links file: {e}");
    }
    path
}

async fn playlist_links(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(q): Q<UrlQ>) -> ApiResult<Response> {
    let url = q.url.ok_or_else(|| invalid("url", "Field required"))?;
    let limit = q.limit.unwrap_or(5000);
    check_range("limit", limit, 1, 10000)?;
    let text = |content: String, n: usize, path: PathBuf| {
        let mut r = (StatusCode::OK, [(header::CONTENT_TYPE, "text/plain; charset=utf-8")], content).into_response();
        r.headers_mut().insert("x-links-count", HeaderValue::from(n));
        if let Ok(v) = HeaderValue::from_str(&path.to_string_lossy()) {
            r.headers_mut().insert("x-links-file", v);
        }
        r
    };
    if crate::youtube::extract_playlist_id(&url).is_none() && !url.contains("list=") && !url.contains("/playlist") && !url.contains("/sets/") {
        reject_ssrf(&url).await?;
        let content = format!("{}\n", url.trim());
        let path = write_links_file(&st, &url, &content);
        return Ok(text(content, 1, path));
    }
    let (_, items) = extract_playlist_items(&st, &headers, &url, limit as usize).await?;
    let content: String = items.iter().map(|i| format!("{}\n", i["url"].as_str().unwrap_or(""))).collect();
    let path = write_links_file(&st, &url, &content);
    Ok(text(content, items.len(), path))
}

#[derive(Deserialize)]
struct RadioQ {
    id: Option<String>,
    source: Option<String>,
    limit: Option<i64>,
}

async fn radio(State(st): State<AppState>, _k: ApiKey, headers: HeaderMap, Q(q): Q<RadioQ>) -> ApiResult<Json<Value>> {
    let id = q.id.ok_or_else(|| invalid("id", "Field required"))?;
    let limit = q.limit.unwrap_or(20);
    check_range("limit", limit, 1, 50)?;
    if lower(&q.source, "youtube") != "youtube" {
        return Err(AppError::bad_request("Radio is only supported for source=youtube"));
    }
    let mut args: Vec<String> = vec!["--dump-json".into(), "--flat-playlist".into(), "--no-warnings".into()];
    args.extend(st.ytdlp.cookie_args(uid(&st, &headers).as_deref(), false).await);
    args.push(format!("https://www.youtube.com/watch?v={id}&list=RD{id}"));
    let entries = st.ytdlp.run_json(&args, Duration::from_secs(30)).await.map_err(|e| match e {
        RunError::Timeout => AppError::new(408, "Radio resolve timed out"),
        _ => AppError::not_found("Could not build radio"),
    })?;
    Ok(Json(Value::Array(entries.iter().filter(|e| e["id"].as_str() != Some(id.as_str())).take(limit as usize).map(|e| parse_track(e, "youtube")).collect())))
}

// ---- batch download into the user's cloud folder --------------------------------------------

#[derive(Deserialize)]
struct BatchQ {
    url: Option<String>,
    format: Option<String>,
    limit: Option<i64>,
    job_id: Option<String>,
}

pub struct BatchJob {
    pub created: Instant,
    pub status: String,
    pub total: usize,
    pub completed: usize,
    pub rejected: usize,
    pub detail: Option<String>,
}

const AUDIO_EXTS: &[&str] = &["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "opus", "ogg", "caf", "mp4", "m4v", "webm", "mov"];

fn audio_files(dir: &Path) -> HashSet<PathBuf> {
    let mut out = HashSet::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            match e.file_type() {
                Ok(t) if t.is_dir() => stack.push(p),
                Ok(t) if t.is_file() => {
                    if p.extension().and_then(|x| x.to_str()).is_some_and(|x| AUDIO_EXTS.contains(&x.to_lowercase().as_str())) {
                        out.insert(p);
                    }
                }
                _ => {}
            }
        }
    }
    out
}

async fn batch_download(State(st): State<AppState>, user: User, headers: HeaderMap, Q(q): Q<BatchQ>) -> ApiResult<Response> {
    let url = q.url.ok_or_else(|| invalid("url", "Field required"))?;
    let limit = q.limit.unwrap_or(5000);
    check_range("limit", limit, 1, 10000)?;
    let music_dir = st.user_music_dir(&user.id).ok_or_else(|| AppError::new(503, "User music storage not configured"))?;
    let format = lower(&q.format, "m4a");
    let (source, items) = extract_playlist_items(&st, &headers, &url, limit as usize).await?;
    if items.is_empty() {
        return Err(AppError::not_found("No items found to download"));
    }
    let links: String = items.iter().map(|i| format!("{}\n", i["url"].as_str().unwrap_or(""))).collect();
    let links_path = write_links_file(&st, &url, &links);
    let now = Instant::now();
    st.batch_jobs.retain(|_, j| now.duration_since(j.created) < Duration::from_secs(3600));
    let job_id = uuid::Uuid::new_v4().simple().to_string();
    st.batch_jobs.insert(job_id.clone(), BatchJob { created: now, status: "pending".into(), total: items.len(), completed: 0, rejected: 0, detail: None });
    let cookies = st.ytdlp.cookie_args(Some(&user.id), false).await;
    let archive = build_download_archive(&st, &music_dir).await;
    tracing::debug!("batch from {source}");
    let (st2, jid) = (st.clone(), job_id.clone());
    tokio::spawn(async move { run_batch(st2, jid, links_path, music_dir, format, cookies, archive).await });
    Ok((StatusCode::ACCEPTED, Json(json!({"job_id": job_id, "total": items.len()}))).into_response())
}

/// `--download-archive` file from LUMISOUND_ID tags already in the folder,
/// so a batch skips tracks the user already has.
async fn build_download_archive(st: &AppState, dir: &Path) -> Option<PathBuf> {
    let archive = dir.join(".lumisound_download_archive.txt");
    let files = { let d = dir.to_path_buf(); tokio::task::spawn_blocking(move || audio_files(&d)).await.unwrap_or_default() };
    let mut lines: std::collections::BTreeSet<String> = Default::default();
    for p in files {
        let readable = crate::storage::readable_copy(&p).await;
        let tags = st.tags.tags(&p, readable.path()).await;
        let lid = tags["lumisound_id"].as_str().unwrap_or("").trim().to_string();
        if let Some((s, v)) = lid.split_once(':') {
            let (s, v) = (s.trim().to_lowercase(), v.trim());
            if !s.is_empty() && !v.is_empty() {
                lines.insert(format!("{s} {v}"));
            }
        }
    }
    st.tags.flush().await;
    let content: String = lines.iter().map(|l| format!("{l}\n")).collect();
    match tokio::fs::write(&archive, content).await {
        Ok(_) => tracing::info!("download archive: {} known track(s) for {}", lines.len(), dir.display()),
        Err(e) => tracing::warn!("download archive write failed: {e}"),
    }
    Some(archive)
}

async fn run_batch(st: AppState, job_id: String, links: PathBuf, music_dir: PathBuf, format: String, cookies: Vec<String>, archive: Option<PathBuf>) {
    let (extra, _) = ytdlp::download_format_args(&format);
    let before = { let d = music_dir.clone(); tokio::task::spawn_blocking(move || audio_files(&d)).await.unwrap_or_default() };
    let mut cmd: Vec<String> = st.ytdlp.network_args().to_vec();
    cmd.extend(
        [
            "--batch-file", &links.to_string_lossy(), "--no-playlist", "--embed-metadata", "--embed-thumbnail", "--ignore-errors",
            "--sleep-interval", "5", "--max-sleep-interval", "15", "-N", "8", "--http-chunk-size", "10M",
            "-P", &music_dir.to_string_lossy(), "-o", "%(title)s.%(ext)s",
        ]
        .map(String::from),
    );
    if let Some(a) = &archive {
        cmd.extend(["--download-archive".into(), a.to_string_lossy().into()]);
    }
    cmd.extend(cookies);
    cmd.extend(extra.iter().map(|s| s.to_string()));
    tracing::info!("batch_download {job_id}: yt-dlp {}", cmd.join(" "));
    let r = {
        let _slot = st.ytdlp.limiter.slot().await;
        st.ytdlp.run("yt-dlp", &cmd, Duration::from_secs(3600)).await
    };
    if let Err(RunError::Spawn(e)) = r {
        if let Some(mut j) = st.batch_jobs.get_mut(&job_id) {
            j.status = "error".into();
            j.detail = Some(e.to_string());
        }
        return;
    }
    let after = { let d = music_dir.clone(); tokio::task::spawn_blocking(move || audio_files(&d)).await.unwrap_or_default() };
    let (mut ok, mut bad) = (0, 0);
    for p in after.difference(&before) {
        if probe::verify_audio(p, None).await {
            ok += 1;
        } else {
            bad += 1;
            tracing::warn!("batch_download {job_id}: rejecting corrupt/truncated file {}", p.display());
            let _ = tokio::fs::remove_file(p).await;
        }
    }
    if let Some(mut j) = st.batch_jobs.get_mut(&job_id) {
        j.completed = ok;
        j.rejected = bad;
        j.status = "done".into();
    }
    tracing::info!("batch_download {job_id}: done ({ok} new files, {bad} rejected as corrupt)");
}

async fn batch_status(State(st): State<AppState>, _u: User, Q(q): Q<BatchQ>) -> ApiResult<Json<Value>> {
    let job_id = q.job_id.ok_or_else(|| invalid("job_id", "Field required"))?;
    let j = st.batch_jobs.get(&job_id).ok_or_else(|| AppError::not_found("Batch job not found"))?;
    Ok(Json(json!({"status": j.status, "total": j.total, "completed": j.completed, "rejected": j.rejected, "detail": j.detail})))
}

// ---- motion artwork -------------------------------------------------------------------------

#[derive(Deserialize)]
struct MotionQ {
    video_id: Option<String>,
}

async fn motion_artwork(State(st): State<AppState>, _u: User, headers: HeaderMap, Q(q): Q<MotionQ>) -> ApiResult<Response> {
    let vid = q.video_id.ok_or_else(|| invalid("video_id", "Field required"))?;
    let n = vid.chars().count();
    if !(5..=32).contains(&n) {
        return Err(invalid("video_id", "String should have between 5 and 32 characters"));
    }
    if !vid.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '-') {
        return Err(AppError::bad_request("Invalid video id"));
    }
    let dest = Path::new(&st.cfg.ytdlp_cache_dir).join("motion-artwork").join(format!("{vid}.mp4"));
    if dest.exists() {
        return Ok(files::serve(&dest, "video/mp4", None, &headers, None).await);
    }
    let lock = st.motion_locks.entry(vid.clone()).or_insert_with(|| Arc::new(tokio::sync::Mutex::new(()))).clone();
    let ok = {
        let _g = lock.lock().await;
        if dest.exists() {
            true
        } else {
            let _p = st.motion_sem.acquire().await;
            extract_motion_clip(&st, &vid, &dest).await
        }
    };
    st.motion_locks.remove(&vid);
    if !ok || !dest.exists() {
        return Err(AppError::new(503, "Motion artwork isn't available for this track"));
    }
    Ok(files::serve(&dest, "video/mp4", None, &headers, None).await)
}

async fn extract_motion_clip(st: &AppState, vid: &str, dest: &Path) -> bool {
    let _ = tokio::fs::create_dir_all(dest.parent().unwrap()).await;
    let raw = dest.with_extension("raw.mp4");
    let tmp = dest.with_extension("tmp.mp4");
    let _ = tokio::fs::remove_file(&raw).await;
    let mut cmd: Vec<String> = st.ytdlp.network_args().to_vec();
    cmd.extend([
        "--cache-dir".into(),
        st.cfg.ytdlp_cache_dir.clone(),
        "-f".into(),
        "bestvideo[height<=480][ext=mp4]/bestvideo[height<=480]/worst[height<=480]/worst".into(),
        "--no-playlist".into(),
        "-o".into(),
        raw.to_string_lossy().into(),
        format!("https://www.youtube.com/watch?v={vid}"),
    ]);
    let result = async {
        let o = st.ytdlp.run("yt-dlp", &cmd, Duration::from_secs(90)).await.ok()?;
        if o.status != Some(0) || !raw.exists() {
            return None;
        }
        let _ = tokio::fs::remove_file(&tmp).await;
        let (r, t) = (raw.to_string_lossy().to_string(), tmp.to_string_lossy().to_string());
        let vaapi: Vec<String> = [
            "-y", "-hide_banner", "-loglevel", "error", "-vaapi_device", "/dev/dri/renderD128", "-i", &r, "-t", "6", "-an",
            "-vf", "scale=480:480:force_original_aspect_ratio=increase,crop=480:480,format=nv12,hwupload",
            "-c:v", "h264_vaapi", "-qp", "26", "-movflags", "+faststart", &t,
        ]
        .map(String::from)
        .to_vec();
        let sw: Vec<String> = [
            "-y", "-hide_banner", "-loglevel", "error", "-i", &r, "-t", "6", "-an",
            "-vf", "scale=480:480:force_original_aspect_ratio=increase,crop=480:480",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-movflags", "+faststart", &t,
        ]
        .map(String::from)
        .to_vec();
        let ok = |o: Result<ytdlp::Output, RunError>| matches!(o, Ok(o) if o.status == Some(0));
        if !ok(st.ytdlp.run("ffmpeg", &vaapi, Duration::from_secs(60)).await) {
            let _ = tokio::fs::remove_file(&tmp).await;
            if !ok(st.ytdlp.run("ffmpeg", &sw, Duration::from_secs(60)).await) {
                return None;
            }
        }
        if !tmp.exists() {
            return None;
        }
        tokio::fs::rename(&tmp, dest).await.ok()
    }
    .await;
    let _ = tokio::fs::remove_file(&raw).await;
    result.is_some()
}
