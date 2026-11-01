//! Stats + discovery (route group 5, the non-AI parts): stats, reviews,
//! heatmap, achievements, on-this-day, artist bio/image, recommendations,
//! smart playlists, weekly mix, discover mix, search trends, export.

use crate::analysis::{camelot, camelot_compatible, pyround};
use crate::auth::{ApiKey, User};
use crate::error::{ApiResult, AppError};
use crate::extract::{Q, check_range, invalid};
use crate::state::AppState;
use crate::ytdlp::{parse_track, source_from_url};
use axum::extract::State;
use axum::http::header;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use chrono::{Datelike, Duration as CDuration, NaiveDate, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/user/stats", get(stats))
        .route("/user/stats/weekly", get(weekly))
        .route("/user/stats/heatmap", get(heatmap))
        .route("/user/stats/year-in-review", get(year_review))
        .route("/user/stats/month-in-review", get(month_review))
        .route("/user/achievements", get(achievements))
        .route("/user/on-this-day", get(on_this_day))
        .route("/api/artist/bio", get(artist_bio))
        .route("/api/artist/image", get(artist_image))
        .route("/user/music/recommendations", get(recommendations))
        .route("/user/music/smart-playlists", get(smart_playlists))
        .route("/user/music/weekly-mix", get(weekly_mix))
        .route("/user/discover-mix", get(discover_mix))
        .route("/api/search/trending", get(trending))
        .route("/api/search/suggestions", get(suggestions))
        .route("/user/export", get(export))
}

#[derive(Deserialize, Default)]
struct P {
    limit: Option<i64>,
    days: Option<i64>,
    year: Option<i64>,
    month: Option<i64>,
    tz_offset_minutes: Option<i64>,
    name: Option<String>,
    id: Option<String>,
    q: Option<String>,
    force_regenerate: Option<bool>,
}

// ---- stats -----------------------------------------------------------------------------------

async fn stats(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Value = sqlx::query_scalar(
        "SELECT json_build_object( \
           'total_plays', (SELECT COUNT(*) FROM ios_play_history WHERE user_id = $1), \
           'total_listen_seconds', (SELECT COALESCE(SUM(listen_seconds), 0)::bigint FROM ios_play_history WHERE user_id = $1), \
           'top_artists', COALESCE((SELECT json_agg(json_build_object('artist', artist, 'play_count', plays) ORDER BY plays DESC) FROM \
              (SELECT artist, COUNT(*) AS plays FROM ios_play_history WHERE user_id = $1 AND artist IS NOT NULL AND artist != '' \
               GROUP BY artist ORDER BY plays DESC LIMIT 5) a), '[]'::json), \
           'top_tracks', COALESCE((SELECT json_agg(json_build_object('title', title, 'artist', artist, 'play_count', plays) ORDER BY plays DESC) FROM \
              (SELECT title, artist, COUNT(*) AS plays FROM ios_play_history WHERE user_id = $1 AND title IS NOT NULL AND title != '' \
               GROUP BY title, artist ORDER BY plays DESC LIMIT 5) t), '[]'::json))",
    )
    .bind(&u.id)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(v))
}

const DAY_ROW: &str = "json_build_object('date', to_char(day, 'YYYY-MM-DD'), 'plays', plays, 'listen_seconds', seconds::bigint)";

async fn weekly(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    Ok(Json(
        sqlx::query_scalar(&format!(
            "SELECT COALESCE(json_agg({DAY_ROW} ORDER BY day ASC), '[]'::json) FROM \
             (SELECT DATE(played_at) AS day, COUNT(*) AS plays, COALESCE(SUM(listen_seconds), 0) AS seconds FROM ios_play_history \
              WHERE user_id = $1 AND played_at >= (CURRENT_DATE - INTERVAL '6 days') GROUP BY DATE(played_at)) d"
        ))
        .bind(&u.id)
        .fetch_one(&st.db)
        .await?,
    ))
}

async fn heatmap(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let days = p.days.unwrap_or(365);
    check_range("days", days, 7, 400)?;
    Ok(Json(
        sqlx::query_scalar(&format!(
            "SELECT COALESCE(json_agg({DAY_ROW} ORDER BY day ASC), '[]'::json) FROM \
             (SELECT DATE(played_at) AS day, COUNT(*) AS plays, COALESCE(SUM(listen_seconds), 0) AS seconds FROM ios_play_history \
              WHERE user_id = $1 AND played_at >= (CURRENT_DATE - make_interval(days => $2)) GROUP BY DATE(played_at)) d"
        ))
        .bind(&u.id)
        .bind((days - 1) as i32)
        .fetch_one(&st.db)
        .await?,
    ))
}

