//! Social (route group 6): profiles, friends, blocks, presence, guestbook,
//! compatibility/blend, people recommendations, listening rooms, device
//! sync, playlist collaborators + tracked sources, avatars and banners.

use crate::auth::User;
use crate::error::{ApiResult, AppError};
use crate::extract::{J, Q, check_range, invalid};
use crate::state::AppState;
use crate::taste::{describe_sonic_match, fingerprint_summary, py_round_int};
use crate::ytdlp::parse_track;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, put};
use axum::{Json, Router};
use chrono::{Duration as CDuration, NaiveDate, Utc};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::time::Duration;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/social/activity", get(public_activity))
        .route("/social/discover", get(public_discover))
        .route("/social/similar-listeners", get(similar_listeners))
        .route("/social/trending-by-energy", get(trending_energy))
        .route("/user/social/twin", get(twin))
        .route("/user/social/twin/mix", get(twin_mix))
        .route("/user/avatar", post(upload_avatar))
        .route("/user/avatar/{user_id}", get(get_avatar))
        .route("/user/bio", get(get_bio).put(set_bio))
        .route("/api/social/fingerprint/{user_id}", get(fingerprint))
        .route("/api/social/profile/me", get(my_profile))
        .route("/api/social/profile", put(update_profile))
        .route("/api/social/profile/banner", post(upload_banner).delete(remove_banner))
        .route("/api/social/profile/banner/{user_id}", get(get_banner))
        .route("/api/social/profile/pinned-tracks", put(pinned_tracks))
        .route("/api/social/profile/featured-playlist", put(featured_playlist))
        .route("/api/social/profile/{user_id}", get(public_profile))
        .route("/api/social/profile/{user_id}/comments", get(list_comments).post(post_comment))
        .route("/api/social/profile/{user_id}/recently-played-together", get(played_together))
        .route("/api/social/profile/comments/{comment_id}", delete(delete_comment))
        .route("/api/social/users/search", get(search_users))
        .route("/api/social/friends", get(list_friends))
        .route("/api/social/friends/request", post(send_request))
        .route("/api/social/friends/request/{id}/accept", post(accept_request))
        .route("/api/social/friends/request/{id}/decline", post(decline_request))
        .route("/api/social/friends/request/{id}/cancel", post(cancel_request))
        .route("/api/social/friends/requests", get(list_requests))
        .route("/api/social/friends/suggestions", get(friend_suggestions))
        .route("/api/social/friends/tags", get(tag_names))
        .route("/api/social/friends/leaderboard", get(leaderboard))
        .route("/api/social/friends/{friend_id}", delete(remove_friend))
        .route("/api/social/friends/{friend_id}/nickname", put(set_nickname))
        .route("/api/social/friends/{friend_id}/tags", post(add_tag))
        .route("/api/social/friends/{friend_id}/tags/{tag}", delete(remove_tag))
        .route("/api/social/block", get(list_blocked))
        .route("/api/social/block/{user_id}", post(block).delete(unblock))
        .route("/api/social/presence", post(update_presence))
        .route("/api/social/presence/friends", get(friends_presence))
        .route("/api/social/presence/listening-together", get(listening_together))
        .route("/api/social/presence/{user_id}", get(user_presence))
        .route("/api/social/activity/friends", get(friends_activity))
        .route("/api/social/recommended-people", get(recommended_people))
        .route("/api/social/compatibility/{user_id}", get(compatibility))
        .route("/api/social/blend/{user_id}", get(blend))
        .route("/rooms", post(create_room))
        .route("/rooms/{code}", get(get_room).put(update_room).delete(close_room))
        .route("/rooms/{code}/join", post(join_room))
        .route("/rooms/{code}/heartbeat", post(room_heartbeat))
        .route("/rooms/{code}/leave", post(leave_room))
        .route("/rooms/{code}/events", get(room_events))
        .route("/rooms/{code}/chat", post(room_chat))
        .route("/rooms/{code}/react", post(room_react))
        .route("/rooms/{code}/queue", get(room_queue).post(add_room_queue))
        .route("/rooms/{code}/queue/{item}/vote", post(vote_room_queue))
        .route("/rooms/{code}/queue/{item}", delete(remove_room_queue))
        .route("/user/device-sync/start", post(device_sync_start))
        .route("/user/device-sync/active", get(device_sync_active))
        .route("/user/device-sync/stop", post(device_sync_stop))
        .route("/user/playlists/shared-with-me", get(shared_with_me))
        .route("/user/playlists/{id}/collaborators", get(list_collaborators).post(add_collaborator))
        .route("/user/playlists/{id}/collaborators/{uid}", delete(remove_collaborator))
        .route("/user/playlists/{id}/source", post(set_playlist_source))
        .route("/user/playlists/{id}/refresh", post(refresh_playlist_source))
}

#[derive(Deserialize, Default)]
struct P {
    limit: Option<i64>,
    days: Option<i64>,
    min_bpm: Option<f64>,
    q: Option<String>,
}

const PUB: &str = "json_build_object('user_id', u.id, 'username', u.username, 'display_name', u.display_name, 'avatar_url', u.avatar_url)";
const PRESENCE_FRESH: i64 = 90;
const ROOM_TTL_SECS: i32 = 90;
const ROOM_IDLE_HOURS: i32 = 12;
/// A device-sync room counts as live only while its host keeps updating it.
const DEVICE_SYNC_LIVE_SECS: i32 = 90;

fn ok() -> Json<Value> {
    Json(json!({"ok": true}))
}

fn now_utc_iso() -> String {
    format!("{}+00:00", crate::db::py_iso(&Utc::now().naive_utc()))
}

async fn blocked(st: &AppState, a: &str, b: &str) -> ApiResult<bool> {
    let r: Option<i32> = sqlx::query_scalar(
        "SELECT 1 FROM ios_social_blocks WHERE (user_id = $1 AND blocked_id = $2) OR (user_id = $2 AND blocked_id = $1) LIMIT 1",
    )
    .bind(a)
    .bind(b)
    .fetch_optional(&st.db)
    .await?;
    Ok(r.is_some())
}

async fn is_friend(st: &AppState, a: &str, b: &str) -> ApiResult<bool> {
    let r: Option<i32> = sqlx::query_scalar("SELECT 1 FROM ios_social_friends WHERE user_id = $1 AND friend_id = $2").bind(a).bind(b).fetch_optional(&st.db).await?;
    Ok(r.is_some())
}

async fn display_name(st: &AppState, id: &str) -> String {
    let r: Option<(String, Option<String>)> =
        sqlx::query_as("SELECT username, display_name FROM ios_users WHERE id = $1").bind(id).fetch_optional(&st.db).await.unwrap_or(None);
    r.map(|(u, d)| d.filter(|d| !d.is_empty()).unwrap_or(u)).unwrap_or_else(|| "Someone".into())
}

async fn notify(st: &AppState, to: &str, kind: &str, title: &str, body: &str, data: Value) {
    if let Err(e) = st.create_notification(to, kind, title, body, data, false).await {
        tracing::warn!("notification {kind} for {to} failed: {e}");
    }
}

// ---- public discovery (/social/*) ------------------------------------------------------------

async fn public_activity(State(st): State<AppState>, _u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(30);
    check_range("limit", limit, 1, 100)?;
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('username', username, 'display_name', display_name, 'avatar_url', avatar_url, \
           'title', title, 'artist', artist, 'played_at', lumi_iso(played_at)) ORDER BY played_at DESC), '[]'::json) FROM \
         (SELECT u.username, u.display_name, u.avatar_url, h.title, h.artist, h.played_at FROM ios_play_history h JOIN ios_users u ON u.id = h.user_id \
          WHERE u.share_listening_activity = TRUE AND u.is_active = TRUE ORDER BY h.played_at DESC LIMIT $1) a",
    )
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"activity": v})))
}

async fn public_discover(State(st): State<AppState>, _u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let (days, limit) = (p.days.unwrap_or(7), p.limit.unwrap_or(20));
    check_range("days", days, 1, 90)?;
    check_range("limit", limit, 1, 100)?;
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('title', title, 'artist', artist, 'play_count', pc, 'listener_count', lc) ORDER BY pc DESC, lc DESC), '[]'::json) FROM \
         (SELECT h.title, h.artist, COUNT(*) AS pc, COUNT(DISTINCT h.user_id) AS lc FROM ios_play_history h JOIN ios_users u ON u.id = h.user_id \
          WHERE u.share_listening_activity = TRUE AND u.is_active = TRUE AND h.played_at >= NOW() - make_interval(days => $1) \
            AND h.title IS NOT NULL AND h.title != '' GROUP BY h.title, h.artist ORDER BY pc DESC, lc DESC LIMIT $2) t",
    )
    .bind(days as i32)
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"tracks": v})))
}

async fn top_artists(st: &AppState, user: &str, n: i64) -> ApiResult<Vec<String>> {
    Ok(sqlx::query_scalar(
        "SELECT artist FROM ios_play_history WHERE user_id = $1 AND artist IS NOT NULL AND artist != '' GROUP BY artist ORDER BY COUNT(*) DESC LIMIT $2",
    )
    .bind(user)
    .bind(n)
    .fetch_all(&st.db)
    .await?)
}

async fn similar_listeners(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(20);
    check_range("limit", limit, 1, 100)?;
    let mine = top_artists(&st, &u.id, 15).await?;
    if mine.is_empty() {
        return Ok(Json(json!({"tracks": [], "similar_listener_count": 0, "reason": "not_enough_history"})));
    }
    let similar: Vec<String> = sqlx::query_scalar(
        "SELECT h.user_id FROM ios_play_history h JOIN ios_users u ON u.id = h.user_id WHERE u.share_listening_activity = TRUE AND u.is_active = TRUE \
         AND h.user_id != $1 AND h.artist = ANY($2) GROUP BY h.user_id ORDER BY COUNT(*) DESC LIMIT 20",
    )
    .bind(&u.id)
    .bind(&mine)
    .fetch_all(&st.db)
    .await?;
    if similar.is_empty() {
        return Ok(Json(json!({"tracks": [], "similar_listener_count": 0, "reason": "no_similar_listeners"})));
    }
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('title', title, 'artist', artist, 'play_count', pc, 'listener_count', lc) ORDER BY lc DESC, pc DESC), '[]'::json) FROM \
         (SELECT title, artist, COUNT(*) AS pc, COUNT(DISTINCT user_id) AS lc FROM ios_play_history WHERE user_id = ANY($1) AND title IS NOT NULL AND title != '' \
          AND artist != ALL($2) GROUP BY title, artist ORDER BY lc DESC, pc DESC LIMIT $3) t",
    )
    .bind(&similar)
    .bind(&mine)
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"similar_listener_count": similar.len(), "tracks": v})))
}

async fn trending_energy(State(st): State<AppState>, _u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let (days, limit, min_bpm) = (p.days.unwrap_or(7), p.limit.unwrap_or(20), p.min_bpm.unwrap_or(120.0));
    check_range("days", days, 1, 90)?;
    check_range("limit", limit, 1, 100)?;
    if min_bpm < 0.0 {
        return Err(invalid("min_bpm", "Input should be greater than or equal to 0"));
    }
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('title', title, 'artist', artist, 'play_count', pc, 'listener_count', lc, \
           'avg_bpm', round(ab::numeric, 1)::float8) ORDER BY ab DESC, pc DESC, lc DESC), '[]'::json) FROM \
         (SELECT h.title, h.artist, COUNT(*) AS pc, COUNT(DISTINCT h.user_id) AS lc, AVG(h.bpm) AS ab FROM ios_play_history h JOIN ios_users u ON u.id = h.user_id \
          WHERE u.share_listening_activity = TRUE AND u.is_active = TRUE AND h.played_at >= NOW() - make_interval(days => $1) \
            AND h.title IS NOT NULL AND h.title != '' AND h.bpm IS NOT NULL GROUP BY h.title, h.artist HAVING AVG(h.bpm) >= $2 \
          ORDER BY ab DESC, pc DESC, lc DESC LIMIT $3) t",
    )
    .bind(days as i32)
    .bind(min_bpm)
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"tracks": v})))
}

async fn twin(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let mine = top_artists(&st, &u.id, 20).await?;
    if mine.is_empty() {
        return Ok(Json(json!({"twin": null, "reason": "not_enough_history"})));
    }
    let row: Option<(String, Option<String>, Option<String>, i64, Vec<String>)> = sqlx::query_as(
        "SELECT u.username, u.display_name, u.avatar_url, COUNT(DISTINCT h.artist), ARRAY_AGG(DISTINCT h.artist) FROM ios_play_history h \
         JOIN ios_users u ON u.id = h.user_id WHERE u.share_listening_activity = TRUE AND u.is_active = TRUE AND h.user_id != $1 AND h.artist = ANY($2) \
         GROUP BY h.user_id, u.username, u.display_name, u.avatar_url ORDER BY COUNT(DISTINCT h.artist) DESC LIMIT 1",
    )
    .bind(&u.id)
    .bind(&mine)
    .fetch_optional(&st.db)
    .await?;
    let Some((username, display, avatar, n, mut shared)) = row else {
        return Ok(Json(json!({"twin": null, "reason": "no_similar_listeners"})));
    };
    shared.sort();
    shared.truncate(10);
    Ok(Json(json!({"twin": {"username": username, "display_name": display, "avatar_url": avatar,
        "similarity": py_round_int(100.0 * n as f64 / mine.len() as f64), "shared_artists": shared}})))
}

/// Search YouTube for each seed artist and collect unknown tracks.
async fn artist_mix(st: &AppState, user: &str, artists: &[String], limit: usize, known: &HashSet<String>, tag: &str) -> Vec<Value> {
    if artists.is_empty() {
        return vec![];
    }
    let per = (limit / artists.len() + 1).max(1);
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for a in artists {
        let mut args: Vec<String> = vec![format!("ytsearch{per}:{a}"), "--dump-json".into(), "--flat-playlist".into(), "--no-playlist".into(), "--cache-dir".into(), st.cfg.ytdlp_cache_dir.clone()];
        args.extend(st.ytdlp.cookie_args(Some(user), false).await);
        let Ok(entries) = st.ytdlp.run_json(&args, Duration::from_secs(20)).await else {
            tracing::warn!("{tag}: yt-dlp search failed for {a:?}");
            continue;
        };
        for e in entries {
            let t = parse_track(&e, "youtube");
            let id = t["id"].as_str().unwrap_or("").to_string();
            if known.contains(&id) || !seen.insert(id) {
                continue;
            }
            out.push(t);
            if out.len() >= limit {
                return out;
            }
        }
    }
    out
}

