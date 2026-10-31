//! Personal cloud library + server library (route group 4): listing,
//! upload (streamed to disk while hashing), streaming, artwork, metadata,
//! waveform, gallery, storage usage, acoustic duplicates. Locked (`.lms`)
//! files are stored and served as-is; the server only reads them through a
//! temporary unmasked copy and never rewrites them.

use crate::analysis;
use crate::auth::User;
use crate::error::{ApiResult, AppError};
use crate::extract::{Q, check_range, invalid};
use crate::files;
use crate::lock;
use crate::state::AppState;
use crate::storage::{self, audio_media_type, gain_db, safe_join, stable_id};
use axum::body::Bytes;
use axum::extract::{Multipart, Path as AxPath, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, patch, post};
use axum::{Json, Router};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::AsyncWriteExt;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/library/server", get(server_library))
        .route("/api/library/server/stream", get(server_stream))
        .route("/api/library/server/artwork", get(server_artwork))
        .route("/user/storage/usage", get(storage_usage))
        .route("/user/download-history", get(download_history))
        .route("/user/music", get(list_music))
        .route("/user/music/search", get(search_music))
        .route("/user/music/upload", post(upload))
        .route("/user/music/artwork-flag", patch(artwork_flag))
        .route("/user/music/waveform", get(get_waveform))
        .route("/user/music/stream", get(stream_music))
        .route("/user/music/artwork-upload", post(artwork_upload))
        .route("/user/music/artwork", get(music_artwork))
        .route("/user/music/metadata", get(list_metadata))
        .route("/user/music/metadata/backfill", post(backfill))
        .route("/user/music/{*filepath}", axum::routing::delete(delete_music))
        .route("/user/rp-artwork-upload", post(rp_artwork_upload))
        .route("/api/rp-artwork/{file}", get(rp_artwork_get))
        .route("/user/gallery/images", get(list_gallery).post(upload_gallery))
        .route("/user/gallery/images/{id}", get(get_gallery).delete(delete_gallery))
        .route("/user/library/acoustic-duplicates", get(acoustic_duplicates))
}

const NO_ART: &[u8] = b"\x00LUMISOUND-NO-ARTWORK";
const MAX_UPLOAD: u64 = 100 * 1024 * 1024;

fn jpeg(data: Vec<u8>) -> Response {
    ([(header::CONTENT_TYPE, "image/jpeg")], data).into_response()
}

fn user_dir(st: &AppState, uid: &str, msg: &str) -> ApiResult<PathBuf> {
    st.user_music_dir(uid).ok_or_else(|| AppError::new(503, msg))
}

/// Python's datetime.fromtimestamp(ts, tz=utc).isoformat().
fn py_iso_utc(t: std::time::SystemTime) -> Option<String> {
    let f = t.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64();
    let mut secs = f.trunc() as i64;
    let mut us = analysis::pyround(f.fract() * 1e6, 0) as i64;
    if us >= 1_000_000 {
        secs += 1;
        us -= 1_000_000;
    }
    let dt = chrono::DateTime::from_timestamp(secs, (us * 1000) as u32)?.naive_utc();
    Some(format!("{}+00:00", crate::db::py_iso(&dt)))
}

// ---- artwork disk cache ----------------------------------------------------------------------

fn art_cache_path(st: &AppState, full: &Path) -> Option<PathBuf> {
    let m = std::fs::metadata(full).ok()?;
    let mtime = m.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
    let d = hex::encode(Sha256::digest(format!("{}|{mtime}|{}", full.display(), m.len()).as_bytes()));
    Some(Path::new(&st.cfg.ytdlp_cache_dir).join("artwork-cache").join(&d[..2]).join(format!("{d}.jpg")))
}

fn art_cache_get(st: &AppState, full: &Path) -> Option<Vec<u8>> {
    std::fs::read(art_cache_path(st, full)?).ok()
}

fn art_cache_put(st: &AppState, full: &Path, data: &[u8]) {
    let Some(p) = art_cache_path(st, full) else { return };
    let tmp = p.with_extension("part");
    let r = std::fs::create_dir_all(p.parent().unwrap()).and_then(|_| std::fs::write(&tmp, data)).and_then(|_| std::fs::rename(&tmp, &p));
    if let Err(e) = r {
        tracing::debug!("artwork cache write failed for {}: {e}", full.display());
    }
}

fn locked_artwork_path(music_dir: &Path, metadata_id: &str) -> PathBuf {
    let safe: String = metadata_id.chars().filter(|c| c.is_alphanumeric()).collect();
    music_dir.join(".artwork").join(format!("{safe}.jpg"))
}

// ---- server library --------------------------------------------------------------------------

#[derive(Deserialize)]
struct ServerLibQ {
    search: Option<String>,
    limit: Option<i64>,
    path: Option<String>,
}

fn server_root(st: &AppState) -> Option<PathBuf> {
    let d = st.cfg.server_music_dir.as_ref()?;
    Some(std::fs::canonicalize(d).unwrap_or_else(|_| PathBuf::from(d)))
}

async fn server_library(State(st): State<AppState>, Q(q): Q<ServerLibQ>) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(200);
    check_range("limit", limit, 1, 500)?;
    let Some(root) = server_root(&st) else {
        return Ok(Json(json!({"tracks": [], "total": 0, "dir": null, "configured": false})));
    };
    let r = root.clone();
    let files: Vec<PathBuf> =
        tokio::task::spawn_blocking(move || storage::walk_files(&r).into_iter().filter(|p| storage::is_audio_ext(p)).collect()).await.unwrap_or_default();
    let search = q.search.unwrap_or_default().to_lowercase();
    let metas = futures_util::stream::iter(files.iter().cloned())
        .map(|p| {
            let st = st.clone();
            async move {
                let abs = std::fs::canonicalize(&p).unwrap_or(p.clone());
                let readable = storage::readable_copy(&p).await;
                let m = st.tags.tags(&abs, readable.path()).await;
                (p, abs, m)
            }
        })
        .buffered(8)
        .collect::<Vec<_>>()
        .await;
    st.tags.flush().await;
    let mut tracks: Vec<Value> = Vec::new();
    for (p, abs, m) in metas {
        let s = |k: &str| m[k].as_str().filter(|s| !s.is_empty()).map(str::to_string);
        let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
        let title = s("title").unwrap_or(stem);
        let artist = s("artist").unwrap_or_else(|| "Unknown Artist".into());
        if !search.is_empty() && !title.to_lowercase().contains(&search) && !artist.to_lowercase().contains(&search) {
            continue;
        }
        let mut album = s("album").unwrap_or_default();
        if album.is_empty() {
            if let Some(parent) = p.parent() {
                if std::fs::canonicalize(parent).unwrap_or(parent.to_path_buf()) != root {
                    album = parent.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
                }
            }
        }
        let rel = p.strip_prefix(&root).map(|r| r.to_string_lossy().into_owned()).unwrap_or_else(|_| p.file_name().unwrap().to_string_lossy().into());
        tracks.push(json!({
            "id": stable_id(&abs), "title": title, "artist": artist, "album": album,
            "duration": m["duration"].as_f64().filter(|d| *d != 0.0).unwrap_or(0.0),
            "genre": s("genre").unwrap_or_default(), "track_number": s("track_number").unwrap_or_default(),
            "has_artwork": m["has_artwork"].as_bool().unwrap_or(false), "server_path": rel,
            "filename": p.file_name().unwrap().to_string_lossy(), "ext": p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase(),
        }));
    }
    let key = |t: &Value, k: &str| t[k].as_str().unwrap_or("").to_lowercase();
    tracks.sort_by(|a, b| (key(a, "artist"), key(a, "album"), key(a, "title")).cmp(&(key(b, "artist"), key(b, "album"), key(b, "title"))));
    let total = tracks.len();
    tracks.truncate(limit as usize);
    Ok(Json(json!({"tracks": tracks, "total": total, "dir": root.to_string_lossy()})))
}