/// Shared body of year/month in review; `filter` restricts ios_play_history.
async fn review(st: &AppState, user: &str, year: i64, month: Option<i64>) -> ApiResult<Value> {
    let filter = "user_id = $1 AND EXTRACT(YEAR FROM played_at) = $2 AND ($3::int IS NULL OR EXTRACT(MONTH FROM played_at) = $3)";
    let v: Value = sqlx::query_scalar(&format!(
        "SELECT json_build_object( \
           'summary', (SELECT json_build_object('plays', COUNT(*), 'seconds', COALESCE(SUM(listen_seconds), 0)::bigint, \
               'artists', COUNT(DISTINCT artist) FILTER (WHERE artist IS NOT NULL AND artist != ''), \
               'tracks', COUNT(DISTINCT (title, COALESCE(artist, ''))), 'bpm', AVG(bpm) FILTER (WHERE bpm IS NOT NULL)) \
             FROM ios_play_history WHERE {filter}), \
           'top_artists', COALESCE((SELECT json_agg(json_build_object('artist', artist, 'play_count', plays, 'listen_seconds', seconds::bigint) ORDER BY plays DESC) \
             FROM (SELECT artist, COUNT(*) AS plays, COALESCE(SUM(listen_seconds), 0) AS seconds FROM ios_play_history WHERE {filter} \
                   AND artist IS NOT NULL AND artist != '' GROUP BY artist ORDER BY plays DESC LIMIT 5) a), '[]'::json), \
           'top_tracks', COALESCE((SELECT json_agg(json_build_object('title', title, 'artist', artist, 'play_count', plays) ORDER BY plays DESC) \
             FROM (SELECT title, artist, COUNT(*) AS plays FROM ios_play_history WHERE {filter} AND title IS NOT NULL AND title != '' \
                   GROUP BY title, artist ORDER BY plays DESC LIMIT 5) t), '[]'::json), \
           'by_month', COALESCE((SELECT json_agg(json_build_object('month', m, 'plays', plays, 'listen_seconds', seconds::bigint)) \
             FROM (SELECT EXTRACT(MONTH FROM played_at)::int AS m, COUNT(*) AS plays, COALESCE(SUM(listen_seconds), 0) AS seconds \
                   FROM ios_play_history WHERE {filter} GROUP BY m) b), '[]'::json), \
           'by_day', COALESCE((SELECT json_agg({DAY_ROW} ORDER BY day ASC) FROM (SELECT DATE(played_at) AS day, COUNT(*) AS plays, \
                   COALESCE(SUM(listen_seconds), 0) AS seconds FROM ios_play_history WHERE {filter} GROUP BY day) d), '[]'::json), \
           'peak', (SELECT {DAY_ROW} FROM (SELECT DATE(played_at) AS day, COUNT(*) AS plays, COALESCE(SUM(listen_seconds), 0) AS seconds \
                   FROM ios_play_history WHERE {filter} GROUP BY day ORDER BY seconds DESC LIMIT 1) p))"
    ))
    .bind(user)
    .bind(year as i32)
    .bind(month.map(|m| m as i32))
    .fetch_one(&st.db)
    .await?;
    let s = &v["summary"];
    let mut out = json!({
        "year": year,
        "total_plays": s["plays"].as_i64().unwrap_or(0),
        "total_listen_seconds": s["seconds"].as_i64().unwrap_or(0),
        "distinct_artists": s["artists"].as_i64().unwrap_or(0),
        "distinct_tracks": s["tracks"].as_i64().unwrap_or(0),
        "average_bpm": s["bpm"].as_f64().map(|b| pyround(b, 1)),
        "top_artists": v["top_artists"],
        "top_tracks": v["top_tracks"],
        "peak_day": if v["peak"]["plays"].as_i64().unwrap_or(0) > 0 { v["peak"].clone() } else { Value::Null },
    });
    match month {
        Some(m) => {
            out["month"] = json!(m);
            out["by_day"] = v["by_day"].clone();
        }
        None => {
            let mut by: HashMap<i64, (i64, i64)> = HashMap::new();
            for r in v["by_month"].as_array().into_iter().flatten() {
                by.insert(r["month"].as_i64().unwrap_or(0), (r["plays"].as_i64().unwrap_or(0), r["listen_seconds"].as_i64().unwrap_or(0)));
            }
            out["by_month"] = json!((1..=12)
                .map(|m| {
                    let (p, s) = by.get(&m).copied().unwrap_or((0, 0));
                    json!({"month": m, "plays": p, "listen_seconds": s})
                })
                .collect::<Vec<_>>());
        }
    }
    Ok(out)
}

async fn year_review(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let year = p.year.filter(|y| *y != 0).unwrap_or(Utc::now().year() as i64);
    Ok(Json(review(&st, &u.id, year, None).await?))
}

async fn month_review(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    if let Some(m) = p.month {
        check_range("month", m, 1, 12)?;
    }
    let now = Utc::now();
    let year = p.year.filter(|y| *y != 0).unwrap_or(now.year() as i64);
    let month = p.month.unwrap_or(now.month() as i64);
    Ok(Json(review(&st, &u.id, year, Some(month)).await?))
}

