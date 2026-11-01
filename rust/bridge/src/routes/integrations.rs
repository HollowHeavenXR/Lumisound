//! Integrations (route group 7): YouTube subscriptions + feed, podcasts,
//! scrobbling, push tokens / devices / playback transfer, notifications,
//! announcements, user + Discord webhooks, Discord RPC config/token, API
//! keys, yt-dlp cookies, GIF search, and the history log (scrobble hook).

use crate::auth::{Admin, User, OPERATOR_USER_ID};
use crate::error::{ApiResult, AppError};
use crate::extract::{J, Q, check_range, invalid};
use crate::routes::media::reject_ssrf;
use crate::state::AppState;
use crate::ytdlp::parse_track;
use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, patch, post};
use axum::{Json, Router};
use chrono::{Duration as CDuration, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use std::time::Duration;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/user/history", post(log_history).get(crate::routes::library::get_history))
        .route("/youtube/resolve-channel", post(resolve_channel))
        .route("/youtube/channel-uploads", get(channel_uploads))
        .route("/youtube/validate-key", post(validate_key))
        .route("/youtube/key-exposure-check", get(key_exposure))
        .route("/user/subscriptions", get(list_subs).post(create_sub))
        .route("/user/subscriptions/feed", get(feed))
        .route("/user/subscriptions/feed/read-all", post(feed_read_all))
        .route("/user/subscriptions/feed/{id}/read", post(feed_read))
        .route("/user/subscriptions/feed/{id}", delete(feed_dismiss))
        .route("/user/subscriptions/{id}", patch(update_sub).delete(delete_sub))
        .route("/user/subscriptions/{id}/check", post(check_sub))
        .route("/user/podcasts/subscriptions", get(list_podcasts).post(subscribe_podcast))
        .route("/user/podcasts/subscriptions/{id}", patch(update_podcast).delete(unsubscribe_podcast))
        .route("/user/podcasts/episodes", get(podcast_episodes))
        .route("/user/podcasts/chapters", get(podcast_chapters))
        .route("/user/podcasts/episode-progress", get(get_progress).put(put_progress))
        .route("/user/podcasts/export-opml", get(export_opml))
        .route("/user/podcasts/import-opml", post(import_opml))
        .route("/podcasts/search", get(search_podcasts))
        .route("/podcasts/trending", get(trending_podcasts))
        .route("/user/scrobble", get(get_scrobble).put(put_scrobble).delete(delete_scrobble))
        .route("/user/scrobble/lastfm/request-token", post(lastfm_token))
        .route("/user/scrobble/lastfm/link", post(lastfm_link))
        .route("/user/scrobble/librefm/request-token", post(librefm_token))
        .route("/user/scrobble/librefm/link", post(librefm_link))
        .route("/user/push-token", post(register_push))
        .route("/user/push-token/{token}", delete(unregister_push))
        .route("/user/devices", get(devices))
        .route("/user/playback/transfer", post(transfer))
        .route("/user/notifications", get(notifications))
        .route("/user/notifications/read-all", post(read_all))
        .route("/user/notifications/{id}/read", post(read_one))
        .route("/user/announcements", get(announcements))
        .route("/user/announcements/{id}/seen", post(announcement_seen))
        .route("/admin/api/announcements", get(admin_announcements).post(admin_create_announcement))
        .route("/admin/api/announcements/{id}", delete(admin_delete_announcement))
        .route("/user/webhooks", get(list_webhooks).post(create_webhook))
        .route("/user/webhooks/{id}", delete(delete_webhook))
        .route("/user/discord-webhook", get(get_discord_webhook).put(put_discord_webhook).delete(delete_discord_webhook))
        .route("/user/rpc-token", post(rpc_token))
        .route("/user/discord-rpc-config", get(get_rpc).put(put_rpc).delete(delete_rpc))
        .route("/user/youtube-api-key", get(get_yt_key).put(put_yt_key).delete(delete_yt_key))
        .route("/user/acoustid-api-key", get(get_aid_key).put(put_aid_key).delete(delete_aid_key))
        .route("/user/ytdlp-cookies", get(cookies_status).put(put_cookies).delete(delete_cookies))
        .route("/user/ytdlp-cookies/preference", get(get_pref).put(put_pref))
        .route("/user/ytdlp-cookies/validate", post(validate_cookies))
        .route("/api/gif-search", get(gif_search))
        .route("/api/gif-search/trending", get(gif_trending))
}

#[derive(Deserialize, Default)]
struct P {
    limit: Option<i64>,
    offset: Option<i64>,
    unread_only: Option<bool>,
    channel_id: Option<String>,
    feed_url: Option<String>,
    chapters_url: Option<String>,
    q: Option<String>,
}

const UA: &str = "Lumisound-iOS-Bridge/1.0";

async fn ev(st: &AppState, cat: &str, name: &str, user: &str, detail: Option<Value>) {
    crate::db::log_event(&st.db, cat, name, Some(user), "info", "", detail).await
}

fn mask(k: &str) -> String {
    if k.chars().count() > 10 {
        let c: Vec<char> = k.chars().collect();
        format!("{}...{}", c[..6].iter().collect::<String>(), c[c.len() - 4..].iter().collect::<String>())
    } else {
        "...".into()
    }
}

// ---- history + scrobbling --------------------------------------------------------------------

#[derive(Deserialize)]
struct PlayBody {
    title: String,
    artist: Option<String>,
    track_url: Option<String>,
    local_song_id: Option<String>,
    listen_seconds: Option<i64>,
    bpm: Option<f64>,
}

async fn log_history(State(st): State<AppState>, u: User, J(b): J<PlayBody>) -> ApiResult<Response> {
    let id = uuid::Uuid::new_v4().to_string();
    let secs = b.listen_seconds.unwrap_or(0);
    sqlx::query("INSERT INTO ios_play_history (id, user_id, track_url, local_song_id, title, artist, listen_seconds, bpm) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)")
        .bind(&id)
        .bind(&u.id)
        .bind(&b.track_url)
        .bind(&b.local_song_id)
        .bind(&b.title)
        .bind(&b.artist)
        .bind(secs as i32)
        .bind(b.bpm)
        .execute(&st.db)
        .await?;
    let (st2, uid, title, artist, bpm) = (st.clone(), u.id.clone(), b.title.clone(), b.artist.clone(), b.bpm);
    tokio::spawn(async move {
        scrobble(&st2, &uid, &title, artist.as_deref(), secs).await;
        now_playing_discord(&st2, &uid, &title, artist.as_deref(), bpm).await;
    });
    Ok((StatusCode::CREATED, Json(json!({"id": id, "status": "logged"}))).into_response())
}

fn as_sign(params: &[(&str, String)], secret: &str) -> String {
    use md5::{Digest, Md5};
    let mut sorted: Vec<&(&str, String)> = params.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(b.0));
    let s: String = sorted.iter().map(|(k, v)| format!("{k}{v}")).collect::<String>() + secret;
    hex::encode(Md5::digest(s.as_bytes()))
}

fn lastfm(_st: &AppState) -> Option<(String, String)> {
    Some((std::env::var("LASTFM_API_KEY").ok().filter(|s| !s.is_empty())?, std::env::var("LASTFM_API_SECRET").ok().filter(|s| !s.is_empty())?))
}

fn librefm() -> (String, String, String, String) {
    let g = |k: &str, d: &str| std::env::var(k).ok().filter(|s| !s.is_empty()).unwrap_or_else(|| d.to_string());
    (g("LIBREFM_API_KEY", "lumisound"), g("LIBREFM_API_SECRET", "lumisound"), g("LIBREFM_API_BASE", "https://libre.fm/2.0/"), g("LIBREFM_AUTH_BASE", "https://libre.fm/api/auth/"))
}

async fn audioscrobble(st: &AppState, base: &str, key: &str, secret: &str, sk: &str, artist: &str, title: &str) {
    let mut p = vec![("method", "track.scrobble".to_string()), ("api_key", key.to_string()), ("sk", sk.to_string()), ("artist", artist.to_string()),
        ("track", title.to_string()), ("timestamp", Utc::now().timestamp().to_string())];
    let sig = as_sign(&p, secret);
    p.push(("api_sig", sig));
    p.push(("format", "json".into()));
    if let Err(e) = st.http.post(base).header("User-Agent", UA).form(&p).timeout(Duration::from_secs(10)).send().await {
        tracing::debug!("scrobble to {base} failed: {e}");
    }
}

/// `_scrobble_track`: Last.fm, ListenBrainz and Libre.fm for plays of 30 s+.
async fn scrobble(st: &AppState, user: &str, title: &str, artist: Option<&str>, secs: i64) {
    if secs < 30 {
        return;
    }
    let row: Option<(Option<String>, Option<String>, Option<bool>, Option<String>)> =
        sqlx::query_as("SELECT lastfm_session_key, listenbrainz_token, enabled, librefm_session_key FROM ios_scrobble_links WHERE user_id = $1")
            .bind(user)
            .fetch_optional(&st.db)
            .await
            .unwrap_or(None);
    let Some((lf, lb, Some(true), lib)) = row else { return };
    let artist = artist.filter(|a| !a.is_empty()).unwrap_or("Unknown Artist");
    if let (Some(sk), Some((k, s))) = (lf.filter(|x| !x.is_empty()), lastfm(st)) {
        audioscrobble(st, "https://ws.audioscrobbler.com/2.0/", &k, &s, &sk, artist, title).await;
    }
    if let Some(tok) = lb.filter(|x| !x.is_empty()) {
        let body = json!({"listen_type": "single", "payload": [{"listened_at": Utc::now().timestamp(), "track_metadata": {
            "artist_name": artist, "track_name": title, "additional_info": if secs > 0 { json!({"duration": secs}) } else { json!({}) }}}]});
        let _ = st.http.post("https://api.listenbrainz.org/1/submit-listens").header("Authorization", format!("Token {tok}")).header("User-Agent", UA)
            .json(&body).timeout(Duration::from_secs(10)).send().await;
    }
    if let Some(sk) = lib.filter(|x| !x.is_empty()) {
        let (k, s, base, _) = librefm();
        audioscrobble(st, &base, &k, &s, &sk, artist, title).await;
    }
}

async fn now_playing_discord(st: &AppState, user: &str, title: &str, artist: Option<&str>, bpm: Option<f64>) {
    let row: Option<(String, Option<bool>)> = sqlx::query_as("SELECT webhook_url, enabled FROM ios_discord_webhooks WHERE user_id = $1").bind(user).fetch_optional(&st.db).await.unwrap_or(None);
    let Some((url, Some(true))) = row else { return };
    let mut d = format!("**{title}**");
    if let Some(a) = artist.filter(|a| !a.is_empty()) {
        d.push_str(&format!("\nby {a}"));
    }
    if let Some(b) = bpm.filter(|b| *b > 0.0) {
        d.push_str(&format!("\n{} BPM", crate::taste::py_round_int(b)));
    }
    post_discord(st, &url, &json!({"embeds": [{"title": "Now Playing", "description": d, "color": 0xEC4079}]})).await;
}

pub async fn post_discord(st: &AppState, url: &str, payload: &Value) {
    if let Err(e) = st.http.post(url).header("User-Agent", UA).json(payload).timeout(Duration::from_secs(10)).send().await {
        tracing::debug!("discord webhook post failed: {e}");
    }
}