fn server_file(st: &AppState, rel: Option<String>) -> ApiResult<PathBuf> {
    let rel = rel.ok_or_else(|| invalid("path", "Field required"))?;
    let root = server_root(st).ok_or_else(|| AppError::not_found("Server music library not configured"))?;
    let p = safe_join(&root, &rel).ok_or_else(|| AppError::forbidden("Access denied"))?;
    if !p.is_file() {
        return Err(AppError::not_found("File not found"));
    }
    Ok(p)
}

async fn server_stream(State(st): State<AppState>, headers: HeaderMap, Q(q): Q<ServerLibQ>) -> ApiResult<Response> {
    let p = server_file(&st, q.path)?;
    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let name = p.file_name().unwrap().to_string_lossy().into_owned();
    Ok(files::serve(&p, audio_media_type(&ext), Some(&name), &headers, None).await)
}

async fn server_artwork(State(st): State<AppState>, Q(q): Q<ServerLibQ>) -> ApiResult<Response> {
    let p = server_file(&st, q.path)?;
    let data = analysis::embedded_artwork_copy(&p).await.map_err(|e| match e {
        "timeout" => AppError::new(408, "Artwork extraction timed out"),
        _ => AppError::internal("Artwork extraction failed"),
    })?;
    if !data.is_empty() {
        art_cache_put(&st, &p, &data);
        return Ok(jpeg(data));
    }
    let readable = storage::readable_copy(&p).await;
    if let (Some(d), _) = analysis::recover_artwork(&st.http, readable.path()).await {
        art_cache_put(&st, &p, &d);
        return Ok(jpeg(d));
    }
    art_cache_put(&st, &p, NO_ART);
    Err(AppError::not_found("No embedded artwork found"))
}

// ---- storage / history -----------------------------------------------------------------------

async fn storage_usage(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let mut usage = st.storage_usage(&u.id).await?;
    let quota = st.user_quota_bytes(&u.id).await;
    let used = usage["used_bytes"].as_i64().unwrap_or(0);
    usage["quota_bytes"] = json!(quota);
    usage["quota_exceeded"] = json!(quota != 0 && used > quota);
    Ok(Json(usage))
}

async fn download_history(State(st): State<AppState>, u: User, Q(q): Q<ServerLibQ>) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(200);
    check_range("limit", limit, 1, 1000)?;
    let search = q.search.unwrap_or_default();
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('source', source, 'id', source_id, 'title', title, 'artist', COALESCE(artist, ''), \
           'thumbnail_url', COALESCE(thumbnail_url, ''), 'duration_seconds', COALESCE(NULLIF(duration_seconds, 0), 0), 'format', format, \
           'download_count', download_count, 'last_downloaded_at', lumi_iso(last_downloaded_at)) ORDER BY last_downloaded_at DESC), '[]'::json) \
         FROM (SELECT * FROM ios_download_history WHERE user_id = $1 AND ($2 = '' OR title ILIKE $3 OR artist ILIKE $3) \
               ORDER BY last_downloaded_at DESC LIMIT $4) h",
    )
    .bind(&u.id)
    .bind(&search)
    .bind(format!("%{search}%"))
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    let n = v.as_array().map_or(0, Vec::len);
    Ok(Json(json!({"tracks": v, "total": n})))
}

// ---- listing ---------------------------------------------------------------------------------

type MetaRow = (
    String,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<f64>,
    Option<bool>,
    Option<String>,
    Option<f64>,
    Option<f64>,
    Option<f64>,
    Option<bool>,
    Option<f64>,
    Option<f64>,
    Option<String>,
    Option<i32>,
);

fn decode_spectral(raw: &Option<String>) -> Value {
    raw.as_deref()
        .and_then(|r| serde_json::from_str::<Value>(r).ok())
        .filter(|v| v.as_array().is_some_and(|a| a.len() == 10))
        .unwrap_or(Value::Null)
}