async fn known_ids(st: &AppState, user: &str, library_table: &str) -> ApiResult<HashSet<String>> {
    let sql = format!("SELECT song_id FROM ios_user_favorites WHERE user_id = $1 UNION SELECT {library_table} WHERE user_id = $1");
    Ok(sqlx::query_scalar::<_, String>(&sql).bind(user).fetch_all(&st.db).await?.into_iter().collect())
}

async fn twin_mix(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(20);
    check_range("limit", limit, 1, 50)?;
    let mine = top_artists(&st, &u.id, 20).await?;
    if mine.is_empty() {
        return Ok(Json(json!([])));
    }
    let twin: Option<String> = sqlx::query_scalar(
        "SELECT h.user_id FROM ios_play_history h JOIN ios_users u ON u.id = h.user_id WHERE u.share_listening_activity = TRUE AND u.is_active = TRUE \
         AND h.user_id != $1 AND h.artist = ANY($2) GROUP BY h.user_id ORDER BY COUNT(DISTINCT h.artist) DESC LIMIT 1",
    )
    .bind(&u.id)
    .bind(&mine)
    .fetch_optional(&st.db)
    .await?;
    let Some(twin) = twin else { return Ok(Json(json!([]))) };
    let theirs = top_artists(&st, &twin, 3).await?;
    let known = known_ids(&st, &u.id, "source_id FROM ios_user_library_inventory").await?;
    Ok(Json(Value::Array(artist_mix(&st, &u.id, &theirs, limit as usize, &known, "twin_mix").await)))
}

// ---- avatar / banner / bio -------------------------------------------------------------------

fn is_gif(b: &[u8]) -> bool {
    b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a")
}

/// `_downscale_profile_image`: re-encode images over 400 KiB to 512 px (GIF 256 px).
async fn downscale(st: &AppState, data: Bytes, gif: bool) -> Bytes {
    if data.len() <= 400 * 1024 {
        return data;
    }
    let edge = if gif { 256 } else { 512 };
    let dir = std::env::temp_dir().join(format!("avatar-{}", uuid::Uuid::new_v4().simple()));
    let ext = if gif { "gif" } else { "jpg" };
    let (src, dst) = (dir.join(format!("in.{ext}")), dir.join(format!("out.{ext}")));
    let result = async {
        tokio::fs::create_dir_all(&dir).await.ok()?;
        tokio::fs::write(&src, &data).await.ok()?;
        let scale = format!("scale='min({edge},iw)':'min({edge},ih)':force_original_aspect_ratio=decrease");
        let (s, d) = (src.to_string_lossy().to_string(), dst.to_string_lossy().to_string());
        let args: Vec<String> = if gif {
            ["-y", "-i", &s, "-vf", &format!("{scale},split[a][b];[a]palettegen[p];[b][p]paletteuse"), "-loop", "0", &d].map(String::from).to_vec()
        } else {
            ["-y", "-i", &s, "-vf", &scale, "-q:v", "4", &d].map(String::from).to_vec()
        };
        let o = st.ytdlp.run("ffmpeg", &args, Duration::from_secs(if gif { 90 } else { 30 })).await.ok()?;
        if o.status != Some(0) {
            tracing::warn!("avatar downscale: ffmpeg failed; storing original ({} bytes)", data.len());
            return None;
        }
        let out = tokio::fs::read(&dst).await.ok()?;
        if out.is_empty() || out.len() >= data.len() {
            return None;
        }
        tracing::info!("avatar downscale: {} -> {} bytes", data.len(), out.len());
        Some(Bytes::from(out))
    }
    .await;
    let _ = tokio::fs::remove_dir_all(&dir).await;
    result.unwrap_or(data)
}

fn image_response(data: Vec<u8>, headers: &HeaderMap) -> Response {
    use md5_lite::md5_hex;
    let etag = format!("\"{}\"", md5_hex(&data));
    let inm = headers.get(header::IF_NONE_MATCH).and_then(|v| v.to_str().ok()).unwrap_or("").trim().to_string();
    let target = etag.trim_start_matches("W/");
    let hit = !inm.is_empty() && (inm == "*" || inm.split(',').any(|p| p.trim().trim_start_matches("W/") == target));
    let cc = "private, max-age=300, must-revalidate";
    if hit {
        return (StatusCode::NOT_MODIFIED, [(header::ETAG, etag), (header::CACHE_CONTROL, cc.to_string())]).into_response();
    }
    let ct = if is_gif(&data) { "image/gif" } else { "image/jpeg" };
    ([(header::CONTENT_TYPE, ct.to_string()), (header::ETAG, etag), (header::CACHE_CONTROL, cc.to_string())], data).into_response()
}

async fn checked_image(body: Bytes, what: &str) -> ApiResult<(Bytes, bool)> {
    let gif = is_gif(&body);
    if body.len() > 15_728_640 {
        return Err(AppError::new(413, if gif { format!("GIF {} must be under 15MB", what.to_lowercase()) } else { format!("{what} must be under 15MB") }));
    }
    if !gif && !body.starts_with(&[0xff, 0xd8, 0xff]) {
        return Err(AppError::bad_request(format!("{what} must be a JPEG or GIF image")));
    }
    Ok((body, gif))
}

async fn upload_avatar(State(st): State<AppState>, u: User, body: Bytes) -> ApiResult<Json<Value>> {
    let (body, gif) = checked_image(body, "Avatar").await?;
    let body = downscale(&st, body, gif).await;
    sqlx::query("UPDATE ios_users SET avatar_data = $1 WHERE id = $2").bind(body.as_ref()).bind(&u.id).execute(&st.db).await?;
    Ok(Json(json!({"ok": true, "stored_bytes": body.len()})))
}

async fn get_avatar(State(st): State<AppState>, headers: HeaderMap, Path(id): Path<String>) -> ApiResult<Response> {
    let d: Option<Option<Vec<u8>>> = sqlx::query_scalar("SELECT avatar_data FROM ios_users WHERE id = $1").bind(&id).fetch_optional(&st.db).await?;
    let d = d.flatten().filter(|d| !d.is_empty()).ok_or_else(|| AppError::not_found("No avatar set"))?;
    Ok(image_response(d, &headers))
}

async fn upload_banner(State(st): State<AppState>, u: User, body: Bytes) -> ApiResult<Json<Value>> {
    let (body, gif) = checked_image(body, "Banner").await?;
    let body = downscale(&st, body, gif).await;
    sqlx::query("INSERT INTO ios_social_profiles (user_id, banner_data) VALUES ($1, $2) ON CONFLICT (user_id) DO UPDATE SET banner_data = EXCLUDED.banner_data")
        .bind(&u.id)
        .bind(body.as_ref())
        .execute(&st.db)
        .await?;
    Ok(ok())
}

async fn remove_banner(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    sqlx::query("UPDATE ios_social_profiles SET banner_data = NULL WHERE user_id = $1").bind(&u.id).execute(&st.db).await?;
    Ok(ok())
}

async fn get_banner(State(st): State<AppState>, headers: HeaderMap, Path(id): Path<String>) -> ApiResult<Response> {
    let d: Option<Option<Vec<u8>>> = sqlx::query_scalar("SELECT banner_data FROM ios_social_profiles WHERE user_id = $1").bind(&id).fetch_optional(&st.db).await?;
    let d = d.flatten().filter(|d| !d.is_empty()).ok_or_else(|| AppError::not_found("No banner set"))?;
    Ok(image_response(d, &headers))
}

async fn get_bio(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let b: Option<Option<String>> = sqlx::query_scalar("SELECT bio FROM ios_user_profile_bio WHERE user_id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    Ok(Json(json!({"bio": b.map(|b| b.unwrap_or_default()).unwrap_or_default()})))
}

#[derive(Deserialize)]
struct BioBody {
    bio: String,
}

async fn set_bio(State(st): State<AppState>, u: User, J(b): J<BioBody>) -> ApiResult<Json<Value>> {
    let bio = b.bio.trim().to_string();
    if bio.chars().count() > 280 {
        return Err(AppError::bad_request("Bio must be 280 characters or fewer"));
    }
    sqlx::query(
        "INSERT INTO ios_user_profile_bio (user_id, bio, updated_at) VALUES ($1, $2, CURRENT_TIMESTAMP) \
         ON CONFLICT (user_id) DO UPDATE SET bio = EXCLUDED.bio, updated_at = CURRENT_TIMESTAMP",
    )
    .bind(&u.id)
    .bind(&bio)
    .execute(&st.db)
    .await?;
    Ok(Json(json!({"bio": bio})))
}

// ---- profiles --------------------------------------------------------------------------------

async fn fingerprint(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    if u.id != id {
        if blocked(&st, &u.id, &id).await? {
            return Err(AppError::not_found("User not found"));
        }
        if !is_friend(&st, &u.id, &id).await? {
            return Err(AppError::forbidden("Only available between friends"));
        }
    }
    let Some(fp) = st.sonic_fingerprint(&id).await else {
        return Ok(Json(json!({"available": false, "reason": "not enough analysed tracks yet"})));
    };
    let mut out = fp.as_object().cloned().unwrap_or_default();
    out.insert("available".into(), json!(true));
    out.insert("band_hz".into(), json!([32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]));
    if let Some(s) = fingerprint_summary(&fp) {
        out.insert("summary".into(), json!(s));
    }
    Ok(Json(Value::Object(out)))
}

async fn listening_streak(st: &AppState, user: &str) -> ApiResult<Value> {
    let dates: Vec<NaiveDate> =
        sqlx::query_scalar("SELECT DISTINCT DATE(played_at) AS d FROM ios_play_history WHERE user_id = $1 AND played_at IS NOT NULL ORDER BY d DESC LIMIT 400")
            .bind(user)
            .fetch_all(&st.db)
            .await?;
    let set: HashSet<NaiveDate> = dates.iter().copied().collect();
    if set.is_empty() {
        return Ok(json!({"current_streak_days": 0, "longest_streak_days": 0}));
    }
    let today = Utc::now().date_naive();
    let mut cursor = if set.contains(&today) { today } else { today - CDuration::days(1) };
    let mut current = 0;
    while set.contains(&cursor) {
        current += 1;
        cursor -= CDuration::days(1);
    }
    let mut sorted: Vec<NaiveDate> = set.into_iter().collect();
    sorted.sort();
    let (mut longest, mut run, mut prev) = (0, 0, None::<NaiveDate>);
    for d in sorted {
        run = if prev.is_some_and(|p| (d - p).num_days() == 1) { run + 1 } else { 1 };
        longest = longest.max(run);
        prev = Some(d);
    }
    Ok(json!({"current_streak_days": current, "longest_streak_days": longest.max(current)}))
}

async fn profile_badges(st: &AppState, user: &str, member_since: Option<chrono::NaiveDateTime>) -> ApiResult<Vec<Value>> {
    let mut b = Vec::new();
    if let Some(m) = member_since {
        let days = (Utc::now().naive_utc() - m).num_days();
        let tier = if days >= 365 { Some(("1 Year+", "gold")) } else if days >= 180 { Some(("6 Months+", "silver")) } else if days >= 30 { Some(("1 Month+", "bronze")) } else { None };
        if let Some((label, tier)) = tier {
            b.push(json!({"id": "veteran", "label": label, "icon": "star.circle.fill", "tier": tier}));
        }
    }
    let (plays, friends, comments, pinned): (i64, i64, i64, i64) = sqlx::query_as(
        "SELECT (SELECT COUNT(*) FROM ios_play_history WHERE user_id = $1), (SELECT COUNT(*) FROM ios_social_friends WHERE user_id = $1), \
                (SELECT COUNT(*) FROM ios_social_profile_comments WHERE profile_user_id = $1), (SELECT COUNT(*) FROM ios_social_pinned_tracks WHERE user_id = $1)",
    )
    .bind(user)
    .fetch_one(&st.db)
    .await?;
    let tiers = |n: i64, steps: [(i64, &'static str, &'static str); 3]| steps.into_iter().find(|(t, _, _)| n >= *t).map(|(_, l, t)| (l, t));
    if let Some((l, t)) = tiers(plays, [(5000, "5,000 Plays", "gold"), (500, "500 Plays", "silver"), (50, "50 Plays", "bronze")]) {
        b.push(json!({"id": "listener", "label": l, "icon": "headphones", "tier": t}));
    }
    if let Some((l, t)) = tiers(friends, [(25, "25 Friends", "gold"), (10, "10 Friends", "silver"), (3, "3 Friends", "bronze")]) {
        b.push(json!({"id": "social", "label": l, "icon": "person.3.fill", "tier": t}));
    }
    if let Some((l, t)) = tiers(comments, [(25, "25 Guestbook Notes", "gold"), (5, "5 Guestbook Notes", "silver"), (1, "First Guestbook Note", "bronze")]) {
        b.push(json!({"id": "popular", "label": l, "icon": "bubble.left.and.bubble.right.fill", "tier": t}));
    }
    if pinned >= 5 {
        b.push(json!({"id": "curator", "label": "Full Showcase", "icon": "pin.fill", "tier": "gold"}));
    }
    Ok(b)
}

async fn visitor_stats(st: &AppState, profile: &str, include_recent: bool) -> ApiResult<Value> {
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM ios_social_profile_views WHERE profile_user_id = $1").bind(profile).fetch_one(&st.db).await?;
    let recent: Value = if include_recent {
        sqlx::query_scalar(&format!(
            "SELECT COALESCE(json_agg(j ORDER BY last DESC), '[]'::json) FROM (SELECT {PUB}::jsonb || jsonb_build_object('last_viewed_at', lumi_iso(MAX(v.viewed_at))) AS j, \
               MAX(v.viewed_at) AS last FROM ios_social_profile_views v JOIN ios_users u ON u.id = v.viewer_user_id \
               JOIN ios_social_friends f ON f.user_id = $1 AND f.friend_id = v.viewer_user_id WHERE v.profile_user_id = $1 \
               GROUP BY u.id, u.username, u.display_name, u.avatar_url ORDER BY last DESC LIMIT 5) r"
        ))
        .bind(profile)
        .fetch_one(&st.db)
        .await?
    } else {
        json!([])
    };
    Ok(json!({"visitor_count": count, "recent_visitors": recent}))
}

async fn featured_payload(st: &AppState, id: Option<String>) -> ApiResult<Value> {
    let Some(id) = id.filter(|i| !i.is_empty()) else { return Ok(Value::Null) };
    Ok(sqlx::query_scalar::<_, Value>(
        "SELECT json_build_object('id', p.id, 'name', p.name, 'description', p.description, \
           'track_count', COALESCE((SELECT COUNT(*) FROM ios_playlist_tracks WHERE playlist_id = p.id), 0), \
           'preview_tracks', COALESCE((SELECT json_agg(json_build_object('title', title, 'artist', artist) ORDER BY position ASC) FROM \
               (SELECT title, artist, position FROM ios_playlist_tracks WHERE playlist_id = p.id ORDER BY position ASC LIMIT 3) t), '[]'::json)) \
         FROM ios_user_playlists p WHERE p.id = $1",
    )
    .bind(&id)
    .fetch_optional(&st.db)
    .await?
    .map(|mut v| {
        // Python reported 0 tracks when the preview was empty.
        if v["preview_tracks"].as_array().is_some_and(Vec::is_empty) {
            v["track_count"] = json!(0);
        }
        v
    })
    .unwrap_or(Value::Null))
}

type ProfileRow = (
    Option<String>,
    Option<String>,
    Option<String>,
    Option<bool>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<bool>,
    Option<bool>,
    Option<bool>,
    Option<bool>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
);

async fn profile_row(st: &AppState, user: &str) -> ApiResult<Option<ProfileRow>> {
    Ok(sqlx::query_as(
        "SELECT bio, main_accent_hex, sub_accent_hex, share_now_playing, pronouns, status_emoji, status_text, avatar_frame, show_top_genres, \
                show_guestbook, show_visitor_stats, show_listening_stats, featured_playlist_id, accent_glow_intensity, avatar_decoration, profile_effect \
         FROM ios_social_profiles WHERE user_id = $1",
    )
    .bind(user)
    .fetch_optional(&st.db)
    .await?)
}

fn nonempty_or(v: &Option<String>, d: &str) -> String {
    v.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| d.to_string())
}