async fn get_scrobble(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let row: Option<(Option<String>, Option<String>, Option<bool>, Option<String>)> =
        sqlx::query_as("SELECT lastfm_username, listenbrainz_token, enabled, librefm_username FROM ios_scrobble_links WHERE user_id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    let ne = |o: &Option<String>| o.as_ref().is_some_and(|s| !s.is_empty());
    Ok(Json(match row {
        None => json!({"lastfm_linked": false, "lastfm_username": null, "listenbrainz_linked": false, "librefm_linked": false, "librefm_username": null, "enabled": true}),
        Some((lf, lb, en, lib)) => json!({"lastfm_linked": ne(&lf), "lastfm_username": lf, "listenbrainz_linked": ne(&lb), "librefm_linked": ne(&lib),
            "librefm_username": lib, "enabled": en.unwrap_or(false)}),
    }))
}

#[derive(Deserialize)]
struct ScrobbleBody {
    lastfm_session_key: Option<String>,
    lastfm_username: Option<String>,
    listenbrainz_token: Option<String>,
    librefm_session_key: Option<String>,
    librefm_username: Option<String>,
    enabled: Option<bool>,
}

async fn put_scrobble(State(st): State<AppState>, u: User, J(b): J<ScrobbleBody>) -> ApiResult<Json<Value>> {
    sqlx::query(
        "INSERT INTO ios_scrobble_links (user_id, lastfm_session_key, lastfm_username, listenbrainz_token, librefm_session_key, librefm_username, enabled) \
         VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (user_id) DO UPDATE SET \
           lastfm_session_key = COALESCE(EXCLUDED.lastfm_session_key, ios_scrobble_links.lastfm_session_key), \
           lastfm_username = COALESCE(EXCLUDED.lastfm_username, ios_scrobble_links.lastfm_username), \
           listenbrainz_token = COALESCE(EXCLUDED.listenbrainz_token, ios_scrobble_links.listenbrainz_token), \
           librefm_session_key = COALESCE(EXCLUDED.librefm_session_key, ios_scrobble_links.librefm_session_key), \
           librefm_username = COALESCE(EXCLUDED.librefm_username, ios_scrobble_links.librefm_username), enabled = EXCLUDED.enabled",
    )
    .bind(&u.id)
    .bind(&b.lastfm_session_key)
    .bind(&b.lastfm_username)
    .bind(&b.listenbrainz_token)
    .bind(&b.librefm_session_key)
    .bind(&b.librefm_username)
    .bind(b.enabled.unwrap_or(true))
    .execute(&st.db)
    .await?;
    Ok(Json(json!({"status": "ok"})))
}

async fn delete_scrobble(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM ios_scrobble_links WHERE user_id = $1").bind(&u.id).execute(&st.db).await?;
    ev(&st, "scrobble", "scrobble_links_removed", &u.id, None).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn as_get(st: &AppState, base: &str, mut p: Vec<(&str, String)>, secret: &str) -> anyhow::Result<Value> {
    let sig = as_sign(&p, secret);
    p.push(("api_sig", sig));
    p.push(("format", "json".into()));
    Ok(st.http.get(base).query(&p).header("User-Agent", UA).timeout(Duration::from_secs(10)).send().await?.error_for_status()?.json().await?)
}

async fn lastfm_token(State(st): State<AppState>, _u: User) -> ApiResult<Json<Value>> {
    let (k, s) = lastfm(&st).ok_or_else(|| AppError::new(503, "Last.fm integration is not configured"))?;
    let d = as_get(&st, "https://ws.audioscrobbler.com/2.0/", vec![("method", "auth.gettoken".into()), ("api_key", k.clone())], &s)
        .await
        .map_err(|e| AppError::new(502, format!("Last.fm request failed: {e}")))?;
    let t = d["token"].as_str().filter(|t| !t.is_empty()).ok_or_else(|| AppError::new(502, "Last.fm did not return a token"))?;
    Ok(Json(json!({"token": t, "auth_url": format!("https://www.last.fm/api/auth/?api_key={k}&token={t}")})))
}

#[derive(Deserialize)]
struct TokenBody {
    token: String,
}

async fn link_session(st: &AppState, user: &str, base: &str, key: &str, secret: &str, token: &str, svc: &str, label: &str) -> ApiResult<Json<Value>> {
    let d = as_get(st, base, vec![("method", "auth.getsession".into()), ("api_key", key.to_string()), ("token", token.to_string())], secret)
        .await
        .map_err(|e| AppError::new(502, format!("{label} request failed: {e}")))?;
    let sk = d["session"]["key"].as_str().filter(|s| !s.is_empty()).ok_or_else(|| AppError::bad_request(format!("{label} did not approve this token")))?;
    let name = d["session"]["name"].as_str().map(str::to_string);
    let sql = format!(
        "INSERT INTO ios_scrobble_links (user_id, {svc}_session_key, {svc}_username, enabled) VALUES ($1, $2, $3, TRUE) \
         ON CONFLICT (user_id) DO UPDATE SET {svc}_session_key = EXCLUDED.{svc}_session_key, {svc}_username = EXCLUDED.{svc}_username"
    );
    sqlx::query(&sql).bind(user).bind(sk).bind(&name).execute(&st.db).await?;
    ev(st, "scrobble", &format!("{svc}_linked"), user, Some(json!({format!("{svc}_username"): name}))).await;
    Ok(Json(json!({format!("{svc}_username"): name})))
}

async fn lastfm_link(State(st): State<AppState>, u: User, J(b): J<TokenBody>) -> ApiResult<Json<Value>> {
    let (k, s) = lastfm(&st).ok_or_else(|| AppError::new(503, "Last.fm integration is not configured"))?;
    link_session(&st, &u.id, "https://ws.audioscrobbler.com/2.0/", &k, &s, &b.token, "lastfm", "Last.fm").await
}

async fn librefm_token(State(st): State<AppState>, _u: User) -> ApiResult<Json<Value>> {
    let (k, s, base, auth) = librefm();
    let d = as_get(&st, &base, vec![("method", "auth.gettoken".into()), ("api_key", k.clone())], &s).await.map_err(|e| AppError::new(502, format!("Libre.fm request failed: {e}")))?;
    let t = d["token"].as_str().filter(|t| !t.is_empty()).ok_or_else(|| AppError::new(502, "Libre.fm did not return a token"))?;
    Ok(Json(json!({"token": t, "auth_url": format!("{auth}?api_key={k}&token={t}")})))
}

async fn librefm_link(State(st): State<AppState>, u: User, J(b): J<TokenBody>) -> ApiResult<Json<Value>> {
    let (k, s, base, _) = librefm();
    link_session(&st, &u.id, &base, &k, &s, &b.token, "librefm", "Libre.fm").await
}

// ---- YouTube channels + subscriptions --------------------------------------------------------

#[derive(Deserialize)]
struct QueryBody {
    query: String,
}

async fn user_yt_key(st: &AppState, user: &str) -> String {
    st.yt.key_for_user(&st.db, user, st.cfg.youtube_api_key.as_deref()).await
}

async fn resolve_channel(State(st): State<AppState>, u: User, J(b): J<QueryBody>) -> ApiResult<Json<Value>> {
    let key = user_yt_key(&st, &u.id).await;
    st.yt.resolve_channel(&b.query, &key).await.map(Json).map_err(|(c, d)| AppError::new(c, d))
}

async fn uploads_ytdlp(st: &AppState, channel_id: &str, n: usize, user: &str) -> anyhow::Result<Vec<Value>> {
    let mut a: Vec<String> = vec![format!("https://www.youtube.com/channel/{channel_id}/videos"), "--dump-json".into(), "--flat-playlist".into(),
        "--playlist-end".into(), n.to_string(), "--cache-dir".into(), st.cfg.ytdlp_cache_dir.clone()];
    a.extend(st.ytdlp.cookie_args(Some(user), false).await);
    Ok(st.ytdlp.run_json(&a, Duration::from_secs(30)).await.map_err(|e| anyhow::anyhow!("{e}"))?.iter().map(|e| parse_track(e, "youtube")).collect())
}

async fn channel_uploads(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let cid = p.channel_id.ok_or_else(|| invalid("channel_id", "Field required"))?;
    let limit = p.limit.unwrap_or(10);
    check_range("limit", limit, 1, 25)?;
    let key = user_yt_key(&st, &u.id).await;
    if !key.is_empty() {
        match st.yt.channel_uploads(&cid, limit as usize, &key).await {
            Ok(t) => return Ok(Json(Value::Array(t))),
            Err(e) => tracing::warn!("channel_uploads: API failed for {cid:?}, falling back to yt-dlp: {e}"),
        }
    }
    uploads_ytdlp(&st, &cid, limit as usize, &u.id).await.map(|t| Json(Value::Array(t))).map_err(|e| {
        tracing::warn!("channel_uploads: yt-dlp failed for {cid:?}: {e}");
        AppError::new(502, "Could not fetch channel uploads")
    })
}

async fn yt_probe(st: &AppState, key: &str) -> (u16, Value) {
    st.yt.get_raw("videos", &[("part", "id".into()), ("chart", "mostPopular".into()), ("maxResults", "1".into())], key).await.unwrap_or((0, json!({})))
}

async fn validate_key(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let key = user_yt_key(&st, &u.id).await;
    if key.is_empty() {
        return Ok(Json(json!({"status": "invalid"})));
    }
    let (code, data) = yt_probe(&st, &key).await;
    let mut out = json!({"quota_units_used_today": st.yt.usage_today(&key), "quota_units_used_today_is_estimate": true, "quota_cooldown_active": st.yt.cooling_down(&key)});
    let reason = data["error"]["errors"][0]["reason"].as_str().unwrap_or("");
    let status = if (200..300).contains(&code) {
        "valid"
    } else if reason == "quotaExceeded" || (code == 403 && reason.to_lowercase().contains("quota")) {
        "quota_exceeded"
    } else {
        "invalid"
    };
    out.as_object_mut().unwrap().shift_insert(0, "status".into(), json!(status));
    Ok(Json(out))
}

async fn key_exposure(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let key = user_yt_key(&st, &u.id).await;
    if key.is_empty() {
        return Ok(Json(json!({"exposed": false, "detail": "No YouTube API key configured"})));
    }
    let (code, data) = yt_probe(&st, &key).await;
    if (200..300).contains(&code) {
        return Ok(Json(json!({"exposed": false, "detail": ""})));
    }
    Ok(Json(match data["error"]["errors"][0]["reason"].as_str().unwrap_or("") {
        "keyInvalid" => json!({"exposed": true, "detail": "API key is invalid or was revoked — possibly after being leaked."}),
        "ipRefererBlocked" => json!({"exposed": true, "detail": "API key is restricted to specific referrers/IPs and was rejected from this server — check your key's application restrictions."}),
        "quotaExceeded" => json!({"exposed": true, "detail": "API key has exhausted its daily quota — if this happens shortly after setup, it may indicate the key was leaked and is being used elsewhere."}),
        _ => json!({"exposed": false, "detail": ""}),
    }))
}

#[derive(Deserialize)]
struct SubBody {
    channel_url: String,
    channel_name: Option<String>,
}

async fn create_sub(State(st): State<AppState>, u: User, J(b): J<SubBody>) -> ApiResult<Response> {
    reject_ssrf(&b.channel_url).await?;
    let (mut cid, mut thumb, mut name, mut url) = (None::<String>, None::<String>, b.channel_name.clone(), b.channel_url.clone());
    let key = user_yt_key(&st, &u.id).await;
    if !key.is_empty() {
        match st.yt.resolve_channel(&b.channel_url, &key).await {
            Ok(r) => {
                cid = r["channel_id"].as_str().map(str::to_string);
                thumb = r["channel_thumbnail"].as_str().map(str::to_string);
                if name.as_deref().is_none_or(str::is_empty) {
                    name = r["channel_title"].as_str().map(str::to_string);
                }
                if let Some(c) = cid.as_deref().filter(|c| !c.is_empty()) {
                    url = format!("https://www.youtube.com/channel/{c}");
                }
            }
            Err((_, d)) => tracing::info!("create_subscription: channel resolution failed for {:?}: {d}", b.channel_url),
        }
    }
    let id = uuid::Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO ios_artist_subscriptions (id, user_id, channel_url, channel_name, channel_id, channel_thumbnail) VALUES ($1, $2, $3, $4, $5, $6)")
        .bind(&id)
        .bind(&u.id)
        .bind(&url)
        .bind(&name)
        .bind(&cid)
        .bind(&thumb)
        .execute(&st.db)
        .await?;
    Ok((StatusCode::CREATED, Json(json!({"id": id, "channel_url": url, "channel_name": name, "channel_id": cid, "channel_thumbnail": thumb}))).into_response())
}

fn frequency(avg: f64) -> &'static str {
    if avg <= 2.0 { "Uploads ~daily" } else if avg <= 10.0 { "Uploads ~weekly" } else if avg <= 20.0 { "Uploads ~every 2 weeks" } else if avg <= 45.0 { "Uploads ~monthly" } else if avg <= 100.0 { "Uploads every few months" } else { "Uploads rarely" }
}

const SUB_FIELDS: &str = "'id', s.id, 'channel_url', s.channel_url, 'channel_name', s.channel_name, 'last_video_id', s.last_video_id, \
    'last_checked_at', lumi_iso(s.last_checked_at), 'created_at', lumi_iso(s.created_at), 'channel_id', s.channel_id, 'channel_thumbnail', s.channel_thumbnail, \
    'auto_download', COALESCE(s.auto_download, false), 'destination_folder', s.destination_folder, 'notifications_muted', COALESCE(s.notifications_muted, false), 'category', s.category";

async fn list_subs(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let rows: Vec<(Value, i64, Option<i64>, Option<i32>)> = sqlx::query_as(&format!(
        "SELECT json_build_object({SUB_FIELDS}), COUNT(h.id), (EXTRACT(EPOCH FROM (MAX(h.discovered_at) - MIN(h.discovered_at))) / 86400)::bigint, \
           CASE WHEN MAX(h.discovered_at) IS NOT NULL THEN EXTRACT(DAY FROM (NOW() - MAX(h.discovered_at)))::int ELSE EXTRACT(DAY FROM (NOW() - s.created_at))::int END \
         FROM ios_artist_subscriptions s LEFT JOIN ios_subscription_upload_history h ON h.subscription_id = s.id WHERE s.user_id = $1 GROUP BY s.id ORDER BY s.created_at DESC"
    ))
    .bind(&u.id)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(Value::Array(
        rows.into_iter()
            .map(|(mut v, n, span_days, since)| {
                let label = match span_days {
                    Some(d) if n >= 2 && d > 0 => Some(frequency(d as f64 / (n - 1) as f64)),
                    _ => None,
                };
                v["upload_frequency_label"] = json!(label);
                v["is_stale"] = json!(since.is_some_and(|d| d >= 90));
                v["days_since_activity"] = json!(since);
                v
            })
            .collect(),
    )))
}

