//! AI + lyrics (route group 8): Aria metadata/duplicate picks, feedback,
//! actions, cloud cleanup, lyrics transcription (Gemini, whole-track then
//! windowed repair), AI DJ lines, stations, daily pick, liner notes, and
//! the LRCLIB-backed lyrics endpoints.

use crate::auth::{ApiKey, User};
use crate::error::{ApiResult, AppError};
use crate::extract::{J, Q, check_range, invalid};
use crate::gemini::{CallError, prompt, py_dumps, schema};
use crate::notify::lyrics_cache_id;
use crate::state::AppState;
use crate::storage::safe_join;
use crate::ytdlp::parse_track;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::time::{Duration, Instant};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/user/intelligence/metadata-resolve", post(metadata_resolve))
        .route("/user/intelligence/duplicate-resolve", post(duplicate_resolve))
        .route("/user/intelligence/feedback", post(feedback))
        .route("/user/intelligence/actions", post(report_action))
        .route("/user/intelligence/actions/{id}/revert", post(revert_action))
        .route("/user/intelligence/cloud-cleanup", post(cloud_cleanup))
        .route("/user/intelligence/lyrics-transcribe", post(start_transcribe).layer(axum::extract::DefaultBodyLimit::max(64 * 1024 * 1024)))
        .route("/user/intelligence/lyrics-transcribe/status", get(transcribe_status))
        .route("/user/ai-dj/transition", post(dj_transition))
        .route("/user/stations/suggestions", post(station_suggestions))
        .route("/user/stations/auto", post(station_auto))
        .route("/user/aria/daily-pick", get(daily_pick))
        .route("/music/liner-notes", get(liner_notes))
        .route("/api/lyrics", get(api_lyrics).put(api_lyrics_put))
        .route("/api/lyrics/search", get(lyrics_search))
        .route("/user/lyrics", get(user_lyrics).post(user_lyrics_post))
        .route("/user/lyrics/prefetch", post(lyrics_prefetch))
}

async fn cache_get(st: &AppState, task: &str, key: &str) -> Option<Value> {
    let r: Option<String> = sqlx::query_scalar("SELECT result_json FROM ios_intelligence_cache WHERE task = $1 AND cache_key = $2")
        .bind(task)
        .bind(key)
        .fetch_optional(&st.db)
        .await
        .ok()
        .flatten();
    r.and_then(|s| serde_json::from_str(&s).ok())
}

async fn cache_put(st: &AppState, task: &str, key: &str, v: &Value) {
    let _ = sqlx::query(
        "INSERT INTO ios_intelligence_cache (task, cache_key, result_json) VALUES ($1, $2, $3) ON CONFLICT (task, cache_key) DO UPDATE SET result_json = EXCLUDED.result_json",
    )
    .bind(task)
    .bind(key)
    .bind(py_dumps(v, false))
    .execute(&st.db)
    .await;
}

fn hash_key(v: &Value) -> String {
    hex::encode(Sha256::digest(py_dumps(v, true).as_bytes()))
}

fn with_memory(mut v: Value, id: Option<i64>) -> Value {
    if let Some(o) = v.as_object_mut() {
        o.insert("memory_id".into(), json!(id));
    }
    v
}

// ---- Aria picks ------------------------------------------------------------------------------

#[derive(Deserialize)]
struct MetaReq {
    filename: String,
    candidates: Vec<Map<String, Value>>,
}

fn candidate_dump(i: usize, c: &Map<String, Value>) -> ApiResult<Value> {
    let bad = |k: &str, t: &str, m: &str| AppError::with_value(422, json!([{"type": t, "loc": ["body", "candidates", i, k], "msg": m}]));
    for k in ["title", "artist", "source"] {
        match c.get(k) {
            Some(Value::String(_)) => {}
            None => return Err(bad(k, "missing", "Field required")),
            Some(_) => return Err(bad(k, "string_type", "Input should be a valid string")),
        }
    }
    for k in ["album", "year", "artwork_url"] {
        if !matches!(c.get(k), None | Some(Value::Null) | Some(Value::String(_))) {
            return Err(bad(k, "string_type", "Input should be a valid string"));
        }
    }
    let g = |k: &str| c.get(k).cloned().unwrap_or(Value::Null);
    Ok(json!({"title": g("title"), "artist": g("artist"), "album": g("album"), "year": g("year"), "source": g("source"), "artwork_url": g("artwork_url")}))
}

async fn metadata_resolve(State(st): State<AppState>, u: User, J(b): J<MetaReq>) -> ApiResult<Json<Value>> {
    if b.candidates.is_empty() {
        return Ok(Json(json!({"best_index": null, "confidence": "low", "memory_id": null})));
    }
    let cands: Vec<Value> = b.candidates.iter().enumerate().map(|(i, c)| candidate_dump(i, c)).collect::<ApiResult<_>>()?;
    let taste = st.taste_profile(&u.id).await;
    let input = json!({"filename": b.filename, "candidates": cands, "user_taste": taste});
    let key = hash_key(&input);
    if let Some(c) = cache_get(&st, "metadata_resolve", &key).await {
        return Ok(Json(with_memory(c, None)));
    }
    let mut model_input = input.clone();
    model_input["recent_corrections"] = st.recent_corrections("metadata_resolve").await;
    let images: Vec<String> = cands.iter().filter_map(|c| c["artwork_url"].as_str().filter(|s| !s.is_empty()).map(str::to_string)).collect();
    let Some(r) = st.intelligence("metadata_resolve", prompt("_METADATA_RESOLVE_SYSTEM_PROMPT"), &model_input, &schema("_METADATA_RESOLVE_SCHEMA"), &images).await else {
        return Ok(Json(json!({"best_index": null, "confidence": "low", "memory_id": null})));
    };
    cache_put(&st, "metadata_resolve", &key, &r).await;
    let mid = st.record_suggestion("metadata_resolve", &u.id, &input, &r).await;
    Ok(Json(with_memory(r, mid)))
}

#[derive(Deserialize)]
struct DupReq {
    title: String,
    artist: String,
    reason: String,
    candidates: Vec<DupCand>,
}

#[derive(Deserialize, serde::Serialize)]
struct DupCand {
    format: String,
    bitrate_kbps: Option<i64>,
    sample_rate: Option<i64>,
    duration_seconds: f64,
    file_size_bytes: i64,
    has_embedded_metadata: bool,
    is_favorite: bool,
}

