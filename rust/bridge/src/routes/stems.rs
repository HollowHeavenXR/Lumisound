//! Stem separation (Demucs htdemucs two-stem, driven as a child process the
//! same way yt-dlp/ffmpeg are) and AcoustID fingerprint identification.

use crate::auth::User;
use crate::error::{ApiResult, AppError};
use crate::extract::{Q, invalid};
use crate::state::AppState;
use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const JOB_MAX_AGE: Duration = Duration::from_secs(900);
const SEPARATION_TIMEOUT: Duration = Duration::from_secs(600);

pub struct StemJob {
    created: Instant,
    work_dir: PathBuf,
    title: String,
    status: &'static str,
    error: Option<String>,
    vocals: Option<PathBuf>,
    instrumental: Option<PathBuf>,
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/stem-separation", post(start).layer(DefaultBodyLimit::max(128 * 1024 * 1024)))
        .route("/api/stem-separation/status", get(status))
        .route("/api/stem-separation/result", get(result))
        .route("/api/fingerprint/identify", post(identify).layer(DefaultBodyLimit::max(128 * 1024 * 1024)))
}

fn sweep(st: &AppState) {
    let now = Instant::now();
    st.stem_jobs.retain(|_, j| {
        let keep = now.duration_since(j.created) <= JOB_MAX_AGE;
        if !keep {
            let _ = std::fs::remove_dir_all(&j.work_dir);
        }
        keep
    });
}

#[derive(Deserialize)]
struct StartQ {
    video_id: Option<String>,
    title: Option<String>,
    job_id: Option<String>,
    stem: Option<String>,
    ext: Option<String>,
}

async fn start(State(st): State<AppState>, _u: User, Q(q): Q<StartQ>, body: Bytes) -> ApiResult<Response> {
    if let Some(v) = &q.video_id {
        let n = v.chars().count();
        if n < 5 {
            return Err(invalid("video_id", "String should have at least 5 characters"));
        }
        if n > 32 {
            return Err(invalid("video_id", "String should have at most 32 characters"));
        }
    }
    sweep(&st);
    let work = std::env::temp_dir().join(format!("lumisound-stems-{}", uuid::Uuid::new_v4().simple()));
    tokio::fs::create_dir_all(&work).await.map_err(|e| anyhow::anyhow!(e))?;
    let fail = |w: &Path, code: u16, msg: &str| {
        let _ = std::fs::remove_dir_all(w);
        AppError::new(code, msg)
    };
    let input = if let Some(vid) = q.video_id.as_deref().filter(|v| !v.is_empty()) {
        if !vid.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '-') {
            return Err(fail(&work, 400, "Invalid video id"));
        }
        let input = work.join("input.m4a");
        let mut args: Vec<String> = st.ytdlp.network().to_vec();
        args.extend(["--cache-dir".into(), st.cfg.ytdlp_cache_dir.clone(), "-f".into(), "bestaudio[ext=m4a]/bestaudio".into(), "--no-playlist".into(), "-o".into(),
            input.to_string_lossy().into_owned(), format!("https://www.youtube.com/watch?v={vid}")]);
        match st.ytdlp.run("yt-dlp", &args, Duration::from_secs(120)).await {
            Err(crate::ytdlp::RunError::Timeout) => return Err(fail(&work, 504, "Fetching source audio timed out")),
            Ok(o) if o.status == Some(0) && input.exists() => {}
            _ => return Err(fail(&work, 502, "Could not fetch source audio for separation")),
        }
        input
    } else {
        if body.is_empty() || body.len() > 60 * 1024 * 1024 {
            return Err(fail(&work, 400, "Invalid or oversized audio (max 60 MB)"));
        }
        let input = work.join("input.audio");
        tokio::fs::write(&input, &body).await.map_err(|e| anyhow::anyhow!(e))?;
        input
    };
    let title = q.title.unwrap_or_else(|| "track".into()).replace(['/', ':'], "-");
    let title = crate::routes::music::truncate_bytes(&title, 240);
    let id = uuid::Uuid::new_v4().simple().to_string();
    st.stem_jobs.insert(id.clone(), StemJob { created: Instant::now(), work_dir: work.clone(), title, status: "pending", error: None, vocals: None, instrumental: None });
    let (st2, jid) = (st.clone(), id.clone());
    tokio::spawn(async move {
        if let Some(mut j) = st2.stem_jobs.get_mut(&jid) {
            j.status = "running";
        }
        let r = separate(&st2, &input, &work).await;
        if let Some(mut j) = st2.stem_jobs.get_mut(&jid) {
            match r {
                Ok((v, i)) => {
                    j.status = "done";
                    j.vocals = Some(v);
                    j.instrumental = Some(i);
                }
                Err(e) => {
                    tracing::warn!("stem_separation job {jid} failed: {e}");
                    j.status = "error";
                    j.error = Some(e);
                }
            }
        }
    });
    Ok((StatusCode::ACCEPTED, Json(json!({"job_id": id}))).into_response())
}

