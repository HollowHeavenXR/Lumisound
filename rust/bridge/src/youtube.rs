//! YouTube Data API v3 and Spotify Web API clients (metadata only).

use crate::cache::TtlCache;
use crate::ytdlp::strip_topic_suffix;
use dashmap::DashMap;
use serde_json::{Value, json};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const QUOTA_COOLDOWN: Duration = Duration::from_secs(3600);

#[derive(Debug)]
pub struct ApiError {
    pub status: u16,
    pub body: Value,
}

impl std::error::Error for ApiError {}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "HTTP {}", self.status)
    }
}

pub struct YouTube {
    http: reqwest::Client,
    quota_until: DashMap<String, Instant>,
    /// api key -> (pacific date, units used today)
    units: DashMap<String, (String, u64)>,
    key_cache: TtlCache<String, String>,
    spotify_token: Mutex<Option<(String, Instant)>>,
}

fn pacific_date() -> String {
    // America/Los_Angeles without a tz database: PDT (UTC-7) from the second
    // Sunday of March to the first Sunday of November, else PST (UTC-8).
    use chrono::{Datelike, Duration as D, NaiveDate, Utc, Weekday};
    let now = Utc::now().naive_utc();
    let y = now.year();
    let nth_sunday = |month: u32, n: u32| {
        let first = NaiveDate::from_ymd_opt(y, month, 1).unwrap();
        let offset = (7 + Weekday::Sun.num_days_from_monday() as i64 - first.weekday().num_days_from_monday() as i64) % 7;
        first + D::days(offset + 7 * (n as i64 - 1))
    };
    let dst_start = nth_sunday(3, 2).and_hms_opt(10, 0, 0).unwrap(); // 2am PST = 10:00 UTC
    let dst_end = nth_sunday(11, 1).and_hms_opt(9, 0, 0).unwrap(); // 2am PDT = 09:00 UTC
    let off = if now >= dst_start && now < dst_end { 7 } else { 8 };
    (now - D::hours(off)).format("%Y-%m-%d").to_string()
}

fn cost(path: &str) -> u64 {
    match path {
        "search" => 100,
        _ => 1,
    }
}

pub fn thumbnail_from_snippet(snippet: &Value) -> String {
    let t = &snippet["thumbnails"];
    for size in ["maxres", "standard", "high", "medium", "default"] {
        if t.get(size).is_some() {
            return t[size]["url"].as_str().unwrap_or("").to_string();
        }
    }
    String::new()
}

pub fn parse_iso8601_duration(d: &str) -> i64 {
    let Some(rest) = d.strip_prefix("PT") else { return 0 };
    let (mut total, mut num, mut seen) = (0i64, String::new(), String::new());
    for c in rest.chars() {
        if c.is_ascii_digit() {
            num.push(c);
            continue;
        }
        let n: i64 = match num.parse() {
            Ok(n) => n,
            Err(_) => return 0,
        };
        num.clear();
        let mult = match c {
            'H' if seen.is_empty() => 3600,
            'M' if !seen.contains('M') && !seen.contains('S') => 60,
            'S' if !seen.contains('S') => 1,
            _ => return 0,
        };
        seen.push(c);
        total += n * mult;
    }
    if !num.is_empty() { 0 } else { total }
}

pub fn extract_playlist_id(url: &str) -> Option<String> {
    let i = url.find("?list=").or_else(|| url.find("&list="))?;
    let id: String = url[i + 6..].chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').collect();
    if id.is_empty() { None } else { Some(id) }
}

pub enum ChannelRef {
    Id(String),
    Handle(String),
    Search(String),
}

/// `_YOUTUBE_CHANNEL_URL_RE`: channel/UC…, @handle, c/custom, user/name.
pub fn channel_url_match(q: &str) -> Option<ChannelRef> {
    let ok = |c: char| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-');
    for host in ["youtube.com/", "youtu.be/"] {
        let mut from = 0;
        while let Some(pos) = q[from..].find(host) {
            let rest = &q[from + pos + host.len()..];
            from += pos + host.len();
            if let Some(r) = rest.strip_prefix("channel/") {
                let id: String = r.chars().take(24).collect();
                if id.len() == 24
                    && id.starts_with("UC")
                    && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
                {
                    return Some(ChannelRef::Id(id));
                }
            } else if let Some(r) = rest.strip_prefix('@') {
                let h: String = r.chars().take_while(|c| ok(*c)).collect();
                if !h.is_empty() {
                    return Some(ChannelRef::Handle(h));
                }
            } else if let Some(r) = rest.strip_prefix("c/").or_else(|| rest.strip_prefix("user/")) {
                let s: String = r.chars().take_while(|c| ok(*c)).collect();
                if !s.is_empty() {
                    return Some(ChannelRef::Search(s));
                }
            }
        }
    }
    None
}