#[derive(Deserialize)]
struct SubSettings {
    auto_download: Option<bool>,
    destination_folder: Option<String>,
    notifications_muted: Option<bool>,
    category: Option<String>,
}

async fn update_sub(State(st): State<AppState>, u: User, Path(id): Path<String>, J(b): J<SubSettings>) -> ApiResult<Json<Value>> {
    if b.auto_download.is_none() && b.destination_folder.is_none() && b.notifications_muted.is_none() && b.category.is_none() {
        return Err(AppError::bad_request("No settings provided"));
    }
    let blank = |s: &Option<String>| s.as_ref().map(|x| if x.trim().is_empty() { None } else { Some(x.clone()) });
    let cat = b.category.as_ref().map(|x| if x.trim().is_empty() { None } else { Some(x.trim().to_string()) });
    sqlx::query(
        "UPDATE ios_artist_subscriptions SET auto_download = COALESCE($1, auto_download), \
           destination_folder = CASE WHEN $2 THEN $3 ELSE destination_folder END, notifications_muted = COALESCE($4, notifications_muted), \
           category = CASE WHEN $5 THEN $6 ELSE category END WHERE id = $7 AND user_id = $8",
    )
    .bind(b.auto_download)
    .bind(b.destination_folder.is_some())
    .bind(blank(&b.destination_folder).flatten())
    .bind(b.notifications_muted)
    .bind(b.category.is_some())
    .bind(cat.flatten())
    .bind(&id)
    .bind(&u.id)
    .execute(&st.db)
    .await?;
    let v: Option<Value> = sqlx::query_scalar(&format!("SELECT json_build_object({SUB_FIELDS}) FROM ios_artist_subscriptions s WHERE s.id = $1 AND s.user_id = $2"))
        .bind(&id)
        .bind(&u.id)
        .fetch_optional(&st.db)
        .await?;
    v.map(Json).ok_or_else(|| AppError::not_found("Subscription not found"))
}

