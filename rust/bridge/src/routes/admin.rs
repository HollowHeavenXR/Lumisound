//! Admin dashboard + telemetry (route group 9): /admin, /admin/api/*,
//! client log ingestion, client analytics events, and bug reports.

use crate::auth::{Admin, OPERATOR_USER_ID};
use crate::error::{ApiResult, AppError};
use crate::extract::{J, Q, check_range, invalid};
use crate::gemini::py_dumps;
use crate::state::AppState;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Html;
use axum::routing::{get, post, put};
use axum::{Json, Router};
use chrono::NaiveDateTime;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const DASHBOARD: &str = include_str!("../admin.html");

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/admin", get(|| async { Html(DASHBOARD) }))
        .route("/admin/api/overview", get(overview))
        .route("/admin/api/download-jobs", get(download_jobs).delete(clear_download_jobs))
        .route("/admin/api/errors", get(errors).delete(clear_errors))
        .route("/admin/api/logs", get(logs))
        .route("/admin/api/events", get(events))
        .route("/admin/api/users", get(users))
        .route("/admin/api/users/{id}/quota", put(set_quota))
        .route("/admin/api/storage-integrity", get(storage_integrity))
        .route("/admin/api/users/{id}/deactivate", post(deactivate))
        .route("/admin/api/users/{id}/reactivate", post(reactivate))
        .route("/admin/api/users/{id}/force-logout", post(force_logout))
        .route("/bug-report", post(bug_report))
        .route("/internal/logs", post(ingest_logs))
        .route("/api/log-event", post(log_event))
}

#[derive(Deserialize, Default)]
struct P {
    limit: Option<i64>,
    level: Option<String>,
    category: Option<String>,
    event: Option<String>,
    user_id: Option<String>,
    search: Option<String>,
    before: Option<String>,
    verify_hash: Option<String>,
}

fn limit(p: &P, def: i64, hi: i64) -> ApiResult<i64> {
    let l = p.limit.unwrap_or(def);
    check_range("limit", l, 1, hi)?;
    Ok(l)
}

/// `shutil.disk_usage`.
fn disk_usage(p: &std::path::Path) -> Option<Value> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(p.as_os_str().as_bytes()).ok()?;
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut s) } != 0 {
        return None;
    }
    let f = s.f_frsize as u64;
    let total = s.f_blocks as u64 * f;
    Some(json!({"total_bytes": total, "used_bytes": (s.f_blocks as u64 - s.f_bfree as u64) * f, "free_bytes": s.f_bavail as u64 * f}))
}

async fn overview(State(st): State<AppState>, _a: Admin) -> ApiResult<Json<Value>> {
    let (users, files, bytes, jobs, errs): (i64, i64, i64, Value, i64) = sqlx::query_as(
        "SELECT (SELECT COUNT(*) FROM ios_users), (SELECT COUNT(*) FROM ios_user_music_metadata), \
                (SELECT COALESCE(SUM(file_size_bytes), 0)::bigint FROM ios_user_music_metadata), \
                (SELECT COALESCE(json_object_agg(status, n), '{}'::json) FROM (SELECT status, COUNT(*) AS n FROM ios_download_log \
                   WHERE created_at >= NOW() - INTERVAL '24 hours' GROUP BY status) j), \
                (SELECT COUNT(*) FROM ios_app_logs WHERE level = 'error' AND timestamp >= NOW() - INTERVAL '24 hours')",
    )
    .fetch_one(&st.db)
    .await?;
    let disk = st.user_music_root().filter(|r| r.exists()).and_then(|r| disk_usage(&r));
    let c = &st.cfg;
    Ok(Json(json!({
        "version": "1.0.0", "yt_dlp_version": st.ytdlp_version, "user_count": users, "music_file_count": files, "music_bytes": bytes,
        "disk": disk, "download_jobs_24h": jobs, "recent_error_count_24h": errs,
        "concurrency": {
            "ytdlp_max": c.ytdlp_max, "ytdlp_safe": c.ytdlp_safe,
            // Python's dict repeated this key; the later value (env, default 2) won.
            "transcode_max": std::env::var("YTDLP_MAX_TRANSCODE_CONCURRENT").ok().and_then(|v| v.parse::<i64>().ok()).unwrap_or(2),
            "available_mb": crate::ytdlp::available_memory_mb().unwrap_or(0.0).round() as i64,
            "ytdlp_available": st.ytdlp.limiter.available(), "transcode_available": st.ytdlp.transcode.available(),
        },
    })))
}