async fn duplicate_resolve(State(st): State<AppState>, u: User, J(b): J<DupReq>) -> ApiResult<Json<Value>> {
    if b.candidates.len() < 2 {
        return Ok(Json(json!({"keep_index": null, "confidence": "low", "memory_id": null})));
    }
    let input = json!({"title": b.title, "artist": b.artist, "reason": b.reason, "candidates": b.candidates});
    let key = hash_key(&input);
    if let Some(c) = cache_get(&st, "duplicate_resolve", &key).await {
        return Ok(Json(with_memory(c, None)));
    }
    let mut mi = input.clone();
    mi["recent_corrections"] = st.recent_corrections("duplicate_resolve").await;
    let Some(r) = st.intelligence("duplicate_resolve", prompt("_DUPLICATE_RESOLVE_SYSTEM_PROMPT"), &mi, &schema("_DUPLICATE_RESOLVE_SCHEMA"), &[]).await else {
        return Ok(Json(json!({"keep_index": null, "confidence": "low", "memory_id": null})));
    };
    cache_put(&st, "duplicate_resolve", &key, &r).await;
    let mid = st.record_suggestion("duplicate_resolve", &u.id, &input, &r).await;
    Ok(Json(with_memory(r, mid)))
}

#[derive(Deserialize)]
struct FeedbackReq {
    memory_id: i64,
    correction: Map<String, Value>,
}

async fn feedback(State(st): State<AppState>, u: User, J(b): J<FeedbackReq>) -> ApiResult<Json<Value>> {
    if let Err(e) = sqlx::query("UPDATE ios_aria_memory SET correction_json = $1 WHERE id = $2").bind(py_dumps(&Value::Object(b.correction), false)).bind(b.memory_id).execute(&st.db).await {
        tracing::error!("failed to record correction for ios_aria_memory id {}: {e}", b.memory_id);
    }
    crate::db::log_event(&st.db, "intelligence", "suggestion_corrected", Some(&u.id), "info", "", Some(json!({"memory_id": b.memory_id}))).await;
    Ok(Json(json!({"ok": true})))
}

#[derive(Deserialize)]
struct ActionReq {
    action_type: String,
    title: String,
    artist: Option<String>,
    detail: Option<String>,
    before: Option<Map<String, Value>>,
    after: Option<Map<String, Value>>,
    confidence: Option<String>,
    memory_id: Option<i64>,
}

async fn report_action(State(st): State<AppState>, u: User, J(b): J<ActionReq>) -> ApiResult<Json<Value>> {
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO ios_aria_actions (user_id, action_type, title, artist, detail, before_json, after_json, confidence, memory_id) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id::bigint",
    )
    .bind(&u.id)
    .bind(&b.action_type)
    .bind(&b.title)
    .bind(&b.artist)
    .bind(&b.detail)
    .bind(b.before.map(|m| py_dumps(&Value::Object(m), false)))
    .bind(b.after.map(|m| py_dumps(&Value::Object(m), false)))
    .bind(&b.confidence)
    .bind(b.memory_id)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"id": id})))
}

async fn revert_action(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    let id: i64 = id.parse().map_err(|_| AppError::with_value(422, json!([{"type": "int_parsing", "loc": ["path", "action_id"], "msg": "Input should be a valid integer"}])))?;
    sqlx::query("UPDATE ios_aria_actions SET reverted_at = NOW() WHERE id = $1 AND user_id = $2 AND reverted_at IS NULL").bind(id).bind(&u.id).execute(&st.db).await?;
    Ok(Json(json!({"ok": true})))
}

async fn cloud_cleanup(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let dir = st.user_music_dir(&u.id).ok_or_else(|| AppError::new(503, "User music storage not configured"))?;
    let rows: Vec<(String, Option<String>, Option<String>)> = sqlx::query_as(
        "SELECT filename, relative_path, title FROM ios_user_music_metadata WHERE user_id = $1 AND (file_size_bytes IS NULL OR file_size_bytes < 1024 \
         OR duration_seconds IS NULL OR duration_seconds <= 0) LIMIT 200",
    )
    .bind(&u.id)
    .fetch_all(&st.db)
    .await?;
    let mut removed = Vec::new();
    for (filename, rel, title) in rows {
        let fp = rel.filter(|r| !r.is_empty()).unwrap_or(filename.clone());
        let Some(p) = safe_join(&dir, &fp) else { continue };
        if p.exists() {
            if let Err(e) = tokio::fs::remove_file(&p).await {
                tracing::error!("aria_cloud_cleanup: failed to remove {fp} for user {}: {e}", u.id);
                continue;
            }
        }
        sqlx::query("DELETE FROM ios_user_music_metadata WHERE user_id = $1 AND filename = $2").bind(&u.id).bind(&filename).execute(&st.db).await?;
        let shown = title.filter(|t| !t.is_empty()).unwrap_or(filename.clone());
        sqlx::query("INSERT INTO ios_aria_actions (user_id, action_type, title, artist, detail, confidence) VALUES ($1, 'cloud_broken_upload_removed', $2, NULL, $3, 'high')")
            .bind(&u.id)
            .bind(&shown)
            .bind("Removed a cloud library entry with no real audio behind it (failed/partial upload).")
            .execute(&st.db)
            .await?;
        removed.push(json!({"filename": filename, "title": shown}));
    }
    Ok(Json(json!({"removed": removed})))
}

// ---- lyrics transcription --------------------------------------------------------------------

pub struct LyricsJob {
    pub created: Instant,
    pub user: String,
    pub state: Value,
}

#[derive(Deserialize)]
struct TranscribeQ {
    title: Option<String>,
    #[serde(default)]
    artist: String,
    hint_lyrics: Option<String>,
    job_id: Option<String>,
}

fn sweep_lyrics_jobs(st: &AppState) {
    let now = Instant::now();
    st.lyrics_jobs.retain(|_, j| {
        let age = now.duration_since(j.created);
        let terminal = matches!(j.state["status"].as_str(), Some("done" | "error" | "cancelled" | "failed"));
        !(age > Duration::from_secs(6 * 3600) || (age > Duration::from_secs(900) && terminal))
    });
}

async fn start_transcribe(State(st): State<AppState>, u: User, headers: HeaderMap, Q(q): Q<TranscribeQ>, body: Bytes) -> ApiResult<Response> {
    let title = q.title.ok_or_else(|| invalid("title", "Field required"))?;
    if q.hint_lyrics.as_ref().is_some_and(|h| h.chars().count() > 6000) {
        return Err(invalid("hint_lyrics", "String should have at most 6000 characters"));
    }
    if body.is_empty() {
        return Err(AppError::bad_request("Empty audio body"));
    }
    if body.len() > 20 * 1024 * 1024 {
        return Err(AppError::new(413, "Audio too large for transcription (max 20 MB)"));
    }
    let mime = headers.get("content-type").and_then(|v| v.to_str().ok()).filter(|s| !s.is_empty()).unwrap_or("audio/mpeg").to_string();
    sweep_lyrics_jobs(&st);
    let in_flight = st.lyrics_jobs.iter().filter(|j| j.user == u.id && matches!(j.state["status"].as_str(), Some("pending" | "running"))).count();
    if in_flight >= 3 {
        let mut r = AppError::new(429, format!("Already transcribing {in_flight} track(s). Let those finish first.")).into_response();
        r.headers_mut().insert("retry-after", HeaderValue::from_static("30"));
        return Ok(r);
    }
    let id = uuid::Uuid::new_v4().simple().to_string();
    st.lyrics_jobs.insert(id.clone(), LyricsJob { created: Instant::now(), user: u.id.clone(), state: json!({"status": "pending"}) });
    let (st2, jid) = (st.clone(), id.clone());
    tokio::spawn(async move { run_transcribe(st2, jid, body, mime, title, q.artist, q.hint_lyrics).await });
    Ok((StatusCode::ACCEPTED, Json(json!({"job_id": id}))).into_response())
}