/// `demucs --two-stems vocals -n htdemucs`, one job at a time, then AAC.
async fn separate(st: &AppState, input: &Path, work: &Path) -> Result<(PathBuf, PathBuf), String> {
    let _permit = st.stem_sem.acquire().await.map_err(|e| e.to_string())?;
    let started = Instant::now();
    tracing::info!("stem_separation: starting demucs for {}", input.file_name().unwrap_or_default().to_string_lossy());
    let args: Vec<String> = ["-m", "demucs", "--two-stems", "vocals", "-n", "htdemucs", "-o"].map(String::from).into_iter()
        .chain([work.to_string_lossy().into_owned(), input.to_string_lossy().into_owned()]).collect();
    let out = match st.ytdlp.run("python", &args, SEPARATION_TIMEOUT).await {
        Ok(o) => o,
        Err(crate::ytdlp::RunError::Timeout) => return Err(format!("demucs timed out after {}s", SEPARATION_TIMEOUT.as_secs())),
        Err(e) => return Err(format!("{e}")),
    };
    if out.status != Some(0) {
        let err = String::from_utf8_lossy(&out.stderr);
        let tail: String = err.chars().rev().take(2000).collect::<Vec<_>>().into_iter().rev().collect();
        tracing::warn!("stem_separation: demucs failed (rc={:?}) in {:.1}s: {tail}", out.status, started.elapsed().as_secs_f64());
        return Err("demucs processing failed".into());
    }
    let stem = input.file_stem().unwrap_or_default().to_string_lossy().into_owned();
    let dir = work.join("htdemucs").join(&stem);
    let (vw, iw) = (dir.join("vocals.wav"), dir.join("no_vocals.wav"));
    if !vw.exists() || !iw.exists() {
        return Err("demucs did not produce the expected output files".into());
    }
    tracing::info!("stem_separation: demucs finished in {:.1}s", started.elapsed().as_secs_f64());
    let (va, ia) = (work.join("vocals.m4a"), work.join("instrumental.m4a"));
    for (src, dst) in [(&vw, &va), (&iw, &ia)] {
        let a: Vec<String> = vec!["-y".into(), "-i".into(), src.to_string_lossy().into_owned(), "-c:a".into(), "aac".into(), "-b:a".into(), "160k".into(), dst.to_string_lossy().into_owned()];
        let ok = matches!(st.ytdlp.run("ffmpeg", &a, Duration::from_secs(120)).await, Ok(o) if o.status == Some(0)) && dst.exists();
        if !ok {
            return Err(format!("AAC encode failed for {}", src.file_name().unwrap_or_default().to_string_lossy()));
        }
    }
    let _ = tokio::fs::remove_dir_all(work.join("htdemucs")).await;
    Ok((va, ia))
}

async fn status(State(st): State<AppState>, _u: User, Q(q): Q<StartQ>) -> ApiResult<Json<Value>> {
    let id = q.job_id.ok_or_else(|| invalid("job_id", "Field required"))?;
    let j = st.stem_jobs.get(&id).ok_or_else(|| AppError::not_found("Unknown or expired job"))?;
    Ok(Json(json!({"status": j.status, "error": j.error})))
}

async fn result(State(st): State<AppState>, _u: User, h: HeaderMap, Q(q): Q<StartQ>) -> ApiResult<Response> {
    let id = q.job_id.ok_or_else(|| invalid("job_id", "Field required"))?;
    let stem = q.stem.ok_or_else(|| invalid("stem", "Field required"))?;
    if stem != "vocals" && stem != "instrumental" {
        return Err(invalid("stem", "String should match pattern '^(vocals|instrumental)$'"));
    }
    let (path, title) = {
        let j = st.stem_jobs.get(&id).ok_or_else(|| AppError::not_found("Unknown or expired job"))?;
        if j.status != "done" {
            return Err(AppError::new(409, format!("Job is not finished (status={})", j.status)));
        }
        (if stem == "vocals" { j.vocals.clone() } else { j.instrumental.clone() }, j.title.clone())
    };
    let path = path.filter(|p| p.exists()).ok_or_else(|| AppError::not_found("Result file missing"))?;
    Ok(crate::files::serve(&path, "audio/mp4", Some(&format!("{title}-{stem}.m4a")), &h, None).await)
}

// ---- fingerprint -----------------------------------------------------------------------------