fn taste_lists(t: &Value) -> (Value, Value) {
    let genres: Vec<Value> = t["library_genres"].as_array().cloned().unwrap_or_default().into_iter().take(6).collect();
    let tp = t["top_played_artists"].as_array().cloned().unwrap_or_default();
    let artists = if tp.is_empty() { t["favorited_artists"].as_array().cloned().unwrap_or_default() } else { tp };
    (json!(genres), json!(artists.into_iter().take(8).collect::<Vec<_>>()))
}

async fn my_profile(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let row = profile_row(&st, &u.id).await?;
    let pinned: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('id', id, 'source_track_id', source_track_id, 'track_url', track_url, 'title', title, \
           'artist', artist, 'album', album) ORDER BY position ASC), '[]'::json) FROM ios_social_pinned_tracks WHERE user_id = $1",
    )
    .bind(&u.id)
    .fetch_one(&st.db)
    .await?;
    let created: Option<Option<chrono::NaiveDateTime>> = sqlx::query_scalar("SELECT created_at FROM ios_users WHERE id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    let created = created.flatten();
    let streak = listening_streak(&st, &u.id).await?;
    let badges = profile_badges(&st, &u.id, created).await?;
    let visitors = visitor_stats(&st, &u.id, true).await?;
    let featured = featured_payload(&st, row.as_ref().and_then(|r| r.12.clone())).await?;
    let (genres, artists) = taste_lists(&st.taste_profile(&u.id).await);
    let r = row.as_ref();
    Ok(Json(json!({
        "user_id": u.id,
        "bio": r.and_then(|r| r.0.clone()),
        "main_accent_hex": r.and_then(|r| r.1.clone()),
        "sub_accent_hex": r.and_then(|r| r.2.clone()),
        "share_now_playing": r.map(|r| r.3.unwrap_or(false)).unwrap_or(true),
        "pronouns": r.and_then(|r| r.4.clone()),
        "status_emoji": r.and_then(|r| r.5.clone()),
        "status_text": r.and_then(|r| r.6.clone()),
        "avatar_frame": r.map(|r| nonempty_or(&r.7, "none")).unwrap_or_else(|| "none".into()),
        "show_top_genres": r.map(|r| r.8.unwrap_or(false)).unwrap_or(false),
        "show_guestbook": r.and_then(|r| r.9).unwrap_or(true),
        "show_visitor_stats": r.and_then(|r| r.10).unwrap_or(true),
        "show_listening_stats": r.map(|r| r.11.unwrap_or(false)).unwrap_or(false),
        "member_since": created.map(|c| crate::db::py_iso(&c)),
        "pinned_tracks": pinned,
        "top_genres": genres,
        "top_artists": artists,
        "listening_streak": streak,
        "badges": badges,
        "visitor_count": visitors["visitor_count"],
        "recent_visitors": visitors["recent_visitors"],
        "featured_playlist": featured,
        "accent_glow_intensity": r.map(|r| nonempty_or(&r.13, "normal")).unwrap_or_else(|| "normal".into()),
        "avatar_decoration": r.map(|r| nonempty_or(&r.14, "none")).unwrap_or_else(|| "none".into()),
        "profile_effect": r.map(|r| nonempty_or(&r.15, "none")).unwrap_or_else(|| "none".into()),
    })))
}

const ACCENTS: &[&str] = &["#F13D7A", "#FF8A5C", "#FFC94D", "#8CE99A", "#4FD1C5", "#4DA3FF", "#7C6CF0", "#C08CFF", "#FF6FB1", "#6EE7DE", "#F76E6E", "#B0B8C4", "#FFFFFF", "#2B2F38"];
const FRAMES: &[&str] = &["none", "glow", "ring", "dashed", "pulse", "gradient", "double", "beads", "spin", "orbit", "halo", "arc"];
const GLOWS: &[&str] = &["subtle", "normal", "vivid", "off"];
const DECORATIONS: &[&str] = &["none", "sparkles", "fireflies", "petals", "snowfall", "embers", "bubbles", "orbits", "rainfall", "dust", "notes"];
const EFFECTS: &[&str] = &["none", "blastOff", "aurora", "shootingStars", "confetti", "rain", "waveform", "starfield", "bokeh", "snowfall", "pulse"];

#[derive(Deserialize)]
struct ProfileBody {
    bio: Option<String>,
    main_accent_hex: Option<String>,
    sub_accent_hex: Option<String>,
    share_now_playing: Option<bool>,
    pronouns: Option<String>,
    status_emoji: Option<String>,
    status_text: Option<String>,
    avatar_frame: Option<String>,
    show_top_genres: Option<bool>,
    show_guestbook: Option<bool>,
    show_visitor_stats: Option<bool>,
    show_listening_stats: Option<bool>,
    accent_glow_intensity: Option<String>,
    avatar_decoration: Option<String>,
    profile_effect: Option<String>,
}

fn pick(v: &Option<String>, allowed: &[&str], lower: bool, what: &str) -> ApiResult<Option<String>> {
    let Some(x) = v else { return Ok(None) };
    let norm = if lower { x.to_lowercase() } else { x.clone() };
    if !allowed.contains(&norm.as_str()) {
        return Err(AppError::bad_request(format!("Unrecognized {what}: {x}")));
    }
    Ok(Some(norm))
}

async fn update_profile(State(st): State<AppState>, u: User, J(b): J<ProfileBody>) -> ApiResult<Json<Value>> {
    let len = |s: &Option<String>| s.as_ref().map_or(0, |s| s.chars().count());
    if len(&b.bio) > 280 {
        return Err(AppError::bad_request("Bio must be 280 characters or fewer"));
    }
    if len(&b.pronouns) > 30 {
        return Err(AppError::bad_request("Pronouns must be 30 characters or fewer"));
    }
    if len(&b.status_text) > 60 {
        return Err(AppError::bad_request("Status must be 60 characters or fewer"));
    }
    if len(&b.status_emoji) > 8 {
        return Err(AppError::bad_request("Status emoji is too long"));
    }
    let accent = |v: &Option<String>| -> ApiResult<Option<String>> {
        let Some(x) = v else { return Ok(None) };
        let up = x.to_uppercase();
        if !ACCENTS.contains(&up.as_str()) {
            return Err(AppError::bad_request(format!("Unrecognized accent color: {x}")));
        }
        Ok(Some(up))
    };
    let (main, sub) = (accent(&b.main_accent_hex)?, accent(&b.sub_accent_hex)?);
    let frame = pick(&b.avatar_frame, FRAMES, true, "avatar frame")?;
    let glow = pick(&b.accent_glow_intensity, GLOWS, true, "glow intensity")?;
    let deco = pick(&b.avatar_decoration, DECORATIONS, true, "avatar decoration")?;
    let effect = pick(&b.profile_effect, EFFECTS, false, "profile effect")?;
    sqlx::query(
        "INSERT INTO ios_social_profiles (user_id, bio, main_accent_hex, sub_accent_hex, share_now_playing, pronouns, status_emoji, status_text, \
           avatar_frame, show_top_genres, show_guestbook, show_visitor_stats, show_listening_stats, accent_glow_intensity, avatar_decoration, profile_effect) \
         VALUES ($1, $2, $3, $4, COALESCE($5, TRUE), $6, $7, $8, COALESCE($9, 'none'), COALESCE($10, FALSE), COALESCE($11, TRUE), COALESCE($12, TRUE), \
           COALESCE($13, FALSE), COALESCE($14, 'normal'), COALESCE($15, 'none'), COALESCE($16, 'none')) \
         ON CONFLICT (user_id) DO UPDATE SET bio = COALESCE(EXCLUDED.bio, ios_social_profiles.bio), \
           main_accent_hex = COALESCE(EXCLUDED.main_accent_hex, ios_social_profiles.main_accent_hex), \
           sub_accent_hex = COALESCE(EXCLUDED.sub_accent_hex, ios_social_profiles.sub_accent_hex), \
           share_now_playing = COALESCE($5, ios_social_profiles.share_now_playing), pronouns = COALESCE(EXCLUDED.pronouns, ios_social_profiles.pronouns), \
           status_emoji = COALESCE(EXCLUDED.status_emoji, ios_social_profiles.status_emoji), status_text = COALESCE(EXCLUDED.status_text, ios_social_profiles.status_text), \
           avatar_frame = COALESCE($9, ios_social_profiles.avatar_frame), show_top_genres = COALESCE($10, ios_social_profiles.show_top_genres), \
           show_guestbook = COALESCE($11, ios_social_profiles.show_guestbook), show_visitor_stats = COALESCE($12, ios_social_profiles.show_visitor_stats), \
           show_listening_stats = COALESCE($13, ios_social_profiles.show_listening_stats), \
           accent_glow_intensity = COALESCE($14, ios_social_profiles.accent_glow_intensity), \
           avatar_decoration = COALESCE($15, ios_social_profiles.avatar_decoration), profile_effect = COALESCE($16, ios_social_profiles.profile_effect)",
    )
    .bind(&u.id)
    .bind(&b.bio)
    .bind(&main)
    .bind(&sub)
    .bind(b.share_now_playing)
    .bind(&b.pronouns)
    .bind(&b.status_emoji)
    .bind(&b.status_text)
    .bind(&frame)
    .bind(b.show_top_genres)
    .bind(b.show_guestbook)
    .bind(b.show_visitor_stats)
    .bind(b.show_listening_stats)
    .bind(&glow)
    .bind(&deco)
    .bind(&effect)
    .execute(&st.db)
    .await?;
    Ok(ok())
}

#[derive(Deserialize)]
struct PinnedBody {
    tracks: Vec<PinnedIn>,
}

#[derive(Deserialize)]
struct PinnedIn {
    source_track_id: Option<String>,
    track_url: Option<String>,
    title: String,
    artist: Option<String>,
    album: Option<String>,
}