async fn delete_sub(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<StatusCode> {
    let r = sqlx::query("DELETE FROM ios_artist_subscriptions WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).execute(&st.db).await?;
    if r.rows_affected() == 0 {
        return Err(AppError::not_found("Subscription not found"));
    }
    Ok(StatusCode::NO_CONTENT)
}

/// `_check_subscription_core`: newest uploads up to the last seen one.
pub async fn check_subscription(st: &AppState, id: &str, user: &str, url: &str, name: Option<&str>, last: Option<&str>, cid: Option<&str>, muted: bool) -> ApiResult<Vec<Value>> {
    let mut tracks: Vec<Value> = Vec::new();
    if let Some(c) = cid.filter(|c| !c.is_empty()) {
        let key = user_yt_key(st, user).await;
        if !key.is_empty() {
            match st.yt.channel_uploads(c, 5, &key).await {
                Ok(t) => tracks = t,
                Err(e) => tracing::warn!("check_subscription: API failed for {c:?}, falling back to yt-dlp: {e}"),
            }
        }
        if tracks.is_empty() {
            tracks = uploads_ytdlp(st, c, 5, user).await.unwrap_or_default();
        }
    }
    if tracks.is_empty() {
        let mut a: Vec<String> = vec![url.into(), "--dump-json".into(), "--flat-playlist".into(), "--playlist-end".into(), "5".into(), "--cache-dir".into(), st.cfg.ytdlp_cache_dir.clone()];
        a.extend(st.ytdlp.cookie_args(Some(user), false).await);
        let e = st.ytdlp.run_json(&a, Duration::from_secs(30)).await.map_err(|e| {
            tracing::warn!("check_subscription: yt-dlp failed for {url:?}: {e}");
            AppError::new(502, "Could not resolve channel")
        })?;
        tracks = e.iter().map(|x| parse_track(x, "youtube")).collect();
    }
    let mut new = Vec::new();
    if let Some(l) = last {
        for t in &tracks {
            if t["id"].as_str() == Some(l) {
                break;
            }
            new.push(t.clone());
        }
    }
    let latest = tracks.first().and_then(|t| t["id"].as_str().map(str::to_string)).or(last.map(str::to_string));
    sqlx::query("UPDATE ios_artist_subscriptions SET last_video_id = $1, last_checked_at = NOW() WHERE id = $2").bind(&latest).bind(id).execute(&st.db).await?;
    for t in &new {
        sqlx::query("INSERT INTO ios_subscription_upload_history (id, subscription_id, video_id) VALUES ($1, $2, $3)")
            .bind(uuid::Uuid::new_v4().to_string())
            .bind(id)
            .bind(t["id"].as_str())
            .execute(&st.db)
            .await?;
        sqlx::query("INSERT INTO ios_subscription_feed (id, subscription_id, user_id, track_json) VALUES ($1, $2, $3, $4)")
            .bind(uuid::Uuid::new_v4().to_string())
            .bind(id)
            .bind(user)
            .bind(t.to_string())
            .execute(&st.db)
            .await?;
        if !muted {
            let _ = st
                .create_notification(user, "new_upload", &format!("New from {}", name.filter(|n| !n.is_empty()).unwrap_or("a channel you follow")),
                    t["title"].as_str().unwrap_or(""), json!({"track": t, "subscription_id": id}), false)
                .await;
        }
    }
    if !new.is_empty() {
        sqlx::query(
            "DELETE FROM ios_subscription_feed WHERE user_id = $1 AND id NOT IN (SELECT id FROM ios_subscription_feed WHERE user_id = $1 ORDER BY discovered_at DESC LIMIT 300)",
        )
        .bind(user)
        .execute(&st.db)
        .await?;
        if !muted {
            st.fire_user_webhooks(user, "new_upload", json!({"subscription_id": id, "channel_name": name, "tracks": new})).await;
        }
    }
    Ok(new)
}

async fn check_sub(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    let row: Option<(String, Option<String>, Option<String>, Option<String>, Option<bool>)> =
        sqlx::query_as("SELECT channel_url, channel_name, last_video_id, channel_id, notifications_muted FROM ios_artist_subscriptions WHERE id = $1 AND user_id = $2")
            .bind(&id)
            .bind(&u.id)
            .fetch_optional(&st.db)
            .await?;
    let (url, name, last, cid, muted) = row.ok_or_else(|| AppError::not_found("Subscription not found"))?;
    let new = check_subscription(&st, &id, &u.id, &url, name.as_deref(), last.as_deref(), cid.as_deref(), muted.unwrap_or(false)).await?;
    Ok(Json(json!({"new_tracks": new})))
}

async fn feed(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(50);
    check_range("limit", limit, 1, 200)?;
    let rows: Vec<(String, String, Option<String>, Option<String>, Option<bool>, Option<String>, Option<String>)> = sqlx::query_as(
        "SELECT f.id, f.subscription_id, f.track_json, lumi_iso(f.discovered_at), f.is_read, s.channel_name, s.channel_thumbnail FROM ios_subscription_feed f \
         JOIN ios_artist_subscriptions s ON s.id = f.subscription_id WHERE f.user_id = $1 AND (NOT $2 OR f.is_read = FALSE) ORDER BY f.discovered_at DESC LIMIT $3",
    )
    .bind(&u.id)
    .bind(p.unread_only.unwrap_or(false))
    .bind(limit)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(Value::Array(
        rows.into_iter()
            .map(|r| json!({"id": r.0, "subscription_id": r.1, "track": r.2.and_then(|t| serde_json::from_str::<Value>(&t).ok()), "discovered_at": r.3,
                "is_read": r.4.unwrap_or(false), "channel_name": r.5, "channel_thumbnail": r.6}))
            .collect(),
    )))
}

async fn feed_read_all(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    sqlx::query("UPDATE ios_subscription_feed SET is_read = TRUE WHERE user_id = $1 AND is_read = FALSE").bind(&u.id).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn feed_read(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<StatusCode> {
    let r = sqlx::query("UPDATE ios_subscription_feed SET is_read = TRUE WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).execute(&st.db).await?;
    if r.rows_affected() == 0 {
        return Err(AppError::not_found("Feed item not found"));
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn feed_dismiss(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<StatusCode> {
    let r = sqlx::query("DELETE FROM ios_subscription_feed WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).execute(&st.db).await?;
    if r.rows_affected() == 0 {
        return Err(AppError::not_found("Feed item not found"));
    }
    Ok(StatusCode::NO_CONTENT)
}

// ---- podcasts --------------------------------------------------------------------------------

const ITUNES: &str = "http://www.itunes.com/dtds/podcast-1.0.dtd";
const PODNS: &str = "https://podcastindex.org/namespace/1.0";

async fn fetch_text(st: &AppState, url: &str) -> anyhow::Result<String> {
    Ok(st.http.get(url).header("User-Agent", "Lumisound-Bridge/1.0").timeout(Duration::from_secs(20)).send().await?.error_for_status()?.text().await?)
}

fn child<'a>(n: roxmltree::Node<'a, 'a>, ns: Option<&str>, name: &str) -> Option<roxmltree::Node<'a, 'a>> {
    n.children().find(|c| c.is_element() && c.tag_name().name() == name && c.tag_name().namespace() == ns)
}

fn text_of(n: roxmltree::Node, ns: Option<&str>, name: &str) -> Option<String> {
    child(n, ns, name).map(|c| c.descendants().filter(|d| d.is_text()).map(|d| d.text().unwrap_or("")).collect::<String>())
}

fn itunes_duration(raw: &str) -> Option<i64> {
    if raw.is_empty() {
        return None;
    }
    if raw.chars().all(|c| c.is_ascii_digit()) {
        return raw.parse().ok();
    }
    let mut s = 0i64;
    for p in raw.split(':') {
        s = s * 60 + p.parse::<i64>().ok()?;
    }
    Some(s)
}

/// (channel meta, episodes) from an RSS document.
fn parse_feed(xml: &str, limit: usize) -> anyhow::Result<(Value, Vec<Value>)> {
    let doc = roxmltree::Document::parse_with_options(xml, roxmltree::ParsingOptions { allow_dtd: true, ..Default::default() })?;
    let channel = child(doc.root_element(), None, "channel").ok_or_else(|| anyhow::anyhow!("Not a valid RSS feed (no <channel>)"))?;
    let title = text_of(channel, None, "title").unwrap_or_default().trim().to_string();
    let mut art = child(channel, None, "image").and_then(|i| text_of(i, None, "url")).map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
    if art.is_none() {
        art = child(channel, Some(ITUNES), "image").and_then(|i| i.attribute("href").map(str::to_string));
    }
    let meta = json!({"title": if title.is_empty() { None } else { Some(title) }, "artwork_url": art});
    let mut eps = Vec::new();
    for item in channel.children().filter(|c| c.is_element() && c.tag_name().name() == "item" && c.tag_name().namespace().is_none()).take(limit) {
        let Some(audio) = child(item, None, "enclosure").and_then(|e| e.attribute("url")).filter(|u| !u.is_empty()) else { continue };
        let guid = text_of(item, None, "guid").map(|g| g.trim().to_string()).filter(|g| !g.is_empty()).unwrap_or_else(|| audio.to_string());
        let published = text_of(item, None, "pubDate")
            .and_then(|d| chrono::DateTime::parse_from_rfc2822(d.trim()).ok())
            .map(|d| {
                let naive = crate::db::py_iso(&d.naive_local());
                format!("{naive}{}", d.format("%:z"))
            });
        let desc = text_of(item, None, "description").filter(|s| !s.is_empty()).or_else(|| text_of(item, Some(ITUNES), "summary")).unwrap_or_default();
        eps.push(json!({
            "guid": guid,
            "title": text_of(item, None, "title").unwrap_or_default().trim(),
            "description": desc.trim(),
            "audio_url": audio,
            "duration_seconds": itunes_duration(text_of(item, Some(ITUNES), "duration").unwrap_or_default().trim()),
            "published_at": published,
            "chapters_url": child(item, Some(PODNS), "chapters").and_then(|c| c.attribute("url")),
        }));
    }
    Ok((meta, eps))
}

async fn subscribe_core(st: &AppState, user: &str, url: &str) -> ApiResult<Value> {
    reject_ssrf(url).await?;
    let xml = fetch_text(st, url).await.map_err(|e| AppError::bad_request(format!("Couldn't read that feed: {e}")))?;
    let (meta, _) = parse_feed(&xml, 0).map_err(|e| AppError::bad_request(format!("Couldn't read that feed: {e}")))?;
    Ok(sqlx::query_scalar(
        "INSERT INTO ios_podcast_subscriptions (id, user_id, feed_url, title, artwork_url) VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (user_id, feed_url) DO UPDATE SET title = EXCLUDED.title, artwork_url = EXCLUDED.artwork_url \
         RETURNING json_build_object('id', id, 'feed_url', feed_url, 'title', title, 'artwork_url', artwork_url, 'added_at', lumi_iso(added_at))",
    )
    .bind(uuid::Uuid::new_v4().to_string())
    .bind(user)
    .bind(url)
    .bind(meta["title"].as_str())
    .bind(meta["artwork_url"].as_str())
    .fetch_one(&st.db)
    .await?)
}

#[derive(Deserialize)]
struct FeedBody {
    feed_url: String,
}

async fn subscribe_podcast(State(st): State<AppState>, u: User, J(b): J<FeedBody>) -> ApiResult<Response> {
    Ok((StatusCode::CREATED, Json(subscribe_core(&st, &u.id, &b.feed_url).await?)).into_response())
}

async fn list_podcasts(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('id', id, 'feed_url', feed_url, 'title', title, 'artwork_url', artwork_url, 'added_at', lumi_iso(added_at), \
               'notifications_muted', COALESCE(notifications_muted, false)) ORDER BY added_at DESC), '[]'::json) FROM ios_podcast_subscriptions WHERE user_id = $1",
        )
        .bind(&u.id)
        .fetch_one(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
struct MuteBody {
    notifications_muted: bool,
}

async fn update_podcast(State(st): State<AppState>, u: User, Path(id): Path<String>, J(b): J<MuteBody>) -> ApiResult<Json<Value>> {
    sqlx::query("UPDATE ios_podcast_subscriptions SET notifications_muted = $1 WHERE id = $2 AND user_id = $3").bind(b.notifications_muted).bind(&id).bind(&u.id).execute(&st.db).await?;
    Ok(Json(json!({"status": "updated"})))
}

async fn unsubscribe_podcast(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM ios_podcast_subscriptions WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn podcast_episodes(State(st): State<AppState>, _u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let url = p.feed_url.ok_or_else(|| invalid("feed_url", "Field required"))?;
    let limit = p.limit.unwrap_or(50);
    check_range("limit", limit, 1, 200)?;
    reject_ssrf(&url).await?;
    let xml = fetch_text(&st, &url).await.map_err(|e| AppError::bad_request(format!("Couldn't read that feed: {e}")))?;
    let (_, eps) = parse_feed(&xml, limit as usize).map_err(|e| AppError::bad_request(format!("Couldn't read that feed: {e}")))?;
    Ok(Json(Value::Array(eps)))
}

async fn podcast_chapters(State(st): State<AppState>, _u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let url = p.chapters_url.ok_or_else(|| invalid("chapters_url", "Field required"))?;
    reject_ssrf(&url).await?;
    let d: Value = serde_json::from_str(&fetch_text(&st, &url).await.map_err(|e| AppError::bad_request(format!("Couldn't read chapters: {e}")))?)
        .map_err(|e| AppError::bad_request(format!("Couldn't read chapters: {e}")))?;
    let out: Vec<Value> = d["chapters"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|e| e.get("startTime").is_some() && e.get("title").is_some())
        .filter_map(|e| {
            let start = match &e["startTime"] { Value::Number(n) => n.as_f64(), Value::String(s) => s.trim().parse().ok(), _ => None }?;
            let title = match &e["title"] { Value::String(s) => s.trim().to_string(), v => v.to_string() };
            Some(json!({"start_time_seconds": start, "title": title, "image_url": e.get("img").cloned().unwrap_or(Value::Null)}))
        })
        .collect();
    Ok(Json(Value::Array(out)))
}

#[derive(Deserialize)]
struct ProgressBody {
    feed_url: String,
    episode_guid: String,
    title: Option<String>,
    #[serde(default)]
    position_seconds: f64,
    #[serde(default)]
    duration_seconds: f64,
    #[serde(default)]
    completed: bool,
}

async fn put_progress(State(st): State<AppState>, u: User, J(b): J<ProgressBody>) -> ApiResult<StatusCode> {
    sqlx::query(
        "INSERT INTO ios_podcast_episode_progress (user_id, feed_url, episode_guid, title, position_seconds, duration_seconds, completed) VALUES ($1, $2, $3, $4, $5, $6, $7) \
         ON CONFLICT (user_id, feed_url, episode_guid) DO UPDATE SET title = EXCLUDED.title, position_seconds = EXCLUDED.position_seconds, \
           duration_seconds = EXCLUDED.duration_seconds, completed = EXCLUDED.completed, updated_at = NOW()",
    )
    .bind(&u.id)
    .bind(&b.feed_url)
    .bind(&b.episode_guid)
    .bind(&b.title)
    .bind(b.position_seconds)
    .bind(b.duration_seconds)
    .bind(b.completed)
    .execute(&st.db)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn get_progress(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(50);
    check_range("limit", limit, 1, 200)?;
    const ROW: &str = "json_build_object('episode_guid', episode_guid, 'feed_url', feed_url, 'title', title, 'position_seconds', position_seconds, \
        'duration_seconds', duration_seconds, 'completed', completed, 'updated_at', lumi_iso(updated_at))";
    let v: Value = match p.feed_url.filter(|f| !f.is_empty()) {
        Some(f) => sqlx::query_scalar(&format!("SELECT COALESCE(json_agg({ROW} ORDER BY updated_at DESC), '[]'::json) FROM ios_podcast_episode_progress WHERE user_id = $1 AND feed_url = $2"))
            .bind(&u.id)
            .bind(&f)
            .fetch_one(&st.db)
            .await?,
        None => sqlx::query_scalar(&format!(
            "SELECT COALESCE(json_agg(r ORDER BY at DESC), '[]'::json) FROM (SELECT {ROW} AS r, updated_at AS at FROM ios_podcast_episode_progress \
             WHERE user_id = $1 AND completed = FALSE AND position_seconds > 5 ORDER BY updated_at DESC LIMIT $2) x"
        ))
        .bind(&u.id)
        .bind(limit)
        .fetch_one(&st.db)
        .await?,
    };
    Ok(Json(v))
}

fn xml_attr(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\n', "&#10;").replace('\r', "&#13;").replace('\t', "&#09;")
}

async fn export_opml(State(st): State<AppState>, u: User) -> ApiResult<Response> {
    let rows: Vec<(String, Option<String>)> = sqlx::query_as("SELECT feed_url, title FROM ios_podcast_subscriptions WHERE user_id = $1 ORDER BY added_at").bind(&u.id).fetch_all(&st.db).await?;
    let mut s = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\"><head><title>Lumisound Podcast Subscriptions</title></head>");
    if rows.is_empty() {
        s.push_str("<body /></opml>");
        return Ok(([(header::CONTENT_TYPE, "text/x-opml+xml; charset=utf-8")], s).into_response());
    }
    s.push_str("<body>");
    for (url, title) in &rows {
        let text = title.as_deref().filter(|t| !t.is_empty()).unwrap_or(url);
        s.push_str(&format!("<outline type=\"rss\" text=\"{}\" xmlUrl=\"{}\" />", xml_attr(text), xml_attr(url)));
    }
    s.push_str("</body></opml>");
    Ok(([(header::CONTENT_TYPE, "text/x-opml+xml; charset=utf-8")], s).into_response())
}

#[derive(Deserialize)]
struct OpmlBody {
    opml: String,
}

async fn import_opml(State(st): State<AppState>, u: User, J(b): J<OpmlBody>) -> ApiResult<Json<Value>> {
    let urls: Vec<String> = {
        let doc = roxmltree::Document::parse(&b.opml).map_err(|e| AppError::bad_request(format!("Couldn't parse OPML: {e}")))?;
        doc.descendants().filter(|n| n.is_element() && n.tag_name().name() == "outline").filter_map(|n| n.attribute("xmlUrl").filter(|u| !u.is_empty()).map(str::to_string)).collect()
    };
    let (mut added, mut failed) = (0, 0);
    for url in urls.iter().take(100) {
        match subscribe_core(&st, &u.id, url).await {
            Ok(_) => added += 1,
            Err(_) => failed += 1,
        }
    }
    Ok(Json(json!({"added": added, "failed": failed, "total": urls.len()})))
}

async fn search_podcasts(State(st): State<AppState>, _u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let q = p.q.ok_or_else(|| invalid("q", "Field required"))?;
    if q.is_empty() || q.chars().count() > 200 {
        return Err(invalid("q", "String should have between 1 and 200 characters"));
    }
    let limit = p.limit.unwrap_or(20);
    check_range("limit", limit, 1, 50)?;
    let d: Value = async {
        st.http.get("https://itunes.apple.com/search").query(&[("term", q.as_str()), ("media", "podcast"), ("limit", &limit.to_string())])
            .header("User-Agent", "Lumisound-Bridge/1.0").timeout(Duration::from_secs(15)).send().await?.error_for_status()?.json().await
    }
    .await
    .map_err(|e: reqwest::Error| AppError::new(502, format!("Podcast search failed: {e}")))?;
    Ok(Json(Value::Array(
        d["results"].as_array().into_iter().flatten().filter(|r| r["feedUrl"].is_string())
            .map(|r| json!({"title": r.get("collectionName").filter(|v| !v.is_null()).or(r.get("trackName")).cloned().unwrap_or(Value::Null),
                "artist": r.get("artistName").cloned().unwrap_or(Value::Null), "feed_url": r["feedUrl"],
                "artwork_url": r.get("artworkUrl600").filter(|v| !v.is_null()).or(r.get("artworkUrl100")).cloned().unwrap_or(Value::Null)}))
            .collect(),
    )))
}

async fn trending_podcasts(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(20);
    check_range("limit", limit, 1, 50)?;
    let fail = |e: String| AppError::new(502, format!("Trending podcasts fetch failed: {e}"));
    let get = |url: String| {
        let http = st.http.clone();
        async move { http.get(url).header("User-Agent", "Lumisound-Bridge/1.0").timeout(Duration::from_secs(15)).send().await?.error_for_status()?.json::<Value>().await }
    };
    let chart = get(format!("https://itunes.apple.com/us/rss/toppodcasts/limit={limit}/json")).await.map_err(|e| fail(e.to_string()))?;
    let mut ids = Vec::new();
    let mut meta = std::collections::HashMap::new();
    for e in chart["feed"]["entry"].as_array().into_iter().flatten() {
        let Some(id) = e["id"]["attributes"]["im:id"].as_str() else { continue };
        ids.push(id.to_string());
        let art = e["im:image"].as_array().and_then(|a| a.last()).and_then(|i| i["label"].as_str().map(str::to_string));
        meta.insert(id.to_string(), json!({"title": e["im:name"]["label"], "artist": e["im:artist"]["label"], "artwork_url": art}));
    }
    if ids.is_empty() {
        return Ok(Json(json!([])));
    }
    let lookup = get(format!("https://itunes.apple.com/lookup?id={}&entity=podcast", ids.join(","))).await.map_err(|e| fail(e.to_string()))?;
    let feeds: std::collections::HashMap<String, String> = lookup["results"].as_array().into_iter().flatten()
        .filter_map(|r| Some((r["collectionId"].as_i64().map(|i| i.to_string()).or(r["collectionId"].as_str().map(str::to_string))?, r["feedUrl"].as_str()?.to_string())))
        .collect();
    let subscribed: std::collections::HashSet<String> =
        sqlx::query_scalar("SELECT feed_url FROM ios_podcast_subscriptions WHERE user_id = $1").bind(&u.id).fetch_all(&st.db).await?.into_iter().collect();
    Ok(Json(Value::Array(
        ids.iter().filter_map(|id| {
            let f = feeds.get(id)?;
            if subscribed.contains(f) {
                return None;
            }
            let mut m = meta[id].clone();
            m["feed_url"] = json!(f);
            Some(m)
        }).collect(),
    )))
}

pub async fn check_podcast(st: &AppState, id: &str, user: &str, url: &str, title: Option<&str>, last: Option<&str>, muted: bool) {
    let fetched = async {
        reject_ssrf(url).await.map_err(|_| anyhow::anyhow!("ssrf"))?;
        parse_feed(&fetch_text(st, url).await?, 10)
    }
    .await;
    let eps = match fetched {
        Ok((_, e)) => e,
        Err(_) => {
            tracing::warn!("podcast polling: failed to fetch feed {url:?} for subscription {id}");
            let _ = sqlx::query("UPDATE ios_podcast_subscriptions SET last_checked_at = NOW() WHERE id = $1").bind(id).execute(&st.db).await;
            return;
        }
    };
    let mut new = Vec::new();
    if let Some(l) = last {
        for e in &eps {
            if e["guid"].as_str() == Some(l) {
                break;
            }
            new.push(e.clone());
        }
    }
    let latest = eps.first().and_then(|e| e["guid"].as_str().map(str::to_string)).or(last.map(str::to_string));
    let _ = sqlx::query("UPDATE ios_podcast_subscriptions SET last_episode_guid = $1, last_checked_at = NOW() WHERE id = $2").bind(&latest).bind(id).execute(&st.db).await;
    if let (Some(n), false) = (new.first(), muted) {
        let _ = st
            .create_notification(user, "new_episode", &format!("New episode from {}", title.filter(|t| !t.is_empty()).unwrap_or("a podcast you follow")),
                n["title"].as_str().unwrap_or(""), json!({"feed_url": url, "episode": n}), false)
            .await;
        tracing::info!("podcast polling: {} new episode(s) for subscription {id} (user {user})", new.len());
    }
}

// ---- push tokens / devices / transfer --------------------------------------------------------

#[derive(Deserialize)]
struct PushBody {
    device_token: String,
    #[serde(default = "ios")]
    platform: String,
    device_name: Option<String>,
}

fn ios() -> String {
    "ios".into()
}

async fn register_push(State(st): State<AppState>, u: User, J(b): J<PushBody>) -> ApiResult<Response> {
    sqlx::query(
        "INSERT INTO ios_push_tokens (user_id, device_token, platform, device_name, last_seen_at) VALUES ($1, $2, $3, $4, NOW()) \
         ON CONFLICT (user_id, device_token) DO UPDATE SET platform = EXCLUDED.platform, device_name = COALESCE(EXCLUDED.device_name, ios_push_tokens.device_name), last_seen_at = NOW()",
    )
    .bind(&u.id)
    .bind(&b.device_token)
    .bind(&b.platform)
    .bind(&b.device_name)
    .execute(&st.db)
    .await?;
    ev(&st, "push", "push_token_registered", &u.id, Some(json!({"platform": b.platform}))).await;
    Ok((StatusCode::CREATED, Json(json!({"status": "ok"}))).into_response())
}

async fn unregister_push(State(st): State<AppState>, u: User, Path(t): Path<String>) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM ios_push_tokens WHERE user_id = $1 AND device_token = $2").bind(&u.id).bind(&t).execute(&st.db).await?;
    ev(&st, "push", "push_token_unregistered", &u.id, None).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn devices(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('device_token', device_token, 'platform', platform, 'device_name', device_name, \
               'last_seen_at', lumi_iso(last_seen_at)) ORDER BY last_seen_at DESC), '[]'::json) FROM ios_push_tokens WHERE user_id = $1",
        )
        .bind(&u.id)
        .fetch_one(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
struct TransferBody {
    target_device_token: String,
    song_id: Option<String>,
    title: String,
    artist: Option<String>,
    track_url: Option<String>,
    source: Option<String>,
    source_id: Option<String>,
    thumbnail_url: Option<String>,
    #[serde(default)]
    position_seconds: f64,
    #[serde(default)]
    duration_seconds: f64,
    #[serde(default = "yes")]
    is_playing: bool,
    bpm: Option<f64>,
}

fn yes() -> bool {
    true
}

async fn transfer(State(st): State<AppState>, u: User, J(b): J<TransferBody>) -> ApiResult<StatusCode> {
    sqlx::query(
        "INSERT INTO ios_playback_state (user_id, song_id, title, artist, track_url, source, position_seconds, duration_seconds, is_playing, bpm, updated_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, CURRENT_TIMESTAMP) ON CONFLICT (user_id) DO UPDATE SET song_id = EXCLUDED.song_id, title = EXCLUDED.title, \
           artist = EXCLUDED.artist, track_url = EXCLUDED.track_url, source = EXCLUDED.source, position_seconds = EXCLUDED.position_seconds, \
           duration_seconds = EXCLUDED.duration_seconds, is_playing = EXCLUDED.is_playing, bpm = EXCLUDED.bpm, updated_at = EXCLUDED.updated_at",
    )
    .bind(&u.id)
    .bind(&b.song_id)
    .bind(&b.title)
    .bind(&b.artist)
    .bind(&b.track_url)
    .bind(&b.source)
    .bind(b.position_seconds)
    .bind(b.duration_seconds)
    .bind(b.is_playing)
    .bind(b.bpm)
    .execute(&st.db)
    .await?;
    let platform: Option<Option<String>> =
        sqlx::query_scalar("SELECT platform FROM ios_push_tokens WHERE user_id = $1 AND device_token = $2").bind(&u.id).bind(&b.target_device_token).fetch_optional(&st.db).await?;
    let platform = platform.ok_or_else(|| AppError::not_found("Target device not found"))?;
    let data = json!({"song_id": b.song_id, "title": b.title, "artist": b.artist, "track_url": b.track_url, "source": b.source, "source_id": b.source_id,
        "thumbnail_url": b.thumbnail_url, "position_seconds": b.position_seconds, "is_playing": b.is_playing});
    let body = format!("Now playing: {}", b.title);
    if platform.as_deref() == Some("android") {
        if st.push.has_fcm() {
            st.push.fcm(&b.target_device_token, "playback_transfer", "Playback Transferred", &body, &data, true).await;
        }
    } else if st.push.has_apns() {
        st.push
            .apns(&b.target_device_token, &json!({"aps": {"alert": {"title": "Playback Transferred", "body": body}, "sound": "default", "content-available": 1},
                "type": "playback_transfer", "data": data}))
            .await;
    }
    Ok(StatusCode::NO_CONTENT)
}

// ---- notifications / announcements -----------------------------------------------------------

async fn notifications(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(50);
    check_range("limit", limit, 1, 200)?;
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(r ORDER BY at DESC), '[]'::json) FROM (SELECT json_build_object('id', id, 'type', type, 'title', title, 'body', body, \
               'data', COALESCE(NULLIF(data_json, '')::json, '{}'::json), 'created_at', lumi_iso(created_at), 'read_at', lumi_iso(read_at)) AS r, created_at AS at \
             FROM ios_notifications WHERE user_id = $1 AND (NOT $2 OR read_at IS NULL) ORDER BY created_at DESC LIMIT $3) x",
        )
        .bind(&u.id)
        .bind(p.unread_only.unwrap_or(false))
        .bind(limit)
        .fetch_one(&st.db)
        .await?,
    ))
}

async fn read_one(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<StatusCode> {
    let r = sqlx::query("UPDATE ios_notifications SET read_at = NOW() WHERE id = $1 AND user_id = $2 AND read_at IS NULL").bind(&id).bind(&u.id).execute(&st.db).await?;
    if r.rows_affected() == 0 {
        let e: Option<i32> = sqlx::query_scalar("SELECT 1 FROM ios_notifications WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).fetch_optional(&st.db).await?;
        if e.is_none() {
            return Err(AppError::not_found("Notification not found"));
        }
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn read_all(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    sqlx::query("UPDATE ios_notifications SET read_at = NOW() WHERE user_id = $1 AND read_at IS NULL").bind(&u.id).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn announcements(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('id', a.id, 'message', a.message, 'from_aria', COALESCE(a.from_aria, false), 'category', a.category, \
               'ends_at', lumi_iso(a.ends_at)) ORDER BY a.created_at), '[]'::json) FROM ios_announcements a \
             LEFT JOIN ios_announcement_views v ON v.announcement_id = a.id AND v.user_id = $1 WHERE v.user_id IS NULL AND NOW() >= a.starts_at AND NOW() < a.ends_at \
               AND POSITION($2 IN ',' || COALESCE(a.exclude_user_ids, '') || ',') = 0",
        )
        .bind(&u.id)
        .bind(format!(",{},", u.id))
        .fetch_one(&st.db)
        .await?,
    ))
}

async fn announcement_seen(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<StatusCode> {
    sqlx::query("INSERT INTO ios_announcement_views (announcement_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING").bind(&id).bind(&u.id).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn admin_announcements(State(st): State<AppState>, _a: Admin) -> ApiResult<Json<Value>> {
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(r ORDER BY at DESC), '[]'::json) FROM (SELECT json_build_object('id', a.id, 'message', a.message, 'from_aria', COALESCE(a.from_aria, false), \
           'category', a.category, 'starts_at', lumi_iso(a.starts_at), 'ends_at', lumi_iso(a.ends_at), \
           'excluded', COALESCE((SELECT json_agg(x) FROM unnest(string_to_array(COALESCE(a.exclude_user_ids, ''), ',')) x WHERE x <> ''), '[]'::json), \
           'active', COALESCE(NOW() < a.ends_at AND NOW() >= a.starts_at, false), \
           'seen_by', (SELECT COUNT(*) FROM ios_announcement_views v WHERE v.announcement_id = a.id)) AS r, a.created_at AS at \
         FROM ios_announcements a ORDER BY a.created_at DESC LIMIT 100) x",
    )
    .fetch_one(&st.db)
    .await?;
    Ok(Json(v))
}

#[derive(Deserialize)]
struct AnnBody {
    message: String,
    #[serde(default = "three")]
    days: f64,
    #[serde(default = "yes")]
    from_aria: bool,
    #[serde(default = "info")]
    category: String,
    exclude_user_ids: Option<Vec<String>>,
}

fn three() -> f64 {
    3.0
}
fn info() -> String {
    "info".into()
}

async fn admin_create_announcement(State(st): State<AppState>, _a: Admin, J(b): J<AnnBody>) -> ApiResult<Response> {
    let msg = b.message.trim().to_string();
    if msg.is_empty() {
        return Err(AppError::bad_request("message must not be empty"));
    }
    if msg.chars().count() > 280 {
        return Err(AppError::bad_request("message must be 280 characters or fewer"));
    }
    if !(b.days > 0.0 && b.days <= 90.0) {
        return Err(AppError::bad_request("days must be > 0 and <= 90"));
    }
    let cat = b.category.to_lowercase();
    if !["success", "error", "warning", "info", "download"].contains(&cat.as_str()) {
        return Err(AppError::bad_request("category must be one of: download, error, info, success, warning"));
    }
    let excluded: Vec<String> = b.exclude_user_ids.unwrap_or_else(|| vec![OPERATOR_USER_ID.into()]).into_iter().filter(|s| !s.is_empty() && !s.contains(',')).map(|s| s.trim().to_string()).collect();
    let id = uuid::Uuid::new_v4().simple().to_string();
    let ends = Utc::now().naive_utc() + CDuration::microseconds((b.days * 86400e6) as i64);
    sqlx::query("INSERT INTO ios_announcements (id, message, from_aria, category, ends_at, exclude_user_ids) VALUES ($1, $2, $3, $4, $5, $6)")
        .bind(&id)
        .bind(&msg)
        .bind(b.from_aria)
        .bind(&cat)
        .bind(ends)
        .bind(excluded.join(","))
        .execute(&st.db)
        .await?;
    tracing::info!("announcement created id={id} days={:.1} excluded={}", b.days, excluded.len());
    Ok((StatusCode::CREATED, Json(json!({"id": id, "ends_at": crate::db::py_iso(&ends), "excluded": excluded}))).into_response())
}

async fn admin_delete_announcement(State(st): State<AppState>, _a: Admin, Path(id): Path<String>) -> ApiResult<StatusCode> {
    let r = sqlx::query("DELETE FROM ios_announcements WHERE id = $1").bind(&id).execute(&st.db).await?;
    if r.rows_affected() == 0 {
        return Err(AppError::not_found("Announcement not found"));
    }
    Ok(StatusCode::NO_CONTENT)
}

// ---- webhooks --------------------------------------------------------------------------------

#[derive(Deserialize)]
struct WebhookBody {
    event_type: String,
    webhook_url: String,
}

async fn create_webhook(State(st): State<AppState>, u: User, J(b): J<WebhookBody>) -> ApiResult<Response> {
    const TYPES: [&str; 4] = ["download_complete", "duplicate_found", "new_upload", "playlist_update"];
    if !TYPES.contains(&b.event_type.as_str()) {
        return Err(AppError::bad_request(format!("event_type must be one of ['{}']", TYPES.join("', '"))));
    }
    reject_ssrf(&b.webhook_url).await?;
    let id = uuid::Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO ios_user_webhooks (id, user_id, event_type, webhook_url) VALUES ($1, $2, $3, $4)").bind(&id).bind(&u.id).bind(&b.event_type).bind(&b.webhook_url).execute(&st.db).await?;
    ev(&st, "webhooks", "webhook_created", &u.id, Some(json!({"webhook_id": id, "event_type": b.event_type}))).await;
    Ok((StatusCode::CREATED, Json(json!({"id": id}))).into_response())
}

async fn list_webhooks(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('id', id, 'event_type', event_type, 'webhook_url', webhook_url, 'enabled', COALESCE(enabled, false), \
           'created_at', lumi_iso(created_at))), '[]'::json) FROM ios_user_webhooks WHERE user_id = $1",
    )
    .bind(&u.id)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"webhooks": v})))
}