async fn identify(State(st): State<AppState>, u: User, Q(q): Q<StartQ>, body: Bytes) -> ApiResult<Json<Value>> {
    let key: Option<String> = sqlx::query_scalar("SELECT acoustid_api_key FROM ios_user_settings WHERE user_id = $1").bind(&u.id).fetch_optional(&st.db).await?.flatten();
    let key = key.filter(|k| !k.is_empty()).ok_or_else(|| AppError::bad_request("No AcoustID API key configured. Add one in Settings."))?;
    if body.is_empty() {
        return Err(AppError::bad_request("Empty file body"));
    }
    if body.len() > 30 * 1024 * 1024 {
        return Err(AppError::new(413, "File too large (max 30 MB)"));
    }
    let ext = q.ext.unwrap_or_else(|| "m4a".into()).to_lowercase();
    let ext = ext.trim_start_matches('.');
    let ext = if crate::storage::AUDIO_EXTS.contains(&ext) { ext } else { "m4a" };
    let tmp = std::env::temp_dir().join(format!("fp-{}.{ext}", uuid::Uuid::new_v4().simple()));
    tokio::fs::write(&tmp, &body).await.map_err(|e| anyhow::anyhow!(e))?;
    let (dur, fp) = chromaprint(&tmp).await;
    let _ = tokio::fs::remove_file(&tmp).await;
    let Some(fp) = fp.filter(|_| dur > 0.0) else {
        crate::db::log_event(&st.db, "metadata", "fingerprint_identify_failed", Some(&u.id), "warn", "could not analyze file (unsupported format or corrupt audio)", None).await;
        return Err(AppError::new(422, "Could not analyze this file (unsupported format or corrupt audio)"));
    };
    let duration = crate::analysis::pyround(dur, 0) as i64;
    let r = st.http.get("https://api.acoustid.org/v2/lookup")
        .query(&[("client", key.as_str()), ("duration", &duration.to_string()), ("fingerprint", fp.as_str()), ("meta", "recordings+releasegroups+compress")])
        .timeout(Duration::from_secs(15)).send().await;
    let (code, data) = match r {
        Ok(r) => (r.status().as_u16(), r.json::<Value>().await.unwrap_or_else(|_| json!({}))),
        Err(e) => (502, json!({"error": {"message": e.to_string()}})),
    };
    if code != 200 {
        let msg = data["error"]["message"].as_str().unwrap_or("AcoustID lookup failed").to_string();
        crate::db::log_event(&st.db, "metadata", "fingerprint_identify_failed", Some(&u.id), "error", &msg, None).await;
        return Err(AppError::new(502, msg));
    }
    let m = best_match(&data);
    crate::db::log_event(&st.db, "metadata", "fingerprint_identify_completed", Some(&u.id), "info", "", Some(json!({"matched": m.is_some()}))).await;
    Ok(Json(match m {
        None => json!({"matched": false}),
        Some(Value::Object(mut o)) => {
            let mut out = serde_json::Map::new();
            out.insert("matched".into(), json!(true));
            out.append(&mut o);
            Value::Object(out)
        }
        Some(v) => v,
    }))
}

async fn chromaprint(p: &Path) -> (f64, Option<String>) {
    let fut = tokio::process::Command::new("fpcalc").args(["-json", "-length", "120"]).arg(p).kill_on_drop(true).output();
    match tokio::time::timeout(Duration::from_secs(30), fut).await {
        Ok(Ok(o)) if o.status.success() => {
            let v: Value = serde_json::from_slice(&o.stdout).unwrap_or_default();
            (v["duration"].as_f64().unwrap_or(0.0), v["fingerprint"].as_str().map(str::to_string))
        }
        Ok(Ok(o)) => {
            tracing::warn!("fpcalc failed for {}: {}", p.display(), String::from_utf8_lossy(&o.stderr).chars().rev().take(300).collect::<String>().chars().rev().collect::<String>());
            (0.0, None)
        }
        _ => {
            tracing::warn!("fpcalc failed for {}", p.display());
            (0.0, None)
        }
    }
}

/// `_best_acoustid_match`: highest score with a titled recording (stable sort).
fn best_match(data: &Value) -> Option<Value> {
    let mut results: Vec<&Value> = data["results"].as_array().map(|a| a.iter().collect()).unwrap_or_default();
    let score = |r: &Value| r["score"].as_f64().unwrap_or(0.0);
    results.sort_by(|a, b| score(b).partial_cmp(&score(a)).unwrap_or(std::cmp::Ordering::Equal));
    for r in results {
        let Some(rec) = r["recordings"].as_array().and_then(|a| a.first()) else { continue };
        let Some(title) = rec["title"].as_str().filter(|t| !t.is_empty()) else { continue };
        let artist = rec["artists"].as_array().and_then(|a| a.first()).map(|a| a["name"].clone()).unwrap_or(Value::Null);
        let album = rec["releasegroups"].as_array().and_then(|a| a.first()).map(|g| g["title"].clone()).unwrap_or(Value::Null);
        return Some(json!({"title": title, "artist": artist, "album": album, "score": r.get("score").cloned().unwrap_or(json!(0))}));
    }
    None
}