async fn pinned_tracks(State(st): State<AppState>, u: User, J(b): J<PinnedBody>) -> ApiResult<Json<Value>> {
    if b.tracks.len() > 5 {
        return Err(AppError::bad_request("Up to 5 pinned tracks allowed"));
    }
    let mut tx = st.db.begin().await?;
    sqlx::query("DELETE FROM ios_social_pinned_tracks WHERE user_id = $1").bind(&u.id).execute(&mut *tx).await?;
    for (i, t) in b.tracks.iter().enumerate() {
        sqlx::query("INSERT INTO ios_social_pinned_tracks (id, user_id, position, source_track_id, track_url, title, artist, album) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)")
            .bind(uuid::Uuid::new_v4().to_string())
            .bind(&u.id)
            .bind(i as i32)
            .bind(&t.source_track_id)
            .bind(&t.track_url)
            .bind(&t.title)
            .bind(&t.artist)
            .bind(&t.album)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(ok())
}

#[derive(Deserialize)]
struct FeaturedBody {
    playlist_id: Option<String>,
}

async fn featured_playlist(State(st): State<AppState>, u: User, J(b): J<FeaturedBody>) -> ApiResult<Json<Value>> {
    if let Some(pid) = &b.playlist_id {
        let own: Option<i32> = sqlx::query_scalar("SELECT 1 FROM ios_user_playlists WHERE id = $1 AND user_id = $2").bind(pid).bind(&u.id).fetch_optional(&st.db).await?;
        if own.is_none() {
            return Err(AppError::not_found("Playlist not found"));
        }
    }
    sqlx::query("INSERT INTO ios_social_profiles (user_id, featured_playlist_id) VALUES ($1, $2) ON CONFLICT (user_id) DO UPDATE SET featured_playlist_id = EXCLUDED.featured_playlist_id")
        .bind(&u.id)
        .bind(&b.playlist_id)
        .execute(&st.db)
        .await?;
    Ok(ok())
}

async fn public_profile(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    if u.id != id && blocked(&st, &u.id, &id).await? {
        return Err(AppError::not_found("User not found"));
    }
    let user: Option<(String, String, Option<String>, Option<String>, Option<chrono::NaiveDateTime>)> =
        sqlx::query_as("SELECT id, username, display_name, avatar_url, created_at FROM ios_users WHERE id = $1 AND is_active = TRUE").bind(&id).fetch_optional(&st.db).await?;
    let (uid, username, display, avatar, created) = user.ok_or_else(|| AppError::not_found("User not found"))?;
    let row = profile_row(&st, &id).await?;
    let pinned: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('source_track_id', source_track_id, 'track_url', track_url, 'title', title, 'artist', artist, \
           'album', album) ORDER BY position ASC), '[]'::json) FROM ios_social_pinned_tracks WHERE user_id = $1",
    )
    .bind(&id)
    .fetch_one(&st.db)
    .await?;
    let friend = is_friend(&st, &u.id, &id).await?;
    let discord: Option<Option<String>> = sqlx::query_scalar("SELECT discord_username FROM ios_discord_verifications WHERE user_id = $1").bind(&id).fetch_optional(&st.db).await?;
    let r = row.as_ref();
    let show_visitors = r.and_then(|r| r.10).unwrap_or(true);
    let show_listening = r.map(|r| r.11.unwrap_or(false)).unwrap_or(false);
    let badges = profile_badges(&st, &id, created).await?;
    let streak = if show_listening { listening_streak(&st, &id).await? } else { Value::Null };
    let visitors = if show_visitors { visitor_stats(&st, &id, friend).await? } else { json!({"visitor_count": null, "recent_visitors": []}) };
    let featured = featured_payload(&st, r.and_then(|r| r.12.clone())).await?;
    let (genres, artists) = if r.map(|r| r.8.unwrap_or(false)).unwrap_or(false) { taste_lists(&st.taste_profile(&id).await) } else { (json!([]), json!([])) };
    if u.id != id && show_visitors {
        let (st2, profile, viewer) = (st.clone(), id.clone(), u.id.clone());
        tokio::spawn(async move {
            let recent: Option<i32> = sqlx::query_scalar(
                "SELECT 1 FROM ios_social_profile_views WHERE profile_user_id = $1 AND viewer_user_id = $2 AND viewed_at > NOW() - INTERVAL '30 minutes' LIMIT 1",
            )
            .bind(&profile)
            .bind(&viewer)
            .fetch_optional(&st2.db)
            .await
            .unwrap_or(None);
            if recent.is_none() {
                if let Err(e) = sqlx::query("INSERT INTO ios_social_profile_views (id, profile_user_id, viewer_user_id) VALUES ($1, $2, $3)")
                    .bind(uuid::Uuid::new_v4().to_string())
                    .bind(&profile)
                    .bind(&viewer)
                    .execute(&st2.db)
                    .await
                {
                    tracing::warn!("record_profile_view failed ({viewer} -> {profile}): {e}");
                }
            }
        });
    }
    Ok(Json(json!({
        "user_id": uid, "username": username, "display_name": display, "avatar_url": avatar,
        "bio": r.and_then(|r| r.0.clone()), "main_accent_hex": r.and_then(|r| r.1.clone()), "sub_accent_hex": r.and_then(|r| r.2.clone()),
        "pronouns": r.and_then(|r| r.4.clone()), "status_emoji": r.and_then(|r| r.5.clone()), "status_text": r.and_then(|r| r.6.clone()),
        "avatar_frame": r.map(|r| nonempty_or(&r.7, "none")).unwrap_or_else(|| "none".into()),
        "show_guestbook": r.and_then(|r| r.9).unwrap_or(true),
        "is_friend": friend,
        "member_since": created.map(|c| crate::db::py_iso(&c)),
        "pinned_tracks": pinned, "top_genres": genres, "top_artists": artists, "badges": badges, "listening_streak": streak,
        "visitor_count": visitors["visitor_count"], "recent_visitors": visitors["recent_visitors"], "featured_playlist": featured,
        "accent_glow_intensity": r.map(|r| nonempty_or(&r.13, "normal")).unwrap_or_else(|| "normal".into()),
        "avatar_decoration": r.map(|r| nonempty_or(&r.14, "none")).unwrap_or_else(|| "none".into()),
        "profile_effect": r.map(|r| nonempty_or(&r.15, "none")).unwrap_or_else(|| "none".into()),
        "discord_verified": discord.is_some(),
        "discord_username": discord.flatten(),
    })))
}

async fn search_users(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let q = p.q.ok_or_else(|| invalid("q", "Field required"))?;
    if q.is_empty() || q.chars().count() > 64 {
        return Err(invalid("q", "String should have between 1 and 64 characters"));
    }
    let limit = p.limit.unwrap_or(20);
    check_range("limit", limit, 1, 50)?;
    let v: Value = sqlx::query_scalar(&format!(
        "SELECT COALESCE(json_agg({PUB} ORDER BY u.username ASC), '[]'::json) FROM (SELECT * FROM ios_users u WHERE u.is_active = TRUE AND u.id != $1 \
           AND u.username ILIKE $2 AND NOT EXISTS (SELECT 1 FROM ios_social_blocks b WHERE (b.user_id = $1 AND b.blocked_id = u.id) OR (b.user_id = u.id AND b.blocked_id = $1)) \
         ORDER BY u.username ASC LIMIT $3) u"
    ))
    .bind(&u.id)
    .bind(format!("%{q}%"))
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"users": v})))
}

// ---- friends ---------------------------------------------------------------------------------

#[derive(Deserialize)]
struct RequestBody {
    to_user_id: Option<String>,
    to_username: Option<String>,
}

async fn send_request(State(st): State<AppState>, u: User, J(b): J<RequestBody>) -> ApiResult<Json<Value>> {
    let mut to = b.to_user_id.filter(|s| !s.is_empty());
    if to.is_none() {
        if let Some(name) = b.to_username.filter(|s| !s.is_empty()) {
            // Current name, or a previous one nobody holds now (see resolve_username in schema.sql).
            to = sqlx::query_scalar("SELECT resolve_username($1)").bind(&name).fetch_one(&st.db).await?;
        }
    }
    let to = to.ok_or_else(|| AppError::not_found("User not found"))?;
    if to == u.id {
        return Err(AppError::bad_request("Cannot friend yourself"));
    }
    if blocked(&st, &u.id, &to).await? {
        return Err(AppError::not_found("User not found"));
    }
    if is_friend(&st, &u.id, &to).await? {
        return Err(AppError::new(409, "Already friends"));
    }
    let pending: Option<String> = sqlx::query_scalar(
        "SELECT id FROM ios_social_friend_requests WHERE status = 'pending' AND ((from_user_id = $1 AND to_user_id = $2) OR (from_user_id = $2 AND to_user_id = $1))",
    )
    .bind(&u.id)
    .bind(&to)
    .fetch_optional(&st.db)
    .await?;
    if pending.is_some() {
        return Err(AppError::new(409, "A pending request already exists"));
    }
    let id = uuid::Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO ios_social_friend_requests (id, from_user_id, to_user_id) VALUES ($1, $2, $3)").bind(&id).bind(&u.id).bind(&to).execute(&st.db).await?;
    let name = display_name(&st, &u.id).await;
    notify(&st, &to, "friend_request", "New Friend Request", &format!("{name} wants to be friends"), json!({"request_id": id, "from_user_id": u.id})).await;
    Ok(Json(json!({"ok": true, "request_id": id})))
}

async fn respond(st: &AppState, id: &str, caller: &str, status: &str) -> ApiResult<Json<Value>> {
    let row: Option<(String, String, String)> =
        sqlx::query_as("SELECT from_user_id, to_user_id, status FROM ios_social_friend_requests WHERE id = $1").bind(id).fetch_optional(&st.db).await?;
    let (from, to, cur) = row.ok_or_else(|| AppError::not_found("Request not found"))?;
    if cur != "pending" {
        return Err(AppError::new(409, "Request already resolved"));
    }
    if status == "cancelled" {
        if caller != from {
            return Err(AppError::forbidden("Only the sender can cancel a request"));
        }
    } else if caller != to {
        return Err(AppError::forbidden("Only the recipient can respond to this request"));
    }
    let mut tx = st.db.begin().await?;
    sqlx::query("UPDATE ios_social_friend_requests SET status = $1, responded_at = NOW() WHERE id = $2").bind(status).bind(id).execute(&mut *tx).await?;
    if status == "accepted" {
        sqlx::query("INSERT INTO ios_social_friends (user_id, friend_id) VALUES ($1, $2), ($2, $1) ON CONFLICT (user_id, friend_id) DO NOTHING")
            .bind(&from)
            .bind(&to)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    if status == "accepted" {
        let name = display_name(st, &to).await;
        notify(st, &from, "friend_request_accepted", "Friend Request Accepted", &format!("{name} accepted your friend request"), json!({"user_id": to})).await;
    }
    Ok(ok())
}

async fn accept_request(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    respond(&st, &id, &u.id, "accepted").await
}
async fn decline_request(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    respond(&st, &id, &u.id, "declined").await
}
async fn cancel_request(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    respond(&st, &id, &u.id, "cancelled").await
}

async fn list_requests(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let q = |col_other: &str, col_me: &str| {
        format!(
            "SELECT COALESCE(json_agg(jsonb_build_object('request_id', r.id) || {PUB}::jsonb || jsonb_build_object('created_at', lumi_iso(r.created_at)) \
               ORDER BY r.created_at DESC), '[]'::json) FROM ios_social_friend_requests r JOIN ios_users u ON u.id = r.{col_other} \
             WHERE r.{col_me} = $1 AND r.status = 'pending'"
        )
    };
    let incoming: Value = sqlx::query_scalar(&q("from_user_id", "to_user_id")).bind(&u.id).fetch_one(&st.db).await?;
    let outgoing: Value = sqlx::query_scalar(&q("to_user_id", "from_user_id")).bind(&u.id).fetch_one(&st.db).await?;
    Ok(Json(json!({"incoming": incoming, "outgoing": outgoing})))
}

async fn list_friends(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Value = sqlx::query_scalar(&format!(
        "SELECT COALESCE(json_agg({PUB}::jsonb || jsonb_build_object('friends_since', lumi_iso(f.created_at), 'nickname', n.nickname, \
           'tags', COALESCE((SELECT json_agg(tag_name ORDER BY tag_name ASC) FROM ios_social_friend_tags t WHERE t.user_id = $1 AND t.friend_id = u.id), '[]'::json)) \
           ORDER BY u.username ASC), '[]'::json) \
         FROM ios_social_friends f JOIN ios_users u ON u.id = f.friend_id \
         LEFT JOIN ios_social_friend_nicknames n ON n.user_id = $1 AND n.friend_id = u.id WHERE f.user_id = $1 AND u.is_active = TRUE"
    ))
    .bind(&u.id)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"friends": v})))
}

async fn remove_friend(State(st): State<AppState>, u: User, Path(fid): Path<String>) -> ApiResult<Json<Value>> {
    sqlx::query("DELETE FROM ios_social_friends WHERE (user_id = $1 AND friend_id = $2) OR (user_id = $2 AND friend_id = $1)").bind(&u.id).bind(&fid).execute(&st.db).await?;
    Ok(ok())
}

async fn block(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    if id == u.id {
        return Err(AppError::bad_request("Cannot block yourself"));
    }
    let mut tx = st.db.begin().await?;
    sqlx::query("INSERT INTO ios_social_blocks (user_id, blocked_id) VALUES ($1, $2) ON CONFLICT (user_id, blocked_id) DO NOTHING").bind(&u.id).bind(&id).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM ios_social_friends WHERE (user_id = $1 AND friend_id = $2) OR (user_id = $2 AND friend_id = $1)").bind(&u.id).bind(&id).execute(&mut *tx).await?;
    sqlx::query(
        "UPDATE ios_social_friend_requests SET status = 'cancelled', responded_at = NOW() WHERE status = 'pending' \
         AND ((from_user_id = $1 AND to_user_id = $2) OR (from_user_id = $2 AND to_user_id = $1))",
    )
    .bind(&u.id)
    .bind(&id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(ok())
}

async fn unblock(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    sqlx::query("DELETE FROM ios_social_blocks WHERE user_id = $1 AND blocked_id = $2").bind(&u.id).bind(&id).execute(&st.db).await?;
    Ok(ok())
}

async fn list_blocked(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Value = sqlx::query_scalar(&format!(
        "SELECT COALESCE(json_agg({PUB} ORDER BY u.username ASC), '[]'::json) FROM ios_social_blocks b JOIN ios_users u ON u.id = b.blocked_id WHERE b.user_id = $1"
    ))
    .bind(&u.id)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"blocked": v})))
}

async fn friend_suggestions(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(10);
    check_range("limit", limit, 1, 30)?;
    let v: Value = sqlx::query_scalar(&format!(
        "SELECT COALESCE(json_agg({PUB}::jsonb || jsonb_build_object('mutual_friend_count', m.n) ORDER BY m.n DESC), '[]'::json) FROM ( \
           SELECT f2.friend_id AS id, COUNT(*) AS n FROM ios_social_friends f1 JOIN ios_social_friends f2 ON f2.user_id = f1.friend_id \
           WHERE f1.user_id = $1 AND f2.friend_id != $1 AND f2.friend_id NOT IN (SELECT friend_id FROM ios_social_friends WHERE user_id = $1) \
             AND NOT EXISTS (SELECT 1 FROM ios_social_friend_requests r WHERE r.status = 'pending' AND ((r.from_user_id = $1 AND r.to_user_id = f2.friend_id) OR (r.from_user_id = f2.friend_id AND r.to_user_id = $1))) \
             AND NOT EXISTS (SELECT 1 FROM ios_social_blocks b WHERE (b.user_id = $1 AND b.blocked_id = f2.friend_id) OR (b.user_id = f2.friend_id AND b.blocked_id = $1)) \
           GROUP BY f2.friend_id ORDER BY n DESC LIMIT $2) m JOIN ios_users u ON u.id = m.id AND u.is_active = TRUE"
    ))
    .bind(&u.id)
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"suggestions": v})))
}

#[derive(Deserialize)]
struct NicknameBody {
    nickname: Option<String>,
}

async fn require_friend(st: &AppState, a: &str, b: &str) -> ApiResult<()> {
    if !is_friend(st, a, b).await? {
        return Err(AppError::not_found("Not friends with this user"));
    }
    Ok(())
}

async fn set_nickname(State(st): State<AppState>, u: User, Path(fid): Path<String>, J(b): J<NicknameBody>) -> ApiResult<Json<Value>> {
    let nick = b.nickname.unwrap_or_default().trim().to_string();
    if nick.chars().count() > 60 {
        return Err(AppError::bad_request("Nickname must be 60 characters or fewer"));
    }
    require_friend(&st, &u.id, &fid).await?;
    if nick.is_empty() {
        sqlx::query("DELETE FROM ios_social_friend_nicknames WHERE user_id = $1 AND friend_id = $2").bind(&u.id).bind(&fid).execute(&st.db).await?;
    } else {
        sqlx::query("INSERT INTO ios_social_friend_nicknames (user_id, friend_id, nickname) VALUES ($1, $2, $3) ON CONFLICT (user_id, friend_id) DO UPDATE SET nickname = EXCLUDED.nickname")
            .bind(&u.id)
            .bind(&fid)
            .bind(&nick)
            .execute(&st.db)
            .await?;
    }
    Ok(ok())
}