async fn list_music(State(st): State<AppState>, u: User, Q(q): Q<ServerLibQ>) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(5000);
    check_range("limit", limit, 1, 100000)?;
    let Some(dir) = st.user_music_dir(&u.id) else {
        return Ok(Json(json!({"tracks": [], "total": 0, "configured": false})));
    };
    let _ = tokio::fs::create_dir_all(&dir).await;
    let d = dir.clone();
    let files: Vec<(PathBuf, bool)> = tokio::task::spawn_blocking(move || {
        storage::walk_files(&d)
            .into_iter()
            .filter_map(|p| {
                if storage::is_audio_ext(&p) {
                    Some((p, false))
                } else if lock::inner_ext(&p.file_name()?.to_string_lossy()).is_some() {
                    Some((p, true))
                } else {
                    None
                }
            })
            .collect()
    })
    .await
    .map_err(|e| AppError::internal(e.to_string()))?;
    let mut stored: std::collections::HashMap<String, (Value, Option<String>)> = Default::default();
    if !files.is_empty() {
        let rows: Vec<MetaRow> = sqlx::query_as(
            "SELECT relative_path, title, artist, album, genre, duration_seconds, has_artwork, lumi_iso(uploaded_at), bpm, \
                    trailing_silence_s, outro_slope_db, outro_cold_stop, intro_lead_in_s, intro_onset_hardness, spectral_profile, sample_rate \
             FROM ios_user_music_metadata WHERE user_id = $1 AND relative_path IS NOT NULL",
        )
        .bind(&u.id)
        .fetch_all(&st.db)
        .await?;
        for r in rows {
            let m = json!({"title": r.1, "artist": r.2, "album": r.3, "genre": r.4, "duration": r.5, "has_artwork": r.6, "bpm": r.8,
                "trailing_silence_s": r.9, "outro_slope_db": r.10, "outro_cold_stop": r.11, "intro_lead_in_s": r.12,
                "intro_onset_hardness": r.13, "spectral_raw": r.14, "sample_rate": r.15});
            stored.insert(r.0, (m, r.7));
        }
    }
    // Tags for plain files (ffprobe, cached by path/mtime/size).
    let unlocked: Vec<PathBuf> = files.iter().filter(|(_, l)| !l).map(|(p, _)| p.clone()).collect();
    let tags: std::collections::HashMap<PathBuf, Value> = futures_util::stream::iter(unlocked)
        .map(|p| {
            let st = st.clone();
            async move {
                let abs = std::fs::canonicalize(&p).unwrap_or(p.clone());
                let readable = storage::readable_copy(&p).await;
                let m = st.tags.tags(&abs, readable.path()).await;
                (p, m)
            }
        })
        .buffered(8)
        .collect()
        .await;
    st.tags.flush().await;
    let dir_real = std::fs::canonicalize(&dir).unwrap_or(dir.clone());
    let search = q.search.unwrap_or_default().to_lowercase();
    let mut tracks: Vec<Value> = Vec::with_capacity(files.len());
    for (p, locked) in &files {
        let abs = std::fs::canonicalize(p).unwrap_or(p.clone());
        let rel = p.strip_prefix(&dir).map(|r| r.to_string_lossy().into_owned()).unwrap_or_else(|_| p.file_name().unwrap().to_string_lossy().into());
        let name = p.file_name().unwrap().to_string_lossy().into_owned();
        let empty = (json!({}), None);
        let (meta, uploaded) = if *locked { stored.get(&rel).cloned().unwrap_or(empty) } else { (tags.get(p).cloned().unwrap_or(json!({})), stored.get(&rel).and_then(|s| s.1.clone())) };
        let s = |k: &str| meta[k].as_str().filter(|s| !s.is_empty()).map(str::to_string);
        let (ext, title, track_number) = if *locked {
            (lock::inner_ext(&name).unwrap_or_default(), s("title").unwrap_or_else(|| lock::display_stem(&name)), String::new())
        } else {
            (
                p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase(),
                s("title").unwrap_or_else(|| p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string()),
                s("track_number").unwrap_or_default(),
            )
        };
        let artist = s("artist").unwrap_or_else(|| "Unknown Artist".into());
        let mut album = s("album").unwrap_or_default();
        if album.is_empty() {
            if let Some(parent) = p.parent() {
                if std::fs::canonicalize(parent).unwrap_or(parent.to_path_buf()) != dir_real {
                    album = parent.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
                }
            }
        }
        if !search.is_empty() && !title.to_lowercase().contains(&search) && !artist.to_lowercase().contains(&search) && !album.to_lowercase().contains(&search) {
            continue;
        }
        let uploaded = uploaded.or_else(|| std::fs::metadata(p).ok().and_then(|m| m.modified().ok()).and_then(py_iso_utc));
        // Plain files are described by their tags (no analysis fields, as in Python); locked ones by their DB row.
        let pick = |k: &str| if *locked { meta.get(k).cloned().unwrap_or(Value::Null) } else { Value::Null };
        tracks.push(json!({
            "id": stable_id(&abs), "title": title, "artist": artist, "album": album,
            "duration": meta["duration"].as_f64().filter(|d| *d != 0.0).map(|d| json!(d)).unwrap_or(json!(0.0)),
            "genre": s("genre").unwrap_or_default(), "track_number": track_number,
            "has_artwork": meta["has_artwork"].as_bool().unwrap_or(false),
            "bpm": pick("bpm"), "trailing_silence_s": pick("trailing_silence_s"), "outro_slope_db": pick("outro_slope_db"),
            "outro_cold_stop": pick("outro_cold_stop"), "intro_lead_in_s": pick("intro_lead_in_s"),
            "intro_onset_hardness": pick("intro_onset_hardness"),
            "spectral_profile": if *locked { decode_spectral(&meta["spectral_raw"].as_str().map(str::to_string)) } else { Value::Null },
            "server_path": rel, "filename": name, "ext": ext, "is_locked": locked, "uploaded_at": uploaded,
            "sample_rate": meta.get("sample_rate").cloned().unwrap_or(Value::Null),
        }));
    }
    let k = |t: &Value, f: &str| t[f].as_str().unwrap_or("").to_lowercase();
    tracks.sort_by(|a, b| (k(a, "album"), k(a, "title")).cmp(&(k(b, "album"), k(b, "title"))));
    let eq_target = {
        let profiles: Vec<Vec<f64>> = tracks
            .iter()
            .filter_map(|t| t["spectral_profile"].as_array().map(|a| a.iter().filter_map(Value::as_f64).collect::<Vec<_>>()))
            .filter(|v| v.len() == 10)
            .collect();
        if profiles.len() < 25 {
            Value::Null
        } else {
            json!((0..10)
                .map(|i| {
                    let mut col: Vec<f64> = profiles.iter().map(|p| p[i]).collect();
                    col.sort_by(|a, b| a.partial_cmp(b).unwrap());
                    let n = col.len();
                    let m = if n % 2 == 1 { col[n / 2] } else { (col[n / 2 - 1] + col[n / 2]) / 2.0 };
                    analysis::pyround(m, 2)
                })
                .collect::<Vec<_>>())
        }
    };
    let total = tracks.len();
    tracks.truncate(limit as usize);
    Ok(Json(json!({"tracks": tracks, "total": total, "configured": true, "eq_target": eq_target})))
}

#[derive(Deserialize)]
struct SearchQ {
    q: Option<String>,
    limit: Option<i64>,
}