fn unescape_html(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let end = rest.find(';').filter(|e| *e <= 10);
        let Some(end) = end else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let ent = &rest[1..end];
        let rep = match ent {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some('\u{a0}'),
            _ if ent.starts_with("#x") || ent.starts_with("#X") => u32::from_str_radix(&ent[2..], 16).ok().and_then(char::from_u32),
            _ if ent.starts_with('#') => ent[1..].parse().ok().and_then(char::from_u32),
            _ => None,
        };
        match rep {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

impl YouTube {
    pub fn new(http: reqwest::Client) -> Self {
        Self {
            http,
            quota_until: DashMap::new(),
            units: DashMap::new(),
            key_cache: TtlCache::new(Duration::from_secs(300), 10_000),
            spotify_token: Mutex::new(None),
        }
    }

    pub fn cooling_down(&self, key: &str) -> bool {
        self.quota_until.get(key).is_some_and(|t| Instant::now() < *t)
    }

    pub fn mark_quota_exceeded(&self, key: &str) {
        self.quota_until.insert(key.to_string(), Instant::now() + QUOTA_COOLDOWN);
    }

    pub fn usage_today(&self, key: &str) -> u64 {
        let today = pacific_date();
        self.units.get(key).filter(|e| e.0 == today).map(|e| e.1).unwrap_or(0)
    }

    fn record(&self, path: &str, key: &str) {
        let today = pacific_date();
        let mut e = self.units.entry(key.to_string()).or_insert((today.clone(), 0));
        if e.0 != today {
            *e = (today, 0);
        }
        e.1 += cost(path);
    }

    /// Raw call: (status, body). Never errors on HTTP status.
    pub async fn get_raw(&self, path: &str, params: &[(&str, String)], key: &str) -> anyhow::Result<(u16, Value)> {
        self.record(path, key);
        let mut q: Vec<(&str, String)> = params.to_vec();
        q.push(("key", key.to_string()));
        let r = self
            .http
            .get(format!("https://www.googleapis.com/youtube/v3/{path}"))
            .query(&q)
            .timeout(Duration::from_secs(15))
            .send()
            .await?;
        let status = r.status().as_u16();
        let body = r.json::<Value>().await.unwrap_or_else(|_| json!({}));
        Ok((status, body))
    }

    /// Strict call: errors on non-2xx and starts the quota cooldown on quotaExceeded.
    pub async fn get(&self, path: &str, params: &[(&str, String)], key: &str) -> anyhow::Result<Value> {
        let (status, body) = self.get_raw(path, params, key).await?;
        if (200..300).contains(&status) {
            return Ok(body);
        }
        if status == 403 {
            let quota = body["error"]["errors"].as_array().is_some_and(|a| a.iter().any(|e| e["reason"] == "quotaExceeded"));
            if quota {
                self.mark_quota_exceeded(key);
            }
        }
        Err(ApiError { status, body }.into())
    }

    /// Per-user key (ios_user_settings.youtube_api_key), else the server key.
    pub async fn key_for_user(&self, db: &sqlx::PgPool, user_id: &str, server_key: Option<&str>) -> String {
        let k = user_id.to_string();
        if let Some(v) = self.key_cache.get(&k) {
            return v;
        }
        let own: Option<String> = sqlx::query_scalar("SELECT youtube_api_key FROM ios_user_settings WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(db)
            .await
            .ok()
            .flatten()
            .flatten();
        let key = own.filter(|s| !s.is_empty()).unwrap_or_else(|| server_key.unwrap_or("").to_string());
        self.key_cache.set(k, key.clone());
        key
    }

    pub fn forget_user_key(&self, user_id: &str) {
        self.key_cache.remove(&user_id.to_string());
    }

    async fn durations(&self, ids: &[String], key: &str) -> anyhow::Result<std::collections::HashMap<String, i64>> {
        let data = self.get("videos", &[("part", "contentDetails".into()), ("id", ids.join(","))], key).await?;
        Ok(data["items"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| Some((v["id"].as_str()?.to_string(), parse_iso8601_duration(v["contentDetails"]["duration"].as_str().unwrap_or("")))))
                    .collect()
            })
            .unwrap_or_default())
    }

    /// `_youtube_search_via_api_sync`. None = fall back to yt-dlp.
    pub async fn search(&self, query: &str, limit: usize, key: &str) -> Option<Vec<Value>> {
        if key.is_empty() {
            return None;
        }
        let params = [
            ("part", "snippet".to_string()),
            ("type", "video".into()),
            ("q", query.into()),
            ("maxResults", limit.clamp(1, 50).to_string()),
            ("order", "relevance".into()),
        ];
        let (status, body) = match self.get_raw("search", &params, key).await {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("YouTube Data API search failed, falling back to yt-dlp: {e}");
                return None;
            }
        };
        if status == 403 {
            let limited = body["error"]["errors"].as_array().is_some_and(|a| {
                a.iter().any(|e| matches!(e["reason"].as_str(), Some("quotaExceeded" | "dailyLimitExceeded" | "rateLimitExceeded")))
            });
            if limited {
                self.mark_quota_exceeded(key);
            }
            return None;
        }
        if status != 200 {
            return None;
        }
        let items: Vec<Value> = body["items"].as_array().cloned().unwrap_or_default();
        let ids: Vec<String> = items.iter().filter_map(|i| i["id"]["videoId"].as_str().map(str::to_string)).collect();
        if ids.is_empty() {
            return Some(vec![]);
        }
        let durations = self.durations_raw(&ids, key).await;
        Some(
            items
                .iter()
                .filter_map(|it| {
                    let vid = it["id"]["videoId"].as_str()?;
                    let sn = &it["snippet"];
                    Some(json!({
                        "id": vid,
                        "title": unescape_html(sn["title"].as_str().filter(|s| !s.is_empty()).unwrap_or("Unknown Title")),
                        "artist": unescape_html(sn["channelTitle"].as_str().filter(|s| !s.is_empty()).unwrap_or("Unknown Artist")),
                        "duration_seconds": durations.get(vid).copied().unwrap_or(0),
                        "thumbnail_url": thumbnail_from_snippet(sn),
                        "source": "youtube",
                        "youtube_url": format!("https://youtube.com/watch?v={vid}"),
                    }))
                })
                .collect(),
        )
    }

    async fn durations_raw(&self, ids: &[String], key: &str) -> std::collections::HashMap<String, i64> {
        match self.get_raw("videos", &[("part", "contentDetails".into()), ("id", ids.join(","))], key).await {
            Ok((200, b)) => b["items"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|v| Some((v["id"].as_str()?.to_string(), parse_iso8601_duration(v["contentDetails"]["duration"].as_str().unwrap_or("")))))
                        .collect()
                })
                .unwrap_or_default(),
            _ => Default::default(),
        }
    }

    /// `_resolve_youtube_playlist_via_api`: items shaped for parse_track.
    pub async fn playlist_items(&self, playlist_id: &str, limit: usize, key: &str) -> anyhow::Result<Vec<Value>> {
        if self.cooling_down(key) {
            anyhow::bail!("YouTube Data API key is in quota-exceeded cooldown");
        }
        let mut items: Vec<Value> = Vec::new();
        let mut page: Option<String> = None;
        while items.len() < limit {
            let mut p = vec![
                ("part", "snippet".to_string()),
                ("playlistId", playlist_id.to_string()),
                ("maxResults", (limit - items.len()).min(50).to_string()),
            ];
            if let Some(t) = &page {
                p.push(("pageToken", t.clone()));
            }
            let data = self.get("playlistItems", &p, key).await?;
            for it in data["items"].as_array().into_iter().flatten() {
                let sn = &it["snippet"];
                let Some(vid) = sn["resourceId"]["videoId"].as_str() else { continue };
                let title = sn["title"].as_str().unwrap_or("");
                if title == "Deleted video" || title == "Private video" {
                    continue;
                }
                let channel = sn["videoOwnerChannelTitle"].as_str().filter(|s| !s.is_empty()).or(sn["channelTitle"].as_str());
                items.push(json!({"id": vid, "title": title, "channel": channel, "thumbnail": thumbnail_from_snippet(sn)}));
            }
            page = data["nextPageToken"].as_str().map(str::to_string);
            if page.is_none() {
                break;
            }
        }
        for chunk in items.chunks_mut(50) {
            let ids: Vec<String> = chunk.iter().map(|i| i["id"].as_str().unwrap_or("").to_string()).collect();
            let d = self.durations(&ids, key).await?;
            for i in chunk.iter_mut() {
                let id = i["id"].as_str().unwrap_or("").to_string();
                i["duration"] = json!(d.get(&id).copied().unwrap_or(0));
            }
        }
        Ok(items)
    }

    /// `_resolve_youtube_channel`: Err((status, detail)) mirrors the HTTPExceptions.
    pub async fn resolve_channel(&self, query: &str, key: &str) -> Result<Value, (u16, String)> {
        if key.is_empty() {
            return Err((400, "No YouTube API key configured".into()));
        }
        let q = query.trim();
        let r = if let Some(m) = channel_url_match(q) {
            m
        } else if let Some(h) = q.strip_prefix('@') {
            ChannelRef::Handle(h.to_string())
        } else if q.starts_with("UC") && q.len() == 24 {
            ChannelRef::Id(q.to_string())
        } else {
            ChannelRef::Search(q.to_string())
        };
        let shaped = |id: &str, sn: &Value| json!({"channel_id": id, "channel_title": sn["title"].as_str().unwrap_or(""), "channel_thumbnail": thumbnail_from_snippet(sn)});
        let err500 = |e: anyhow::Error| (500u16, format!("{e}"));
        let search_term = match r {
            ChannelRef::Id(id) => {
                let (_, data) = self.get_raw("channels", &[("part", "snippet".into()), ("id", id.clone())], key).await.map_err(err500)?;
                let Some(first) = data["items"].as_array().and_then(|a| a.first()) else {
                    return Err((404, "Channel not found".into()));
                };
                return Ok(shaped(&id, &first["snippet"]));
            }
            ChannelRef::Handle(h) => {
                let (_, data) =
                    self.get_raw("channels", &[("part", "snippet".into()), ("forHandle", format!("@{h}"))], key).await.map_err(err500)?;
                if let Some(first) = data["items"].as_array().and_then(|a| a.first()) {
                    return Ok(shaped(first["id"].as_str().unwrap_or(""), &first["snippet"]));
                }
                h
            }
            ChannelRef::Search(s) => s,
        };
        if search_term.is_empty() {
            return Err((400, "Could not parse a channel from that input".into()));
        }
        let (_, data) = self
            .get_raw(
                "search",
                &[("part", "snippet".into()), ("type", "channel".into()), ("q", search_term), ("maxResults", "1".into())],
                key,
            )
            .await
            .map_err(err500)?;
        let Some(first) = data["items"].as_array().and_then(|a| a.first()) else {
            return Err((404, "No channel found for that search".into()));
        };
        Ok(shaped(first["id"]["channelId"].as_str().unwrap_or(""), &first["snippet"]))
    }

    /// `_channel_uploads_via_api`: client tracks.
    pub async fn channel_uploads(&self, channel_id: &str, max: usize, key: &str) -> anyhow::Result<Vec<Value>> {
        let data = self.get("channels", &[("part", "contentDetails,snippet".into()), ("id", channel_id.into())], key).await?;
        let Some(ch) = data["items"].as_array().and_then(|a| a.first()).cloned() else {
            anyhow::bail!("Channel {channel_id} not found");
        };
        let uploads = ch["contentDetails"]["relatedPlaylists"]["uploads"].as_str().map(str::to_string);
        let raw_title = ch["snippet"]["title"].as_str().filter(|s| !s.is_empty()).unwrap_or("Unknown Artist").to_string();
        let is_topic = raw_title.trim().ends_with(" - Topic");
        let channel_title = if is_topic { strip_topic_suffix(&raw_title) } else { raw_title.clone() };
        let Some(uploads) = uploads else { return Ok(vec![]) };
        let mut tracks: Vec<Value> = Vec::new();
        let mut page: Option<String> = None;
        while tracks.len() < max {
            let mut p = vec![
                ("part", "snippet".to_string()),
                ("playlistId", uploads.clone()),
                ("maxResults", (max - tracks.len()).min(50).to_string()),
            ];
            if let Some(t) = &page {
                p.push(("pageToken", t.clone()));
            }
            let data = self.get("playlistItems", &p, key).await?;
            for it in data["items"].as_array().into_iter().flatten() {
                let sn = &it["snippet"];
                let Some(vid) = sn["resourceId"]["videoId"].as_str() else { continue };
                let title = sn["title"].as_str().unwrap_or("");
                if title == "Deleted video" || title == "Private video" {
                    continue;
                }
                let raw_artist = sn["videoOwnerChannelTitle"].as_str().filter(|s| !s.is_empty()).unwrap_or(&raw_title);
                let track_topic = is_topic || raw_artist.trim().ends_with(" - Topic");
                let artist = if track_topic { strip_topic_suffix(raw_artist) } else if raw_artist.is_empty() { channel_title.clone() } else { raw_artist.to_string() };
                tracks.push(json!({
                    "id": vid,
                    "title": if title.is_empty() { "Unknown Title" } else { title },
                    "artist": if artist.is_empty() { channel_title.clone() } else { artist },
                    "duration_seconds": 0,
                    "thumbnail_url": thumbnail_from_snippet(sn),
                    "source": "youtube",
                    "youtube_url": format!("https://youtube.com/watch?v={vid}"),
                    "is_topic_channel": track_topic,
                }));
            }
            page = data["nextPageToken"].as_str().map(str::to_string);
            if page.is_none() {
                break;
            }
        }
        for chunk in tracks.chunks_mut(50) {
            let ids: Vec<String> = chunk.iter().map(|i| i["id"].as_str().unwrap_or("").to_string()).collect();
            match self.durations(&ids, key).await {
                Ok(d) => {
                    for t in chunk.iter_mut() {
                        let id = t["id"].as_str().unwrap_or("").to_string();
                        t["duration_seconds"] = json!(d.get(&id).copied().unwrap_or(0));
                    }
                }
                Err(e) => tracing::warn!("channel_uploads: duration batch fetch failed: {e}"),
            }
        }
        Ok(tracks)
    }

    // ---- Spotify (catalog metadata only) ------------------------------------------------

    async fn spotify_token(&self, id: &str, secret: &str) -> Option<String> {
        if let Some((t, exp)) = self.spotify_token.lock().unwrap().clone() {
            if Instant::now() < exp {
                return Some(t);
            }
        }
        let r = self
            .http
            .post("https://accounts.spotify.com/api/token")
            .basic_auth(id, Some(secret))
            .form(&[("grant_type", "client_credentials")])
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .ok()?;
        if !r.status().is_success() {
            tracing::warn!("Spotify token request failed: {}", r.status());
            return None;
        }
        let data: Value = r.json().await.ok()?;
        let token = data["access_token"].as_str()?.to_string();
        let ttl = (data["expires_in"].as_i64().unwrap_or(3600) - 60).max(60) as u64;
        *self.spotify_token.lock().unwrap() = Some((token.clone(), Instant::now() + Duration::from_secs(ttl)));
        Some(token)
    }

    pub async fn spotify_get(&self, id: &str, secret: &str, path: &str, params: &[(&str, String)]) -> Option<Value> {
        let token = self.spotify_token(id, secret).await?;
        let r = self
            .http
            .get(format!("https://api.spotify.com/v1/{path}"))
            .query(params)
            .bearer_auth(token)
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .ok()?;
        if !r.status().is_success() {
            tracing::warn!("Spotify Web API request failed ({path}): {}", r.status());
            return None;
        }
        r.json().await.ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn iso_duration() {
        assert_eq!(parse_iso8601_duration("PT1H2M3S"), 3723);
        assert_eq!(parse_iso8601_duration("PT4M"), 240);
        assert_eq!(parse_iso8601_duration("P1D"), 0);
    }
    #[test]
    fn playlist_id() {
        assert_eq!(extract_playlist_id("https://youtube.com/watch?v=a&list=PLx-1_2").as_deref(), Some("PLx-1_2"));
    }
    #[test]
    fn html() {
        assert_eq!(unescape_html("Rock &amp; Roll &#39;n&#x27;"), "Rock & Roll 'n'");
    }
}