async fn achievements(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let tz = p.tz_offset_minutes.unwrap_or(0);
    check_range("tz_offset_minutes", tz, -840, 840)?;
    let shift = "($2 || ' minutes')::interval";
    let v: Value = sqlx::query_scalar(&format!(
        "SELECT json_build_object( \
           'plays', (SELECT COUNT(*) FROM ios_play_history WHERE user_id = $1), \
           'seconds', (SELECT COALESCE(SUM(listen_seconds), 0)::bigint FROM ios_play_history WHERE user_id = $1), \
           'dates', COALESCE((SELECT json_agg(d ORDER BY d DESC) FROM (SELECT DISTINCT DATE(played_at + {shift}) AS d FROM ios_play_history WHERE user_id = $1) x), '[]'::json), \
           'hours', COALESCE((SELECT json_agg(h) FROM (SELECT DISTINCT EXTRACT(HOUR FROM played_at + {shift})::int AS h FROM ios_play_history WHERE user_id = $1) y), '[]'::json), \
           'max_day', (SELECT COALESCE(MAX(daily), 0)::bigint FROM (SELECT SUM(listen_seconds) AS daily FROM ios_play_history WHERE user_id = $1 GROUP BY DATE(played_at + {shift})) t), \
           'artists', (SELECT COUNT(DISTINCT artist) FROM ios_play_history WHERE user_id = $1 AND artist IS NOT NULL), \
           'per_artist', (SELECT COALESCE(MAX(cnt), 0) FROM (SELECT COUNT(DISTINCT title) AS cnt FROM ios_play_history WHERE user_id = $1 AND artist IS NOT NULL GROUP BY artist) t), \
           'library', (SELECT COUNT(*) FROM ios_user_library WHERE user_id = $1), \
           'distinct_played', (SELECT COUNT(DISTINCT COALESCE(local_song_id, track_url, title)) FROM ios_play_history WHERE user_id = $1))"
    ))
    .bind(&u.id)
    .bind(tz.to_string())
    .fetch_one(&st.db)
    .await?;
    let dates: Vec<NaiveDate> = v["dates"].as_array().into_iter().flatten().filter_map(|d| NaiveDate::parse_from_str(d.as_str()?, "%Y-%m-%d").ok()).collect();
    let (mut current, mut longest) = (0, 0);
    if !dates.is_empty() {
        let mut run = 1;
        longest = 1;
        for i in 1..dates.len() {
            if (dates[i - 1] - dates[i]).num_days() == 1 {
                run += 1;
            } else {
                longest = longest.max(run);
                run = 1;
            }
        }
        longest = longest.max(run);
        let today = (Utc::now() + CDuration::minutes(tz)).date_naive();
        if dates[0] == today || dates[0] == today - CDuration::days(1) {
            current = 1;
            for i in 1..dates.len() {
                if (dates[i - 1] - dates[i]).num_days() == 1 {
                    current += 1;
                } else {
                    break;
                }
            }
        }
    }
    let plays = v["plays"].as_i64().unwrap_or(0);
    let secs = v["seconds"].as_i64().unwrap_or(0);
    let hours: HashSet<i64> = v["hours"].as_array().into_iter().flatten().filter_map(Value::as_i64).collect();
    let mut badges: Vec<String> = Vec::new();
    badges.extend([10, 50, 100, 500, 1000].iter().filter(|n| plays >= **n).map(|n| format!("plays_{n}")));
    badges.extend([1, 10, 24, 100].iter().filter(|n| secs as f64 / 3600.0 >= **n as f64).map(|n| format!("hours_{n}")));
    badges.extend([3, 7, 30, 100].iter().filter(|n| longest >= **n).map(|n| format!("streak_{n}")));
    if (0..5).any(|h| hours.contains(&h)) {
        badges.push("night_owl".into());
    }
    if (5..9).any(|h| hours.contains(&h)) {
        badges.push("early_bird".into());
    }
    if v["max_day"].as_i64().unwrap_or(0) >= 3 * 3600 {
        badges.push("marathon".into());
    }
    if v["library"].as_i64().unwrap_or(0) >= 100 {
        badges.push("crate_digger".into());
    }
    if v["artists"].as_i64().unwrap_or(0) >= 25 {
        badges.push("globe_trotter".into());
    }
    if v["per_artist"].as_i64().unwrap_or(0) >= 15 {
        badges.push("completionist".into());
    }
    if v["distinct_played"].as_i64().unwrap_or(0) >= 200 {
        badges.push("shuffle_master".into());
    }
    Ok(Json(json!({"total_plays": plays, "total_listen_seconds": secs, "current_streak_days": current, "longest_streak_days": longest, "badges": badges})))
}

fn track_id_from_url(url: &str, source: &str) -> String {
    let Ok(u) = url::Url::parse(url) else { return url.to_string() };
    if source == "youtube" {
        if let Some(q) = u.query() {
            for part in q.split('&') {
                if let Some(v) = part.strip_prefix("v=") {
                    let id: String = v.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').collect();
                    if !id.is_empty() {
                        return id;
                    }
                }
            }
        }
        if u.host_str().is_some_and(|h| h.contains("youtu.be")) {
            return u.path().trim_matches('/').to_string();
        }
    }
    u.path().split('/').filter(|s| !s.is_empty()).last().map(str::to_string).unwrap_or_else(|| url.to_string())
}

async fn on_this_day(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let rows: Vec<(String, Option<String>, Option<String>, i32)> = sqlx::query_as(
        "SELECT track_url, title, artist, EXTRACT(YEAR FROM played_at)::int FROM ios_play_history \
         WHERE user_id = $1 AND track_url IS NOT NULL AND track_url != '' \
           AND EXTRACT(MONTH FROM played_at) = EXTRACT(MONTH FROM CURRENT_DATE) AND EXTRACT(DAY FROM played_at) = EXTRACT(DAY FROM CURRENT_DATE) \
           AND EXTRACT(YEAR FROM played_at) < EXTRACT(YEAR FROM CURRENT_DATE) ORDER BY played_at DESC",
    )
    .bind(&u.id)
    .fetch_all(&st.db)
    .await?;
    let this_year = Utc::now().year();
    let mut groups: std::collections::BTreeMap<i32, Vec<Value>> = Default::default();
    let mut seen: HashMap<i32, HashSet<String>> = HashMap::new();
    for (url, title, artist, year) in rows {
        let source = source_from_url(&url);
        let id = track_id_from_url(&url, source);
        if !seen.entry(year).or_default().insert(id.clone()) {
            continue;
        }
        let g = groups.entry(year).or_default();
        if g.len() >= 15 {
            continue;
        }
        g.push(json!({"id": id, "title": title.filter(|t| !t.is_empty()).unwrap_or_else(|| "Unknown Title".into()),
            "artist": artist.filter(|a| !a.is_empty()).unwrap_or_else(|| "Unknown Artist".into()), "duration_seconds": 0,
            "thumbnail_url": "", "source": source, "youtube_url": url}));
    }
    Ok(Json(Value::Array(groups.into_iter().rev().map(|(y, t)| json!({"years_ago": this_year - y, "year": y, "tracks": t})).collect())))
}