fn set_job(st: &AppState, id: &str, v: Value) {
    if let Some(mut j) = st.lyrics_jobs.get_mut(id) {
        j.state = v;
    }
}

async fn probe_duration(body: &[u8]) -> Option<f64> {
    let tmp = std::env::temp_dir().join(format!("lyr-{}.audio", uuid::Uuid::new_v4().simple()));
    tokio::fs::write(&tmp, body).await.ok()?;
    let d = crate::analysis::duration_of(&tmp).await;
    let _ = tokio::fs::remove_file(&tmp).await;
    (d > 0.0).then_some(d)
}

/// Plain lyrics text to align against: the app's hint, else LRCLIB / our cache.
async fn reference_text(st: &AppState, title: &str, artist: &str, dur: Option<f64>, hint: Option<String>) -> Option<String> {
    if let Some(h) = hint.filter(|h| h.lines().filter(|l| !l.trim().is_empty()).count() >= 3) {
        return Some(h);
    }
    let cached: Option<Option<String>> = sqlx::query_scalar("SELECT plain_lyrics FROM ios_lyrics_cache WHERE id = $1 AND is_user_submitted IS NOT TRUE")
        .bind(lyrics_cache_id(title, artist))
        .fetch_optional(&st.db)
        .await
        .ok()
        .flatten();
    if let Some(Some(p)) = cached.filter(|p| p.as_ref().is_some_and(|p| !p.is_empty())) {
        return Some(p);
    }
    let mut params = vec![("track_name", title.to_string()), ("artist_name", artist.to_string())];
    if let Some(d) = dur {
        params.push(("duration", (d.round() as i64).to_string()));
    }
    let data: Option<Value> = match st.http.get("https://lrclib.net/api/get").query(&params).header("User-Agent", "Lumisound-iOS-Bridge/1.0").timeout(Duration::from_secs(10)).send().await {
        Ok(r) if r.status().is_success() => r.json().await.ok(),
        _ => None,
    };
    data.and_then(|d| d["plainLyrics"].as_str().filter(|s| !s.is_empty()).map(str::to_string))
}

async fn run_transcribe(st: AppState, id: String, body: Bytes, mime: String, title: String, artist: String, hint: Option<String>) {
    set_job(&st, &id, json!({"status": "running", "stage": "queued"}));
    let dur = probe_duration(&body).await;
    // Aria Lyrics engine (crate::lyricsgen): Demucs vocals, voice phrases,
    // on-server whisper, alignment to known text when there is any.
    let ext = match mime.as_str() { m if m.contains("mp4") || m.contains("m4a") || m.contains("aac") => "m4a", m if m.contains("ogg") || m.contains("opus") => "ogg", m if m.contains("wav") => "wav", m if m.contains("flac") => "flac", m if m.contains("webm") => "webm", _ => "mp3" };
    let tmp = std::env::temp_dir().join(format!("aria-in-{}.{ext}", uuid::Uuid::new_v4().simple()));
    if tokio::fs::write(&tmp, &body).await.is_err() {
        set_job(&st, &id, json!({"status": "error", "detail": "Couldn't read the audio"}));
        return;
    }
    let reference = reference_text(&st, &title, &artist, dur, hint).await;
    let st2 = st.clone();
    let jid = id.clone();
    let started = Instant::now();
    let r = crate::lyricsgen::generate(&st, &tmp, &title, &artist, reference.as_deref(), move |stage| set_job(&st2, &jid, json!({"status": "running", "stage": stage}))).await;
    let _ = tokio::fs::remove_file(&tmp).await;
    let result = match r {
        Ok(o) => {
            tracing::info!("aria lyrics: {title:?} -> {} line(s), instrumental {}, lang {:?}, aligned {:?}, {:.0}s", o.lines.len(), o.instrumental, o.language, o.aligned, started.elapsed().as_secs_f64());
            crate::lyricsgen::outcome_json(&o)
        }
        Err(e) => {
            tracing::warn!("aria lyrics failed for {title:?}: {e}");
            set_job(&st, &id, json!({"status": "error", "detail": "Aria couldn't transcribe this track."}));
            return;
        }
    };
    let _ = &mime;
    let lines: Vec<Value> = result["lines"].as_array().cloned().unwrap_or_default();
    if result["instrumental"].as_bool().unwrap_or(false) || lines.is_empty() {
        set_job(&st, &id, json!({"status": "done", "lrc": "", "instrumental": result["instrumental"].as_bool().unwrap_or(false), "confidence": result.get("confidence").cloned().unwrap_or(json!("low"))}));
        return;
    }
    let cache = lyrics_cache_id(&title, &artist);
    if !result["timings_ok"].as_bool().unwrap_or(true) {
        let plain: Vec<String> = lines.iter().filter_map(|l| text_of(l)).collect();
        let plain = plain.join("\n");
        tracing::warn!("lyrics transcription: returning {} line(s) UNSYNCED for {title:?}", lines.len());
        set_job(&st, &id, json!({"status": "done", "lrc": "", "plain": plain, "synced": false, "instrumental": false, "confidence": "low"}));
        if !plain.is_empty() {
            let _ = sqlx::query(
                "INSERT INTO ios_lyrics_cache (id, title, artist, synced_lyrics, plain_lyrics, found) VALUES ($1, $2, $3, NULL, $4, TRUE) \
                 ON CONFLICT (id) DO UPDATE SET plain_lyrics = EXCLUDED.plain_lyrics, found = TRUE",
            )
            .bind(&cache)
            .bind(&title)
            .bind(&artist)
            .bind(&plain)
            .execute(&st.db)
            .await;
        }
        return;
    }
    let mut sorted = lines.clone();
    sorted.sort_by(|a, b| time_of(a).partial_cmp(&time_of(b)).unwrap_or(std::cmp::Ordering::Equal));
    let lrc: Vec<String> = sorted
        .iter()
        .filter_map(|l| {
            let text = text_of(l)?;
            let t = time_of(l).max(0.0);
            let (m, s) = ((t / 60.0).floor(), t % 60.0);
            Some(format!("[{:02}:{:05.2}]{text}", m as i64, s))
        })
        .collect();
    let lrc = lrc.join("\n");
    set_job(&st, &id, json!({"status": "done", "lrc": lrc, "synced": true, "instrumental": false, "confidence": result.get("confidence").cloned().unwrap_or(json!("medium"))}));
    if !lrc.is_empty() {
        let r = sqlx::query(
            "INSERT INTO ios_lyrics_cache (id, title, artist, synced_lyrics, plain_lyrics, found, is_user_submitted) VALUES ($1, $2, $3, $4, NULL, TRUE, TRUE) \
             ON CONFLICT (id) DO UPDATE SET synced_lyrics = EXCLUDED.synced_lyrics, found = TRUE, is_user_submitted = TRUE",
        )
        .bind(&cache)
        .bind(&title)
        .bind(&artist)
        .bind(&lrc)
        .execute(&st.db)
        .await;
        match r {
            Ok(_) => tracing::info!("lyrics-transcribe: cached Aria's lyrics for {title:?} by {artist:?}"),
            Err(e) => tracing::warn!("lyrics-transcribe: could not cache result for {title:?}: {e}"),
        }
    }
}