async fn tag_names(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let t: Vec<String> = sqlx::query_scalar("SELECT DISTINCT tag_name FROM ios_social_friend_tags WHERE user_id = $1 ORDER BY tag_name ASC").bind(&u.id).fetch_all(&st.db).await?;
    Ok(Json(json!({"tags": t})))
}

#[derive(Deserialize)]
struct TagBody {
    tag_name: String,
}

async fn add_tag(State(st): State<AppState>, u: User, Path(fid): Path<String>, J(b): J<TagBody>) -> ApiResult<Response> {
    let tag = b.tag_name.trim().to_string();
    if tag.is_empty() {
        return Err(AppError::bad_request("Tag name can't be empty"));
    }
    if tag.chars().count() > 40 {
        return Err(AppError::bad_request("Tag name must be 40 characters or fewer"));
    }
    require_friend(&st, &u.id, &fid).await?;
    let n: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM ios_social_friend_tags WHERE user_id = $1 AND friend_id = $2").bind(&u.id).bind(&fid).fetch_one(&st.db).await?;
    if n >= 10 {
        return Err(AppError::bad_request("A friend can have at most 10 tags"));
    }
    sqlx::query("INSERT INTO ios_social_friend_tags (id, user_id, friend_id, tag_name) VALUES ($1, $2, $3, $4) ON CONFLICT (user_id, friend_id, tag_name) DO NOTHING")
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(&u.id)
        .bind(&fid)
        .bind(&tag)
        .execute(&st.db)
        .await?;
    Ok((StatusCode::CREATED, ok()).into_response())
}

async fn remove_tag(State(st): State<AppState>, u: User, Path((fid, tag)): Path<(String, String)>) -> ApiResult<Json<Value>> {
    sqlx::query("DELETE FROM ios_social_friend_tags WHERE user_id = $1 AND friend_id = $2 AND tag_name = $3").bind(&u.id).bind(&fid).bind(&tag).execute(&st.db).await?;
    Ok(ok())
}

async fn leaderboard(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let (days, limit) = (p.days.unwrap_or(7), p.limit.unwrap_or(10));
    check_range("days", days, 1, 30)?;
    check_range("limit", limit, 1, 30)?;
    let v: Value = sqlx::query_scalar(&format!(
        "SELECT COALESCE(json_agg({PUB}::jsonb || jsonb_build_object('play_count', x.n) ORDER BY x.n DESC), '[]'::json) FROM ( \
           SELECT h.user_id, COUNT(*) AS n FROM ios_play_history h JOIN ios_users u2 ON u2.id = h.user_id LEFT JOIN ios_social_profiles sp ON sp.user_id = h.user_id \
           WHERE h.user_id IN (SELECT friend_id FROM ios_social_friends WHERE user_id = $1) AND u2.is_active = TRUE \
             AND h.played_at >= NOW() - make_interval(days => $2) AND COALESCE(sp.share_now_playing, TRUE) = TRUE \
           GROUP BY h.user_id ORDER BY n DESC LIMIT $3) x JOIN ios_users u ON u.id = x.user_id"
    ))
    .bind(&u.id)
    .bind(days as i32)
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"leaderboard": v})))
}

// ---- presence --------------------------------------------------------------------------------

#[derive(Deserialize)]
struct PresenceBody {
    #[serde(default)]
    is_playing: bool,
    now_playing_title: Option<String>,
    now_playing_artist: Option<String>,
    now_playing_artwork_url: Option<String>,
    #[serde(default)]
    going_offline: bool,
}

async fn update_presence(State(st): State<AppState>, u: User, J(b): J<PresenceBody>) -> ApiResult<Json<Value>> {
    let online = !b.going_offline;
    let playing = b.is_playing && online;
    sqlx::query(
        "INSERT INTO ios_presence_state (user_id, is_online, is_playing, now_playing_title, now_playing_artist, now_playing_artwork_url, last_seen_at) \
         VALUES ($1, $2, $3, $4, $5, $6, NOW()) ON CONFLICT (user_id) DO UPDATE SET is_online = EXCLUDED.is_online, is_playing = EXCLUDED.is_playing, \
           now_playing_title = EXCLUDED.now_playing_title, now_playing_artist = EXCLUDED.now_playing_artist, \
           now_playing_artwork_url = EXCLUDED.now_playing_artwork_url, last_seen_at = NOW()",
    )
    .bind(&u.id)
    .bind(online)
    .bind(playing)
    .bind(&b.now_playing_title)
    .bind(&b.now_playing_artist)
    .bind(&b.now_playing_artwork_url)
    .execute(&st.db)
    .await?;
    let (st2, uid) = (st.clone(), u.id.clone());
    let ev = json!({"type": "presence", "user_id": u.id, "online": online, "is_playing": playing, "now_playing_title": b.now_playing_title,
        "now_playing_artist": b.now_playing_artist, "now_playing_artwork_url": b.now_playing_artwork_url});
    tokio::spawn(async move { st2.push_live_to_friends(&uid, ev).await });
    Ok(ok())
}

fn offline(uid: &str) -> Value {
    json!({"user_id": uid, "online": false, "is_playing": false, "now_playing_title": null, "now_playing_artist": null, "now_playing_artwork_url": null, "last_seen_at": null})
}

async fn presence_rows(st: &AppState, ids: &[String]) -> ApiResult<HashMap<String, Value>> {
    if ids.is_empty() {
        return Ok(HashMap::new());
    }
    let rows: Vec<(String, Value)> = sqlx::query_as(&format!(
        "SELECT p.user_id, (SELECT json_build_object('user_id', p.user_id, 'online', s.online, 'is_playing', COALESCE(p.is_playing, false) AND s.online AND s.share, \
           'now_playing_title', CASE WHEN s.online AND s.share THEN p.now_playing_title END, 'now_playing_artist', CASE WHEN s.online AND s.share THEN p.now_playing_artist END, \
           'now_playing_artwork_url', CASE WHEN s.online AND s.share THEN p.now_playing_artwork_url END, 'last_seen_at', lumi_iso(p.last_seen_at)) \
           FROM (SELECT COALESCE(p.is_online, false) AND p.last_seen_at IS NOT NULL AND p.last_seen_at >= (NOW() AT TIME ZONE 'UTC') - INTERVAL '{PRESENCE_FRESH} seconds' AS online, \
                        COALESCE(sp.share_now_playing, TRUE) AS share) s) \
         FROM ios_presence_state p LEFT JOIN ios_social_profiles sp ON sp.user_id = p.user_id WHERE p.user_id = ANY($1)"
    ))
    .bind(ids)
    .fetch_all(&st.db)
    .await?;
    Ok(rows.into_iter().collect())
}

async fn friend_ids(st: &AppState, user: &str) -> ApiResult<Vec<String>> {
    Ok(sqlx::query_scalar("SELECT friend_id FROM ios_social_friends WHERE user_id = $1").bind(user).fetch_all(&st.db).await?)
}

async fn friends_presence(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let ids = friend_ids(&st, &u.id).await?;
    let mut by = presence_rows(&st, &ids).await?;
    Ok(Json(json!({"presence": ids.iter().map(|f| by.remove(f).unwrap_or_else(|| offline(f))).collect::<Vec<_>>()})))
}

async fn user_presence(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    if u.id != id && blocked(&st, &u.id, &id).await? {
        return Err(AppError::not_found("User not found"));
    }
    let mut by = presence_rows(&st, std::slice::from_ref(&id)).await?;
    Ok(Json(by.remove(&id).unwrap_or_else(|| offline(&id))))
}

async fn listening_together(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let none = || Json(json!({"title": null, "artist": null, "listening_together": []}));
    let own: Option<(Option<bool>, Option<bool>, Option<String>, Option<String>, bool)> = sqlx::query_as(&format!(
        "SELECT is_online, is_playing, now_playing_title, now_playing_artist, \
           COALESCE(last_seen_at >= (NOW() AT TIME ZONE 'UTC') - INTERVAL '{PRESENCE_FRESH} seconds', false) FROM ios_presence_state WHERE user_id = $1"
    ))
    .bind(&u.id)
    .fetch_optional(&st.db)
    .await?;
    let Some((online, playing, Some(title), artist, fresh)) = own.filter(|o| o.1.unwrap_or(false) && o.2.as_deref().is_some_and(|t| !t.is_empty())) else {
        return Ok(none());
    };
    if !playing.unwrap_or(false) || !online.unwrap_or(false) || !fresh {
        return Ok(none());
    }
    let norm = |s: Option<&str>| s.unwrap_or("").trim().to_lowercase();
    let ids = friend_ids(&st, &u.id).await?;
    let by = presence_rows(&st, &ids).await?;
    let matches: Vec<String> = ids
        .into_iter()
        .filter(|f| {
            by.get(f).is_some_and(|p| {
                p["is_playing"].as_bool().unwrap_or(false)
                    && norm(p["now_playing_title"].as_str()) == norm(Some(&title))
                    && norm(p["now_playing_artist"].as_str()) == norm(artist.as_deref())
            })
        })
        .collect();
    let users: Value = if matches.is_empty() {
        json!([])
    } else {
        sqlx::query_scalar(&format!("SELECT COALESCE(json_agg({PUB}), '[]'::json) FROM ios_users u WHERE u.id = ANY($1) AND u.is_active = TRUE"))
            .bind(&matches)
            .fetch_one(&st.db)
            .await?
    };
    Ok(Json(json!({"title": title, "artist": artist, "listening_together": users})))
}

async fn friends_activity(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(30);
    check_range("limit", limit, 1, 100)?;
    let ids = friend_ids(&st, &u.id).await?;
    if ids.is_empty() {
        return Ok(Json(json!({"activity": []})));
    }
    let v: Value = sqlx::query_scalar(&format!(
        "SELECT COALESCE(json_agg({PUB}::jsonb || jsonb_build_object('kind', a.kind, 'title', a.title, 'artist', a.artist, 'at', lumi_iso(a.at)) ORDER BY a.at DESC), '[]'::json) FROM ( \
           (SELECT h.user_id AS uid, 'played' AS kind, h.title, h.artist, h.played_at AS at FROM ios_play_history h JOIN ios_users u ON u.id = h.user_id \
            LEFT JOIN ios_social_profiles sp ON sp.user_id = u.id WHERE h.user_id = ANY($1) AND u.is_active = TRUE AND COALESCE(sp.share_now_playing, TRUE) = TRUE) \
           UNION ALL \
           (SELECT f.user_id, 'favorited', f.title, f.artist, f.added_at FROM ios_user_favorites f JOIN ios_users u ON u.id = f.user_id \
            LEFT JOIN ios_social_profiles sp ON sp.user_id = u.id WHERE f.user_id = ANY($1) AND u.is_active = TRUE AND COALESCE(sp.share_now_playing, TRUE) = TRUE) \
           ORDER BY at DESC LIMIT $2) a JOIN ios_users u ON u.id = a.uid"
    ))
    .bind(&ids)
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"activity": v})))
}

// ---- guestbook -------------------------------------------------------------------------------

const COMMENT: &str = "json_build_object('id', c.id, 'author_user_id', c.author_user_id, 'author_username', u.username, \
    'author_display_name', u.display_name, 'author_avatar_url', u.avatar_url, 'body', c.body, 'created_at', lumi_iso(c.created_at))";

async fn list_comments(State(st): State<AppState>, u: User, Path(id): Path<String>, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(50);
    check_range("limit", limit, 1, 100)?;
    if u.id != id && blocked(&st, &u.id, &id).await? {
        return Err(AppError::not_found("User not found"));
    }
    let v: Value = sqlx::query_scalar(&format!(
        "SELECT COALESCE(json_agg(j ORDER BY at DESC), '[]'::json) FROM (SELECT {COMMENT} AS j, c.created_at AS at FROM ios_social_profile_comments c \
         JOIN ios_users u ON u.id = c.author_user_id WHERE c.profile_user_id = $1 ORDER BY c.created_at DESC LIMIT $2) x"
    ))
    .bind(&id)
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"comments": v})))
}

#[derive(Deserialize)]
struct CommentBody {
    body: String,
}

async fn post_comment(State(st): State<AppState>, u: User, Path(id): Path<String>, J(b): J<CommentBody>) -> ApiResult<Response> {
    if u.id == id {
        return Err(AppError::bad_request("You can't leave a comment on your own profile"));
    }
    let text = b.body.trim().to_string();
    if text.is_empty() {
        return Err(AppError::bad_request("Comment can't be empty"));
    }
    if text.chars().count() > 280 {
        return Err(AppError::bad_request("Comment must be 280 characters or fewer"));
    }
    if blocked(&st, &u.id, &id).await? {
        return Err(AppError::not_found("User not found"));
    }
    if !is_friend(&st, &u.id, &id).await? {
        return Err(AppError::forbidden("You can only comment on friends' profiles"));
    }
    let gb: Option<Option<bool>> = sqlx::query_scalar("SELECT show_guestbook FROM ios_social_profiles WHERE user_id = $1").bind(&id).fetch_optional(&st.db).await?;
    if gb.flatten() == Some(false) {
        return Err(AppError::forbidden("This user has turned off their guestbook"));
    }
    let cid = uuid::Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO ios_social_profile_comments (id, profile_user_id, author_user_id, body) VALUES ($1, $2, $3, $4)").bind(&cid).bind(&id).bind(&u.id).bind(&text).execute(&st.db).await?;
    let name = display_name(&st, &u.id).await;
    let snippet: String = text.chars().take(100).collect();
    notify(&st, &id, "profile_comment", "New Profile Comment", &format!("{name}: {snippet}"), json!({"comment_id": cid, "author_user_id": u.id})).await;
    let v: Value = sqlx::query_scalar(&format!("SELECT {COMMENT} FROM ios_social_profile_comments c JOIN ios_users u ON u.id = c.author_user_id WHERE c.id = $1"))
        .bind(&cid)
        .fetch_one(&st.db)
        .await?;
    let (st2, pid, d) = (st.clone(), id.clone(), json!({"author_user_id": u.id, "body": text}));
    tokio::spawn(async move { st2.fire_user_webhooks(&pid, "profile_comment", d).await });
    Ok((StatusCode::CREATED, Json(v)).into_response())
}