// ---- artists ---------------------------------------------------------------------------------

const BIO_UA: &str = "Lumisound-iOS-Bridge/1.0 (+https://github.com/HollowHeavenXR/Lumisound)";

async fn get_json(st: &AppState, url: &str, q: &[(&str, &str)]) -> Option<Value> {
    let r = st.http.get(url).query(q).header("User-Agent", BIO_UA).timeout(Duration::from_secs(10)).send().await.ok()?;
    if !r.status().is_success() {
        return None;
    }
    r.json().await.ok()
}

async fn wiki_summary(st: &AppState, name: &str) -> Option<Value> {
    let s = get_json(st, "https://en.wikipedia.org/w/api.php", &[("action", "query"), ("list", "search"), ("srsearch", &format!("{name} musician")), ("format", "json"), ("srlimit", "1")]).await?;
    let title = s["query"]["search"][0]["title"].as_str()?.replace(' ', "_");
    get_json(st, &format!("https://en.wikipedia.org/api/rest_v1/page/summary/{}", urlencoding::encode(&title)), &[]).await
}

fn name_param(p: &P) -> ApiResult<String> {
    let n = p.name.clone().ok_or_else(|| invalid("name", "Field required"))?;
    if n.is_empty() || n.chars().count() > 255 {
        return Err(invalid("name", "String should have between 1 and 255 characters"));
    }
    Ok(n)
}

async fn artist_bio(State(st): State<AppState>, _u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let name = name_param(&p)?;
    let key = name.trim().to_lowercase();
    if key.is_empty() {
        return Err(AppError::bad_request("name is required"));
    }
    let row: Option<(Option<String>, Option<bool>)> =
        sqlx::query_as("SELECT bio_json, found FROM ios_artist_bio_cache WHERE artist_name = $1 AND cached_at > NOW() - make_interval(days => 30)")
            .bind(&key)
            .fetch_optional(&st.db)
            .await?;
    if let Some((bio, found)) = row {
        if found.unwrap_or(false) {
            if let Some(v) = bio.and_then(|b| serde_json::from_str(&b).ok()) {
                return Ok(Json(v));
            }
        }
        return Ok(Json(json!({"found": false})));
    }
    let mb = get_json(&st, "https://musicbrainz.org/ws/2/artist/", &[("query", &format!("artist:\"{name}\"")), ("fmt", "json"), ("limit", "1")]).await;
    let mb = mb.and_then(|d| d["artists"].get(0).cloned()).unwrap_or(json!({}));
    let wiki = wiki_summary(&st, &name).await;
    let found = wiki.as_ref().and_then(|w| w["extract"].as_str()).is_some_and(|e| !e.is_empty());
    let result = if found {
        let w = wiki.unwrap();
        let tags: Vec<Value> = mb["tags"].as_array().into_iter().flatten().filter_map(|t| t.get("name").cloned()).take(6).collect();
        json!({
            "found": true,
            "name": mb["name"].as_str().filter(|s| !s.is_empty()).unwrap_or(&name),
            "bio": w["extract"].as_str().unwrap_or(""),
            "image_url": w["thumbnail"]["source"].as_str().unwrap_or(""),
            "wikipedia_url": w["content_urls"]["desktop"]["page"].as_str().unwrap_or(""),
            "artist_type": mb.get("type").cloned().unwrap_or(Value::Null),
            "country": mb.get("country").cloned().unwrap_or(Value::Null),
            "begin_date": mb["life-span"].get("begin").cloned().unwrap_or(Value::Null),
            "end_date": mb["life-span"].get("end").cloned().unwrap_or(Value::Null),
            "tags": tags,
        })
    } else {
        json!({"found": false})
    };
    sqlx::query(
        "INSERT INTO ios_artist_bio_cache (artist_name, bio_json, found) VALUES ($1, $2, $3) \
         ON CONFLICT (artist_name) DO UPDATE SET bio_json = EXCLUDED.bio_json, found = EXCLUDED.found, cached_at = NOW()",
    )
    .bind(&key)
    .bind(result.to_string())
    .bind(found)
    .execute(&st.db)
    .await?;
    Ok(Json(result))
}

/// `_resolve_artist_image`: Deezer, then Wikipedia, then the YouTube channel icon.
pub async fn resolve_artist_image(st: &AppState, name: &str, yt_key: &str) -> Value {
    let trimmed = name.trim();
    if !trimmed.is_empty() && trimmed.to_lowercase() != "unknown artist" {
        if let Some(d) = get_json(st, "https://api.deezer.com/search/artist", &[("q", trimmed), ("limit", "1")]).await {
            if let Some(first) = d["data"].get(0) {
                for f in ["picture_xl", "picture_big", "picture_medium"] {
                    if let Some(u) = first[f].as_str().filter(|u| !u.is_empty() && !u.contains("artist//")) {
                        return json!({"found": true, "image_url": u, "source": "deezer"});
                    }
                }
            }
        }
    }
    if let Some(img) = wiki_summary(st, name).await.and_then(|w| w["thumbnail"]["source"].as_str().map(str::to_string)) {
        return json!({"found": true, "image_url": img, "source": "wikipedia"});
    }
    if !yt_key.is_empty() {
        if let Ok(r) = st.yt.resolve_channel(name, yt_key).await {
            if let Some(t) = r["channel_thumbnail"].as_str().filter(|t| !t.is_empty()) {
                return json!({"found": true, "image_url": t, "source": "youtube"});
            }
        }
    }
    json!({"found": false, "image_url": null, "source": null})
}