fn text_of(l: &Value) -> Option<String> {
    let t = match &l["text"] { Value::String(s) => s.trim().to_string(), Value::Null => String::new(), v => v.to_string() };
    (!t.is_empty()).then_some(t)
}

fn time_of(l: &Value) -> f64 {
    l["time_seconds"].as_f64().unwrap_or(0.0)
}

pub fn timings_plausible(lines: &[Value], dur: Option<f64>) -> bool {
    let Some(d) = dur.filter(|d| *d > 0.0) else { return true };
    let times: Vec<f64> = lines.iter().filter(|l| text_of(l).is_some()).map(time_of).collect();
    times.is_empty() || times.iter().cloned().fold(f64::MIN, f64::max) <= d + 3.0
}

fn audio_part(bytes: &[u8], mime: &str) -> Value {
    json!({"inlineData": {"mimeType": mime, "data": base64::engine::general_purpose::STANDARD.encode(bytes)}})
}

/// `lyrics_ai.transcribe_lyrics`.
async fn transcribe(st: &AppState, audio: &[u8], mime: &str, title: &str, artist: &str, hint: Option<&str>, dur: Option<f64>) -> Option<Value> {
    st.cfg.gemini_api_key.as_ref()?;
    const TASK: &str = "lyrics_transcribe";
    if st.gemini.cooling(TASK) {
        tracing::info!("transcribe_lyrics: skipping, cooling down after a recent 429");
        return None;
    }
    let started = Instant::now();
    let mut models = vec![crate::gemini::model()];
    let fb = crate::gemini::fallback_model();
    if !fb.is_empty() && fb != models[0] {
        models.push(fb);
    }
    let system = format!("{}\n{}", prompt("ARIA_PERSONA"), prompt("_SYSTEM_PROMPT"));
    let input = json!({"title": title, "artist": artist, "candidate_lyrics": hint.filter(|h| !h.is_empty()),
        "track_duration_seconds": dur.map(|d| crate::analysis::pyround(d, 2))});
    let parts = vec![json!({"text": py_dumps(&input, false)}), audio_part(audio, mime)];
    let mut whole: Option<Value> = None;
    'models: for m in &models {
        for attempt in 1..=3 {
            if started.elapsed() > Duration::from_secs(420) {
                tracing::warn!("transcribe_lyrics: giving up after {:.0}s", started.elapsed().as_secs_f64());
                return None;
            }
            match st.gemini_raw(m, &system, parts.clone(), &schema("_LYRICS_SCHEMA"), Duration::from_secs(240)).await {
                Ok(text) => {
                    let Ok(mut parsed) = serde_json::from_str::<Value>(&text) else {
                        tracing::warn!("transcribe_lyrics: {m} returned unparseable JSON");
                        return None;
                    };
                    let Some(lines) = parsed["lines"].as_array().cloned() else {
                        tracing::warn!("transcribe_lyrics: {m} returned no usable 'lines' array");
                        return None;
                    };
                    let ok = timings_plausible(&lines, dur);
                    parsed["timings_ok"] = json!(ok);
                    if !ok {
                        tracing::warn!("transcribe_lyrics: {m} timings overrun the track for {title:?} — attempt {attempt}/3");
                        whole = Some(parsed);
                        break 'models;
                    }
                    return Some(parsed);
                }
                Err(CallError::Status(code, msg)) => {
                    let retry = [500, 502, 503, 504].contains(&code);
                    tracing::warn!("transcribe_lyrics: {m} attempt {attempt}/3 failed (code={code}, retryable={retry}): {msg}");
                    if code == 429 {
                        st.gemini.start_cooldown(TASK);
                    }
                    if !retry {
                        break;
                    }
                    if attempt < 3 {
                        tokio::time::sleep(Duration::from_secs(if attempt == 1 { 3 } else { 9 })).await;
                    }
                }
                Err(CallError::Other(e)) => {
                    tracing::error!("transcribe_lyrics: unexpected failure on {m}: {e}");
                    return None;
                }
            }
        }
    }
    let whole = whole?;
    if let Some(d) = dur.filter(|d| *d >= 90.0) {
        if started.elapsed() < Duration::from_secs(420) {
            tracing::info!("transcribe_lyrics: repairing {title:?} with windowed transcription");
            if let Some(mut w) = windowed(st, audio, title, artist, hint, d, &models).await {
                let lines = w["lines"].as_array().cloned().unwrap_or_default();
                let ok = timings_plausible(&lines, dur);
                w["timings_ok"] = json!(ok);
                if ok {
                    return Some(w);
                }
                tracing::warn!("transcribe_lyrics: windowed repair also overran for {title:?}");
            }
        }
    }
    tracing::warn!("transcribe_lyrics: {title:?} returning UNSYNCED — no trustworthy timing");
    Some(whole)
}

fn chunk_windows(dur: f64) -> Vec<(f64, f64)> {
    let chunk: f64 = std::env::var("LUMISOUND_LYRICS_CHUNK_SECONDS").ok().and_then(|v| v.parse().ok()).unwrap_or(60.0);
    let max_w: f64 = std::env::var("LUMISOUND_LYRICS_MAX_WINDOWS").ok().and_then(|v| v.parse().ok()).unwrap_or(4.0);
    let step = chunk.max(dur / max_w);
    let mut w = Vec::new();
    let mut s = 0.0;
    while s < dur {
        w.push((s, (step + 6.0).min(dur - s)));
        s += step;
    }
    if w.len() >= 2 && w.last().unwrap().1 <= 7.0 {
        let (ps, _) = w[w.len() - 2];
        let n = w.len();
        w[n - 2] = (ps, dur - ps);
        w.pop();
    }
    w
}