async fn search_music(State(st): State<AppState>, u: User, Q(q): Q<SearchQ>) -> ApiResult<Json<Value>> {
    let text = q.q.ok_or_else(|| invalid("q", "Field required"))?;
    if text.is_empty() || text.chars().count() > 200 {
        return Err(invalid("q", "String should have between 1 and 200 characters"));
    }
    let limit = q.limit.unwrap_or(50);
    check_range("limit", limit, 1, 200)?;
    const FIELDS: &str = "json_build_object('metadata_id', id, 'filename', filename, 'title', title, 'artist', artist, 'album', album, \
        'genre', genre, 'duration', COALESCE(NULLIF(duration_seconds, 0), 0.0), 'has_artwork', COALESCE(has_artwork, false), 'bpm', bpm, 'musical_key', musical_key)";
    let doc = "to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(artist, '') || ' ' || COALESCE(album, ''))";
    let mut v: Value = sqlx::query_scalar(&format!(
        "SELECT COALESCE(json_agg(r.j ORDER BY r.rank DESC), '[]'::json) FROM (SELECT {FIELDS} AS j, ts_rank({doc}, plainto_tsquery('english', $2)) AS rank \
         FROM ios_user_music_metadata WHERE user_id = $1 AND {doc} @@ plainto_tsquery('english', $2) ORDER BY rank DESC LIMIT $3) r"
    ))
    .bind(&u.id)
    .bind(&text)
    .bind(limit)
    .fetch_one(&st.db)
    .await?;
    if v.as_array().is_none_or(Vec::is_empty) {
        v = sqlx::query_scalar(&format!(
            "SELECT COALESCE(json_agg(r.j), '[]'::json) FROM (SELECT {FIELDS} AS j FROM ios_user_music_metadata \
             WHERE user_id = $1 AND (title ILIKE $2 OR artist ILIKE $2 OR album ILIKE $2) LIMIT $3) r"
        ))
        .bind(&u.id)
        .bind(format!("%{text}%"))
        .bind(limit)
        .fetch_one(&st.db)
        .await?;
    }
    let n = v.as_array().map_or(0, Vec::len);
    Ok(Json(json!({"results": v, "total": n})))
}

// ---- upload ----------------------------------------------------------------------------------

#[derive(Deserialize)]
struct UploadQ {
    filename: Option<String>,
    #[serde(default)]
    folder: String,
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    genre: Option<String>,
    year: Option<String>,
    duration: Option<f64>,
    bitrate: Option<i32>,
    sample_rate: Option<i32>,
    #[serde(default)]
    has_artwork: bool,
}

fn truncate_bytes(s: &str, max: usize) -> String {
    let mut end = s.len().min(max);
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

async fn upload(State(st): State<AppState>, u: User, Q(q): Q<UploadQ>, req: Request) -> ApiResult<Response> {
    let filename = q.filename.clone().ok_or_else(|| invalid("filename", "Field required"))?;
    let dir = user_dir(&st, &u.id, "User music storage not configured on server")?;
    let safe = Path::new(&filename).file_name().and_then(|n| n.to_str()).unwrap_or("").trim().to_string();
    let locked = lock::inner_ext(&safe).is_some();
    let ext_ok = Path::new(&safe).extension().and_then(|e| e.to_str()).is_some_and(|e| storage::AUDIO_EXTS.contains(&e.to_lowercase().as_str()));
    if safe.is_empty() || safe == "." || safe == ".." || (!locked && !ext_ok) {
        return Err(AppError::bad_request("Unsupported or invalid filename"));
    }
    let suffix = if locked {
        format!(".{}.{}", lock::inner_ext(&safe).unwrap(), lock::EXT)
    } else {
        Path::new(&safe).extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default()
    };
    let stem = &safe[..safe.len() - suffix.len()];
    let safe = format!("{}{suffix}", truncate_bytes(stem, 240usize.saturating_sub(suffix.len())));
    let folder = q.folder.trim_matches('/');
    let dest_dir = if folder.is_empty() { Some(dir.clone()) } else { safe_join(&dir, folder) };
    let dest_dir = dest_dir.ok_or_else(|| AppError::bad_request("Invalid folder path"))?;
    tokio::fs::create_dir_all(&dest_dir).await?;
    let dest = dest_dir.join(&safe);

    // Stream the body to a temp file next to the destination while hashing.
    let tmp = dest_dir.join(format!(".upload-{}.part", uuid::Uuid::new_v4().simple()));
    let mut file = tokio::fs::File::create(&tmp).await?;
    let mut hasher = Sha256::new();
    let mut size: u64 = 0;
    let mut stream = req.into_body().into_data_stream();
    let cleanup = |p: PathBuf| async move {
        let _ = tokio::fs::remove_file(p).await;
    };
    while let Some(chunk) = stream.next().await {
        let chunk = match chunk {
            Ok(c) => c,
            Err(_) => {
                cleanup(tmp.clone()).await;
                return Err(AppError::new(499, "Client disconnected before upload completed"));
            }
        };
        size += chunk.len() as u64;
        if size > MAX_UPLOAD {
            cleanup(tmp.clone()).await;
            return Err(AppError::new(413, "File too large (max 100 MB)"));
        }
        hasher.update(&chunk);
        file.write_all(&chunk).await?;
    }
    file.flush().await?;
    drop(file);
    if size == 0 {
        cleanup(tmp.clone()).await;
        tracing::warn!("upload_user_music: empty body for {safe} (user {})", u.id);
        return Err(AppError::bad_request("Empty file body"));
    }
    let quota = st.user_quota_bytes(&u.id).await;
    if quota != 0 {
        let used = st.storage_usage(&u.id).await?["used_bytes"].as_i64().unwrap_or(0);
        if used + size as i64 > quota {
            cleanup(tmp.clone()).await;
            return Err(AppError::new(507, format!("Storage quota exceeded ({used} + {size} > {quota} bytes)")));
        }
    }
    let hash = hex::encode(hasher.finalize());
    let existing: Option<String> =
        sqlx::query_scalar("SELECT filename FROM ios_user_music_metadata WHERE id = $1 AND user_id = $2").bind(&hash).bind(&u.id).fetch_optional(&st.db).await?;
    if let Some(name) = existing {
        let p = dir.join(&name);
        if p.exists() {
            cleanup(tmp.clone()).await;
            tracing::info!("upload_user_music: duplicate of {name} for user {}, skipping write", u.id);
            let abs = std::fs::canonicalize(&p).unwrap_or(p.clone());
            let size = std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
            let rel = p.strip_prefix(&dir).map(|r| r.to_string_lossy().into_owned()).unwrap_or(name.clone());
            return Ok((StatusCode::CREATED, Json(json!({"filename": name, "path": rel, "id": stable_id(&abs), "metadata_id": hash, "size": size, "duplicate": true})))
                .into_response());
        }
    }
    if st.cfg.user_music_compression {
        let (src, dst) = (tmp.clone(), dest.clone());
        let r = tokio::task::spawn_blocking(move || -> std::io::Result<u64> {
            let mut enc = flate2::write::GzEncoder::new(std::fs::File::create(&dst)?, flate2::Compression::new(6));
            std::io::copy(&mut std::fs::File::open(&src)?, &mut enc)?;
            let f = enc.finish()?;
            let n = f.metadata()?.len();
            std::fs::remove_file(&src)?;
            Ok(n)
        })
        .await
        .map_err(|e| AppError::internal(e.to_string()))?;
        match r {
            Ok(n) => tracing::info!("upload_user_music: saved {safe} for user {} compressed ({size} -> {n} bytes)", u.id),
            Err(e) => {
                cleanup(tmp.clone()).await;
                tracing::error!("upload_user_music: write failed for user {}: {e}", u.id);
                return Err(AppError::internal("Failed to save file"));
            }
        }
    } else if let Err(e) = tokio::fs::rename(&tmp, &dest).await {
        cleanup(tmp.clone()).await;
        tracing::error!("upload_user_music: write failed for user {}: {e}", u.id);
        return Err(AppError::internal("Failed to save file"));
    } else {
        tracing::info!("upload_user_music: saved {safe} for user {} ({size} bytes)", u.id);
    }
    let abs = std::fs::canonicalize(&dest).unwrap_or(dest.clone());
    let rel = dest.strip_prefix(&dir).map(|r| r.to_string_lossy().into_owned()).unwrap_or(safe.clone());
    let ext = Path::new(&safe).extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let a = if locked {
        analysis::UploadAnalysis { loudness_lufs: None, bpm: None, musical_key: None, waveform: None }
    } else {
        let _p = st.analysis_sem.acquire().await;
        let readable = storage::readable_copy(&dest).await;
        analysis::analyze_upload(readable.path()).await
    };
    let wf_json = a.waveform.as_ref().filter(|w| !w.is_empty()).map(|w| serde_json::to_string(w).unwrap());
    let r = sqlx::query(
        "INSERT INTO ios_user_music_metadata (id, user_id, filename, original_filename, title, artist, album, genre, year, duration_seconds, \
           file_size_bytes, bitrate, sample_rate, mime_type, has_artwork, loudness_lufs, bpm, musical_key, waveform_json, relative_path) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20) \
         ON CONFLICT (id) DO UPDATE SET filename = EXCLUDED.filename, relative_path = EXCLUDED.relative_path, \
           title = COALESCE(EXCLUDED.title, ios_user_music_metadata.title), artist = COALESCE(EXCLUDED.artist, ios_user_music_metadata.artist), \
           album = COALESCE(EXCLUDED.album, ios_user_music_metadata.album), genre = COALESCE(EXCLUDED.genre, ios_user_music_metadata.genre), \
           year = COALESCE(EXCLUDED.year, ios_user_music_metadata.year), \
           duration_seconds = COALESCE(EXCLUDED.duration_seconds, ios_user_music_metadata.duration_seconds), \
           file_size_bytes = EXCLUDED.file_size_bytes, bitrate = COALESCE(EXCLUDED.bitrate, ios_user_music_metadata.bitrate), \
           sample_rate = COALESCE(EXCLUDED.sample_rate, ios_user_music_metadata.sample_rate), mime_type = EXCLUDED.mime_type, \
           has_artwork = EXCLUDED.has_artwork OR ios_user_music_metadata.has_artwork, \
           loudness_lufs = COALESCE(EXCLUDED.loudness_lufs, ios_user_music_metadata.loudness_lufs), bpm = COALESCE(EXCLUDED.bpm, ios_user_music_metadata.bpm), \
           musical_key = COALESCE(EXCLUDED.musical_key, ios_user_music_metadata.musical_key), \
           waveform_json = COALESCE(EXCLUDED.waveform_json, ios_user_music_metadata.waveform_json)",
    )
    .bind(&hash)
    .bind(&u.id)
    .bind(&safe)
    .bind(&filename)
    .bind(&q.title)
    .bind(&q.artist)
    .bind(&q.album)
    .bind(&q.genre)
    .bind(&q.year)
    .bind(q.duration)
    .bind(size as i64)
    .bind(q.bitrate)
    .bind(q.sample_rate)
    .bind(audio_media_type(&ext))
    .bind(q.has_artwork)
    .bind(a.loudness_lufs)
    .bind(a.bpm)
    .bind(&a.musical_key)
    .bind(&wf_json)
    .bind(&rel)
    .execute(&st.db)
    .await;
    if let Err(e) = r {
        tracing::warn!("upload_user_music: metadata insert failed for {safe}: {e}");
    }
    {
        let (st2, uid) = (st.clone(), u.id.clone());
        tokio::spawn(async move { st2.maybe_warn_storage_quota(&uid).await });
    }
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "filename": safe, "path": rel, "id": stable_id(&abs), "loudness_lufs": a.loudness_lufs, "gain_db": gain_db(a.loudness_lufs),
            "bpm": a.bpm, "musical_key": a.musical_key, "waveform": a.waveform.filter(|w| !w.is_empty()), "metadata_id": hash, "size": size,
        })),
    )
        .into_response())
}