async fn download_jobs(State(st): State<AppState>, _a: Admin, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let l = limit(&p, 50, 200)?;
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('id', id, 'source', source, 'source_id', source_id, 'title', title, 'status', status, \
               'error_message', error_message, 'duration_ms', duration_ms, 'created_at', lumi_iso(created_at)) ORDER BY created_at DESC), '[]'::json) \
             FROM (SELECT * FROM ios_download_log ORDER BY created_at DESC LIMIT $1) d",
        )
        .bind(l)
        .fetch_one(&st.db)
        .await?,
    ))
}

async fn errors(State(st): State<AppState>, _a: Admin, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let l = limit(&p, 50, 200)?;
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('category', category, 'message', message, 'file', file, 'line', line, \
               'timestamp', lumi_iso(timestamp), 'app_version', app_version, 'os_version', os_version) ORDER BY timestamp DESC NULLS FIRST), '[]'::json) \
             FROM (SELECT * FROM ios_app_logs WHERE level = 'error' ORDER BY timestamp DESC LIMIT $1) e",
        )
        .bind(l)
        .fetch_one(&st.db)
        .await?,
    ))
}

/// `datetime.fromisoformat` → naive wall-clock time (what a TIMESTAMP column compares against).
fn parse_iso(s: &str) -> Option<NaiveDateTime> {
    let s = s.trim();
    if let Ok(d) = chrono::DateTime::parse_from_rfc3339(&s.replacen(' ', "T", 1)) {
        return Some(d.naive_local());
    }
    for f in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M"] {
        if let Ok(d) = NaiveDateTime::parse_from_str(s, f) {
            return Some(d);
        }
    }
    for f in ["%Y-%m-%dT%H:%M:%S%.f%:z", "%Y-%m-%d %H:%M:%S%.f%:z", "%Y-%m-%dT%H:%M:%S%.fZ"] {
        if let Ok(d) = chrono::DateTime::parse_from_str(s, f) {
            return Some(d.naive_local());
        }
    }
    chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok().and_then(|d| d.and_hms_opt(0, 0, 0))
}

/// Shared filter builder for /admin/api/logs and /events.
fn filters(p: &P, time_col: &str, with_event: bool, with_search: bool) -> ApiResult<(String, Vec<String>, Option<NaiveDateTime>)> {
    let mut conds = Vec::new();
    let mut args = Vec::new();
    let mut add = |col: &str, v: &Option<String>, like: bool| {
        if let Some(v) = v.as_ref().filter(|v| !v.is_empty()) {
            args.push(if like { format!("%{v}%") } else { v.clone() });
            conds.push(format!("{col} {} ${}", if like { "ILIKE" } else { "=" }, args.len()));
        }
    };
    add("level", &p.level, false);
    add("category", &p.category, false);
    if with_event {
        add("event", &p.event, false);
    }
    add("user_id", &p.user_id, false);
    if with_search {
        if let Some(s) = &p.search {
            if s.chars().count() < 2 {
                return Err(invalid("search", "String should have at least 2 characters"));
            }
        }
        add("message", &p.search, true);
    }
    let mut before = None;
    if let Some(b) = p.before.as_ref().filter(|b| !b.is_empty()) {
        before = Some(parse_iso(b).ok_or_else(|| AppError::bad_request("before must be an ISO 8601 timestamp"))?);
        conds.push(format!("{time_col} < ${}", args.len() + 1));
    }
    let w = if conds.is_empty() { String::new() } else { format!("WHERE {}", conds.join(" AND ")) };
    Ok((w, args, before))
}