pub async fn upsert_artist_image(st: &AppState, key: &str, r: &Value) {
    let found = r["found"].as_bool().unwrap_or(false);
    let _ = sqlx::query(
        "INSERT INTO ios_artist_image_cache (artist_name, image_url, image_source, found, last_checked_at, resolved_at) \
         VALUES ($1, $2, $3, $4, NOW(), CASE WHEN $4 THEN NOW() ELSE NULL END) ON CONFLICT (artist_name) DO UPDATE SET \
           image_url = EXCLUDED.image_url, image_source = EXCLUDED.image_source, found = EXCLUDED.found, last_checked_at = NOW(), \
           resolved_at = CASE WHEN EXCLUDED.found THEN NOW() ELSE ios_artist_image_cache.resolved_at END",
    )
    .bind(key)
    .bind(r["image_url"].as_str())
    .bind(r["source"].as_str())
    .bind(found)
    .execute(&st.db)
    .await;
}

async fn artist_image(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let name = name_param(&p)?;
    let key = name.trim().to_lowercase();
    if key.is_empty() {
        return Err(AppError::bad_request("name is required"));
    }
    let row: Option<(Option<String>, Option<String>, Option<bool>)> =
        sqlx::query_as("SELECT image_url, image_source, found FROM ios_artist_image_cache WHERE artist_name = $1").bind(&key).fetch_optional(&st.db).await?;
    if let Some((url, source, found)) = row {
        return Ok(Json(json!({"found": found.unwrap_or(false), "image_url": url, "source": source})));
    }
    let yt_key = st.yt.key_for_user(&st.db, &u.id, st.cfg.youtube_api_key.as_deref()).await;
    let r = resolve_artist_image(&st, &name, &yt_key).await;
    upsert_artist_image(&st, &key, &r).await;
    Ok(Json(json!({"found": r["found"], "image_url": r["image_url"], "source": r["source"]})))
}

// ---- library-derived mixes -------------------------------------------------------------------

async fn recommendations(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let id = p.id.ok_or_else(|| invalid("id", "Field required"))?;
    let limit = p.limit.unwrap_or(10);
    check_range("limit", limit, 1, 50)?;
    let seed: Option<(Option<f64>, Option<String>)> =
        sqlx::query_as("SELECT bpm, musical_key FROM ios_user_music_metadata WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).fetch_optional(&st.db).await?;
    let (seed_bpm, seed_key) = seed.ok_or_else(|| AppError::not_found("Track not found"))?;
    type R = (String, Option<String>, Option<String>, Option<String>, Option<String>, f64, String);
    let rows: Vec<R> = sqlx::query_as(
        "SELECT id, filename, title, artist, album, bpm, musical_key FROM ios_user_music_metadata \
         WHERE user_id = $1 AND id != $2 AND bpm IS NOT NULL AND musical_key IS NOT NULL",
    )
    .bind(&u.id)
    .bind(&id)
    .fetch_all(&st.db)
    .await?;
    let seed_cam = camelot(seed_key.as_deref());
    let mut c: Vec<(bool, f64, Value)> = Vec::new();
    for (mid, filename, title, artist, album, bpm, key) in rows {
        let mut ratio: Option<f64> = None;
        if let Some(sb) = seed_bpm.filter(|b| *b != 0.0) {
            if bpm != 0.0 {
                for f in [1.0, 0.5, 2.0] {
                    let r = bpm * f / sb;
                    let r = if r <= 1.0 { r } else { 1.0 / r };
                    ratio = Some(ratio.map_or(r, |x: f64| x.max(r)));
                }
            }
        }
        let key_ok = camelot_compatible(seed_cam, camelot(Some(&key)));
        let bpm_ok = ratio.is_some_and(|r| r >= 0.92);
        if !key_ok && !bpm_ok {
            continue;
        }
        let rr = ratio.map(|r| pyround(r, 3));
        c.push((key_ok, rr.unwrap_or(0.0), json!({"id": mid, "filename": filename, "title": title, "artist": artist, "album": album,
            "bpm": bpm, "musical_key": key, "key_compatible": key_ok, "bpm_ratio": rr})));
    }
    c.sort_by(|a, b| (!a.0).cmp(&!b.0).then(b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal)));
    Ok(Json(json!({"seed_bpm": seed_bpm, "seed_key": seed_key, "tracks": c.into_iter().take(limit as usize).map(|x| x.2).collect::<Vec<_>>()})))
}