#[derive(Deserialize)]
struct FlagQ {
    filename: Option<String>,
    has_artwork: Option<bool>,
}

async fn artwork_flag(State(st): State<AppState>, u: User, Q(q): Q<FlagQ>) -> ApiResult<StatusCode> {
    let f = q.filename.ok_or_else(|| invalid("filename", "Field required"))?;
    let h = q.has_artwork.ok_or_else(|| invalid("has_artwork", "Field required"))?;
    sqlx::query("UPDATE ios_user_music_metadata SET has_artwork = $1 WHERE user_id = $2 AND filename = $3").bind(h).bind(&u.id).bind(&f).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct IdQ {
    metadata_id: Option<String>,
    id: Option<String>,
    path: Option<String>,
    quality: Option<String>,
    key: Option<String>,
    song_id: Option<String>,
    force_rescan: Option<bool>,
    display_order: Option<i32>,
}

async fn get_waveform(State(st): State<AppState>, u: User, Q(q): Q<IdQ>) -> ApiResult<Json<Value>> {
    let id = q.metadata_id.ok_or_else(|| invalid("metadata_id", "Field required"))?;
    let raw: Option<Option<String>> =
        sqlx::query_scalar("SELECT waveform_json FROM ios_user_music_metadata WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).fetch_optional(&st.db).await?;
    let raw = raw.flatten().filter(|r| !r.is_empty()).ok_or_else(|| AppError::not_found("No waveform data for this track"))?;
    let peaks: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
    Ok(Json(json!({"metadata_id": id, "peaks": peaks})))
}

fn user_file(st: &AppState, uid: &str, rel: Option<String>) -> ApiResult<(PathBuf, PathBuf)> {
    let rel = rel.ok_or_else(|| invalid("path", "Field required"))?;
    let dir = user_dir(st, uid, "User music storage not configured")?;
    let p = safe_join(&dir, &rel).ok_or_else(|| AppError::forbidden("Access denied"))?;
    if !p.is_file() {
        return Err(AppError::not_found("File not found"));
    }
    Ok((dir, p))
}

async fn stream_music(State(st): State<AppState>, u: User, headers: HeaderMap, Q(q): Q<IdQ>) -> ApiResult<Response> {
    let (dir, p) = user_file(&st, &u.id, q.path)?;
    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let rel = p.strip_prefix(&dir).map(|r| r.to_string_lossy().into_owned()).unwrap_or_default();
    let lufs: Option<Option<f64>> = sqlx::query_scalar("SELECT loudness_lufs FROM ios_user_music_metadata WHERE user_id = $1 AND filename = $2")
        .bind(&u.id)
        .bind(&rel)
        .fetch_optional(&st.db)
        .await
        .unwrap_or(None);
    let gain = gain_db(lufs.flatten());
    let servable = storage::materialize_gzip(&p).await;
    let mut media = audio_media_type(&ext).to_string();
    let mut name = p.file_name().unwrap().to_string_lossy().into_owned();
    let mut serve_path = servable.path().to_path_buf();
    let mut transcoded: Option<PathBuf> = None;
    let bitrate = match q.quality.as_deref() {
        Some("low") => Some("64k"),
        Some("medium") => Some("128k"),
        _ => None,
    };
    if let Some(br) = bitrate {
        let out = std::env::temp_dir().join(format!("transcode_{}.m4a", uuid::Uuid::new_v4().simple()));
        let args: Vec<String> = [
            "-hide_banner", "-nostats", "-v", "quiet", "-i", &serve_path.to_string_lossy(), "-c:a", "aac", "-b:a", br, "-movflags", "+faststart", "-y",
            &out.to_string_lossy(),
        ]
        .map(String::from)
        .to_vec();
        let ok = matches!(st.ytdlp.run("ffmpeg", &args, Duration::from_secs(60)).await, Ok(o) if o.status == Some(0)) && out.exists();
        if ok {
            serve_path = out.clone();
            transcoded = Some(out);
            media = "audio/mp4".into();
            name = format!("{}.m4a", p.file_stem().and_then(|s| s.to_str()).unwrap_or("track"));
        } else {
            let _ = tokio::fs::remove_file(&out).await;
        }
    }
    let mut res = files::serve(
        &serve_path,
        &media,
        Some(&name),
        &headers,
        Some(Box::new(move || {
            drop(servable);
            if let Some(t) = transcoded {
                let _ = std::fs::remove_file(t);
            }
        })),
    )
    .await;
    if let Some(g) = gain {
        if let Ok(v) = HeaderValue::from_str(&crate::probe::py_float(g)) {
            res.headers_mut().insert("x-loudness-gain-db", v);
        }
    }
    Ok(res)
}

async fn read_small_body(req: Request, max: usize) -> Result<Bytes, AppError> {
    axum::body::to_bytes(req.into_body(), max + 1).await.map_err(|_| AppError::new(499, "Client disconnected before upload completed"))
}

async fn artwork_upload(State(st): State<AppState>, u: User, Q(q): Q<IdQ>, req: Request) -> ApiResult<StatusCode> {
    let id = q.id.ok_or_else(|| invalid("id", "Field required"))?;
    let dir = user_dir(&st, &u.id, "User music storage not configured")?;
    let known: Option<i32> = sqlx::query_scalar("SELECT 1 FROM ios_user_music_metadata WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).fetch_optional(&st.db).await?;
    if known.is_none() {
        return Err(AppError::not_found("Unknown track id"));
    }
    let body = read_small_body(req, 2 * 1024 * 1024).await.map_err(|_| AppError::bad_request("Invalid or oversized thumbnail (max 2 MB)"))?;
    if body.is_empty() || body.len() > 2 * 1024 * 1024 {
        return Err(AppError::bad_request("Invalid or oversized thumbnail (max 2 MB)"));
    }
    let dest = locked_artwork_path(&dir, &id);
    tokio::fs::create_dir_all(dest.parent().unwrap()).await?;
    tokio::fs::write(&dest, &body).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn music_artwork(State(st): State<AppState>, u: User, Q(q): Q<IdQ>) -> ApiResult<Response> {
    let raw_rel = q.path.clone().unwrap_or_default();
    let (dir, p) = user_file(&st, &u.id, q.path)?;
    if let Some(c) = art_cache_get(&st, &p) {
        if c == NO_ART {
            return Err(AppError::not_found("No artwork available"));
        }
        return Ok(jpeg(c));
    }
    let rel = p.strip_prefix(&dir).map(|r| r.to_string_lossy().into_owned()).unwrap_or_default();
    let row: Option<String> =
        sqlx::query_scalar("SELECT id FROM ios_user_music_metadata WHERE user_id = $1 AND relative_path = $2").bind(&u.id).bind(&rel).fetch_optional(&st.db).await.unwrap_or(None);
    if let Some(id) = &row {
        if let Ok(d) = tokio::fs::read(locked_artwork_path(&dir, id)).await {
            art_cache_put(&st, &p, &d);
            return Ok(jpeg(d));
        }
    }
    let readable = storage::readable_copy(&p).await;
    let data = analysis::embedded_artwork_copy(readable.path()).await.map_err(|e| match e {
        "timeout" => AppError::new(408, "Artwork extraction timed out"),
        _ => AppError::internal("Artwork extraction failed"),
    })?;
    if !data.is_empty() {
        art_cache_put(&st, &p, &data);
        return Ok(jpeg(data));
    }
    let (rec, source) = analysis::recover_artwork(&st.http, readable.path()).await;
    if let Some(d) = rec {
        let row: Option<String> = sqlx::query_scalar("SELECT id FROM ios_user_music_metadata WHERE user_id = $1 AND relative_path = $2")
            .bind(&u.id)
            .bind(&raw_rel)
            .fetch_optional(&st.db)
            .await
            .unwrap_or(None);
        if let Some(id) = row {
            let cp = locked_artwork_path(&dir, &id);
            let _ = tokio::fs::create_dir_all(cp.parent().unwrap()).await;
            let _ = tokio::fs::write(&cp, &d).await;
            let _ = sqlx::query("UPDATE ios_user_music_metadata SET has_artwork = TRUE WHERE user_id = $1 AND id = $2").bind(&u.id).bind(&id).execute(&st.db).await;
        }
        tracing::info!("user_music_artwork: recovered {source} artwork for {raw_rel} ({} bytes)", d.len());
        art_cache_put(&st, &p, &d);
        return Ok(jpeg(d));
    }
    art_cache_put(&st, &p, NO_ART);
    Err(AppError::not_found("No embedded artwork found"))
}

async fn delete_music(State(st): State<AppState>, u: User, AxPath(filepath): AxPath<String>) -> ApiResult<StatusCode> {
    let dir = user_dir(&st, &u.id, "User music storage not configured")?;
    let p = safe_join(&dir, &filepath).ok_or_else(|| AppError::forbidden("Access denied"))?;
    let existed = p.exists();
    if existed {
        if let Err(e) = tokio::fs::remove_file(&p).await {
            tracing::error!("delete_user_music: failed for user {} path {filepath}: {e}", u.id);
            return Err(AppError::internal("Failed to delete file"));
        }
        let mut parent = p.parent().map(Path::to_path_buf);
        while let Some(d) = parent {
            if d == dir || !d.exists() || std::fs::remove_dir(&d).is_err() {
                break;
            }
            parent = d.parent().map(Path::to_path_buf);
        }
    }
    let deleted: Option<String> = sqlx::query_scalar("DELETE FROM ios_user_music_metadata WHERE user_id = $1 AND filename = $2 RETURNING id")
        .bind(&u.id)
        .bind(&filepath)
        .fetch_optional(&st.db)
        .await?;
    if !existed && deleted.is_none() {
        return Err(AppError::not_found("File not found"));
    }
    if let Some(id) = deleted {
        let _ = tokio::fs::remove_file(locked_artwork_path(&dir, &id)).await;
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct MetaQ {
    limit: Option<i64>,
    min_bpm: Option<f64>,
    max_bpm: Option<f64>,
    key: Option<String>,
}

async fn list_metadata(State(st): State<AppState>, u: User, Q(q): Q<MetaQ>) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(5000);
    check_range("limit", limit, 1, 100000)?;
    for (n, v) in [("min_bpm", q.min_bpm), ("max_bpm", q.max_bpm)] {
        if v.is_some_and(|v| v < 0.0) {
            return Err(invalid(n, "Input should be greater than or equal to 0"));
        }
    }
    let has_dir = st.user_music_dir(&u.id).is_some();
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('id', id, 'filename', filename, 'original_filename', original_filename, \
           'title', title, 'artist', artist, 'album', album, 'genre', genre, 'year', year, 'duration_seconds', duration_seconds, \
           'file_size_bytes', file_size_bytes, 'bitrate', bitrate, 'sample_rate', sample_rate, 'mime_type', mime_type, \
           'has_artwork', COALESCE(has_artwork, false), 'uploaded_at', lumi_iso(uploaded_at), 'loudness_lufs', loudness_lufs, 'bpm', bpm, \
           'musical_key', musical_key, \
           'artwork_url', CASE WHEN COALESCE(has_artwork, false) AND $6 THEN '/user/music/artwork?path=' || replace(filename, ' ', '%20') END, \
           'gain_db', CASE WHEN loudness_lufs IS NULL THEN NULL ELSE round(LEAST(12.0, GREATEST(-12.0, -14.0 - loudness_lufs))::numeric, 2)::float8 END) \
           ORDER BY uploaded_at DESC), '[]'::json) \
         FROM (SELECT * FROM ios_user_music_metadata WHERE user_id = $1 AND ($2::float8 IS NULL OR bpm >= $2) AND ($3::float8 IS NULL OR bpm <= $3) \
               AND ($4::text IS NULL OR $4 = '' OR musical_key = $4) ORDER BY uploaded_at DESC LIMIT $5) m",
    )
    .bind(&u.id)
    .bind(q.min_bpm)
    .bind(q.max_bpm)
    .bind(&q.key)
    .bind(limit)
    .bind(has_dir)
    .fetch_one(&st.db)
    .await?;
    let n = v.as_array().map_or(0, Vec::len);
    Ok(Json(json!({"tracks": v, "total": n})))
}

#[derive(Deserialize)]
struct BackfillQ {
    limit: Option<i64>,
}

async fn backfill(State(st): State<AppState>, u: User, Q(q): Q<BackfillQ>) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(5);
    check_range("limit", limit, 1, 20)?;
    let Some(dir) = st.user_music_dir(&u.id) else { return Ok(Json(json!({"processed": 0, "remaining": 0}))) };
    let rows: Vec<(String, String)> = sqlx::query_as(
        "SELECT id, filename FROM ios_user_music_metadata WHERE user_id = $1 \
         AND (loudness_lufs IS NULL OR bpm IS NULL OR musical_key IS NULL OR waveform_json IS NULL)",
    )
    .bind(&u.id)
    .fetch_all(&st.db)
    .await?;
    let pending: Vec<(String, PathBuf)> = rows.into_iter().filter_map(|(id, f)| safe_join(&dir, &f).filter(|p| p.exists()).map(|p| (id, p))).collect();
    let mut processed = 0;
    for (id, p) in pending.iter().take(limit as usize) {
        let a = {
            let _s = st.analysis_sem.acquire().await;
            let readable = storage::readable_copy(p).await;
            analysis::analyze_upload(readable.path()).await
        };
        sqlx::query(
            "UPDATE ios_user_music_metadata SET loudness_lufs = COALESCE(loudness_lufs, $1), bpm = COALESCE(bpm, $2), \
             musical_key = COALESCE(musical_key, $3), waveform_json = COALESCE(waveform_json, $4) WHERE id = $5 AND user_id = $6",
        )
        .bind(a.loudness_lufs)
        .bind(a.bpm)
        .bind(&a.musical_key)
        .bind(a.waveform.filter(|w| !w.is_empty()).map(|w| serde_json::to_string(&w).unwrap()))
        .bind(id)
        .bind(&u.id)
        .execute(&st.db)
        .await?;
        processed += 1;
    }
    let remaining = pending.len().saturating_sub(processed);
    crate::db::log_event(&st.db, "metadata", "backfill_batch_completed", Some(&u.id), "info", "", Some(json!({"processed": processed, "remaining": remaining}))).await;
    Ok(Json(json!({"processed": processed, "remaining": remaining})))
}

// ---- Rich Presence artwork -------------------------------------------------------------------

fn rp_path(st: &AppState, key: &str) -> Option<PathBuf> {
    if key.len() != 64 || !key.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)) {
        return None;
    }
    Some(Path::new(&st.cfg.ytdlp_cache_dir).join("rp-artwork").join(&key[..2]).join(format!("{key}.jpg")))
}