async fn logs(State(st): State<AppState>, _a: Admin, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let l = limit(&p, 100, 500)?;
    let (w, args, before) = filters(&p, "timestamp", false, true)?;
    let n = args.len() + before.is_some() as usize + 1;
    let sql = format!(
        "SELECT COALESCE(json_agg(json_build_object('level', level, 'category', category, 'message', message, 'file', file, 'line', line, \
           'timestamp', lumi_iso(timestamp), 'extra', extra, 'device_model', device_model, 'os_version', os_version, 'app_version', app_version, \
           'user_id', user_id) ORDER BY timestamp DESC NULLS FIRST), '[]'::json) FROM (SELECT * FROM ios_app_logs {w} ORDER BY timestamp DESC LIMIT ${n}) x"
    );
    let mut q = sqlx::query_scalar::<_, Value>(&sql);
    for a in &args {
        q = q.bind(a);
    }
    if let Some(b) = before {
        q = q.bind(b);
    }
    Ok(Json(q.bind(l).fetch_one(&st.db).await?))
}

async fn events(State(st): State<AppState>, _a: Admin, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let l = limit(&p, 100, 500)?;
    let (w, args, before) = filters(&p, "created_at", true, false)?;
    let n = args.len() + before.is_some() as usize + 1;
    let sql = format!(
        "SELECT COALESCE(json_agg(json_build_object('source', source, 'user_id', user_id, 'category', category, 'event', event, 'level', level, \
           'message', message, 'detail', detail, 'timestamp', lumi_iso(created_at)) ORDER BY created_at DESC NULLS FIRST), '[]'::json) \
         FROM (SELECT * FROM ios_app_event_log {w} ORDER BY created_at DESC LIMIT ${n}) x"
    );
    let mut q = sqlx::query_scalar::<_, Value>(&sql);
    for a in &args {
        q = q.bind(a);
    }
    if let Some(b) = before {
        q = q.bind(b);
    }
    Ok(Json(q.bind(l).fetch_one(&st.db).await?))
}