async fn windowed(st: &AppState, audio: &[u8], title: &str, artist: &str, hint: Option<&str>, dur: f64, models: &[String]) -> Option<Value> {
    let windows = chunk_windows(dur);
    if windows.len() < 2 {
        return None;
    }
    let src = std::env::temp_dir().join(format!("lyr-{}.src", uuid::Uuid::new_v4().simple()));
    tokio::fs::write(&src, audio).await.ok()?;
    let sem = tokio::sync::Semaphore::new(std::env::var("LUMISOUND_LYRICS_CHUNK_CONCURRENCY").ok().and_then(|v| v.parse().ok()).unwrap_or(3usize).max(1));
    let futs = windows.iter().map(|&(s, l)| {
        let (src, sem) = (&src, &sem);
        async move {
            let _p = sem.acquire().await.ok()?;
            let out = src.with_extension(format!("{}.m4a", s as i64));
            let args: Vec<String> = ["-y", "-v", "quiet", "-ss", &format!("{s:.3}"), "-t", &format!("{l:.3}"), "-i", &src.to_string_lossy(), "-vn", "-ac", "1", "-ar", "24000",
                "-c:a", "aac", "-b:a", "48k", &out.to_string_lossy()].map(String::from).to_vec();
            let ok = matches!(st.ytdlp.run("ffmpeg", &args, Duration::from_secs(90)).await, Ok(o) if o.status == Some(0));
            let bytes = if ok { tokio::fs::read(&out).await.ok() } else { None };
            let _ = tokio::fs::remove_file(&out).await;
            let bytes = bytes?;
            Some(chunk_lines(st, &bytes, s, l, title, artist, hint, models).await)
        }
    });
    let groups: Vec<Vec<Value>> = futures_util::future::join_all(futs).await.into_iter().map(|g| g.unwrap_or_default()).collect();
    let _ = tokio::fs::remove_file(&src).await;
    let produced = groups.iter().filter(|g| !g.is_empty()).count();
    let mut all: Vec<Value> = groups.into_iter().flatten().collect();
    all.sort_by(|a, b| time_of(a).partial_cmp(&time_of(b)).unwrap_or(std::cmp::Ordering::Equal));
    let norm = |v: &Value| v["text"].as_str().unwrap_or("").to_lowercase().split_whitespace().collect::<Vec<_>>().join(" ");
    let mut merged: Vec<Value> = Vec::new();
    for line in all {
        let key = norm(&line);
        let dup = merged.iter().rev().take_while(|k| time_of(&line) - time_of(k) <= 6.0).any(|k| norm(k) == key);
        if !dup {
            merged.push(line);
        }
    }
    tracing::info!("lyrics windowed transcription: {} window(s), {produced} produced lines, {} lines merged for {title:?}", windows.len(), merged.len());
    if merged.is_empty() || produced < (windows.len() / 3).max(1) {
        return None;
    }
    Some(json!({"instrumental": false, "confidence": "medium", "lines": merged, "windowed": true}))
}

#[allow(clippy::too_many_arguments)]
async fn chunk_lines(st: &AppState, bytes: &[u8], start: f64, len: f64, title: &str, artist: &str, hint: Option<&str>, models: &[String]) -> Vec<Value> {
    let system = format!("{}\n{}", prompt("ARIA_PERSONA"), prompt("_CHUNK_SYSTEM_PROMPT"));
    let input = json!({"title": title, "artist": artist, "candidate_lyrics": hint.filter(|h| !h.is_empty()), "excerpt_duration_seconds": crate::analysis::pyround(len, 2)});
    let parts = vec![json!({"text": py_dumps(&input, false)}), audio_part(bytes, "audio/mp4")];
    for m in models {
        for attempt in 1..=2 {
            match st.gemini_raw(m, &system, parts.clone(), &schema("_LYRICS_SCHEMA"), Duration::from_secs(120)).await {
                Ok(text) => {
                    let Ok(p) = serde_json::from_str::<Value>(&text) else { return vec![] };
                    let Some(lines) = p["lines"].as_array() else { return vec![] };
                    return lines
                        .iter()
                        .filter_map(|e| {
                            let t = text_of(e)?;
                            let rel = time_of(e);
                            if rel < -1.0 || rel > len + 1.0 {
                                return None;
                            }
                            Some(json!({"time_seconds": start + rel.max(0.0), "text": t}))
                        })
                        .collect();
                }
                Err(CallError::Status(429, _)) => {
                    st.gemini.start_cooldown("lyrics_transcribe");
                    tracing::warn!("lyrics chunk at {start:.1}s: {m} is rate-limited, trying next model");
                    break;
                }
                Err(CallError::Status(c, e)) if [500, 502, 503, 504].contains(&c) && attempt < 2 => {
                    tracing::debug!("lyrics chunk retry: {e}");
                    tokio::time::sleep(Duration::from_secs(3)).await;
                }
                Err(e) => {
                    let msg = match e { CallError::Status(c, m) => format!("{c} {m}"), CallError::Other(m) => m };
                    tracing::warn!("lyrics chunk at {start:.1}s failed on {m}: {msg}");
                    break;
                }
            }
        }
    }
    vec![]
}

async fn transcribe_status(State(st): State<AppState>, _u: User, Q(q): Q<TranscribeQ>) -> ApiResult<Json<Value>> {
    let id = q.job_id.ok_or_else(|| invalid("job_id", "Field required"))?;
    let j = st.lyrics_jobs.get(&id).ok_or_else(|| AppError::not_found("Lyrics transcription job not found"))?;
    let s = &j.state;
    let g = |k: &str| s.get(k).cloned().unwrap_or(Value::Null);
    Ok(Json(json!({"status": g("status"), "detail": g("detail"), "lrc": g("lrc"), "plain": g("plain"), "synced": g("synced"), "instrumental": g("instrumental"), "confidence": g("confidence")})))
}

// ---- DJ / stations / picks / liner notes ------------------------------------------------------

#[derive(Deserialize)]
struct DjReq {
    next_title: String,
    next_artist: Option<String>,
    previous_title: Option<String>,
    previous_artist: Option<String>,
}

async fn dj_transition(State(st): State<AppState>, _u: User, J(b): J<DjReq>) -> ApiResult<Json<Value>> {
    let input = json!({"next": {"title": b.next_title, "artist": b.next_artist},
        "previous": if b.previous_title.as_deref().is_some_and(|t| !t.is_empty()) { json!({"title": b.previous_title, "artist": b.previous_artist}) } else { Value::Null }});
    let r = st.intelligence("dj_transition", prompt("_DJ_TRANSITION_SYSTEM_PROMPT"), &input, &schema("_DJ_TRANSITION_SCHEMA"), &[]).await;
    Ok(Json(json!({"blurb": r.and_then(|r| r.get("blurb").cloned())})))
}

#[derive(Deserialize, Default)]
struct StationSeed {
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    genre: Option<String>,
    bpm: Option<f64>,
    source_track_id: Option<String>,
    local_hour: Option<i64>,
}

fn signal(v: Option<&str>, limit: usize) -> String {
    v.map(|s| s.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(limit).collect()).unwrap_or_default()
}

fn strs(v: &Value) -> Vec<String> {
    v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(|s| signal(Some(s), 100))).filter(|s| !s.is_empty()).collect()).unwrap_or_default()
}

fn title_case(s: &str) -> String {
    s.split(' ').map(|w| {
        let mut c = w.chars();
        c.next().map(|f| f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase()).unwrap_or_default()
    }).collect::<Vec<_>>().join(" ")
}