async fn rp_artwork_upload(State(st): State<AppState>, u: User, Q(q): Q<IdQ>, req: Request) -> ApiResult<StatusCode> {
    let key = q.key.ok_or_else(|| invalid("key", "Field required"))?;
    let song = q.song_id.ok_or_else(|| invalid("song_id", "Field required"))?;
    if key != hex::encode(Sha256::digest(format!("{}:{song}", u.id).as_bytes())) {
        return Err(AppError::bad_request("key does not match sha256(user_id + song_id)"));
    }
    let dest = rp_path(&st, &key).ok_or_else(|| AppError::bad_request("Invalid key"))?;
    let body = read_small_body(req, 2 * 1024 * 1024).await.map_err(|_| AppError::bad_request("Invalid or oversized thumbnail (max 2 MB)"))?;
    if body.is_empty() || body.len() > 2 * 1024 * 1024 {
        return Err(AppError::bad_request("Invalid or oversized thumbnail (max 2 MB)"));
    }
    tokio::fs::create_dir_all(dest.parent().unwrap()).await?;
    tokio::fs::write(&dest, &body).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn rp_artwork_get(State(st): State<AppState>, AxPath(file): AxPath<String>) -> ApiResult<Response> {
    let key = file.strip_suffix(".jpg").ok_or_else(|| AppError::not_found("Not Found"))?;
    let p = rp_path(&st, key).filter(|p| p.exists()).ok_or_else(|| AppError::not_found("Not found"))?;
    let data = tokio::fs::read(&p).await?;
    Ok(([(header::CONTENT_TYPE, "image/jpeg"), (header::CACHE_CONTROL, "public, max-age=3600")], data).into_response())
}

// ---- gallery ---------------------------------------------------------------------------------

const GALLERY_JSON: &str = "json_build_object('id', id, 'filename', filename, 'display_order', display_order, \
    'uploaded_at', lumi_iso(uploaded_at), 'url', '/user/gallery/images/' || id)";

async fn list_gallery(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    Ok(Json(
        sqlx::query_scalar(&format!(
            "SELECT COALESCE(json_agg({GALLERY_JSON} ORDER BY display_order ASC, uploaded_at DESC), '[]'::json) FROM ios_user_gallery_images WHERE user_id = $1"
        ))
        .bind(&u.id)
        .fetch_one(&st.db)
        .await?,
    ))
}

async fn upload_gallery(State(st): State<AppState>, u: User, Q(q): Q<IdQ>, mut mp: Multipart) -> ApiResult<Response> {
    let gdir = st.user_gallery_dir(&u.id).ok_or_else(|| AppError::new(503, "User storage not configured on server"))?;
    tokio::fs::create_dir_all(&gdir).await?;
    let mut found: Option<(String, Bytes)> = None;
    while let Ok(Some(field)) = mp.next_field().await {
        if field.name() == Some("file") {
            let ct = field.content_type().unwrap_or("").to_string();
            let data = field.bytes().await.map_err(|_| AppError::bad_request("Empty file body"))?;
            found = Some((ct, data));
            break;
        }
    }
    let (ct, body) = found.ok_or_else(|| AppError::with_value(422, json!([{"type": "missing", "loc": ["body", "file"], "msg": "Field required"}])))?;
    if !["image/jpeg", "image/jpg", "image/png", "image/webp"].contains(&ct.as_str()) {
        return Err(AppError::bad_request("Unsupported image type. Use JPEG, PNG, or WebP."));
    }
    if body.is_empty() {
        return Err(AppError::bad_request("Empty file body"));
    }
    if body.len() > 10 * 1024 * 1024 {
        return Err(AppError::new(413, "Image too large (max 10 MB)"));
    }
    let quota = st.user_quota_bytes(&u.id).await;
    if quota != 0 {
        let used = st.storage_usage(&u.id).await?["used_bytes"].as_i64().unwrap_or(0);
        if used + body.len() as i64 > quota {
            return Err(AppError::new(507, format!("Storage quota exceeded ({used} + {} > {quota} bytes)", body.len())));
        }
    }
    let id = uuid::Uuid::new_v4().to_string();
    let name = format!("{id}.jpg");
    if let Err(e) = tokio::fs::write(gdir.join(&name), &body).await {
        tracing::error!("upload_gallery_image: write failed for user {}: {e}", u.id);
        return Err(AppError::internal("Failed to save image"));
    }
    let v: Value = sqlx::query_scalar(&format!(
        "INSERT INTO ios_user_gallery_images (id, user_id, filename, display_order) VALUES ($1, $2, $3, $4) RETURNING {GALLERY_JSON}"
    ))
    .bind(&id)
    .bind(&u.id)
    .bind(&name)
    .bind(q.display_order.unwrap_or(0))
    .fetch_one(&st.db)
    .await?;
    let (st2, uid) = (st.clone(), u.id.clone());
    tokio::spawn(async move { st2.maybe_warn_storage_quota(&uid).await });
    Ok((StatusCode::CREATED, Json(v)).into_response())
}

async fn get_gallery(State(st): State<AppState>, u: User, headers: HeaderMap, AxPath(id): AxPath<String>) -> ApiResult<Response> {
    let name: String = sqlx::query_scalar("SELECT filename FROM ios_user_gallery_images WHERE id = $1 AND user_id = $2")
        .bind(&id)
        .bind(&u.id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("Image not found"))?;
    let gdir = st.user_gallery_dir(&u.id).ok_or_else(|| AppError::new(503, "User storage not configured"))?;
    let p = safe_join(&gdir, &name).ok_or_else(|| AppError::forbidden("Access denied"))?;
    if !p.is_file() {
        return Err(AppError::not_found("Image file not found on disk"));
    }
    Ok(files::serve(&p, "image/jpeg", Some(&name), &headers, None).await)
}

async fn delete_gallery(State(st): State<AppState>, u: User, AxPath(id): AxPath<String>) -> ApiResult<StatusCode> {
    let name: String = sqlx::query_scalar("DELETE FROM ios_user_gallery_images WHERE id = $1 AND user_id = $2 RETURNING filename")
        .bind(&id)
        .bind(&u.id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("Image not found"))?;
    if let Some(p) = st.user_gallery_dir(&u.id).and_then(|g| safe_join(&g, &name)) {
        if p.exists() {
            if let Err(e) = tokio::fs::remove_file(&p).await {
                tracing::warn!("delete_gallery_image: could not remove file {}: {e}", p.display());
            }
        }
    }
    Ok(StatusCode::NO_CONTENT)
}

// ---- acoustic duplicates ---------------------------------------------------------------------

async fn acoustic_duplicates(State(st): State<AppState>, u: User, Q(q): Q<IdQ>) -> ApiResult<Json<Value>> {
    if !q.force_rescan.unwrap_or(false) {
        let row: Option<(String, Option<String>)> =
            sqlx::query_as("SELECT groups_json, lumi_iso(scanned_at) FROM ios_duplicate_scan_cache WHERE user_id = $1").bind(&u.id).fetch_optional(&st.db).await?;
        if let Some((g, at)) = row {
            let d: Value = serde_json::from_str(&g).unwrap_or(json!({}));
            return Ok(Json(json!({"scanned": d.get("scanned").cloned().unwrap_or(json!(0)),
                "duplicate_groups": d.get("duplicate_groups").cloned().unwrap_or(json!([])), "cached": true, "scanned_at": at})));
        }
    }
    let r = crate::background::scan_acoustic_duplicates(&st, &u.id).await.ok_or_else(|| AppError::new(503, "User music storage not configured"))?;
    crate::background::save_duplicate_scan(&st, &u.id, &r).await;
    let mut out = r;
    out["cached"] = json!(false);
    out["scanned_at"] = Value::Null;
    Ok(Json(out))
}