async fn users(State(st): State<AppState>, _a: Admin, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let l = limit(&p, 200, 1000)?;
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('id', id, 'username', username, 'email', email, 'created_at', lumi_iso(created_at), \
               'last_login', lumi_iso(last_login), 'is_active', COALESCE(is_active, FALSE), 'active_sessions', active_sessions, 'is_operator', id = $2, \
               'storage_quota_bytes', NULLIF(storage_quota_bytes, 0), 'storage_used_bytes', storage_used_bytes) ORDER BY created_at DESC NULLS FIRST), '[]'::json) \
             FROM (SELECT u.id, u.username, u.email, u.created_at, u.last_login, u.is_active, \
                     (SELECT COUNT(*) FROM ios_user_sessions s WHERE s.user_id = u.id AND s.expires_at > NOW()) AS active_sessions, \
                     s.storage_quota_bytes, \
                     (SELECT COALESCE(SUM(file_size_bytes), 0)::bigint FROM ios_user_music_metadata m WHERE m.user_id = u.id) AS storage_used_bytes \
                   FROM ios_users u LEFT JOIN ios_user_settings s ON s.user_id = u.id ORDER BY u.created_at DESC LIMIT $1) x",
        )
        .bind(l)
        .bind(OPERATOR_USER_ID)
        .fetch_one(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
struct QuotaBody {
    quota_bytes: Option<i64>,
}

async fn set_quota(State(st): State<AppState>, _a: Admin, Path(id): Path<String>, J(b): J<QuotaBody>) -> ApiResult<Json<Value>> {
    if b.quota_bytes.is_some_and(|q| q < 0) {
        return Err(AppError::bad_request("quota_bytes must be >= 0"));
    }
    let exists: Option<i32> = sqlx::query_scalar("SELECT 1 FROM ios_users WHERE id = $1").bind(&id).fetch_optional(&st.db).await?;
    if exists.is_none() {
        return Err(AppError::not_found("User not found"));
    }
    sqlx::query("INSERT INTO ios_user_settings (user_id, storage_quota_bytes) VALUES ($1, $2) ON CONFLICT (user_id) DO UPDATE SET storage_quota_bytes = EXCLUDED.storage_quota_bytes")
        .bind(&id)
        .bind(b.quota_bytes)
        .execute(&st.db)
        .await?;
    crate::db::log_event(&st.db, "admin", "set_user_quota", Some(&id), "info", "storage quota set by operator", Some(json!({"quota_bytes": b.quota_bytes}))).await;
    Ok(Json(json!({"status": "ok", "quota_bytes": b.quota_bytes})))
}

fn py_bool(field: &str, v: &Option<String>) -> ApiResult<bool> {
    match v.as_deref().map(str::to_ascii_lowercase).as_deref() {
        None => Ok(false),
        Some("true" | "1" | "yes" | "on" | "t" | "y") => Ok(true),
        Some("false" | "0" | "no" | "off" | "f" | "n") => Ok(false),
        _ => Err(invalid(field, "Input should be a valid boolean, unable to interpret input")),
    }
}

async fn storage_integrity(State(st): State<AppState>, _a: Admin, Q(p): Q<P>) -> ApiResult<Json<Value>> {
    let verify = py_bool("verify_hash", &p.verify_hash)?;
    let l = limit(&p, 500, 5000)?;
    if st.user_music_root().is_none() {
        return Err(AppError::new(503, "USER_MUSIC_DIR/SERVER_MUSIC_DIR not configured"));
    }
    let rows: Vec<(String, String, String, Option<String>)> =
        sqlx::query_as("SELECT id, user_id, filename, relative_path FROM ios_user_music_metadata ORDER BY uploaded_at DESC LIMIT $1").bind(l).fetch_all(&st.db).await?;
    let total = rows.len();
    let (mut missing, mut corrupted, mut checked) = (Vec::new(), Vec::new(), 0);
    for (id, user, filename, rel) in rows {
        let Some(dir) = st.user_music_dir(&user) else { continue };
        let path = dir.join(rel.filter(|r| !r.is_empty()).unwrap_or_else(|| filename.clone()));
        if !path.exists() {
            missing.push(json!({"id": id, "user_id": user, "filename": filename}));
            continue;
        }
        checked += 1;
        if verify {
            let r = crate::storage::materialize_gzip(&path).await;
            let rp = r.path().to_path_buf();
            let actual = tokio::task::spawn_blocking(move || -> std::io::Result<String> {
                let mut f = std::fs::File::open(rp)?;
                let mut h = Sha256::new();
                std::io::copy(&mut f, &mut h)?;
                Ok(hex::encode(h.finalize()))
            })
            .await
            .map_err(|e| anyhow::anyhow!(e))?
            .map_err(|e| anyhow::anyhow!(e))?;
            drop(r);
            if actual != id {
                corrupted.push(json!({"id": id, "user_id": user, "filename": filename, "expected_hash": id, "actual_hash": actual}));
            }
        }
    }
    Ok(Json(json!({"checked": checked, "total_rows": total, "hash_verified": verify, "missing": missing, "corrupted": corrupted})))
}

async fn deactivate(State(st): State<AppState>, _a: Admin, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    if id == OPERATOR_USER_ID {
        return Err(AppError::bad_request("Cannot deactivate the operator account"));
    }
    sqlx::query("UPDATE ios_users SET is_active = FALSE WHERE id = $1").bind(&id).execute(&st.db).await?;
    sqlx::query("DELETE FROM ios_user_sessions WHERE user_id = $1").bind(&id).execute(&st.db).await?;
    st.session_cache.clear();
    crate::db::log_event(&st.db, "admin", "deactivate_user", Some(&id), "info", "deactivated by operator", None).await;
    Ok(Json(json!({"status": "deactivated"})))
}

async fn reactivate(State(st): State<AppState>, _a: Admin, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    sqlx::query("UPDATE ios_users SET is_active = TRUE WHERE id = $1").bind(&id).execute(&st.db).await?;
    crate::db::log_event(&st.db, "admin", "reactivate_user", Some(&id), "info", "reactivated by operator", None).await;
    Ok(Json(json!({"status": "reactivated"})))
}

async fn force_logout(State(st): State<AppState>, _a: Admin, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    sqlx::query("DELETE FROM ios_user_sessions WHERE user_id = $1").bind(&id).execute(&st.db).await?;
    st.session_cache.clear();
    crate::db::log_event(&st.db, "admin", "force_logout_user", Some(&id), "info", "all sessions revoked by operator", None).await;
    Ok(Json(json!({"status": "logged_out"})))
}

async fn clear_errors(State(st): State<AppState>, _a: Admin) -> ApiResult<Json<Value>> {
    sqlx::query("DELETE FROM ios_app_logs WHERE level = 'error'").execute(&st.db).await?;
    Ok(Json(json!({"status": "cleared"})))
}

async fn clear_download_jobs(State(st): State<AppState>, _a: Admin) -> ApiResult<Json<Value>> {
    sqlx::query("DELETE FROM ios_download_log").execute(&st.db).await?;
    Ok(Json(json!({"status": "cleared"})))
}

// ---- telemetry -------------------------------------------------------------------------------

/// `decode_token(...)["sub"]` from an optional bearer header (signature + expiry only).
fn token_sub(st: &AppState, h: &HeaderMap) -> Option<String> {
    let v = h.get("authorization")?.to_str().ok()?;
    let (scheme, tok) = v.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return None;
    }
    st.keys.decode(tok.trim())?.sub
}