fn station_plans(profile: &Value, seed: &StationSeed) -> Vec<Value> {
    let (artist, title, album, genre) = (signal(seed.artist.as_deref(), 100), signal(seed.title.as_deref(), 100), signal(seed.album.as_deref(), 100), signal(seed.genre.as_deref(), 100));
    let top = strs(&profile["top_played_artists"]);
    let favs = strs(&profile["favorited_artists"]);
    let genres = strs(&profile["library_genres"]);
    let mut plans = Vec::new();
    if !artist.is_empty() || !title.is_empty() || !album.is_empty() {
        let ctx = [&artist, &title, &album].iter().filter(|s| !s.is_empty()).map(|s| s.as_str()).collect::<Vec<_>>().join(" · ");
        let tempo = match seed.bpm { Some(b) if (40.0..=220.0).contains(&b) => if b >= 120.0 { " energetic" } else { " mellow" }, _ => "" };
        let mut qs = vec![format!("{artist} {title} {album} similar songs{tempo}").trim().to_string()];
        if !artist.is_empty() {
            qs.push(format!("{artist} radio{tempo}").trim().to_string());
        }
        let first = [&artist, &title, &album].into_iter().find(|s| !s.is_empty()).cloned().unwrap_or_default();
        plans.push(json!({"id": "context", "title": format!("Station from {first}"), "subtitle": format!("Because you're listening to {ctx}"), "icon": "dot.radiowaves.left.and.right", "queries": qs}));
    }
    let favorite = if !favs.is_empty() { favs.clone() } else { top.clone() };
    if let Some(f) = favorite.first() {
        plans.push(json!({"id": "favorites", "title": format!("More from {f}"), "subtitle": "Built from your favorites and recent plays", "icon": "heart.fill",
            "queries": [format!("{f} mix"), format!("{f} deep cuts")]}));
    }
    let g = if !genre.is_empty() { genre.clone() } else { genres.first().cloned().unwrap_or_default() };
    if !g.is_empty() {
        let anchor = top.first().cloned().unwrap_or_default();
        plans.push(json!({"id": "genre", "title": format!("{g} station"), "subtitle": "A genre match for your library", "icon": "guitars.fill",
            "queries": [format!("{anchor} {g} mix").trim().to_string(), format!("best {g} songs")]}));
    }
    let hour = seed.local_hour.filter(|h| (0..=23).contains(h)).unwrap_or_else(|| chrono::Timelike::hour(&chrono::Local::now()) as i64);
    let mood = if hour >= 21 || hour < 6 { "late night" } else if (9..17).contains(&hour) { "focus" } else { "easy listening" };
    let anchor = top.first().cloned().or(favorite.first().cloned()).unwrap_or_default();
    if !anchor.is_empty() {
        plans.push(json!({"id": "moment", "title": format!("{} station", title_case(mood)), "subtitle": format!("Tuned to your listening time and {anchor}"),
            "icon": if mood == "late night" { "moon.stars.fill" } else { "sparkles" }, "queries": [format!("{anchor} {mood} mix"), format!("{mood} music mix")]}));
    }
    if plans.is_empty() {
        if let Some(g) = genres.first() {
            plans.push(json!({"id": "library", "title": format!("{g} station"), "subtitle": "Built from your library", "icon": "music.note.list", "queries": [format!("{g} mix")]}));
        }
    }
    plans
}

async fn known(st: &AppState, user: &str) -> HashSet<String> {
    sqlx::query_scalar::<_, String>("SELECT song_id FROM ios_user_favorites WHERE user_id = $1 UNION SELECT source_id FROM ios_user_library_inventory WHERE user_id = $1")
        .bind(user)
        .fetch_all(&st.db)
        .await
        .unwrap_or_default()
        .into_iter()
        .collect()
}

async fn build_station(st: &AppState, user: &str, plan: &Value, limit: usize, known: &HashSet<String>) -> Value {
    let per = limit.clamp(2, 8);
    let mut tracks: Vec<Value> = Vec::new();
    let mut seen = HashSet::new();
    'q: for q in plan["queries"].as_array().into_iter().flatten() {
        let q = signal(q.as_str(), 180);
        if q.is_empty() {
            continue;
        }
        let mut a: Vec<String> = vec![format!("ytsearch{per}:{q}"), "--dump-json".into(), "--flat-playlist".into(), "--no-playlist".into(), "--cache-dir".into(), st.cfg.ytdlp_cache_dir.clone()];
        a.extend(st.ytdlp.cookie_args(Some(user), false).await);
        let Ok(entries) = st.ytdlp.run_json(&a, Duration::from_secs(20)).await else {
            tracing::warn!("station search failed for {q:?}");
            continue;
        };
        for e in entries {
            let t = parse_track(&e, "youtube");
            let id = t["id"].as_str().unwrap_or("").to_string();
            let sid = format!("{}:{id}", t["source"].as_str().unwrap_or(""));
            if known.contains(&id) || known.contains(&sid) || !seen.insert(id) {
                continue;
            }
            tracks.push(t);
            if tracks.len() >= limit {
                break 'q;
            }
        }
    }
    json!({"id": plan["id"], "title": plan["title"], "subtitle": plan["subtitle"], "icon": plan["icon"], "tracks": tracks})
}

#[derive(Deserialize)]
struct StationQ {
    limit: Option<i64>,
    track_limit: Option<i64>,
}

async fn station_suggestions(State(st): State<AppState>, u: User, Q(q): Q<StationQ>, J(seed): J<StationSeed>) -> ApiResult<Json<Value>> {
    let (limit, tl) = (q.limit.unwrap_or(4), q.track_limit.unwrap_or(6));
    check_range("limit", limit, 1, 6)?;
    check_range("track_limit", tl, 3, 12)?;
    let plans = station_plans(&st.taste_profile(&u.id).await, &seed);
    let mut k = known(&st, &u.id).await;
    if let Some(s) = &seed.source_track_id {
        k.insert(signal(Some(s), 180));
    }
    let stations = futures_util::future::join_all(plans.iter().take(limit as usize).map(|p| build_station(&st, &u.id, p, tl as usize, &k))).await;
    Ok(Json(Value::Array(stations.into_iter().filter(|s| s["tracks"].as_array().is_some_and(|t| !t.is_empty())).collect())))
}

/// Auto-Radio for older app builds: answered by the Lumisound Radio engine
/// (routes/radio.rs) — same response shape, plus `session_id`.
async fn station_auto(State(st): State<AppState>, u: User, Q(q): Q<StationQ>, J(seed): J<StationSeed>) -> ApiResult<Json<Value>> {
    let tl = q.track_limit.unwrap_or(8);
    check_range("track_limit", tl, 3, 15)?;
    let seed = crate::routes::radio::Seed { title: seed.title, artist: seed.artist, album: seed.album, genre: seed.genre, bpm: seed.bpm, source_track_id: seed.source_track_id, local_hour: seed.local_hour };
    let (_, mut s) = crate::routes::radio::start_session(&st, &u.id, seed, "balanced", tl as usize).await;
    s["id"] = json!("auto");
    Ok(Json(s))
}