fn mood_bucket(bpm: Option<f64>, genre: Option<&str>, title: Option<&str>) -> Option<&'static str> {
    if let Some(b) = bpm.filter(|b| *b != 0.0) {
        return Some(if b >= 120.0 { "energetic" } else if b >= 90.0 { "focus" } else if b >= 60.0 { "chill" } else { "sleep" });
    }
    const GENRE: &[(&str, &[&str])] = &[
        ("energetic", &["rock", "metal", "dance", "electronic", "edm", "house", "techno", "punk", "rap", "hip hop", "hip-hop", "drum", "bass", "trance", "workout", "hardstyle", "remix", "pop"]),
        ("focus", &["soundtrack", "score", "instrumental", "game", "video game", "orchestral", "epic", "cinematic", "study", "chiptune", "synthwave"]),
        ("chill", &["chill", "lo-fi", "lofi", "jazz", "acoustic", "indie", "folk", "r&b", "soul", "reggae", "bossa"]),
        ("sleep", &["ambient", "sleep", "calm", "meditation", "piano", "classical", "rain"]),
    ];
    const TITLE: &[(&str, &[&str])] = &[
        ("chill", &["slowed", "reverb", "chill", "lofi", "lo-fi", "acoustic"]),
        ("sleep", &["sleep", "lullaby", "rain", "ambient", "calm"]),
        ("energetic", &["remix", "8 bit", "8-bit", "hardstyle", "nightcore", "epic remix"]),
        ("focus", &["ost", "theme", "soundtrack", "instrumental", "orchestral"]),
    ];
    for (text, table) in [(genre.unwrap_or("").to_lowercase(), GENRE), (title.unwrap_or("").to_lowercase(), TITLE)] {
        if text.is_empty() {
            continue;
        }
        for (bucket, hints) in table {
            if hints.iter().any(|h| text.contains(h)) {
                return Some(bucket);
            }
        }
    }
    None
}

async fn smart_playlists(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    type R = (String, Option<String>, Option<String>, Option<String>, Option<String>, Option<f64>, Option<String>, i64);
    let rows: Vec<R> = sqlx::query_as(
        "SELECT m.id, m.filename, m.title, m.artist, m.album, m.bpm, m.genre, COALESCE(p.plays, 0) FROM ios_user_music_metadata m \
         LEFT JOIN (SELECT title, artist, COUNT(*) AS plays FROM ios_play_history WHERE user_id = $1 GROUP BY title, artist) p \
           ON p.title = m.title AND p.artist = m.artist WHERE m.user_id = $1",
    )
    .bind(&u.id)
    .fetch_all(&st.db)
    .await?;
    let mut b: HashMap<&str, Vec<(i64, String, Value)>> = HashMap::new();
    for (id, f, t, a, al, bpm, g, plays) in rows {
        if let Some(k) = mood_bucket(bpm, g.as_deref(), t.as_deref()) {
            let sort_t = t.clone().unwrap_or_default().to_lowercase();
            b.entry(k).or_default().push((plays, sort_t, json!({"id": id, "filename": f, "title": t, "artist": a, "album": al, "bpm": bpm, "plays": plays})));
        }
    }
    let mut take = |k: &str| {
        let mut v = b.remove(k).unwrap_or_default();
        v.sort_by(|x, y| y.0.cmp(&x.0).then(x.1.cmp(&y.1)));
        v.into_iter().take(200).map(|x| x.2).collect::<Vec<_>>()
    };
    Ok(Json(json!({"playlists": [
        {"name": "Workout", "key": "energetic", "tracks": take("energetic")},
        {"name": "Focus", "key": "focus", "tracks": take("focus")},
        {"name": "Cooldown", "key": "chill", "tracks": take("chill")},
        {"name": "Sleep", "key": "sleep", "tracks": take("sleep")},
    ]})))
}

/// `_generate_weekly_mix_core`: 25 random tracks weighted to 90-day top artists.
pub async fn generate_weekly_mix(st: &AppState, user: &str) -> anyhow::Result<Vec<Value>> {
    const ROW: &str = "json_build_object('metadata_id', id, 'title', COALESCE(title, 'Unknown Title'), 'artist', COALESCE(artist, 'Unknown Artist'), \
        'album', COALESCE(album, ''), 'bpm', bpm, 'musical_key', musical_key, 'relative_path', relative_path, 'has_artwork', COALESCE(has_artwork, false))";
    let top: Vec<String> = sqlx::query_scalar(
        "SELECT artist FROM ios_play_history WHERE user_id = $1 AND played_at >= NOW() - INTERVAL '90 days' AND artist IS NOT NULL AND artist != '' \
         GROUP BY artist ORDER BY COUNT(*) DESC LIMIT 10",
    )
    .bind(user)
    .fetch_all(&st.db)
    .await?;
    let mut rows: Vec<Value> = if top.is_empty() {
        vec![]
    } else {
        sqlx::query_scalar(&format!(
            "SELECT {ROW} FROM ios_user_music_metadata WHERE user_id = $1 AND artist = ANY($2) AND relative_path IS NOT NULL ORDER BY RANDOM() LIMIT 25"
        ))
        .bind(user)
        .bind(&top)
        .fetch_all(&st.db)
        .await?
    };
    if rows.len() < 25 {
        let mut seen: HashSet<String> = rows.iter().filter_map(|r| r["metadata_id"].as_str().map(str::to_string)).collect();
        let extra: Vec<Value> = sqlx::query_scalar(&format!("SELECT {ROW} FROM ios_user_music_metadata WHERE user_id = $1 AND relative_path IS NOT NULL ORDER BY RANDOM() LIMIT 25"))
            .bind(user)
            .fetch_all(&st.db)
            .await?;
        for r in extra {
            let id = r["metadata_id"].as_str().unwrap_or("").to_string();
            if rows.len() < 25 && seen.insert(id) {
                rows.push(r);
            }
        }
    }
    Ok(rows)
}