#[derive(Deserialize)]
struct BugReport {
    #[serde(default = "other")]
    category: String,
    description: String,
    contact_email: Option<String>,
    app_version: Option<String>,
    device_info: Option<String>,
    recent_logs: Option<String>,
}

fn other() -> String {
    "other".into()
}

async fn bug_report(State(st): State<AppState>, h: HeaderMap, J(b): J<BugReport>) -> ApiResult<(StatusCode, Json<Value>)> {
    if b.description.trim().is_empty() {
        return Err(AppError::bad_request("Description is required"));
    }
    let user = token_sub(&st, &h);
    let id = uuid::Uuid::new_v4().to_string();
    let t = crate::db::truncate;
    let category = t(&b.category, 30);
    sqlx::query("INSERT INTO ios_bug_reports (id, user_id, category, description, contact_email, app_version, device_info, recent_logs) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)")
        .bind(&id)
        .bind(&user)
        .bind(&category)
        .bind(t(&b.description, 5000))
        .bind(&b.contact_email)
        .bind(&b.app_version)
        .bind(&b.device_info)
        .bind(b.recent_logs.as_deref().map(|l| t(l, 50_000)))
        .execute(&st.db)
        .await?;
    // The webhook comes from BUG_REPORT_WEBHOOK_URL only (never baked into code).
    if let Some(hook) = st.cfg.bug_report_webhook_url.clone().filter(|h| !h.is_empty()) {
        let nz = |v: &Option<String>| v.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| "unknown".into());
        let mut fields = vec![
            json!({"name": "Device", "value": nz(&b.device_info), "inline": true}),
            json!({"name": "App Version", "value": nz(&b.app_version), "inline": true}),
            json!({"name": "User", "value": user.clone().unwrap_or_else(|| "anonymous".into()), "inline": true}),
        ];
        if let Some(c) = b.contact_email.as_ref().filter(|c| !c.is_empty()) {
            fields.push(json!({"name": "Contact", "value": c, "inline": true}));
        }
        let embed = json!({"embeds": [{"title": format!("New Bug Report — {}", b.category), "description": t(&b.description, 4000), "color": 0xEC4079,
            "fields": fields, "footer": {"text": format!("Report ID: {id}")}}]});
        crate::routes::integrations::post_discord(&st, &hook, &embed).await;
    }
    let (st2, u, d) = (st.clone(), user.clone(), json!({"report_id": id, "category": category}));
    tokio::spawn(async move { crate::db::log_event(&st2.db, "support", "bug_report_submitted", u.as_deref(), "info", "", Some(d)).await });
    Ok((StatusCode::CREATED, Json(json!({"id": id, "status": "received"}))))
}

fn norm_level(v: Option<&Value>) -> String {
    let raw = match v {
        None | Some(Value::Null) => "info".to_string(),
        Some(x) => py_str(x),
    };
    let raw = raw.trim().to_lowercase();
    match raw.as_str() {
        "warn" | "warning" => "warning".into(),
        "err" | "error" | "fatal" | "critical" | "fault" | "severe" => "error".into(),
        "info" | "notice" => "info".into(),
        "debug" | "trace" | "verbose" => "debug".into(),
        _ => {
            let t = crate::db::truncate(&raw, 10);
            if t.is_empty() { "info".into() } else { t }
        }
    }
}