async fn daily_pick(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let key = format!("{}:{}", u.id, chrono::Utc::now().date_naive().format("%Y-%m-%d"));
    if let Some(c) = cache_get(&st, "daily_pick", &key).await {
        return Ok(Json(c));
    }
    let cands = crate::routes::discovery::discover_tracks(&st, &u.id, 8).await?;
    if cands.is_empty() {
        return Ok(Json(json!({"pick": null, "reason": null})));
    }
    let input = json!({"candidates": cands.iter().map(|c| json!({"title": c["title"], "artist": c["artist"]})).collect::<Vec<_>>(), "user_taste": st.taste_profile(&u.id).await});
    let r = st.intelligence("daily_pick", prompt("_DAILY_PICK_SYSTEM_PROMPT"), &input, &schema("_DAILY_PICK_SCHEMA"), &[]).await;
    let (pick, reason) = match r.as_ref().and_then(|r| Some((r["pick_index"].as_i64()?, r["reason"].clone()))) {
        Some((i, reason)) if i >= 0 && (i as usize) < cands.len() => (cands[i as usize].clone(), reason),
        _ => (cands[0].clone(), json!("From an artist you've been playing a lot lately.")),
    };
    let resp = json!({"pick": pick, "reason": reason});
    cache_put(&st, "daily_pick", &key, &resp).await;
    Ok(Json(resp))
}

#[derive(Deserialize)]
struct LinerQ {
    artist: Option<String>,
    album: Option<String>,
}

async fn liner_notes(State(st): State<AppState>, _u: User, Q(q): Q<LinerQ>) -> ApiResult<Json<Value>> {
    let artist = q.artist.ok_or_else(|| invalid("artist", "Field required"))?;
    let album = q.album.ok_or_else(|| invalid("album", "Field required"))?;
    let (an, bn) = (artist.trim().to_lowercase(), album.trim().to_lowercase());
    if an.is_empty() || bn.is_empty() {
        return Ok(Json(json!({"blurb": null})));
    }
    let key = format!("{an}|{bn}");
    if let Some(c) = cache_get(&st, "liner_notes", &key).await {
        return Ok(Json(c));
    }
    let r = st.intelligence("liner_notes", prompt("_LINER_NOTES_SYSTEM_PROMPT"), &json!({"artist": artist, "album": album}), &schema("_LINER_NOTES_SCHEMA"), &[]).await;
    let resp = json!({"blurb": r.as_ref().map(|r| r["blurb"].clone())});
    if r.is_some() {
        cache_put(&st, "liner_notes", &key, &resp).await;
    }
    Ok(Json(resp))
}

// ---- lyrics (LRCLIB + user submissions) ------------------------------------------------------

#[derive(Deserialize)]
struct LyricsQ {
    title: Option<String>,
    #[serde(default)]
    artist: String,
    duration: Option<i64>,
    q: Option<String>,
    limit: Option<i64>,
}

fn title_param(q: &LyricsQ) -> ApiResult<String> {
    let t = q.title.clone().ok_or_else(|| invalid("title", "Field required"))?;
    if t.is_empty() || t.chars().count() > 200 {
        return Err(invalid("title", "String should have between 1 and 200 characters"));
    }
    if q.artist.chars().count() > 200 {
        return Err(invalid("artist", "String should have at most 200 characters"));
    }
    Ok(t)
}

async fn api_lyrics(State(st): State<AppState>, _k: ApiKey, Q(q): Q<LyricsQ>) -> ApiResult<Json<Value>> {
    let title = title_param(&q)?;
    let id = lyrics_cache_id(&title, &q.artist);
    let cached: Option<(Option<String>, Option<String>, Option<bool>)> =
        sqlx::query_as("SELECT synced_lyrics, plain_lyrics, found FROM ios_lyrics_cache WHERE id = $1").bind(&id).fetch_optional(&st.db).await?;
    if let Some((s, p, f)) = cached {
        if !f.unwrap_or(false) {
            return Err(AppError::not_found("No lyrics found"));
        }
        return Ok(Json(json!({"title": title, "artist": q.artist, "synced_lyrics": s, "plain_lyrics": p, "instrumental": false})));
    }
    let mut params = vec![("track_name", title.clone()), ("artist_name", q.artist.clone())];
    if let Some(d) = q.duration.filter(|d| *d != 0) {
        params.push(("duration", d.to_string()));
    }
    let data: Option<Value> = match st.http.get("https://lrclib.net/api/get").query(&params).header("User-Agent", "Lumisound-iOS-Bridge/1.0").timeout(Duration::from_secs(10)).send().await {
        Ok(r) if r.status().is_success() => r.json().await.ok(),
        _ => None,
    };
    let s = data.as_ref().and_then(|d| d["syncedLyrics"].as_str()).filter(|s| !s.is_empty()).map(str::to_string);
    let p = data.as_ref().and_then(|d| d["plainLyrics"].as_str()).filter(|s| !s.is_empty()).map(str::to_string);
    let found = s.is_some() || p.is_some();
    let r = sqlx::query(
        "INSERT INTO ios_lyrics_cache (id, title, artist, synced_lyrics, plain_lyrics, found) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (id) DO UPDATE SET \
           synced_lyrics = CASE WHEN ios_lyrics_cache.is_user_submitted THEN ios_lyrics_cache.synced_lyrics ELSE EXCLUDED.synced_lyrics END, \
           plain_lyrics = CASE WHEN ios_lyrics_cache.is_user_submitted THEN ios_lyrics_cache.plain_lyrics ELSE EXCLUDED.plain_lyrics END, \
           found = CASE WHEN ios_lyrics_cache.is_user_submitted THEN ios_lyrics_cache.found ELSE EXCLUDED.found END",
    )
    .bind(&id)
    .bind(&title)
    .bind(&q.artist)
    .bind(data.as_ref().and_then(|d| d["syncedLyrics"].as_str()))
    .bind(data.as_ref().and_then(|d| d["plainLyrics"].as_str()))
    .bind(found)
    .execute(&st.db)
    .await;
    if let Err(e) = r {
        tracing::warn!("get_lyrics: cache write failed for {title}/{}: {e}", q.artist);
    }
    if !found {
        return Err(AppError::not_found("No lyrics found"));
    }
    let d = data.unwrap();
    Ok(Json(json!({"title": d["trackName"].as_str().filter(|s| !s.is_empty()).unwrap_or(&title), "artist": d["artistName"].as_str().filter(|s| !s.is_empty()).unwrap_or(&q.artist),
        "synced_lyrics": s, "plain_lyrics": p, "instrumental": d["instrumental"].as_bool().unwrap_or(false)})))
}

#[derive(Deserialize)]
struct LyricsBody {
    title: String,
    #[serde(default)]
    artist: String,
    synced_lyrics: Option<String>,
    plain_lyrics: Option<String>,
}