async fn delete_comment(State(st): State<AppState>, u: User, Path(cid): Path<String>) -> ApiResult<StatusCode> {
    let row: Option<(String, String)> =
        sqlx::query_as("SELECT author_user_id, profile_user_id FROM ios_social_profile_comments WHERE id = $1").bind(&cid).fetch_optional(&st.db).await?;
    let (a, p) = row.ok_or_else(|| AppError::not_found("Comment not found"))?;
    if u.id != a && u.id != p {
        return Err(AppError::forbidden("Not authorized to delete this comment"));
    }
    sqlx::query("DELETE FROM ios_social_profile_comments WHERE id = $1").bind(&cid).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn played_together(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    if u.id == id {
        return Err(AppError::bad_request("Can't compare listening history with yourself"));
    }
    if blocked(&st, &u.id, &id).await? {
        return Err(AppError::not_found("User not found"));
    }
    if !is_friend(&st, &u.id, &id).await? {
        return Err(AppError::forbidden("Only available between friends"));
    }
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('title', title, 'artist', artist, 'your_last_played_at', lumi_iso(yl), 'their_last_played_at', lumi_iso(tl)) \
           ORDER BY GREATEST(yl, tl) DESC), '[]'::json) FROM ( \
           SELECT MAX(a.title) AS title, MAX(a.artist) AS artist, MAX(a.played_at) AS yl, MAX(b.played_at) AS tl FROM ios_play_history a \
           JOIN ios_play_history b ON LOWER(TRIM(a.title)) = LOWER(TRIM(b.title)) AND LOWER(TRIM(COALESCE(a.artist, ''))) = LOWER(TRIM(COALESCE(b.artist, ''))) \
           WHERE a.user_id = $1 AND b.user_id = $2 AND a.played_at > NOW() - INTERVAL '30 days' AND b.played_at > NOW() - INTERVAL '30 days' \
           GROUP BY LOWER(TRIM(a.title)), LOWER(TRIM(COALESCE(a.artist, ''))) ORDER BY GREATEST(MAX(a.played_at), MAX(b.played_at)) DESC LIMIT 8) t",
    )
    .bind(&u.id)
    .bind(&id)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"tracks": v})))
}

// ---- matching --------------------------------------------------------------------------------

fn keys(items: &[String]) -> (HashMap<String, String>, BTreeSet<String>) {
    let mut display = HashMap::new();
    let mut set = BTreeSet::new();
    for i in items {
        let s = i.trim();
        if s.is_empty() {
            continue;
        }
        let k = s.to_lowercase();
        set.insert(k.clone());
        display.entry(k).or_insert_with(|| s.to_string());
    }
    (display, set)
}

fn strs(v: &Value) -> Vec<String> {
    v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()).unwrap_or_default()
}

fn jaccard(a: &BTreeSet<String>, b: &BTreeSet<String>) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    a.intersection(b).count() as f64 / a.union(b).count() as f64
}

fn overlap(a: &BTreeSet<String>, b: &BTreeSet<String>) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let smaller = a.len().min(b.len()) as f64;
    a.intersection(b).count() as f64 / smaller * (smaller / 8.0).min(1.0)
}

async fn compatibility(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    if u.id == id {
        return Err(AppError::bad_request("Can't compute compatibility with yourself"));
    }
    if blocked(&st, &u.id, &id).await? {
        return Err(AppError::not_found("User not found"));
    }
    if !is_friend(&st, &u.id, &id).await? {
        return Err(AppError::forbidden("Compatibility is only available between friends"));
    }
    let (pa, pb) = (st.taste_profile(&u.id).await, st.taste_profile(&id).await);
    let both = |p: &Value| [strs(&p["top_played_artists"]), strs(&p["favorited_artists"])].concat();
    let (da, aa) = keys(&both(&pa));
    let (_, ab) = keys(&both(&pb));
    let (dg, ga) = keys(&strs(&pa["library_genres"]));
    let (_, gb) = keys(&strs(&pb["library_genres"]));
    if aa.is_empty() || ab.is_empty() {
        return Ok(Json(json!({"score": 0, "insufficient_data": true, "shared_artists": [], "shared_genres": []})));
    }
    let (fa, fb) = (st.sonic_fingerprint(&u.id).await, st.sonic_fingerprint(&id).await);
    let (sonic, mut reasons) = match (&fa, &fb) {
        (Some(a), Some(b)) => {
            let (s, r) = describe_sonic_match(a, b);
            (Some(s), r)
        }
        _ => (None, vec![]),
    };
    let name = 0.7 * jaccard(&aa, &ab) + 0.3 * jaccard(&ga, &gb);
    let mut score = py_round_int(100.0 * match sonic { None => name, Some(s) => 0.65 * name + 0.35 * s });
    let shared_a: Vec<String> = aa.intersection(&ab).take(10).cloned().collect();
    let shared_g: Vec<String> = ga.intersection(&gb).take(6).cloned().collect();
    if shared_a.is_empty() && sonic.is_some() {
        score = score.min(80);
    }
    if !shared_a.is_empty() {
        reasons.insert(0, format!("{} artists in common", shared_a.len()));
    }
    reasons.truncate(3);
    Ok(Json(json!({
        "score": score, "insufficient_data": false,
        "shared_artists": shared_a.iter().map(|k| da.get(k).cloned().unwrap_or(k.clone())).collect::<Vec<_>>(),
        "shared_genres": shared_g.iter().map(|k| dg.get(k).cloned().unwrap_or(k.clone())).collect::<Vec<_>>(),
        "sonic_score": sonic.map(|s| py_round_int(100.0 * s)),
        "reasons": reasons,
    })))
}

async fn blend(State(st): State<AppState>, u: User, Path(id): Path<String>, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(20);
    check_range("limit", limit, 1, 50)?;
    if u.id == id {
        return Err(AppError::bad_request("Can't blend with yourself"));
    }
    if blocked(&st, &u.id, &id).await? {
        return Err(AppError::not_found("User not found"));
    }
    if !is_friend(&st, &u.id, &id).await? {
        return Err(AppError::forbidden("Blend is only available between friends"));
    }
    let known = known_ids(&st, &u.id, "song_id FROM ios_user_library").await?;
    let (a, b): (Vec<String>, Vec<String>) = (
        strs(&st.taste_profile(&u.id).await["top_played_artists"]).into_iter().take(6).collect(),
        strs(&st.taste_profile(&id).await["top_played_artists"]).into_iter().take(6).collect(),
    );
    if a.is_empty() && b.is_empty() {
        return Ok(Json(json!([])));
    }
    let mut inter = Vec::new();
    for i in 0..a.len().max(b.len()) {
        if let Some(x) = a.get(i) {
            inter.push(x.clone());
        }
        if let Some(x) = b.get(i) {
            inter.push(x.clone());
        }
    }
    Ok(Json(Value::Array(artist_mix(&st, &u.id, &inter, limit as usize, &known, "social_blend_mix").await)))
}