/// Python `str(value)` for JSON values.
fn py_str(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => "None".into(),
        Value::Bool(b) => if *b { "True".into() } else { "False".into() },
        Value::Number(n) => match n.as_f64().filter(|_| n.is_f64()) {
            Some(f) => crate::probe::py_float(f),
            None => n.to_string(),
        },
        other => py_dumps(other, false).replace("\": ", "': ").replace("{\"", "{'").replace(", \"", ", '").replace("\"", "'"),
    }
}

/// Python `int(x)`; None means the whole batch is dropped (the Python
/// handler swallows the ValueError).
fn py_int(v: Option<&Value>) -> Option<i64> {
    match v {
        None => Some(0),
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f.trunc() as i64)),
        Some(Value::Bool(b)) => Some(*b as i64),
        Some(Value::String(s)) => s.trim().replace('_', "").parse().ok(),
        _ => None,
    }
}

fn truthy(v: Option<&Value>) -> Option<&Value> {
    v.filter(|v| match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::String(s) => !s.is_empty(),
        Value::Number(n) => n.as_f64() != Some(0.0),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    })
}

async fn ingest_logs(State(st): State<AppState>, raw: Bytes) -> ApiResult<StatusCode> {
    if raw.len() > 1_048_576 {
        return Err(AppError::new(413, "Log payload too large"));
    }
    let Ok(Value::Array(entries)) = serde_json::from_slice::<Value>(&raw) else { return Ok(StatusCode::NO_CONTENT) };
    type Row = (String, String, String, String, i64, Option<NaiveDateTime>, String, Option<String>, Option<String>, Option<String>, Option<String>);
    let mut rows: Vec<Row> = Vec::new();
    let t = crate::db::truncate;
    for e in entries.iter().take(100) {
        let Some(o) = e.as_object() else { continue };
        let Some(line) = py_int(o.get("line")) else { return Ok(StatusCode::NO_CONTENT) };
        let opt = |k: &str, n: usize| truthy(o.get(k)).map(|v| t(&py_str(v), n));
        rows.push((
            norm_level(o.get("level")),
            t(&o.get("category").map(py_str).unwrap_or_else(|| "general".into()), 30),
            t(&o.get("message").map(py_str).unwrap_or_default(), 500),
            t(&o.get("file").map(py_str).unwrap_or_default(), 100),
            line,
            o.get("timestamp").and_then(Value::as_str).and_then(|s| parse_iso(&s.replace('Z', "+00:00"))),
            py_dumps(o.get("extra").unwrap_or(&json!({})), false),
            opt("deviceModel", 50),
            opt("osVersion", 20),
            opt("appVersion", 20),
            opt("userId", 36),
        ));
    }
    if rows.is_empty() {
        return Ok(StatusCode::NO_CONTENT);
    }
    let mut qb = sqlx::QueryBuilder::new("INSERT INTO ios_app_logs (level, category, message, file, line, timestamp, extra, device_model, os_version, app_version, user_id) ");
    qb.push_values(rows, |mut b, r| {
        b.push_bind(r.0).push_bind(r.1).push_bind(r.2).push_bind(r.3).push_bind(r.4 as i32).push_bind(r.5);
        b.push_bind(r.6).push_unseparated("::json").push_bind(r.7).push_bind(r.8).push_bind(r.9).push_bind(r.10);
    });
    if let Err(e) = qb.build().execute(&st.db).await {
        tracing::debug!("ingest_logs insert failed: {e}");
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct LogEventBody {
    category: String,
    event: String,
    #[serde(default = "info")]
    level: String,
    #[serde(default)]
    message: String,
    detail: Option<serde_json::Map<String, Value>>,
}

fn info() -> String {
    "info".into()
}

async fn log_event(State(st): State<AppState>, h: HeaderMap, J(b): J<LogEventBody>) -> ApiResult<StatusCode> {
    let user = token_sub(&st, &h);
    crate::db::log_event_from(&st.db, "ios_client", &b.category, &b.event, user.as_deref(), &b.level, &b.message, b.detail.map(Value::Object)).await;
    Ok(StatusCode::NO_CONTENT)
}