async fn delete_webhook(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<StatusCode> {
    let r = sqlx::query("DELETE FROM ios_user_webhooks WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).execute(&st.db).await?;
    if r.rows_affected() == 0 {
        return Err(AppError::not_found("Webhook not found"));
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn get_discord_webhook(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let row: Option<(String, Option<bool>)> = sqlx::query_as("SELECT webhook_url, enabled FROM ios_discord_webhooks WHERE user_id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    Ok(Json(match row {
        None => json!({"configured": false, "enabled": false, "webhook_url": null}),
        Some((url, en)) => {
            let m = if url.chars().count() > 48 { format!("{}...", url.chars().take(48).collect::<String>()) } else { url };
            json!({"configured": true, "enabled": en.unwrap_or(false), "webhook_url": m})
        }
    }))
}

#[derive(Deserialize)]
struct DiscordHookBody {
    webhook_url: Option<String>,
    #[serde(default = "yes")]
    enabled: bool,
}

async fn put_discord_webhook(State(st): State<AppState>, u: User, J(b): J<DiscordHookBody>) -> ApiResult<Json<Value>> {
    match &b.webhook_url {
        Some(url) => {
            let p = url::Url::parse(url).ok();
            let host_ok = p.as_ref().is_some_and(|p| p.scheme() == "https" && matches!(p.host_str(), Some("discord.com" | "discordapp.com" | "canary.discord.com" | "ptb.discord.com")));
            if !host_ok {
                return Err(AppError::bad_request("webhook_url must be an https://discord.com/api/webhooks/... URL"));
            }
            if !p.unwrap().path().contains("/api/webhooks/") {
                return Err(AppError::bad_request("webhook_url does not look like a webhook URL"));
            }
            sqlx::query("INSERT INTO ios_discord_webhooks (user_id, webhook_url, enabled) VALUES ($1, $2, $3) ON CONFLICT (user_id) DO UPDATE SET webhook_url = EXCLUDED.webhook_url, enabled = EXCLUDED.enabled")
                .bind(&u.id)
                .bind(url)
                .bind(b.enabled)
                .execute(&st.db)
                .await?;
        }
        None => {
            let r = sqlx::query("UPDATE ios_discord_webhooks SET enabled = $1 WHERE user_id = $2").bind(b.enabled).bind(&u.id).execute(&st.db).await?;
            if r.rows_affected() == 0 {
                return Err(AppError::bad_request("webhook_url is required"));
            }
        }
    }
    ev(&st, "webhooks", "discord_webhook_set", &u.id, Some(json!({"url_changed": b.webhook_url.is_some(), "enabled": b.enabled}))).await;
    Ok(Json(json!({"status": "ok"})))
}

async fn delete_discord_webhook(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM ios_discord_webhooks WHERE user_id = $1").bind(&u.id).execute(&st.db).await?;
    ev(&st, "webhooks", "discord_webhook_removed", &u.id, None).await;
    Ok(StatusCode::NO_CONTENT)
}

// ---- Discord RPC -----------------------------------------------------------------------------

#[derive(Deserialize, Default)]
struct RpcTokenBody {
    device_name: Option<String>,
}

async fn rpc_token(State(st): State<AppState>, u: User, body: axum::body::Bytes) -> ApiResult<Json<Value>> {
    let b: RpcTokenBody = if body.is_empty() { RpcTokenBody::default() } else { serde_json::from_slice(&body).unwrap_or_default() };
    let device = b.device_name.as_deref().map(str::trim).filter(|d| !d.is_empty()).map(|d| d.chars().take(200).collect::<String>()).unwrap_or_else(|| "Discord RPC Bridge".into());
    let cur = u.token_id.clone().unwrap_or_default();
    let mut tx = st.db.begin().await?;
    let expired = sqlx::query("DELETE FROM ios_user_sessions WHERE user_id = $1 AND expires_at <= NOW()").bind(&u.id).execute(&mut *tx).await?.rows_affected();
    let stale = sqlx::query(
        "DELETE FROM ios_user_sessions WHERE user_id = $1 AND device_name LIKE '%(setup)' AND created_at < NOW() - (15 * INTERVAL '1 minute') AND token_id <> $2",
    )
    .bind(&u.id)
    .bind(&cur)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    let superseded = sqlx::query("DELETE FROM ios_user_sessions WHERE user_id = $1 AND device_name = $2 AND token_id <> $3").bind(&u.id).bind(&device).bind(&cur).execute(&mut *tx).await?.rows_affected();
    let tid = uuid::Uuid::new_v4().to_string();
    let expires = Utc::now().naive_utc() + CDuration::days(365);
    sqlx::query("INSERT INTO ios_user_sessions (token_id, user_id, expires_at, device_name) VALUES ($1, $2, $3, $4)").bind(&tid).bind(&u.id).bind(expires).bind(&device).execute(&mut *tx).await?;
    tx.commit().await?;
    if expired + stale + superseded > 0 {
        st.session_cache.clear();
        tracing::info!("rpc-token housekeeping for user {}: {expired} expired, {stale} stale setup, {superseded} superseded ({device:?})", u.id);
    }
    Ok(Json(json!({"token": st.keys.create_token(&u.id, &tid, 365), "expires_at": format!("{}+00:00", crate::db::py_iso(&expires)), "device_name": device,
        "cleaned_up": {"expired": expired, "stale_setup": stale, "superseded": superseded}})))
}

async fn get_rpc(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let row: Option<(Option<String>, Option<String>, Option<bool>, Option<String>, Option<bool>)> =
        sqlx::query_as("SELECT discord_client_id, large_image, enabled, small_image, show_buttons FROM ios_discord_rpc_config WHERE user_id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    let Some((cid, large, en, small, buttons)) = row else {
        return Ok(Json(json!({"configured": false, "enabled": false, "discord_client_id": null, "large_image": null, "small_image": null, "show_buttons": true, "is_custom": false})));
    };
    let custom = cid.is_some();
    Ok(Json(json!({
        "configured": true, "enabled": en.unwrap_or(false),
        "discord_client_id": cid.filter(|c| !c.is_empty()).or(st.cfg.discord_rpc_default_client_id.clone()),
        "large_image": if custom { large } else { st.cfg.discord_rpc_default_large_image.clone() },
        "small_image": if custom { small } else { st.cfg.discord_rpc_default_small_image.clone() },
        "show_buttons": buttons.unwrap_or(false), "is_custom": custom,
    })))
}

#[derive(Deserialize)]
struct RpcBody {
    discord_client_id: Option<String>,
    large_image: Option<String>,
    small_image: Option<String>,
    #[serde(default = "yes")]
    show_buttons: bool,
    #[serde(default = "yes")]
    enabled: bool,
}

async fn put_rpc(State(st): State<AppState>, u: User, J(b): J<RpcBody>) -> ApiResult<Json<Value>> {
    let cid = match b.discord_client_id.as_deref().filter(|c| !c.is_empty()) {
        Some(c) if (15..=25).contains(&c.len()) && c.chars().all(|x| x.is_ascii_digit()) => Some(c.to_string()),
        Some(_) => return Err(AppError::bad_request("discord_client_id must be a numeric Discord application ID")),
        None => None,
    };
    sqlx::query(
        "INSERT INTO ios_discord_rpc_config (user_id, discord_client_id, large_image, small_image, show_buttons, enabled) VALUES ($1, $2, $3, $4, $5, $6) \
         ON CONFLICT (user_id) DO UPDATE SET discord_client_id = EXCLUDED.discord_client_id, large_image = EXCLUDED.large_image, small_image = EXCLUDED.small_image, \
           show_buttons = EXCLUDED.show_buttons, enabled = EXCLUDED.enabled",
    )
    .bind(&u.id)
    .bind(&cid)
    .bind(&b.large_image)
    .bind(&b.small_image)
    .bind(b.show_buttons)
    .bind(b.enabled)
    .execute(&st.db)
    .await?;
    ev(&st, "settings", "discord_rpc_config_set", &u.id, Some(json!({"enabled": b.enabled, "is_custom": cid.is_some()}))).await;
    Ok(Json(json!({"status": "ok"})))
}

async fn delete_rpc(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM ios_discord_rpc_config WHERE user_id = $1").bind(&u.id).execute(&st.db).await?;
    ev(&st, "settings", "discord_rpc_config_removed", &u.id, None).await;
    Ok(StatusCode::NO_CONTENT)
}

// ---- API keys --------------------------------------------------------------------------------

#[derive(Deserialize)]
struct KeyBody {
    api_key: Option<String>,
}

async fn get_key(st: &AppState, user: &str, col: &str) -> ApiResult<Json<Value>> {
    let k: Option<Option<String>> = sqlx::query_scalar(&format!("SELECT {col} FROM ios_user_settings WHERE user_id = $1")).bind(user).fetch_optional(&st.db).await?;
    Ok(Json(match k.flatten().filter(|k| !k.is_empty()) {
        None => json!({"configured": false, "api_key": null}),
        Some(k) => json!({"configured": true, "api_key": mask(&k)}),
    }))
}

async fn set_key(st: &AppState, user: &str, col: &str, b: KeyBody, event: &str) -> ApiResult<Json<Value>> {
    let k = b.api_key.filter(|k| !k.is_empty()).ok_or_else(|| AppError::bad_request("api_key is required"))?;
    sqlx::query(&format!("INSERT INTO ios_user_settings (user_id, {col}) VALUES ($1, $2) ON CONFLICT (user_id) DO UPDATE SET {col} = EXCLUDED.{col}"))
        .bind(user)
        .bind(&k)
        .execute(&st.db)
        .await?;
    st.yt.forget_user_key(user);
    ev(st, "settings", event, user, None).await;
    Ok(Json(json!({"status": "ok"})))
}

async fn clear_key(st: &AppState, user: &str, col: &str, event: &str) -> ApiResult<StatusCode> {
    sqlx::query(&format!("UPDATE ios_user_settings SET {col} = NULL WHERE user_id = $1")).bind(user).execute(&st.db).await?;
    st.yt.forget_user_key(user);
    ev(st, "settings", event, user, None).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn get_yt_key(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    get_key(&st, &u.id, "youtube_api_key").await
}
async fn put_yt_key(State(st): State<AppState>, u: User, J(b): J<KeyBody>) -> ApiResult<Json<Value>> {
    set_key(&st, &u.id, "youtube_api_key", b, "youtube_api_key_set").await
}
async fn delete_yt_key(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    clear_key(&st, &u.id, "youtube_api_key", "youtube_api_key_removed").await
}
async fn get_aid_key(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    get_key(&st, &u.id, "acoustid_api_key").await
}
async fn put_aid_key(State(st): State<AppState>, u: User, J(b): J<KeyBody>) -> ApiResult<Json<Value>> {
    set_key(&st, &u.id, "acoustid_api_key", b, "acoustid_api_key_set").await
}
async fn delete_aid_key(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    clear_key(&st, &u.id, "acoustid_api_key", "acoustid_api_key_removed").await
}

// ---- yt-dlp cookies --------------------------------------------------------------------------

struct Cookie {
    domain: String,
    expiry: i64,
    name: String,
}

fn parse_netscape(text: &str) -> Vec<Cookie> {
    text.lines()
        .filter_map(|raw| {
            let mut line = raw.trim();
            if line.is_empty() {
                return None;
            }
            if line.starts_with('#') {
                line = line.strip_prefix("#HttpOnly_")?;
            }
            let p: Vec<&str> = line.split('\t').collect();
            if p.len() != 7 {
                return None;
            }
            Some(Cookie { domain: p[0].into(), expiry: if p[4].chars().all(|c| c.is_ascii_digit()) && !p[4].is_empty() { p[4].parse().unwrap_or(0) } else { 0 }, name: p[5].into() })
        })
        .collect()
}

async fn cookies_status(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let row: Option<(bool, Option<String>)> = sqlx::query_as("SELECT ytdlp_cookies IS NOT NULL, lumi_iso(ytdlp_cookies_updated_at) FROM ios_user_settings WHERE user_id = $1")
        .bind(&u.id)
        .fetch_optional(&st.db)
        .await?;
    Ok(Json(match row {
        Some((true, at)) => json!({"configured": true, "updated_at": at}),
        _ => json!({"configured": false, "updated_at": null}),
    }))
}

#[derive(Deserialize)]
struct CookiesBody {
    cookies_text: String,
}

fn drop_cookie_file(st: &AppState, user: &str) {
    let _ = std::fs::remove_file(std::path::Path::new(&st.cfg.ytdlp_user_cookies_dir).join(format!("{user}.txt")));
    st.ytdlp.invalidate_user_cookies(user);
}

async fn put_cookies(State(st): State<AppState>, u: User, J(b): J<CookiesBody>) -> ApiResult<Json<Value>> {
    let t = b.cookies_text.trim();
    if t.is_empty() {
        return Err(AppError::bad_request("cookies_text is required"));
    }
    if t.chars().count() > 2_000_000 {
        return Err(AppError::new(413, "Cookie file is too large"));
    }
    if parse_netscape(t).is_empty() {
        return Err(AppError::bad_request("Not a valid Netscape cookies.txt export"));
    }
    sqlx::query(
        "INSERT INTO ios_user_settings (user_id, ytdlp_cookies, ytdlp_cookies_updated_at) VALUES ($1, $2, CURRENT_TIMESTAMP) \
         ON CONFLICT (user_id) DO UPDATE SET ytdlp_cookies = EXCLUDED.ytdlp_cookies, ytdlp_cookies_updated_at = CURRENT_TIMESTAMP",
    )
    .bind(&u.id)
    .bind(t)
    .execute(&st.db)
    .await?;
    drop_cookie_file(&st, &u.id);
    Ok(Json(json!({"status": "ok"})))
}

async fn delete_cookies(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    sqlx::query("UPDATE ios_user_settings SET ytdlp_cookies = NULL, ytdlp_cookies_updated_at = NULL WHERE user_id = $1").bind(&u.id).execute(&st.db).await?;
    drop_cookie_file(&st, &u.id);
    Ok(StatusCode::NO_CONTENT)
}

async fn get_pref(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let created: Option<Option<chrono::NaiveDateTime>> = sqlx::query_scalar("SELECT created_at FROM ios_users WHERE id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    let age = created.flatten().map(|c| (Utc::now().naive_utc() - c).num_days());
    Ok(Json(json!({"preference": st.ytdlp.cookie_fallback_preference(&u.id).await, "eligible": age.is_some_and(|a| a >= 15), "account_age_days": age,
        "days_until_eligible": age.map(|a| (15 - a).max(0))})))
}

#[derive(Deserialize)]
struct PrefBody {
    preference: String,
}

async fn put_pref(State(st): State<AppState>, u: User, J(b): J<PrefBody>) -> ApiResult<Json<Value>> {
    if !["auto", "own_only", "global_only"].contains(&b.preference.as_str()) {
        return Err(AppError::bad_request("preference must be one of: auto, own_only, global_only"));
    }
    sqlx::query("INSERT INTO ios_user_settings (user_id, cookie_fallback_preference) VALUES ($1, $2) ON CONFLICT (user_id) DO UPDATE SET cookie_fallback_preference = EXCLUDED.cookie_fallback_preference")
        .bind(&u.id)
        .bind(&b.preference)
        .execute(&st.db)
        .await?;
    st.ytdlp.invalidate_user_cookies(&u.id);
    Ok(Json(json!({"status": "ok", "preference": b.preference})))
}

async fn validate_cookies(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let text: Option<Option<String>> = sqlx::query_scalar("SELECT ytdlp_cookies FROM ios_user_settings WHERE user_id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    let Some(text) = text.flatten().filter(|t| !t.trim().is_empty()) else {
        return Ok(Json(json!({"status": "missing", "detail": "No cookies uploaded.", "missing": ["cookies.txt file"], "age_restriction_ready": false, "cookie_count": 0})));
    };
    let cookies = parse_netscape(&text);
    if cookies.is_empty() {
        return Ok(Json(json!({"status": "invalid", "detail": "File isn't a valid Netscape cookies.txt export.", "missing": [], "age_restriction_ready": false, "cookie_count": 0})));
    }
    let yt: Vec<&Cookie> = cookies.iter().filter(|c| c.domain.contains("youtube.com") || c.domain.contains("google.com")).collect();
    if yt.is_empty() {
        return Ok(Json(json!({"status": "invalid", "detail": "No youtube.com/google.com cookies found in this file.", "missing": ["youtube.com cookies"], "age_restriction_ready": false, "cookie_count": 0})));
    }
    let now = Utc::now().timestamp();
    let names: std::collections::HashSet<&str> = yt.iter().map(|c| c.name.as_str()).collect();
    let expired: std::collections::HashSet<&str> = yt.iter().filter(|c| c.expiry != 0 && c.expiry < now).map(|c| c.name.as_str()).collect();
    const SESSION: [&str; 9] = ["SID", "HSID", "SSID", "APISID", "SAPISID", "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID"];
    let present: Vec<&str> = SESSION.iter().copied().filter(|n| names.contains(n)).collect();
    let age_ready = names.contains("LOGIN_INFO") && !expired.contains("LOGIN_INFO");
    let mut missing = Vec::new();
    if present.is_empty() {
        missing.push("Sign-in session cookies (SID/HSID/SSID/APISID/SAPISID or the __Secure- variants)");
    }
    if !age_ready {
        missing.push("LOGIN_INFO (required to unlock age-restricted videos)");
    }
    let (mut status, mut detail) = if present.is_empty() {
        ("incomplete", "Missing required sign-in cookies — re-export cookies.txt while logged into YouTube (not in a private/incognito or guest session).")
    } else if present.iter().any(|n| expired.contains(n)) {
        ("expired", "Your session cookies have expired — re-export a fresh cookies.txt.")
    } else if !age_ready {
        ("valid_no_age_restriction", "Cookies are valid for normal downloads, but missing LOGIN_INFO — age-restricted videos will likely still fail. Make sure you're fully logged in (not a guest session) when exporting.")
    } else {
        ("valid", "Cookies look complete, including age-restriction support.")
    };
    if status == "valid" || status == "valid_no_age_restriction" {
        let path = std::path::Path::new(&st.cfg.ytdlp_user_cookies_dir).join(format!("{}.txt", u.id));
        let _ = std::fs::create_dir_all(&st.cfg.ytdlp_user_cookies_dir);
        let ok = if std::fs::write(&path, &text).is_ok() {
            let a: Vec<String> = ["--dump-json", "--no-playlist", "--simulate", "--skip-download", "--cookies", &path.to_string_lossy(), "https://www.youtube.com/watch?v=jNQXAC9IVRw"]
                .map(String::from)
                .to_vec();
            st.ytdlp.run_json(&a, Duration::from_secs(20)).await.map(|e| !e.is_empty()).unwrap_or(false)
        } else {
            false
        };
        if !ok {
            status = "invalid";
            detail = "yt-dlp rejected these cookies when actually used — they may be expired, revoked, or exported from a session that was since signed out.";
        }
    }
    Ok(Json(json!({"status": status, "detail": detail, "missing": missing, "age_restriction_ready": age_ready, "cookie_count": yt.len()})))
}

// ---- GIF search ------------------------------------------------------------------------------

fn gif_item(i: &Value) -> Option<Value> {
    let im = &i["images"];
    let full = [&im["downsized"], &im["fixed_height"], &im["original"]].into_iter().find(|x| x.is_object()).cloned().unwrap_or(json!({}));
    full["url"].as_str().filter(|u| !u.is_empty())?;
    let prev = [&im["fixed_height_small"], &im["fixed_width_small"]].into_iter().find(|x| x.is_object()).cloned().unwrap_or(full.clone());
    let int = |v: &Value| v.as_i64().or_else(|| v.as_str().and_then(|s| s.parse().ok()));
    Some(json!({"id": i["id"].as_str().unwrap_or(""), "description": i["title"].as_str().unwrap_or(""), "preview_url": prev["url"], "gif_url": full["url"],
        "width": int(&full["width"]), "height": int(&full["height"])}))
}

async fn giphy(st: &AppState, path: &str, params: &[(&str, String)]) -> ApiResult<Vec<Value>> {
    let key = st.cfg.giphy_api_key.clone().ok_or_else(|| AppError::new(501, "GIF search isn't configured on this server."))?;
    let mut q: Vec<(&str, String)> = params.to_vec();
    q.push(("api_key", key));
    q.push(("rating", "pg-13".into()));
    let d: Value = async {
        st.http.get(format!("https://api.giphy.com/v1/gifs/{path}")).query(&q).header("User-Agent", "Mozilla/5.0").timeout(Duration::from_secs(10)).send().await?.error_for_status()?.json().await
    }
    .await
    .map_err(|e: reqwest::Error| {
        tracing::warn!("GIPHY GIF request failed ({path}): {e}");
        AppError::new(502, "GIF search is temporarily unavailable.")
    })?;
    Ok(d["data"].as_array().into_iter().flatten().filter_map(gif_item).collect())
}

fn gif_variants(q: &str) -> Vec<String> {
    const STOP: &[&str] = &["a", "an", "the", "of", "for", "with", "my", "your", "his", "her", "their", "this", "that", "these", "those", "some", "any", "please",
        "looking", "look", "need", "want", "like", "from", "pic", "pics", "picture", "pictures", "pfp", "photo", "photos", "image", "images", "avatar", "icon",
        "wallpaper", "gif", "gifs", "me", "to", "find", "get", "show"];
    let words: Vec<&str> = q.split_whitespace().collect();
    let kept: Vec<&str> = words.iter().copied().filter(|w| !STOP.contains(&w.to_lowercase().trim_matches(|c: char| c.is_ascii_punctuation()))).collect();
    let mut out: Vec<String> = Vec::new();
    for c in [q.to_string(), kept.join(" ")] {
        if !c.is_empty() && !out.contains(&c) {
            out.push(c);
        }
    }
    let mut tail = kept.clone();
    while tail.len() > 1 && out.len() < 5 {
        tail.pop();
        let c = tail.join(" ");
        if !out.contains(&c) {
            out.push(c);
        }
    }
    out.truncate(5);
    out
}

async fn gif_search(State(st): State<AppState>, _u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let q = p.q.ok_or_else(|| invalid("q", "Field required"))?;
    if q.is_empty() || q.chars().count() > 100 {
        return Err(invalid("q", "String should have between 1 and 100 characters"));
    }
    let (limit, offset) = (p.limit.unwrap_or(30), p.offset.unwrap_or(0));
    check_range("limit", limit, 1, 50)?;
    check_range("offset", offset, 0, 4975)?;
    let mut results = Vec::new();
    for v in gif_variants(&q) {
        results = giphy(&st, "search", &[("q", v), ("limit", limit.to_string()), ("offset", offset.to_string())]).await?;
        if !results.is_empty() {
            break;
        }
    }
    Ok(Json(json!({"results": results})))
}

async fn gif_trending(State(st): State<AppState>, _u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let (limit, offset) = (p.limit.unwrap_or(30), p.offset.unwrap_or(0));
    check_range("limit", limit, 1, 50)?;
    check_range("offset", offset, 0, 4975)?;
    Ok(Json(json!({"results": giphy(&st, "trending", &[("limit", limit.to_string()), ("offset", offset.to_string())]).await?})))
}

/// Subscription / tracked playlist / podcast polling (every 30 min).
pub async fn subscription_loop(st: AppState) {
    loop {
        tokio::time::sleep(Duration::from_secs(1800)).await;
        type S = (String, String, String, Option<String>, Option<String>, Option<String>, Option<bool>);
        let subs: Vec<S> = sqlx::query_as(
            "SELECT id, user_id, channel_url, channel_name, last_video_id, channel_id, notifications_muted FROM ios_artist_subscriptions \
             WHERE last_checked_at IS NULL OR last_checked_at < NOW() - make_interval(hours => 4) ORDER BY last_checked_at IS NULL DESC, last_checked_at ASC LIMIT 10",
        )
        .fetch_all(&st.db)
        .await
        .unwrap_or_default();
        for (id, user, url, name, last, cid, muted) in subs {
            match check_subscription(&st, &id, &user, &url, name.as_deref(), last.as_deref(), cid.as_deref(), muted.unwrap_or(false)).await {
                Ok(n) if !n.is_empty() => tracing::info!("subscription polling: {} new track(s) for subscription {id} (user {user})", n.len()),
                Err(e) => tracing::error!("subscription polling: check failed for subscription {id}: {:?}", e.detail),
                _ => {}
            }
        }
        let pls: Vec<(String, String, String, i64)> = sqlx::query_as(
            "SELECT p.id, p.user_id, p.source_url, COUNT(t.id) FROM ios_user_playlists p LEFT JOIN ios_playlist_tracks t ON t.playlist_id = p.id \
             WHERE p.source_url IS NOT NULL AND (p.source_checked_at IS NULL OR p.source_checked_at < NOW() - make_interval(hours => 4)) \
             GROUP BY p.id, p.user_id, p.source_url ORDER BY p.source_checked_at IS NULL DESC, p.source_checked_at ASC LIMIT 10",
        )
        .fetch_all(&st.db)
        .await
        .unwrap_or_default();
        for (pid, user, url, local) in pls {
            match crate::routes::social::refresh_source(&st, &pid, &user, &url, local, true).await {
                Ok(r) if r["new_count"].as_i64().unwrap_or(0) > 0 => tracing::info!("playlist polling: {} new track(s) for playlist {pid} (user {user})", r["new_count"]),
                Err(e) => tracing::error!("playlist polling: refresh failed for playlist {pid}: {:?}", e.detail),
                _ => {}
            }
        }
        let pods: Vec<(String, String, String, Option<String>, Option<String>, Option<bool>)> = sqlx::query_as(
            "SELECT id, user_id, feed_url, title, last_episode_guid, notifications_muted FROM ios_podcast_subscriptions \
             WHERE last_checked_at IS NULL OR last_checked_at < NOW() - make_interval(hours => 6) ORDER BY last_checked_at IS NULL DESC, last_checked_at ASC LIMIT 10",
        )
        .fetch_all(&st.db)
        .await
        .unwrap_or_default();
        for (id, user, url, title, last, muted) in pods {
            check_podcast(&st, &id, &user, &url, title.as_deref(), last.as_deref(), muted.unwrap_or(false)).await;
        }
    }
}