async fn recommended_people(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(20);
    check_range("limit", limit, 1, 50)?;
    let my_artists: Vec<String> = sqlx::query_scalar(
        "SELECT DISTINCT trim(artist) FROM ios_play_history WHERE user_id = $1 AND artist IS NOT NULL AND trim(artist) <> '' \
         UNION SELECT DISTINCT trim(artist) FROM ios_user_favorites WHERE user_id = $1 AND artist IS NOT NULL AND trim(artist) <> ''",
    )
    .bind(&u.id)
    .fetch_all(&st.db)
    .await?;
    let my_genres: Vec<String> =
        sqlx::query_scalar("SELECT DISTINCT trim(genre) FROM ios_user_music_metadata WHERE user_id = $1 AND genre IS NOT NULL AND trim(genre) <> ''")
            .bind(&u.id)
            .fetch_all(&st.db)
            .await?;
    let (da, ma) = keys(&my_artists);
    let (dg, mg) = keys(&my_genres);
    if ma.is_empty() && mg.is_empty() {
        return Ok(Json(json!({"people": [], "reason": "not_enough_listening_history"})));
    }
    let cands: Vec<(String, String, Option<String>, Option<String>, Option<bool>)> = sqlx::query_as(
        "SELECT u.id, u.username, u.display_name, u.avatar_url, u.share_listening_activity FROM ios_users u WHERE u.is_active = TRUE \
         AND COALESCE(u.discoverable_in_recommendations, TRUE) = TRUE AND u.id <> $1 AND u.id NOT IN (SELECT friend_id FROM ios_social_friends WHERE user_id = $1) \
         AND NOT EXISTS (SELECT 1 FROM ios_social_friend_requests r WHERE r.status = 'pending' AND ((r.from_user_id = $1 AND r.to_user_id = u.id) OR (r.from_user_id = u.id AND r.to_user_id = $1))) \
         AND NOT EXISTS (SELECT 1 FROM ios_social_blocks b WHERE (b.user_id = $1 AND b.blocked_id = u.id) OR (b.user_id = u.id AND b.blocked_id = $1))",
    )
    .bind(&u.id)
    .fetch_all(&st.db)
    .await?;
    if cands.is_empty() {
        return Ok(Json(json!({"people": [], "reason": "no_candidates"})));
    }
    let ids: Vec<String> = cands.iter().map(|c| c.0.clone()).collect();
    let mut artists_by: HashMap<String, BTreeSet<String>> = HashMap::new();
    let ar: Vec<(String, String)> = sqlx::query_as(
        "SELECT user_id, lower(trim(artist)) FROM ios_play_history WHERE user_id = ANY($1) AND artist IS NOT NULL AND trim(artist) <> '' GROUP BY user_id, lower(trim(artist)) \
         UNION SELECT user_id, lower(trim(artist)) FROM ios_user_favorites WHERE user_id = ANY($1) AND artist IS NOT NULL AND trim(artist) <> ''",
    )
    .bind(&ids)
    .fetch_all(&st.db)
    .await?;
    for (uid, k) in ar {
        artists_by.entry(uid).or_default().insert(k);
    }
    let mut genres_by: HashMap<String, BTreeSet<String>> = HashMap::new();
    let gr: Vec<(String, String)> = sqlx::query_as(
        "SELECT user_id, lower(trim(genre)) FROM ios_user_music_metadata WHERE user_id = ANY($1) AND genre IS NOT NULL AND trim(genre) <> '' GROUP BY user_id, lower(trim(genre))",
    )
    .bind(&ids)
    .fetch_all(&st.db)
    .await?;
    for (uid, k) in gr {
        genres_by.entry(uid).or_default().insert(k);
    }
    let mutual: HashMap<String, i64> = sqlx::query_as::<_, (String, i64)>(
        "SELECT f2.friend_id, COUNT(*) FROM ios_social_friends f1 JOIN ios_social_friends f2 ON f2.user_id = f1.friend_id WHERE f1.user_id = $1 AND f2.friend_id <> $1 GROUP BY f2.friend_id",
    )
    .bind(&u.id)
    .fetch_all(&st.db)
    .await?
    .into_iter()
    .collect();
    let empty = BTreeSet::new();
    let mut scored: Vec<(f64, i64, Map<String, Value>, bool)> = Vec::new();
    for (cid, username, display, avatar, shares) in cands {
        let ta = artists_by.get(&cid).unwrap_or(&empty);
        let tg = genres_by.get(&cid).unwrap_or(&empty);
        if ta.is_empty() && tg.is_empty() {
            continue;
        }
        let name = 0.7 * overlap(&ma, ta) + 0.3 * overlap(&mg, tg);
        let m = mutual.get(&cid).copied().unwrap_or(0);
        if name <= 0.0 && m == 0 {
            continue;
        }
        let known = ma.len().min(ta.len());
        let conf = if known >= 8 { "high" } else if known >= 4 { "medium" } else { "low" };
        let score = (name + (0.05 * m as f64).min(0.15)).min(1.0);
        let mut o = Map::new();
        o.insert("user_id".into(), json!(cid));
        o.insert("username".into(), json!(username));
        o.insert("display_name".into(), json!(display));
        o.insert("avatar_url".into(), json!(avatar));
        o.insert("mutual_friend_count".into(), json!(m));
        o.insert("shared_artists".into(), json!(ma.intersection(ta).map(|k| da.get(k).cloned().unwrap_or(k.clone())).collect::<Vec<_>>()));
        o.insert("shared_genres".into(), json!(mg.intersection(tg).map(|k| dg.get(k).cloned().unwrap_or(k.clone())).collect::<Vec<_>>()));
        o.insert("confidence".into(), json!(conf));
        scored.push((score, m, o, shares.unwrap_or(false)));
    }
    scored.sort_by(|a, b| (b.0, b.1).partial_cmp(&(a.0, a.1)).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(limit as usize);
    let my_fp = st.sonic_fingerprint(&u.id).await;
    let mut people: Vec<Value> = Vec::new();
    for (raw, m, mut o, shares) in scored {
        let (mut sonic, mut sreasons) = (None, vec![]);
        if let Some(fp) = &my_fp {
            if let Some(theirs) = st.sonic_fingerprint(o["user_id"].as_str().unwrap_or("")).await {
                let (s, r) = describe_sonic_match(fp, &theirs);
                sonic = Some(s);
                sreasons = r;
            }
        }
        let fin = match sonic { None => raw, Some(s) => 0.65 * raw + 0.35 * s };
        let sa = strs(&o["shared_artists"]);
        let sg = strs(&o["shared_genres"]);
        let mut reasons: Vec<String> = Vec::new();
        if m > 0 {
            reasons.push(format!("{m} mutual friend{}", if m != 1 { "s" } else { "" }));
        }
        if shares {
            if !sa.is_empty() {
                let extra = sa.len() as i64 - 2;
                reasons.push(format!("Both listen to {}{}", sa.iter().take(2).cloned().collect::<Vec<_>>().join(", "), if extra > 0 { format!(" and {extra} more") } else { String::new() }));
            } else if let Some(g) = sg.first() {
                reasons.push(format!("Both into {g}"));
            }
        } else if !sa.is_empty() {
            reasons.push(format!("{} artists in common", sa.len()));
        }
        reasons.extend(sreasons.into_iter().take(2));
        reasons.truncate(3);
        o.insert("score".into(), json!(py_round_int(100.0 * fin)));
        o.insert("sonic_score".into(), json!(sonic.map(|s| py_round_int(100.0 * s))));
        o.insert("reasons".into(), json!(reasons));
        o.insert("shared_artists".into(), json!(if shares { sa.into_iter().take(5).collect::<Vec<_>>() } else { vec![] }));
        o.insert("shared_genres".into(), json!(if shares { sg.into_iter().take(3).collect::<Vec<_>>() } else { vec![] }));
        people.push(Value::Object(o));
    }
    people.sort_by(|a, b| b["score"].as_i64().cmp(&a["score"].as_i64()));
    if people.is_empty() {
        return Ok(Json(json!({"people": [], "reason": "no_similar_listeners_yet"})));
    }
    Ok(Json(json!({"people": people})))
}

// ---- listening rooms -------------------------------------------------------------------------

fn room_code() -> String {
    use rand::Rng;
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut r = rand::rng();
    (0..6).map(|_| A[r.random_range(0..A.len())] as char).collect()
}

async fn participants(st: &AppState, room: &str) -> ApiResult<Value> {
    Ok(sqlx::query_scalar(&format!(
        "SELECT COALESCE(json_agg(json_build_object('user_id', p.user_id, 'username', u.username, 'display_name', u.display_name, \
           'joined_at', lumi_iso(p.joined_at) || '+00:00', 'is_host', p.user_id = r.host_user_id) ORDER BY (p.user_id = r.host_user_id) DESC, p.joined_at ASC), '[]'::json) \
         FROM ios_room_participants p JOIN ios_listen_rooms r ON r.id = p.room_id LEFT JOIN ios_users u ON u.id = p.user_id \
         WHERE p.room_id = $1 AND p.last_seen_at > NOW() - make_interval(secs => {ROOM_TTL_SECS})"
    ))
    .bind(room)
    .fetch_one(&st.db)
    .await?)
}

async fn push_room(st: &AppState, room: &str, ev: Value, exclude: Option<&str>) {
    let Ok(m) = participants(st, room).await else {
        tracing::error!("room push: could not resolve participants for {room}");
        return;
    };
    for p in m.as_array().into_iter().flatten() {
        if let Some(uid) = p["user_id"].as_str() {
            if Some(uid) != exclude {
                st.push_live(uid, ev.clone());
            }
        }
    }
}

async fn touch(st: &AppState, room: &str, user: &str) -> ApiResult<()> {
    sqlx::query("INSERT INTO ios_room_participants (room_id, user_id) VALUES ($1, $2) ON CONFLICT (room_id, user_id) DO UPDATE SET last_seen_at = NOW()")
        .bind(room)
        .bind(user)
        .execute(&st.db)
        .await?;
    Ok(())
}

async fn room_by_code(st: &AppState, code: &str) -> ApiResult<Option<(String, String)>> {
    Ok(sqlx::query_as("SELECT id, host_user_id FROM ios_listen_rooms WHERE room_code = $1").bind(code.to_uppercase()).fetch_optional(&st.db).await?)
}

#[derive(Deserialize)]
struct RoomBody {
    track_url: Option<String>,
    title: Option<String>,
    artist: Option<String>,
    position_seconds: Option<f64>,
    is_playing: Option<bool>,
}

async fn insert_room(st: &AppState, user: &str, b: &RoomBody, device_sync: bool) -> ApiResult<(String, String)> {
    let id = uuid::Uuid::new_v4().to_string();
    for _ in 0..5 {
        let code = room_code();
        let r = sqlx::query(
            "INSERT INTO ios_listen_rooms (id, host_user_id, room_code, track_url, title, artist, position_seconds, is_playing, is_device_sync) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        )
        .bind(&id)
        .bind(user)
        .bind(&code)
        .bind(&b.track_url)
        .bind(&b.title)
        .bind(&b.artist)
        .bind(b.position_seconds.unwrap_or(0.0))
        .bind(b.is_playing.unwrap_or(false))
        .bind(device_sync)
        .execute(&st.db)
        .await;
        if r.is_ok() {
            return Ok((id, code));
        }
    }
    Err(AppError::internal("Could not allocate room code"))
}

async fn create_room(State(st): State<AppState>, u: User, J(b): J<RoomBody>) -> ApiResult<Response> {
    let (id, code) = insert_room(&st, &u.id, &b, false).await?;
    Ok((StatusCode::CREATED, Json(json!({"id": id, "room_code": code}))).into_response())
}

async fn device_sync_start(State(st): State<AppState>, u: User, J(b): J<RoomBody>) -> ApiResult<Json<Value>> {
    let existing: Option<String> = sqlx::query_scalar(&format!(
        "SELECT room_code FROM ios_listen_rooms WHERE host_user_id = $1 AND is_device_sync = TRUE AND updated_at > NOW() - make_interval(hours => {ROOM_IDLE_HOURS})"
    ))
    .bind(&u.id)
    .fetch_optional(&st.db)
    .await?;
    if let Some(c) = existing {
        return Ok(Json(json!({"room_code": c})));
    }
    let (_, code) = insert_room(&st, &u.id, &b, true).await?;
    Ok(Json(json!({"room_code": code})))
}

async fn device_sync_active(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    // The host pushes its state every ~5 s while it plays. A room it has
    // stopped updating (app closed, reinstalled, crashed) is not a session to
    // follow: a 12 h window kept followers forcing a long-gone host's song
    // back over whatever the listener picked, every 5 s.
    let c: Option<String> = sqlx::query_scalar(&format!(
        "SELECT room_code FROM ios_listen_rooms WHERE host_user_id = $1 AND is_device_sync = TRUE AND updated_at > NOW() - make_interval(secs => {DEVICE_SYNC_LIVE_SECS}) \
         ORDER BY updated_at DESC LIMIT 1"
    ))
    .bind(&u.id)
    .fetch_optional(&st.db)
    .await?;
    Ok(Json(json!({"room_code": c})))
}

async fn device_sync_stop(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM ios_listen_rooms WHERE host_user_id = $1 AND is_device_sync = TRUE").bind(&u.id).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

type RoomState = (String, String, String, Option<String>, Option<String>, Option<String>, Option<f64>, Option<bool>, Option<String>);

async fn room_state(st: &AppState, code: &str) -> ApiResult<Option<RoomState>> {
    Ok(sqlx::query_as(
        "SELECT id, host_user_id, room_code, track_url, title, artist, position_seconds, is_playing, lumi_iso(updated_at) || '+00:00' \
         FROM ios_listen_rooms WHERE room_code = $1",
    )
    .bind(code.to_uppercase())
    .fetch_optional(&st.db)
    .await?)
}

async fn get_room(State(st): State<AppState>, Path(code): Path<String>) -> ApiResult<Json<Value>> {
    let r = room_state(&st, &code).await?.ok_or_else(|| AppError::not_found("Room not found"))?;
    let members = participants(&st, &r.0).await?;
    Ok(Json(json!({"id": r.0, "room_code": r.2, "track_url": r.3, "title": r.4, "artist": r.5, "position_seconds": r.6,
        "is_playing": r.7.unwrap_or(false), "updated_at": r.8, "server_time": now_utc_iso(), "participants": members})))
}

async fn update_room(State(st): State<AppState>, u: User, Path(code): Path<String>, J(b): J<RoomBody>) -> ApiResult<Json<Value>> {
    let row: Option<(String, String, Option<String>, Option<String>)> =
        sqlx::query_as("SELECT id, host_user_id, title, artist FROM ios_listen_rooms WHERE room_code = $1").bind(code.to_uppercase()).fetch_optional(&st.db).await?;
    let (rid, host, pt, pa) = row.ok_or_else(|| AppError::not_found("Room not found"))?;
    if host != u.id {
        return Err(AppError::forbidden("Only the host can update this room"));
    }
    if b.track_url.is_some() || b.title.is_some() || b.artist.is_some() || b.position_seconds.is_some() || b.is_playing.is_some() {
        sqlx::query(
            "UPDATE ios_listen_rooms SET track_url = COALESCE($1, track_url), title = COALESCE($2, title), artist = COALESCE($3, artist), \
             position_seconds = COALESCE($4, position_seconds), is_playing = COALESCE($5, is_playing) WHERE room_code = $6",
        )
        .bind(&b.track_url)
        .bind(&b.title)
        .bind(&b.artist)
        .bind(b.position_seconds)
        .bind(b.is_playing)
        .bind(code.to_uppercase())
        .execute(&st.db)
        .await?;
    }
    let changed = (b.title.is_some() && b.title != pt) || (b.artist.is_some() && b.artist != pa);
    if changed {
        sqlx::query("INSERT INTO ios_room_events (room_id, user_id, event_type, title, artist) VALUES ($1, $2, 'track_change', $3, $4)")
            .bind(&rid)
            .bind(&u.id)
            .bind(b.title.clone().filter(|s| !s.is_empty()).or(pt.clone()))
            .bind(b.artist.clone().filter(|s| !s.is_empty()).or(pa.clone()))
            .execute(&st.db)
            .await?;
    }
    touch(&st, &rid, &u.id).await?;
    let ev = json!({"type": "room_state", "room_code": code.to_uppercase(), "track_url": b.track_url,
        "title": b.title.clone().or(pt), "artist": b.artist.clone().or(pa), "position_seconds": b.position_seconds,
        "is_playing": b.is_playing, "as_of": now_utc_iso()});
    let (st2, uid) = (st.clone(), u.id.clone());
    tokio::spawn(async move { push_room(&st2, &rid, ev, Some(&uid)).await });
    Ok(Json(json!({"status": "updated"})))
}

async fn join_room(State(st): State<AppState>, u: User, Path(code): Path<String>) -> ApiResult<Json<Value>> {
    let (rid, host) = room_by_code(&st, &code).await?.ok_or_else(|| AppError::not_found("Room not found"))?;
    let present: Option<i32> = sqlx::query_scalar(&format!(
        "SELECT 1 FROM ios_room_participants WHERE room_id = $1 AND user_id = $2 AND last_seen_at > NOW() - make_interval(secs => {ROOM_TTL_SECS})"
    ))
    .bind(&rid)
    .bind(&u.id)
    .fetch_optional(&st.db)
    .await?;
    touch(&st, &rid, &u.id).await?;
    if present.is_none() {
        sqlx::query("INSERT INTO ios_room_events (room_id, user_id, event_type, message) VALUES ($1, $2, 'join', 'joined the room')").bind(&rid).bind(&u.id).execute(&st.db).await?;
    }
    let s = room_state(&st, &code).await?.ok_or_else(|| AppError::not_found("Room not found"))?;
    let members = participants(&st, &rid).await?;
    if present.is_none() {
        let (st2, uid, c) = (st.clone(), u.id.clone(), code.to_uppercase());
        let rid2 = rid.clone();
        tokio::spawn(async move { push_room(&st2, &rid2, json!({"type": "room_members", "room_code": c}), Some(&uid)).await });
    }
    Ok(Json(json!({"room_code": code.to_uppercase(), "is_host": host == u.id, "track_url": s.3, "title": s.4, "artist": s.5,
        "position_seconds": s.6, "is_playing": s.7.unwrap_or(false), "updated_at": s.8, "server_time": now_utc_iso(), "participants": members})))
}

async fn room_heartbeat(State(st): State<AppState>, u: User, Path(code): Path<String>) -> ApiResult<Json<Value>> {
    let (rid, _) = room_by_code(&st, &code).await?.ok_or_else(|| AppError::not_found("Room not found"))?;
    touch(&st, &rid, &u.id).await?;
    Ok(Json(json!({"participants": participants(&st, &rid).await?, "server_time": now_utc_iso()})))
}

async fn leave_room(State(st): State<AppState>, u: User, Path(code): Path<String>) -> ApiResult<StatusCode> {
    let Some((rid, _)) = room_by_code(&st, &code).await? else { return Ok(StatusCode::NO_CONTENT) };
    let r = sqlx::query("DELETE FROM ios_room_participants WHERE room_id = $1 AND user_id = $2").bind(&rid).bind(&u.id).execute(&st.db).await?;
    if r.rows_affected() > 0 {
        sqlx::query("INSERT INTO ios_room_events (room_id, user_id, event_type, message) VALUES ($1, $2, 'leave', 'left the room')").bind(&rid).bind(&u.id).execute(&st.db).await?;
    }
    let (st2, uid, c) = (st.clone(), u.id.clone(), code.to_uppercase());
    tokio::spawn(async move { push_room(&st2, &rid, json!({"type": "room_members", "room_code": c}), Some(&uid)).await });
    Ok(StatusCode::NO_CONTENT)
}

async fn close_room(State(st): State<AppState>, u: User, Path(code): Path<String>) -> ApiResult<StatusCode> {
    let (rid, host) = room_by_code(&st, &code).await?.ok_or_else(|| AppError::not_found("Room not found"))?;
    if host != u.id {
        return Err(AppError::forbidden("Only the host can close this room"));
    }
    push_room(&st, &rid, json!({"type": "room_closed", "room_code": code.to_uppercase()}), Some(&u.id)).await;
    sqlx::query("DELETE FROM ios_listen_rooms WHERE id = $1").bind(&rid).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn room_id(st: &AppState, code: &str) -> ApiResult<String> {
    sqlx::query_scalar("SELECT id FROM ios_listen_rooms WHERE room_code = $1")
        .bind(code.to_uppercase())
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("Room not found"))
}

async fn room_events(State(st): State<AppState>, Path(code): Path<String>, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(50);
    check_range("limit", limit, 1, 200)?;
    let rid = room_id(&st, &code).await?;
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(j ORDER BY at ASC), '[]'::json) FROM (SELECT json_build_object('event_type', e.event_type, 'title', e.title, 'artist', e.artist, \
           'message', e.message, 'created_at', lumi_iso(e.created_at) || '+00:00', 'user_id', e.user_id, 'username', u.username, \
           'display_name', COALESCE(NULLIF(u.display_name, ''), u.username)) AS j, e.created_at AS at, e.id \
         FROM ios_room_events e LEFT JOIN ios_users u ON u.id = e.user_id WHERE e.room_id = $1 ORDER BY e.created_at DESC LIMIT $2) x",
    )
    .bind(&rid)
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"events": v})))
}

#[derive(Deserialize)]
struct ChatBody {
    message: String,
}

async fn room_chat(State(st): State<AppState>, u: User, Path(code): Path<String>, J(b): J<ChatBody>) -> ApiResult<Response> {
    if b.message.trim().is_empty() {
        return Err(AppError::bad_request("Message cannot be empty"));
    }
    let rid = room_id(&st, &code).await?;
    let msg: String = b.message.trim().chars().take(1000).collect();
    sqlx::query("INSERT INTO ios_room_events (room_id, user_id, event_type, message) VALUES ($1, $2, 'chat', $3)").bind(&rid).bind(&u.id).bind(&msg).execute(&st.db).await?;
    touch(&st, &rid, &u.id).await?;
    let who: Option<(String, Option<String>)> = sqlx::query_as("SELECT username, display_name FROM ios_users WHERE id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    let ev = json!({"type": "room_chat", "room_code": code.to_uppercase(), "user_id": u.id, "username": who.as_ref().map(|w| w.0.clone()),
        "display_name": who.as_ref().map(|w| w.1.clone().filter(|d| !d.is_empty()).unwrap_or(w.0.clone())), "message": msg, "created_at": now_utc_iso()});
    let (st2, uid) = (st.clone(), u.id.clone());
    tokio::spawn(async move { push_room(&st2, &rid, ev, Some(&uid)).await });
    Ok((StatusCode::CREATED, Json(json!({"status": "posted"}))).into_response())
}