async fn api_lyrics_put(State(st): State<AppState>, _k: ApiKey, J(b): J<LyricsBody>) -> ApiResult<Json<Value>> {
    let ne = |s: &Option<String>| s.as_deref().is_some_and(|x| !x.is_empty());
    if !ne(&b.synced_lyrics) && !ne(&b.plain_lyrics) {
        return Err(AppError::bad_request("Provide synced_lyrics and/or plain_lyrics"));
    }
    sqlx::query(
        "INSERT INTO ios_lyrics_cache (id, title, artist, synced_lyrics, plain_lyrics, found, is_user_submitted) VALUES ($1, $2, $3, $4, $5, TRUE, TRUE) \
         ON CONFLICT (id) DO UPDATE SET synced_lyrics = EXCLUDED.synced_lyrics, plain_lyrics = EXCLUDED.plain_lyrics, found = TRUE, is_user_submitted = TRUE",
    )
    .bind(lyrics_cache_id(&b.title, &b.artist))
    .bind(&b.title)
    .bind(&b.artist)
    .bind(&b.synced_lyrics)
    .bind(&b.plain_lyrics)
    .execute(&st.db)
    .await?;
    Ok(Json(json!({"status": "saved"})))
}

async fn user_lyrics(State(st): State<AppState>, _u: User, Q(q): Q<LyricsQ>) -> ApiResult<Json<Value>> {
    let title = title_param(&q)?;
    let id = lyrics_cache_id(&title, &q.artist);
    let row: Option<(Option<String>, Option<String>, Option<bool>)> =
        sqlx::query_as("SELECT synced_lyrics, plain_lyrics, found FROM ios_lyrics_cache WHERE id = $1").bind(&id).fetch_optional(&st.db).await?;
    if let Some((s, p, Some(true))) = &row {
        if s.as_deref().is_some_and(|x| !x.is_empty()) || p.as_deref().is_some_and(|x| !x.is_empty()) {
            return Ok(Json(json!({"title": title, "artist": q.artist, "synced_lyrics": s, "plain_lyrics": p, "instrumental": false, "source": "cache"})));
        }
    }
    let warmed = st.fetch_and_cache_lyrics(&title, &q.artist, q.duration).await;
    let (mut s, mut p) = (None, None);
    if warmed {
        if let Some((a, b)) = sqlx::query_as::<_, (Option<String>, Option<String>)>("SELECT synced_lyrics, plain_lyrics FROM ios_lyrics_cache WHERE id = $1").bind(&id).fetch_optional(&st.db).await? {
            s = a;
            p = b;
        }
    }
    let has = s.as_deref().is_some_and(|x| !x.is_empty()) || p.as_deref().is_some_and(|x| !x.is_empty());
    Ok(Json(json!({"title": title, "artist": q.artist, "synced_lyrics": s, "plain_lyrics": p, "instrumental": false, "source": if has { "lrclib" } else { "none" }})))
}

async fn user_lyrics_post(State(st): State<AppState>, u: User, J(b): J<LyricsBody>) -> ApiResult<StatusCode> {
    let title = b.title.trim().to_string();
    if title.is_empty() {
        return Err(AppError::bad_request("title is required"));
    }
    let s = b.synced_lyrics.as_deref().map(str::trim).filter(|x| !x.is_empty());
    let p = b.plain_lyrics.as_deref().map(str::trim).filter(|x| !x.is_empty());
    if s.is_none() && p.is_none() {
        return Err(AppError::bad_request("Provide synced_lyrics and/or plain_lyrics"));
    }
    sqlx::query(
        "INSERT INTO ios_lyrics_cache (id, title, artist, synced_lyrics, plain_lyrics, found, is_user_submitted, submitted_by_user_id) VALUES ($1, $2, $3, $4, $5, TRUE, TRUE, $6) \
         ON CONFLICT (id) DO UPDATE SET synced_lyrics = CASE WHEN ios_lyrics_cache.is_user_submitted THEN ios_lyrics_cache.synced_lyrics ELSE EXCLUDED.synced_lyrics END, \
           plain_lyrics = CASE WHEN ios_lyrics_cache.is_user_submitted THEN ios_lyrics_cache.plain_lyrics ELSE EXCLUDED.plain_lyrics END, found = TRUE, is_user_submitted = TRUE, \
           submitted_by_user_id = COALESCE(ios_lyrics_cache.submitted_by_user_id, EXCLUDED.submitted_by_user_id)",
    )
    .bind(lyrics_cache_id(&title, &b.artist))
    .bind(&title)
    .bind(&b.artist)
    .bind(s)
    .bind(p)
    .bind(&u.id)
    .execute(&st.db)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct PrefetchBody {
    tracks: Vec<PrefetchTrack>,
}

#[derive(Deserialize)]
struct PrefetchTrack {
    title: String,
    #[serde(default)]
    artist: String,
    duration: Option<i64>,
}

async fn lyrics_prefetch(State(st): State<AppState>, u: User, J(b): J<PrefetchBody>) -> ApiResult<Json<Value>> {
    let tracks: Vec<&PrefetchTrack> = b.tracks.iter().take(25).collect();
    let found = futures_util::future::join_all(tracks.iter().map(|t| st.fetch_and_cache_lyrics(&t.title, &t.artist, t.duration))).await.into_iter().filter(|x| *x).count();
    crate::db::log_event(&st.db, "metadata", "lyrics_prefetch_completed", Some(&u.id), "info", "", Some(json!({"requested": tracks.len(), "found": found}))).await;
    Ok(Json(json!({"requested": tracks.len(), "found": found})))
}

async fn lyrics_search(State(st): State<AppState>, _k: ApiKey, Q(q): Q<LyricsQ>) -> ApiResult<Json<Value>> {
    let text = q.q.ok_or_else(|| invalid("q", "Field required"))?;
    if text.chars().count() < 2 || text.chars().count() > 200 {
        return Err(invalid("q", if text.chars().count() < 2 { "String should have at least 2 characters" } else { "String should have at most 200 characters" }));
    }
    let limit = q.limit.unwrap_or(25);
    check_range("limit", limit, 1, 100)?;
    let doc = "to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(artist, '') || ' ' || COALESCE(plain_lyrics, ''))";
    let rows: Vec<(String, String, Option<String>)> = sqlx::query_as(&format!(
        "SELECT title, artist, plain_lyrics FROM ios_lyrics_cache WHERE found = TRUE AND plain_lyrics IS NOT NULL AND {doc} @@ plainto_tsquery('english', $1) \
         ORDER BY ts_rank({doc}, plainto_tsquery('english', $1)) DESC LIMIT $2"
    ))
    .bind(&text)
    .bind(limit)
    .fetch_all(&st.db)
    .await?;
    let ql = text.to_lowercase();
    Ok(Json(Value::Array(
        rows.into_iter()
            .map(|(t, a, p)| {
                let lines: Vec<&str> = p.as_deref().unwrap_or("").lines().map(str::trim).filter(|l| !l.is_empty()).collect();
                let snip = lines.iter().find(|l| l.to_lowercase().contains(&ql)).or(lines.first()).map(|l| l.chars().take(200).collect::<String>()).unwrap_or_default();
                json!({"title": t, "artist": a, "snippet": snip})
            })
            .collect(),
    )))
}