pub async fn save_weekly_mix(st: &AppState, user: &str, tracks: &[Value]) -> anyhow::Result<()> {
    sqlx::query(
        "INSERT INTO ios_weekly_mix_cache (user_id, track_ids_json) VALUES ($1, $2) \
         ON CONFLICT (user_id) DO UPDATE SET track_ids_json = EXCLUDED.track_ids_json, generated_at = NOW()",
    )
    .bind(user)
    .bind(serde_json::to_string(tracks)?)
    .execute(&st.db)
    .await?;
    Ok(())
}

async fn weekly_mix(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    if !p.force_regenerate.unwrap_or(false) {
        let row: Option<(String, Option<String>)> =
            sqlx::query_as("SELECT track_ids_json, lumi_iso(generated_at) FROM ios_weekly_mix_cache WHERE user_id = $1").bind(&u.id).fetch_optional(&st.db).await?;
        if let Some((t, at)) = row {
            return Ok(Json(json!({"tracks": serde_json::from_str::<Value>(&t).unwrap_or(json!([])), "generated_at": at})));
        }
    }
    let tracks = generate_weekly_mix(&st, &u.id).await?;
    save_weekly_mix(&st, &u.id, &tracks).await?;
    Ok(Json(json!({"tracks": tracks, "generated_at": null})))
}

/// `_rotating_seed`: a different `count`-slice of `pool` each day, per user.
pub fn rotating_seed(pool: &[String], user: &str, count: usize) -> Vec<String> {
    if pool.is_empty() {
        return vec![];
    }
    // date.today().toordinal(): days since 0001-01-01, day 1.
    let day = Utc::now().date_naive().num_days_from_ce() as u64;
    let off = ((day + crc32fast::hash(user.as_bytes()) as u64) % pool.len() as u64) as usize;
    (0..count.min(pool.len())).map(|i| pool[(off + i) % pool.len()].clone()).collect()
}

async fn discover_mix(State(st): State<AppState>, u: User, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(20);
    check_range("limit", limit, 1, 50)?;
    Ok(Json(Value::Array(discover_tracks(&st, &u.id, limit).await?)))
}

/// `get_discover_mix` body, shared with Aria's daily pick.
pub async fn discover_tracks(st: &AppState, user: &str, limit: i64) -> ApiResult<Vec<Value>> {
    let pool: Vec<String> = sqlx::query_scalar(
        "SELECT artist FROM ios_play_history WHERE user_id = $1 AND artist IS NOT NULL AND artist != '' GROUP BY artist ORDER BY COUNT(*) DESC, artist LIMIT 20",
    )
    .bind(user)
    .fetch_all(&st.db)
    .await?;
    let top = rotating_seed(&pool, user, 3);
    let known: HashSet<String> =
        sqlx::query_scalar("SELECT song_id FROM ios_user_favorites WHERE user_id = $1 UNION SELECT source_id FROM ios_user_library_inventory WHERE user_id = $1")
            .bind(user)
            .fetch_all(&st.db)
            .await?
            .into_iter()
            .collect();
    if top.is_empty() {
        return Ok(vec![]);
    }
    let per = (limit as usize / top.len() + 1).max(1);
    let mut out: Vec<Value> = Vec::new();
    let mut seen = HashSet::new();
    'outer: for artist in &top {
        let mut args: Vec<String> = vec![format!("ytsearch{per}:{artist}"), "--dump-json".into(), "--flat-playlist".into(), "--no-playlist".into(), "--cache-dir".into(), st.cfg.ytdlp_cache_dir.clone()];
        args.extend(st.ytdlp.cookie_args(Some(user), false).await);
        let entries = match st.ytdlp.run_json(&args, Duration::from_secs(20)).await {
            Ok(e) => e,
            Err(e) => {
                tracing::warn!("discover_mix: yt-dlp search failed for {artist:?}: {e}");
                continue;
            }
        };
        for e in entries {
            let mut t = parse_track(&e, "youtube");
            let id = t["id"].as_str().unwrap_or("").to_string();
            if known.contains(&id) || !seen.insert(id) {
                continue;
            }
            t["seed_artist"] = json!(artist);
            out.push(t);
            if out.len() >= limit as usize {
                break 'outer;
            }
        }
    }
    Ok(out)
}

async fn trending(State(st): State<AppState>, _k: ApiKey, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let (limit, days) = (p.limit.unwrap_or(10), p.days.unwrap_or(7));
    check_range("limit", limit, 1, 25)?;
    check_range("days", days, 1, 30)?;
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('query', query, 'count', hits) ORDER BY hits DESC, last DESC), '[]'::json) FROM \
             (SELECT query, COUNT(*) AS hits, MAX(searched_at) AS last FROM ios_search_log WHERE searched_at >= NOW() - make_interval(days => $1) \
              GROUP BY query ORDER BY hits DESC, MAX(searched_at) DESC LIMIT $2) s",
        )
        .bind(days as i32)
        .bind(limit)
        .fetch_one(&st.db)
        .await?,
    ))
}

async fn suggestions(State(st): State<AppState>, _k: ApiKey, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let q = p.q.ok_or_else(|| invalid("q", "Field required"))?;
    if q.is_empty() || q.chars().count() > 200 {
        return Err(invalid("q", "String should have between 1 and 200 characters"));
    }
    let limit = p.limit.unwrap_or(8);
    check_range("limit", limit, 1, 20)?;
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('query', query, 'count', hits) ORDER BY hits DESC), '[]'::json) FROM \
             (SELECT query, COUNT(*) AS hits FROM ios_search_log WHERE query ILIKE $1 GROUP BY query ORDER BY hits DESC LIMIT $2) s",
        )
        .bind(format!("{q}%"))
        .bind(limit)
        .fetch_one(&st.db)
        .await?,
    ))
}