#[derive(Deserialize)]
struct ReactBody {
    emoji: String,
}

/// A live reaction (an emoji floating up for everyone in the room). Not
/// stored: it only matters to whoever is listening right now.
async fn room_react(State(st): State<AppState>, u: User, Path(code): Path<String>, J(b): J<ReactBody>) -> ApiResult<Json<Value>> {
    let emoji: String = b.emoji.trim().chars().take(8).collect();
    if emoji.is_empty() || emoji.chars().any(|c| c.is_ascii_alphanumeric()) {
        return Err(AppError::bad_request("Send one emoji"));
    }
    let rid = room_id(&st, &code).await?;
    touch(&st, &rid, &u.id).await?;
    let who: Option<(String, Option<String>)> = sqlx::query_as("SELECT username, display_name FROM ios_users WHERE id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    let ev = json!({"type": "room_reaction", "room_code": code.to_uppercase(), "user_id": u.id,
        "display_name": who.as_ref().map(|w| w.1.clone().filter(|d| !d.is_empty()).unwrap_or(w.0.clone())), "emoji": emoji, "created_at": now_utc_iso()});
    let (st2, uid) = (st.clone(), u.id.clone());
    tokio::spawn(async move { push_room(&st2, &rid, ev, Some(&uid)).await });
    Ok(Json(json!({"status": "sent", "server_time": now_utc_iso()})))
}

async fn room_queue(State(st): State<AppState>, Path(code): Path<String>) -> ApiResult<Json<Value>> {
    let rid = room_id(&st, &code).await?;
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('id', id, 'track_url', track_url, 'title', title, 'artist', artist, 'votes', votes, \
           'added_by_user_id', added_by_user_id, 'added_at', lumi_iso(added_at)) ORDER BY votes DESC, added_at ASC), '[]'::json) FROM ios_room_queue WHERE room_id = $1",
    )
    .bind(&rid)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"queue": v})))
}

#[derive(Deserialize)]
struct QueueAdd {
    track_url: Option<String>,
    title: String,
    artist: Option<String>,
}

async fn add_room_queue(State(st): State<AppState>, u: User, Path(code): Path<String>, J(b): J<QueueAdd>) -> ApiResult<Response> {
    let rid = room_id(&st, &code).await?;
    let id = uuid::Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO ios_room_queue (id, room_id, added_by_user_id, track_url, title, artist) VALUES ($1, $2, $3, $4, $5, $6)")
        .bind(&id)
        .bind(&rid)
        .bind(&u.id)
        .bind(&b.track_url)
        .bind(&b.title)
        .bind(&b.artist)
        .execute(&st.db)
        .await?;
    touch(&st, &rid, &u.id).await?;
    let ev = json!({"type": "room_queue", "room_code": code.to_uppercase(), "added": {"item_id": id, "title": b.title, "artist": b.artist}});
    let (st2, uid) = (st.clone(), u.id.clone());
    tokio::spawn(async move { push_room(&st2, &rid, ev, Some(&uid)).await });
    Ok((StatusCode::CREATED, Json(json!({"id": id}))).into_response())
}

async fn vote_room_queue(State(st): State<AppState>, u: User, Path((code, item)): Path<(String, String)>) -> ApiResult<Json<Value>> {
    let rid: String = sqlx::query_scalar("SELECT q.room_id FROM ios_room_queue q JOIN ios_listen_rooms r ON r.id = q.room_id WHERE q.id = $1 AND r.room_code = $2")
        .bind(&item)
        .bind(code.to_uppercase())
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("Queue item not found"))?;
    let mut tx = st.db.begin().await?;
    let removed = sqlx::query("DELETE FROM ios_room_queue_votes WHERE item_id = $1 AND user_id = $2").bind(&item).bind(&u.id).execute(&mut *tx).await?.rows_affected();
    let voted = removed == 0;
    if voted {
        sqlx::query("INSERT INTO ios_room_queue_votes (item_id, user_id) VALUES ($1, $2) ON CONFLICT (item_id, user_id) DO NOTHING").bind(&item).bind(&u.id).execute(&mut *tx).await?;
    }
    let total: i32 = sqlx::query_scalar("UPDATE ios_room_queue SET votes = (SELECT count(*) FROM ios_room_queue_votes WHERE item_id = $1) WHERE id = $1 RETURNING votes")
        .bind(&item)
        .fetch_one(&mut *tx)
        .await?;
    tx.commit().await?;
    touch(&st, &rid, &u.id).await?;
    let ev = json!({"type": "room_queue", "room_code": code.to_uppercase(), "item_id": item, "votes": total});
    let st2 = st.clone();
    tokio::spawn(async move { push_room(&st2, &rid, ev, None).await });
    Ok(Json(json!({"status": if voted { "voted" } else { "unvoted" }, "votes": total})))
}

async fn remove_room_queue(State(st): State<AppState>, u: User, Path((code, item)): Path<(String, String)>) -> ApiResult<StatusCode> {
    let row: Option<(Option<String>, String)> =
        sqlx::query_as("SELECT q.added_by_user_id, r.host_user_id FROM ios_room_queue q JOIN ios_listen_rooms r ON r.id = q.room_id WHERE q.id = $1 AND r.room_code = $2")
            .bind(&item)
            .bind(code.to_uppercase())
            .fetch_optional(&st.db)
            .await?;
    let (added_by, host) = row.ok_or_else(|| AppError::not_found("Queue item not found"))?;
    if added_by.as_deref() != Some(u.id.as_str()) && host != u.id {
        return Err(AppError::forbidden("Only the host or the person who added this track can remove it"));
    }
    sqlx::query("DELETE FROM ios_room_queue WHERE id = $1").bind(&item).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn rooms_janitor(st: AppState) {
    loop {
        tokio::time::sleep(Duration::from_secs(3600)).await;
        let a = sqlx::query(&format!("DELETE FROM ios_listen_rooms WHERE updated_at < NOW() - make_interval(hours => {ROOM_IDLE_HOURS})")).execute(&st.db).await;
        let b = sqlx::query("DELETE FROM ios_room_participants WHERE last_seen_at < NOW() - make_interval(hours => 1)").execute(&st.db).await;
        match (a, b) {
            (Ok(a), Ok(b)) if a.rows_affected() + b.rows_affected() > 0 => {
                tracing::info!("rooms janitor: closed {} idle room(s), dropped {} stale membership(s)", a.rows_affected(), b.rows_affected())
            }
            (Err(e), _) | (_, Err(e)) => tracing::error!("rooms janitor: cleanup failed: {e}"),
            _ => {}
        }
    }
}

// ---- collaborators / tracked sources ---------------------------------------------------------

#[derive(Deserialize)]
struct CollabBody {
    username: String,
    #[serde(default = "editor")]
    role: String,
}

fn editor() -> String {
    "editor".into()
}

async fn add_collaborator(State(st): State<AppState>, u: User, Path(pid): Path<String>, J(b): J<CollabBody>) -> ApiResult<Response> {
    if b.role != "editor" && b.role != "viewer" {
        return Err(AppError::bad_request("role must be 'editor' or 'viewer'"));
    }
    let row: Option<(String, String)> = sqlx::query_as("SELECT user_id, name FROM ios_user_playlists WHERE id = $1").bind(&pid).fetch_optional(&st.db).await?;
    let (owner, name) = row.ok_or_else(|| AppError::not_found("Playlist not found"))?;
    if owner != u.id {
        return Err(AppError::forbidden("Only the owner can add collaborators"));
    }
    let target: Option<(String, String)> =
        sqlx::query_as("SELECT id, username FROM ios_users WHERE id = resolve_username($1)").bind(&b.username).fetch_optional(&st.db).await?;
    let (tid, tname) = target.ok_or_else(|| AppError::not_found("User not found"))?;
    if tid == u.id {
        return Err(AppError::bad_request("You already own this playlist"));
    }
    sqlx::query("INSERT INTO ios_playlist_collaborators (playlist_id, user_id, role) VALUES ($1, $2, $3) ON CONFLICT (playlist_id, user_id) DO UPDATE SET role = EXCLUDED.role")
        .bind(&pid)
        .bind(&tid)
        .bind(&b.role)
        .execute(&st.db)
        .await?;
    notify(&st, &tid, "playlist_collaborator", "Added to a playlist", &format!("You can now {} \"{name}\"", if b.role == "editor" { "edit" } else { "view" }),
        json!({"playlist_id": pid, "role": b.role})).await;
    crate::db::log_event(&st.db, "playlist", "collaborator_added", Some(&u.id), "info", "", Some(json!({"playlist_id": pid, "target_user_id": tid, "role": b.role}))).await;
    Ok((StatusCode::CREATED, Json(json!({"playlist_id": pid, "username": tname, "role": b.role}))).into_response())
}

async fn list_collaborators(State(st): State<AppState>, u: User, Path(pid): Path<String>) -> ApiResult<Json<Value>> {
    if crate::routes::library::playlist_role(&st, &pid, &u.id).await?.is_none() {
        return Err(AppError::not_found("Playlist not found"));
    }
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('user_id', u.id, 'username', u.username, 'role', c.role, 'added_at', lumi_iso(c.added_at)) ORDER BY c.added_at ASC), '[]'::json) \
             FROM ios_playlist_collaborators c JOIN ios_users u ON u.id = c.user_id WHERE c.playlist_id = $1",
        )
        .bind(&pid)
        .fetch_one(&st.db)
        .await?,
    ))
}

async fn remove_collaborator(State(st): State<AppState>, u: User, Path((pid, cid)): Path<(String, String)>) -> ApiResult<StatusCode> {
    let owner: String = sqlx::query_scalar("SELECT user_id FROM ios_user_playlists WHERE id = $1").bind(&pid).fetch_optional(&st.db).await?.ok_or_else(|| AppError::not_found("Playlist not found"))?;
    if owner != u.id && cid != u.id {
        return Err(AppError::forbidden("Not allowed"));
    }
    let r = sqlx::query("DELETE FROM ios_playlist_collaborators WHERE playlist_id = $1 AND user_id = $2").bind(&pid).bind(&cid).execute(&st.db).await?;
    if r.rows_affected() == 0 {
        return Err(AppError::not_found("Collaborator not found"));
    }
    crate::db::log_event(&st.db, "playlist", "collaborator_removed", Some(&u.id), "info", "", Some(json!({"playlist_id": pid, "target_user_id": cid}))).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn shared_with_me(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('id', p.id, 'name', p.name, 'description', p.description, 'role', c.role, 'owner_username', u.username, \
               'updated_at', lumi_iso(p.updated_at)) ORDER BY p.updated_at DESC), '[]'::json) FROM ios_playlist_collaborators c \
             JOIN ios_user_playlists p ON p.id = c.playlist_id JOIN ios_users u ON u.id = p.user_id WHERE c.user_id = $1",
        )
        .bind(&u.id)
        .fetch_one(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
struct SourceBody {
    source_url: String,
}

async fn set_playlist_source(State(st): State<AppState>, u: User, Path(pid): Path<String>, J(b): J<SourceBody>) -> ApiResult<Json<Value>> {
    crate::routes::media::reject_ssrf(&b.source_url).await?;
    let r = sqlx::query("UPDATE ios_user_playlists SET source_url = $1, source_new_count = 0 WHERE id = $2 AND user_id = $3").bind(&b.source_url).bind(&pid).bind(&u.id).execute(&st.db).await?;
    if r.rows_affected() == 0 {
        return Err(AppError::not_found("Playlist not found"));
    }
    Ok(Json(json!({"status": "ok"})))
}

/// `_refresh_playlist_source_core`.
pub async fn refresh_source(st: &AppState, pid: &str, user: &str, url: &str, local: i64, notify_user: bool) -> ApiResult<Value> {
    let mut args: Vec<String> = vec!["--dump-json".into(), "--flat-playlist".into(), "--no-warnings".into()];
    args.extend(st.ytdlp.cookie_args(Some(user), false).await);
    args.push(url.into());
    let entries = st.ytdlp.run_json(&args, Duration::from_secs(60)).await.map_err(|e| match e {
        crate::ytdlp::RunError::Timeout => AppError::new(408, "Playlist refresh timed out"),
        _ => AppError::not_found("Could not resolve playlist source"),
    })?;
    let remote = entries.len() as i64;
    let new = (remote - local).max(0);
    sqlx::query("UPDATE ios_user_playlists SET source_checked_at = NOW(), source_new_count = $1 WHERE id = $2 AND user_id = $3").bind(new as i32).bind(pid).bind(user).execute(&st.db).await?;
    if notify_user && new > 0 {
        let name: String = sqlx::query_scalar("SELECT name FROM ios_user_playlists WHERE id = $1")
            .bind(pid)
            .fetch_optional(&st.db)
            .await?
            .unwrap_or_else(|| "a tracked playlist".into());
        notify(st, user, "playlist_source_update", &format!("{new} new track{} in \"{name}\"", if new != 1 { "s" } else { "" }), "Tap to review and import",
            json!({"playlist_id": pid, "new_count": new})).await;
        st.fire_user_webhooks(user, "playlist_update", json!({"playlist_id": pid, "playlist_name": name, "new_count": new})).await;
    }
    Ok(json!({"remote_count": remote, "local_count": local, "new_count": new}))
}

async fn refresh_playlist_source(State(st): State<AppState>, u: User, Path(pid): Path<String>) -> ApiResult<Json<Value>> {
    let src: Option<Option<String>> = sqlx::query_scalar("SELECT source_url FROM ios_user_playlists WHERE id = $1 AND user_id = $2").bind(&pid).bind(&u.id).fetch_optional(&st.db).await?;
    let src = src.ok_or_else(|| AppError::not_found("Playlist not found"))?.filter(|s| !s.is_empty()).ok_or_else(|| AppError::bad_request("Playlist has no source URL set"))?;
    let local: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM ios_playlist_tracks WHERE playlist_id = $1").bind(&pid).fetch_one(&st.db).await?;
    Ok(Json(refresh_source(&st, &pid, &u.id, &src, local, false).await?))
}

mod md5_lite {
    /// MD5 hex digest (ETag compatibility with the Python bridge's hashlib.md5).
    pub fn md5_hex(data: &[u8]) -> String {
        use md5::{Digest, Md5};
        hex::encode(Md5::digest(data))
    }
}