/// Python json.dumps(indent=2) formatting (", " / ": " separators, ASCII escapes).
fn py_json_pretty(v: &Value) -> String {
    fn esc(s: &str, out: &mut String) {
        out.push('"');
        for c in s.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                c if (c as u32) < 0x20 || (c as u32) > 0x7e => {
                    let mut buf = [0u16; 2];
                    for u in c.encode_utf16(&mut buf) {
                        out.push_str(&format!("\\u{:04x}", u));
                    }
                }
                c => out.push(c),
            }
        }
        out.push('"');
    }
    fn go(v: &Value, ind: usize, out: &mut String) {
        let pad = |n: usize| " ".repeat(n);
        match v {
            Value::Null => out.push_str("null"),
            Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Value::Number(n) => out.push_str(&n.to_string()),
            Value::String(s) => esc(s, out),
            Value::Array(a) if a.is_empty() => out.push_str("[]"),
            Value::Object(o) if o.is_empty() => out.push_str("{}"),
            Value::Array(a) => {
                out.push_str("[\n");
                for (i, x) in a.iter().enumerate() {
                    out.push_str(&pad(ind + 2));
                    go(x, ind + 2, out);
                    if i + 1 < a.len() {
                        out.push(',');
                    }
                    out.push('\n');
                }
                out.push_str(&pad(ind));
                out.push(']');
            }
            Value::Object(o) => {
                out.push_str("{\n");
                for (i, (k, x)) in o.iter().enumerate() {
                    out.push_str(&pad(ind + 2));
                    esc(k, out);
                    out.push_str(": ");
                    go(x, ind + 2, out);
                    if i + 1 < o.len() {
                        out.push(',');
                    }
                    out.push('\n');
                }
                out.push_str(&pad(ind));
                out.push('}');
            }
        }
    }
    let mut s = String::new();
    go(v, 0, &mut s);
    s
}

async fn export(State(st): State<AppState>, u: User) -> ApiResult<Response> {
    let v: Value = sqlx::query_scalar(
        "SELECT json_build_object( \
           'playlists', COALESCE((SELECT json_agg(json_build_object('id', p.id, 'name', p.name, 'description', p.description, 'source_url', p.source_url, \
               'tracks', COALESCE((SELECT json_agg(json_build_object('track_url', t.track_url, 'local_song_id', t.local_song_id, 'title', t.title, \
                   'artist', t.artist, 'album', t.album, 'duration_seconds', t.duration_seconds, 'position', t.position) ORDER BY t.position) \
                   FROM ios_playlist_tracks t WHERE t.playlist_id = p.id AND (t.track_url IS NOT NULL OR t.title IS NOT NULL)), '[]'::json)) ORDER BY p.id) \
               FROM ios_user_playlists p WHERE p.user_id = $1), '[]'::json), \
           'favorites', COALESCE((SELECT json_agg(json_build_object('song_id', song_id, 'title', title, 'artist', artist, 'album', album, \
               'added_at', lumi_iso(added_at))) FROM ios_user_favorites WHERE user_id = $1), '[]'::json), \
           'settings', (SELECT json_build_object('audio_settings_json', audio_settings_json, 'track_audio_settings_json', track_audio_settings_json, \
               'theme_color', theme_color) FROM ios_user_settings WHERE user_id = $1), \
           'history', COALESCE((SELECT json_agg(json_build_object('track_url', track_url, 'local_song_id', local_song_id, 'title', title, 'artist', artist, \
               'played_at', lumi_iso(played_at), 'listen_seconds', listen_seconds) ORDER BY played_at DESC) FROM \
               (SELECT * FROM ios_play_history WHERE user_id = $1 ORDER BY played_at DESC LIMIT 1000) h), '[]'::json))",
    )
    .bind(&u.id)
    .fetch_one(&st.db)
    .await?;
    let exported = format!("{}+00:00", crate::db::py_iso(&Utc::now().naive_utc()));
    let settings = if v["settings"].is_null() { json!({}) } else { v["settings"].clone() };
    let files: Vec<(&str, String)> = vec![
        ("playlists.json", py_json_pretty(&v["playlists"])),
        ("favorites.json", py_json_pretty(&v["favorites"])),
        ("settings.json", py_json_pretty(&settings)),
        ("history.json", py_json_pretty(&v["history"])),
        ("export_info.json", py_json_pretty(&json!({"exported_at": exported, "user_id": u.id}))),
    ];
    let buf = tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<u8>> {
        let mut w = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        let now = chrono::Utc::now().naive_utc();
        let stamp = zip::DateTime::from_date_and_time(now.year() as u16, now.month() as u8, now.day() as u8, chrono::Timelike::hour(&now) as u8, chrono::Timelike::minute(&now) as u8, chrono::Timelike::second(&now) as u8).unwrap_or_default();
        let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated).last_modified_time(stamp).unix_permissions(0o600);
        for (name, body) in files {
            w.start_file(name, opts)?;
            std::io::Write::write_all(&mut w, body.as_bytes())?;
        }
        Ok(w.finish()?.into_inner())
    })
    .await
    .map_err(|e| AppError::internal(e.to_string()))??;
    Ok(([(header::CONTENT_TYPE, "application/zip"), (header::CONTENT_DISPOSITION, "attachment; filename=lumisound_export.zip")], buf).into_response())
}
