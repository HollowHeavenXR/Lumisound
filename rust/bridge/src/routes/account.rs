//! Accounts and sign-in (route group 2): register, login, 2FA, sessions,
//! password, deletion, profile, privacy, Discord OAuth sign-in/verification.

use crate::auth::{User, client_ip, hash_password, verify_password};
use crate::email;
use crate::error::{ApiResult, AppError};
use crate::extract::J;
use crate::state::AppState;
use crate::totp;
use axum::extract::{ConnectInfo, Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Redirect, Response};
use axum::routing::{delete, get, post, put};
use axum::{Json, Router};
use chrono::{Duration as CDuration, NaiveDateTime, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use std::net::SocketAddr;
use std::time::{Duration, Instant};

/// Username changes allowed in any rolling 30 days.
const MAX_USERNAME_CHANGES_PER_30_DAYS: usize = 3;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/auth/register", post(register))
        .route("/auth/login", post(login))
        .route("/auth/2fa/status", get(totp_status))
        .route("/auth/2fa/setup", post(totp_setup))
        .route("/auth/2fa/verify", post(totp_verify))
        .route("/auth/2fa/disable", post(totp_disable))
        .route("/auth/2fa/login", post(totp_login))
        .route("/auth/logout", post(logout))
        .route("/auth/sessions", get(list_sessions))
        .route("/auth/sessions/{token_id}", delete(revoke_session))
        .route("/auth/change-password", post(change_password))
        .route("/auth/delete-account", post(delete_account))
        .route("/auth/me", get(me).put(update_me))
        .route("/user/privacy", put(update_privacy))
        .route("/api/discord/oauth/start", get(discord_verify_start))
        .route("/auth/discord/start", get(discord_login_start))
        .route("/api/discord/oauth/callback", get(discord_callback))
        .route("/api/discord/verification", get(discord_verification).delete(discord_unverify))
        .route("/api/app/latest-release", get(latest_release))
        .route("/api/app/release-asset/{id}/{name}", get(release_asset))
}

const AUTH_RATE_LIMIT: usize = 10;
const AUTH_WINDOW: Duration = Duration::from_secs(60);
const LOCKOUT: &[(i32, i64)] = &[(5, 60), (8, 15 * 60), (12, 60 * 60)];
const WEAK: &[&str] = &[
    "password", "password1", "password123", "12345678", "123456789", "1234567890", "qwerty", "qwerty123", "abc12345",
    "11111111", "00000000", "iloveyou", "letmein", "welcome", "admin123", "sunshine", "princess", "football", "baseball",
    "trustno1", "dragon123", "monkey123", "passw0rd", "p@ssword", "lumisound", "lumisound1", "lumisound123", "music123",
    "spotify",
];
const DISCORD_SCOPE: &str = "identify email";
const DISCORD_VERIFY_LINK: &str = "lumisound://discord-verify";
const DISCORD_LOGIN_LINK: &str = "lumisound://discord-login";

/// The user object every auth endpoint returns (`_user_dict`).
pub const USER_JSON_SQL: &str = "SELECT json_build_object('id', id, 'username', username, 'email', email, \
     'display_name', display_name, 'avatar_url', avatar_url, 'created_at', lumi_iso(created_at), \
     'last_login', lumi_iso(last_login), 'date_of_birth', to_char(date_of_birth, 'YYYY-MM-DD'), \
     'share_listening_activity', COALESCE(share_listening_activity, false), \
     'ai_assisted_suggestions', COALESCE(ai_assisted_suggestions, false)) FROM ios_users WHERE id = $1";

async fn user_json(st: &AppState, user_id: &str, active_only: bool) -> ApiResult<Option<Value>> {
    let sql = if active_only { format!("{USER_JSON_SQL} AND is_active = TRUE") } else { USER_JSON_SQL.to_string() };
    Ok(sqlx::query_scalar(&sql).bind(user_id).fetch_optional(&st.db).await?)
}

fn check_auth_rate(st: &AppState, ip: &str) -> ApiResult<()> {
    let now = Instant::now();
    let mut e = st.auth_attempts.entry(ip.to_string()).or_default();
    e.retain(|t| now.duration_since(*t) < AUTH_WINDOW);
    if e.len() >= AUTH_RATE_LIMIT {
        return Err(AppError::new(429, format!("Too many authentication attempts. Try again in {} seconds.", AUTH_WINDOW.as_secs())));
    }
    e.push(now);
    Ok(())
}

pub fn validate_password(password: &str, username: &str) -> ApiResult<()> {
    if password.chars().count() < 8 {
        return Err(AppError::bad_request("Password must be at least 8 characters"));
    }
    let lowered = password.to_lowercase();
    if WEAK.contains(&lowered.as_str()) {
        return Err(AppError::bad_request("That password is among the most commonly used ones. Please choose another."));
    }
    if !username.is_empty() && lowered == username.trim().to_lowercase() {
        return Err(AppError::bad_request("Password must not be the same as your username"));
    }
    if password.chars().collect::<std::collections::HashSet<_>>().len() < 4 {
        return Err(AppError::bad_request("Password must use at least 4 different characters"));
    }
    Ok(())
}

async fn log(st: &AppState, cat: &str, ev: &str, user: Option<&str>, level: &str, msg: &str) {
    crate::db::log_event(&st.db, cat, ev, user, level, msg, None).await
}

/// New session row + signed token.
async fn new_session(st: &AppState, user_id: &str, device: &str) -> ApiResult<String> {
    let token_id = uuid::Uuid::new_v4().to_string();
    let expires = Utc::now().naive_utc() + CDuration::days(30);
    sqlx::query("INSERT INTO ios_user_sessions (token_id, user_id, expires_at, device_name) VALUES ($1, $2, $3, $4)")
        .bind(&token_id)
        .bind(user_id)
        .bind(expires)
        .bind(device)
        .execute(&st.db)
        .await?;
    Ok(st.keys.create_token(user_id, &token_id, 30))
}

fn py_repr(s: &str) -> String {
    // Python repr() of a str, good enough for log messages.
    if s.contains('\'') && !s.contains('"') { format!("\"{s}\"") } else { format!("'{}'", s.replace('\\', "\\\\").replace('\'', "\\'")) }
}

// ---- register / login ------------------------------------------------------------------------

#[derive(Deserialize)]
struct RegisterBody {
    username: String,
    password: String,
    email: Option<String>,
    display_name: Option<String>,
}

async fn register(
    State(st): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    J(b): J<RegisterBody>,
) -> ApiResult<Response> {
    check_auth_rate(&st, &client_ip(&headers, Some(peer)))?;
    let username = b.username.trim().to_string();
    if username.chars().count() < 3 {
        return Err(AppError::bad_request("Username must be at least 3 characters"));
    }
    let email = email::normalize(b.email.as_deref(), "Email").await?;
    validate_password(&b.password, &username)?;
    let taken: Option<String> = sqlx::query_scalar("SELECT id FROM ios_users WHERE username = $1").bind(&username).fetch_optional(&st.db).await?;
    if taken.is_some() {
        return Err(AppError::new(409, "Username already taken"));
    }
    let taken: Option<String> =
        sqlx::query_scalar("SELECT id FROM ios_users WHERE lower(email) = lower($1)").bind(&email).fetch_optional(&st.db).await?;
    if taken.is_some() {
        return Err(AppError::new(409, "Email already registered"));
    }
    let user_id = uuid::Uuid::new_v4().to_string();
    let hash = hash_password(b.password.clone()).await?;
    let mut tx = st.db.begin().await?;
    sqlx::query("INSERT INTO ios_users (id, username, email, password_hash, display_name) VALUES ($1, $2, $3, $4, $5)")
        .bind(&user_id)
        .bind(&username)
        .bind(&email)
        .bind(&hash)
        .bind(&b.display_name)
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO ios_user_settings (user_id) VALUES ($1)").bind(&user_id).execute(&mut *tx).await?;
    tx.commit().await?;
    let token = new_session(&st, &user_id, "Unknown device").await?;
    let user = user_json(&st, &user_id, false).await?;
    log(&st, "auth", "register", Some(&user_id), "info", &format!("new account registered: {}", py_repr(&username))).await;
    Ok((StatusCode::CREATED, Json(json!({"user": user, "token": token}))).into_response())
}

#[derive(Deserialize)]
struct LoginBody {
    username: String,
    password: String,
    device_name: Option<String>,
}

async fn check_account_lock(st: &AppState, user_id: &str) -> ApiResult<()> {
    let until: Option<Option<NaiveDateTime>> =
        sqlx::query_scalar("SELECT locked_until FROM ios_login_failures WHERE user_id = $1").bind(user_id).fetch_optional(&st.db).await?;
    if let Some(Some(until)) = until {
        let now = Utc::now().naive_utc();
        if until > now {
            let remaining = (until - now).num_seconds();
            return Err(AppError::new(
                429,
                format!(
                    "Too many failed sign-in attempts for this account. Try again in {} minute(s), or reset your password.",
                    (remaining / 60).max(1)
                ),
            ));
        }
    }
    Ok(())
}

async fn record_login_failure(st: &AppState, user_id: &str) -> ApiResult<()> {
    let now = Utc::now().naive_utc();
    let row: Option<(Option<i32>, Option<NaiveDateTime>)> =
        sqlx::query_as("SELECT failure_count, first_failure_at FROM ios_login_failures WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(&st.db)
            .await?;
    let (count, first) = match row {
        Some((c, Some(f))) if now - f <= CDuration::hours(12) => (c.unwrap_or(0) + 1, f),
        _ => (1, now),
    };
    let mut locked: Option<NaiveDateTime> = None;
    for (th, secs) in LOCKOUT {
        if count >= *th {
            locked = Some(now + CDuration::seconds(*secs));
        }
    }
    sqlx::query(
        "INSERT INTO ios_login_failures (user_id, failure_count, first_failure_at, last_failure_at, locked_until) \
         VALUES ($1, $2, $3, $4, $5) ON CONFLICT (user_id) DO UPDATE SET failure_count = EXCLUDED.failure_count, \
         first_failure_at = EXCLUDED.first_failure_at, last_failure_at = EXCLUDED.last_failure_at, locked_until = EXCLUDED.locked_until",
    )
    .bind(user_id)
    .bind(count)
    .bind(first)
    .bind(now)
    .bind(locked)
    .execute(&st.db)
    .await?;
    if let Some(l) = locked {
        tracing::warn!("account locked after {count} failed sign-ins: user {user_id} until {l}");
    }
    Ok(())
}

/// `_note_device_and_alert_if_new`: security notification for a device name
/// this account has never signed in from (not on the very first sign-in).
async fn note_device(st: &AppState, user_id: &str, device: &str) -> ApiResult<()> {
    use sha2::{Digest, Sha256};
    let hash = hex::encode(Sha256::digest(format!("{user_id}|{}", device.trim().to_lowercase()).as_bytes()));
    let known: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM ios_known_devices WHERE user_id = $1").bind(user_id).fetch_one(&st.db).await?;
    let seen: Option<i32> = sqlx::query_scalar("SELECT 1 FROM ios_known_devices WHERE user_id = $1 AND device_hash = $2")
        .bind(user_id)
        .bind(&hash)
        .fetch_optional(&st.db)
        .await?;
    sqlx::query(
        "INSERT INTO ios_known_devices (user_id, device_hash) VALUES ($1, $2) \
         ON CONFLICT (user_id, device_hash) DO UPDATE SET last_seen_at = NOW()",
    )
    .bind(user_id)
    .bind(&hash)
    .execute(&st.db)
    .await?;
    if seen.is_some() || known == 0 {
        return Ok(());
    }
    let name = { let t = device.trim(); if t.is_empty() { "a new device" } else { t } };
    let name: String = name.chars().take(60).collect();
    if let Err(e) = st
        .create_notification(
            user_id,
            "security",
            "New sign-in",
            &format!("Your account was signed in on {name}. If this wasn't you, change your password."),
            json!({"kind": "new_device_sign_in", "device": name}),
            false,
        )
        .await
    {
        tracing::error!("could not create new-device alert for user {user_id}: {e}");
    }
    log(st, "auth", "new_device_sign_in", Some(user_id), "info", &format!("sign-in from an unrecognised device: {name}")).await;
    Ok(())
}

type LoginRow = (String, String, Option<String>, Option<String>, Option<bool>, Option<bool>);

async fn login(State(st): State<AppState>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, J(b): J<LoginBody>) -> ApiResult<Json<Value>> {
    check_auth_rate(&st, &client_ip(&headers, Some(peer)))?;
    let ident = b.username.trim().to_string();
    const COLS: &str = "SELECT id, username, email, password_hash, is_active, totp_enabled FROM ios_users ";
    let mut row: Option<LoginRow> = sqlx::query_as(&format!("{COLS}WHERE username = $1")).bind(&ident).fetch_optional(&st.db).await?;
    if row.is_none() {
        row = sqlx::query_as(&format!("{COLS}WHERE email IS NOT NULL AND lower(email) = lower($1)")).bind(&ident).fetch_optional(&st.db).await?;
    }
    let Some((user_id, username, _email, hash, active, totp_enabled)) = row else {
        tracing::warn!("Login attempt for unknown username/email: {ident:?}");
        log(&st, "auth", "login_failed", None, "warn", &format!("unknown username/email: {}", py_repr(&ident))).await;
        return Err(AppError::unauthorized("Invalid username or password"));
    };
    if !active.unwrap_or(false) {
        tracing::warn!("Login attempt for disabled account: {username:?} (user_id={user_id})");
        log(&st, "auth", "login_failed", Some(&user_id), "warn", "account is disabled").await;
        return Err(AppError::forbidden("Account is disabled"));
    }
    check_account_lock(&st, &user_id).await?;
    if !verify_password(b.password.clone(), hash.unwrap_or_default()).await {
        record_login_failure(&st, &user_id).await?;
        tracing::warn!("Failed password attempt for username: {username:?} (user_id={user_id})");
        log(&st, "auth", "login_failed", Some(&user_id), "warn", "incorrect password").await;
        return Err(AppError::unauthorized("Invalid username or password"));
    }
    if totp_enabled.unwrap_or(false) {
        log(&st, "auth", "login_2fa_required", Some(&user_id), "info", "password verified, awaiting TOTP code").await;
        return Ok(Json(json!({"requires_2fa": true, "pending_token": st.keys.create_purpose_token(Some(&user_id), "totp_pending", 300)})));
    }
    let device = b.device_name.clone().filter(|d| !d.is_empty()).unwrap_or_else(|| "Unknown device".into());
    let token = new_session(&st, &user_id, &device).await?;
    sqlx::query("UPDATE ios_users SET last_login = NOW() WHERE id = $1").bind(&user_id).execute(&st.db).await?;
    sqlx::query("DELETE FROM ios_login_failures WHERE user_id = $1").bind(&user_id).execute(&st.db).await?;
    note_device(&st, &user_id, &device).await?;
    let user = user_json(&st, &user_id, false).await?;
    log(&st, "auth", "login_success", Some(&user_id), "info", &format!("device={}", py_repr(&device))).await;
    Ok(Json(json!({"user": user, "token": token})))
}

// ---- 2FA -------------------------------------------------------------------------------------

async fn totp_status(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let e: Option<Option<bool>> = sqlx::query_scalar("SELECT totp_enabled FROM ios_users WHERE id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    Ok(Json(json!({"enabled": e.flatten().unwrap_or(false)})))
}

async fn totp_setup(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let username: String = sqlx::query_scalar("SELECT username FROM ios_users WHERE id = $1")
        .bind(&u.id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("User not found"))?;
    let secret = totp::random_secret();
    sqlx::query("UPDATE ios_users SET totp_secret = $1, totp_enabled = FALSE WHERE id = $2").bind(&secret).bind(&u.id).execute(&st.db).await?;
    log(&st, "auth", "totp_setup_started", Some(&u.id), "info", "new TOTP secret generated (not yet enabled)").await;
    Ok(Json(json!({"secret": secret, "otpauth_url": totp::provisioning_uri(&secret, &username, "Lumisound")})))
}

#[derive(Deserialize)]
struct CodeBody {
    code: String,
}

async fn totp_verify(State(st): State<AppState>, u: User, J(b): J<CodeBody>) -> ApiResult<Json<Value>> {
    let secret: Option<String> =
        sqlx::query_scalar("SELECT totp_secret FROM ios_users WHERE id = $1").bind(&u.id).fetch_optional(&st.db).await?.flatten();
    let secret = secret.filter(|s| !s.is_empty()).ok_or_else(|| AppError::bad_request("Call /auth/2fa/setup first"))?;
    if !totp::verify(&secret, &b.code) {
        log(&st, "auth", "totp_verify_failed", Some(&u.id), "warn", "incorrect code").await;
        return Err(AppError::bad_request("Incorrect code"));
    }
    sqlx::query("UPDATE ios_users SET totp_enabled = TRUE WHERE id = $1").bind(&u.id).execute(&st.db).await?;
    log(&st, "auth", "totp_enabled", Some(&u.id), "info", "2FA enabled").await;
    Ok(Json(json!({"status": "enabled"})))
}

#[derive(Deserialize)]
struct PasswordBody {
    password: String,
}

async fn password_ok(st: &AppState, user_id: &str, password: &str) -> ApiResult<Option<bool>> {
    let hash: Option<Option<String>> = sqlx::query_scalar("SELECT password_hash FROM ios_users WHERE id = $1").bind(user_id).fetch_optional(&st.db).await?;
    Ok(match hash {
        None => None,
        Some(h) => Some(verify_password(password.to_string(), h.unwrap_or_default()).await),
    })
}

async fn totp_disable(State(st): State<AppState>, u: User, J(b): J<PasswordBody>) -> ApiResult<Json<Value>> {
    if password_ok(&st, &u.id, &b.password).await? != Some(true) {
        log(&st, "auth", "totp_disable_failed", Some(&u.id), "warn", "incorrect password").await;
        return Err(AppError::unauthorized("Incorrect password"));
    }
    sqlx::query("UPDATE ios_users SET totp_enabled = FALSE, totp_secret = NULL WHERE id = $1").bind(&u.id).execute(&st.db).await?;
    log(&st, "auth", "totp_disabled", Some(&u.id), "info", "2FA disabled").await;
    Ok(Json(json!({"status": "disabled"})))
}

#[derive(Deserialize)]
struct TotpLoginBody {
    pending_token: String,
    code: String,
    device_name: Option<String>,
}

async fn totp_login(State(st): State<AppState>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, J(b): J<TotpLoginBody>) -> ApiResult<Json<Value>> {
    check_auth_rate(&st, &client_ip(&headers, Some(peer)))?;
    let Some(user_id) = st.keys.decode_purpose(&b.pending_token, "totp_pending").and_then(|c| c.sub) else {
        log(&st, "auth", "login_2fa_failed", None, "warn", "pending token expired or invalid").await;
        return Err(AppError::unauthorized("2FA login session expired — please log in again"));
    };
    let row: Option<(Option<String>, Option<bool>, Option<bool>)> =
        sqlx::query_as("SELECT totp_secret, totp_enabled, is_active FROM ios_users WHERE id = $1").bind(&user_id).fetch_optional(&st.db).await?;
    let Some((Some(secret), Some(true), active)) = row.filter(|r| r.0.as_deref().is_some_and(|s| !s.is_empty())) else {
        return Err(AppError::unauthorized("2FA is not enabled for this account"));
    };
    if !active.unwrap_or(false) {
        log(&st, "auth", "login_2fa_failed", Some(&user_id), "warn", "account is disabled").await;
        return Err(AppError::forbidden("Account is disabled"));
    }
    if !totp::verify(&secret, &b.code) {
        log(&st, "auth", "login_2fa_failed", Some(&user_id), "warn", "incorrect code").await;
        return Err(AppError::unauthorized("Incorrect code"));
    }
    let device = b.device_name.clone().filter(|d| !d.is_empty()).unwrap_or_else(|| "Unknown device".into());
    let token = new_session(&st, &user_id, &device).await?;
    sqlx::query("UPDATE ios_users SET last_login = NOW() WHERE id = $1").bind(&user_id).execute(&st.db).await?;
    let user = user_json(&st, &user_id, false).await?;
    log(&st, "auth", "login_2fa_success", Some(&user_id), "info", "2FA login completed").await;
    Ok(Json(json!({"user": user, "token": token})))
}

// ---- sessions --------------------------------------------------------------------------------

async fn logout(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    if let Some(t) = &u.token_id {
        sqlx::query("DELETE FROM ios_user_sessions WHERE token_id = $1").bind(t).execute(&st.db).await?;
        st.forget_session(t);
    }
    log(&st, "auth", "logout", Some(&u.id), "info", "session ended").await;
    Ok(StatusCode::NO_CONTENT)
}

async fn list_sessions(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('token_id', token_id, 'device_name', device_name, \
           'created_at', lumi_iso(created_at), 'expires_at', lumi_iso(expires_at), 'is_current', token_id = $2) \
           ORDER BY created_at DESC), '[]'::json) \
         FROM ios_user_sessions WHERE user_id = $1 AND expires_at > NOW()",
    )
    .bind(&u.id)
    .bind(u.token_id.clone().unwrap_or_default())
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"sessions": v})))
}

async fn revoke_session(State(st): State<AppState>, u: User, Path(token_id): Path<String>) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM ios_user_sessions WHERE token_id = $1 AND user_id = $2").bind(&token_id).bind(&u.id).execute(&st.db).await?;
    st.forget_session(&token_id);
    let which = if Some(&token_id) == u.token_id.as_ref() { "current" } else { "other" };
    log(&st, "auth", "session_revoked", Some(&u.id), "info", &format!("revoked {which} device session")).await;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct ChangePasswordBody {
    current_password: String,
    new_password: String,
}

async fn change_password(State(st): State<AppState>, u: User, J(b): J<ChangePasswordBody>) -> ApiResult<StatusCode> {
    validate_password(&b.new_password, "")?;
    match password_ok(&st, &u.id, &b.current_password).await? {
        None => return Err(AppError::unauthorized("User not found")),
        Some(false) => {
            log(&st, "auth", "change_password_failed", Some(&u.id), "warn", "current password incorrect").await;
            return Err(AppError::unauthorized("Current password is incorrect"));
        }
        Some(true) => {}
    }
    let hash = hash_password(b.new_password.clone()).await?;
    sqlx::query("UPDATE ios_users SET password_hash = $1 WHERE id = $2").bind(&hash).bind(&u.id).execute(&st.db).await?;
    let revoked: Vec<String> = sqlx::query_scalar("DELETE FROM ios_user_sessions WHERE user_id = $1 AND token_id IS DISTINCT FROM $2 RETURNING token_id")
        .bind(&u.id)
        .bind(&u.token_id)
        .fetch_all(&st.db)
        .await?;
    for t in revoked {
        st.forget_session(&t);
    }
    log(&st, "auth", "change_password", Some(&u.id), "info", "password changed; other sessions revoked").await;
    Ok(StatusCode::NO_CONTENT)
}

async fn delete_account(State(st): State<AppState>, u: User, J(b): J<PasswordBody>) -> ApiResult<StatusCode> {
    match password_ok(&st, &u.id, &b.password).await? {
        None => return Err(AppError::unauthorized("User not found")),
        Some(false) => {
            log(&st, "auth", "delete_account_failed", Some(&u.id), "warn", "incorrect password").await;
            return Err(AppError::unauthorized("Incorrect password"));
        }
        Some(true) => {}
    }
    sqlx::query("DELETE FROM ios_users WHERE id = $1").bind(&u.id).execute(&st.db).await?;
    if let Some(t) = &u.token_id {
        st.forget_session(t);
    }
    if let Some(dir) = st.user_music_dir(&u.id) {
        if dir.exists() {
            let _ = tokio::fs::remove_dir_all(&dir).await;
        }
    }
    tracing::info!("delete_account: user {} deleted their account", u.id);
    log(&st, "auth", "delete_account", None, "info", &format!("user {} deleted their account", u.id)).await;
    Ok(StatusCode::NO_CONTENT)
}

// ---- profile ---------------------------------------------------------------------------------

async fn me(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    user_json(&st, &u.id, true).await?.map(Json).ok_or_else(|| AppError::unauthorized("User not found"))
}

#[derive(Deserialize)]
struct UpdateMeBody {
    display_name: Option<String>,
    date_of_birth: Option<String>,
    email: Option<String>,
    username: Option<String>,
}

async fn update_me(State(st): State<AppState>, u: User, J(b): J<UpdateMeBody>) -> ApiResult<Json<Value>> {
    if let Some(d) = &b.display_name {
        let d: String = d.trim().chars().take(100).collect();
        sqlx::query("UPDATE ios_users SET display_name = $1 WHERE id = $2 AND is_active = TRUE")
            .bind(if d.is_empty() { None } else { Some(d) })
            .bind(&u.id)
            .execute(&st.db)
            .await?;
    }
    if let Some(n) = &b.username {
        let new = n.trim().to_string();
        if new.chars().count() < 3 {
            return Err(AppError::bad_request("Username must be at least 3 characters"));
        }
        let current: Option<String> = sqlx::query_scalar("SELECT username FROM ios_users WHERE id = $1").bind(&u.id).fetch_optional(&st.db).await?;
        if let Some(cur) = current.filter(|c| *c != new) {
            let window_start = Utc::now().naive_utc() - CDuration::days(30);
            let recent: Vec<NaiveDateTime> = sqlx::query_scalar(
                "SELECT changed_at FROM ios_username_change_log WHERE user_id = $1 AND changed_at >= $2 ORDER BY changed_at ASC",
            )
            .bind(&u.id)
            .bind(window_start)
            .fetch_all(&st.db)
            .await?;
            if recent.len() >= MAX_USERNAME_CHANGES_PER_30_DAYS {
                let next = recent[recent.len() - MAX_USERNAME_CHANGES_PER_30_DAYS] + CDuration::days(30);
                return Err(AppError::new(
                    429,
                    format!(
                        "You've already changed your username {MAX_USERNAME_CHANGES_PER_30_DAYS} times in the last 30 days. You can change it again on {}.",
                        next.format("%Y-%m-%d")
                    ),
                ));
            }
            let clash: Option<String> =
                sqlx::query_scalar("SELECT id FROM ios_users WHERE username = $1 AND id <> $2").bind(&new).bind(&u.id).fetch_optional(&st.db).await?;
            if clash.is_some() {
                return Err(AppError::new(409, "Username already taken"));
            }
            // The ios_users_username_changed trigger logs the change and updates
            // every registered copy of the username (schema.sql).
            sqlx::query("UPDATE ios_users SET username = $1 WHERE id = $2 AND is_active = TRUE").bind(&new).bind(&u.id).execute(&st.db).await?;
            log(&st, "account", "username_changed", Some(&u.id), "info", &format!("username changed from {} to {}", py_repr(&cur), py_repr(&new))).await;
        }
    }
    if let Some(e) = &b.email {
        let new = email::normalize(Some(e), "Email").await?;
        let clash: Option<String> = sqlx::query_scalar("SELECT id FROM ios_users WHERE lower(email) = lower($1) AND id <> $2")
            .bind(&new)
            .bind(&u.id)
            .fetch_optional(&st.db)
            .await?;
        if clash.is_some() {
            return Err(AppError::new(409, "That email is already registered to another account"));
        }
        sqlx::query("UPDATE ios_users SET email = $1 WHERE id = $2 AND is_active = TRUE").bind(&new).bind(&u.id).execute(&st.db).await?;
        log(&st, "account", "email_updated", Some(&u.id), "info", "account email set/changed").await;
    }
    if let Some(dob) = b.date_of_birth.as_deref().filter(|d| !d.is_empty()) {
        let date = chrono::NaiveDate::parse_from_str(dob, "%Y-%m-%d").map_err(|_| AppError::bad_request("date_of_birth must be in YYYY-MM-DD format"))?;
        let existing: Option<Option<chrono::NaiveDate>> =
            sqlx::query_scalar("SELECT date_of_birth FROM ios_users WHERE id = $1").bind(&u.id).fetch_optional(&st.db).await?;
        if existing.flatten().is_some() {
            return Err(AppError::bad_request("Date of birth cannot be changed once set"));
        }
        sqlx::query("UPDATE ios_users SET date_of_birth = $1 WHERE id = $2").bind(date).bind(&u.id).execute(&st.db).await?;
    }
    user_json(&st, &u.id, true).await?.map(Json).ok_or_else(|| AppError::unauthorized("User not found"))
}

#[derive(Deserialize)]
struct PrivacyBody {
    share_listening_activity: Option<bool>,
    ai_assisted_suggestions: Option<bool>,
    discoverable_in_recommendations: Option<bool>,
}

async fn update_privacy(State(st): State<AppState>, u: User, J(b): J<PrivacyBody>) -> ApiResult<Json<Value>> {
    let mut updates = serde_json::Map::new();
    for (k, v) in [
        ("share_listening_activity", b.share_listening_activity),
        ("ai_assisted_suggestions", b.ai_assisted_suggestions),
        ("discoverable_in_recommendations", b.discoverable_in_recommendations),
    ] {
        if let Some(v) = v {
            updates.insert(k.into(), json!(v));
        }
    }
    if !updates.is_empty() {
        sqlx::query(
            "UPDATE ios_users SET share_listening_activity = COALESCE($1, share_listening_activity), \
             ai_assisted_suggestions = COALESCE($2, ai_assisted_suggestions), \
             discoverable_in_recommendations = COALESCE($3, discoverable_in_recommendations) WHERE id = $4 AND is_active = TRUE",
        )
        .bind(b.share_listening_activity)
        .bind(b.ai_assisted_suggestions)
        .bind(b.discoverable_in_recommendations)
        .bind(&u.id)
        .execute(&st.db)
        .await?;
        crate::db::log_event(&st.db, "settings", "privacy_updated", Some(&u.id), "info", "", Some(Value::Object(updates.clone()))).await;
    }
    Ok(Json(Value::Object(updates)))
}

// ---- Discord ---------------------------------------------------------------------------------

fn discord_cfg(st: &AppState) -> ApiResult<(String, String, String)> {
    match (&st.cfg.discord_oauth_client_id, &st.cfg.discord_oauth_client_secret, &st.cfg.discord_oauth_redirect_uri) {
        (Some(a), Some(b), Some(c)) => Ok((a.clone(), b.clone(), c.clone())),
        _ => Err(AppError::new(
            503,
            "Discord verification is not configured on this server (DISCORD_OAUTH_CLIENT_ID/DISCORD_OAUTH_CLIENT_SECRET/DISCORD_OAUTH_REDIRECT_URI unset).",
        )),
    }
}

fn authorize_url(client_id: &str, redirect: &str, state: &str) -> String {
    let q = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("client_id", client_id)
        .append_pair("redirect_uri", redirect)
        .append_pair("response_type", "code")
        .append_pair("scope", DISCORD_SCOPE)
        .append_pair("state", state)
        .append_pair("prompt", "consent")
        .finish();
    format!("https://discord.com/api/oauth2/authorize?{q}")
}

async fn discord_verify_start(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let (id, _, redirect) = discord_cfg(&st)?;
    let state = st.keys.create_purpose_token(Some(&u.id), "discord_oauth_state", 600);
    Ok(Json(json!({"authorize_url": authorize_url(&id, &redirect, &state)})))
}

async fn discord_login_start(State(st): State<AppState>) -> ApiResult<Json<Value>> {
    let (id, _, redirect) = discord_cfg(&st)?;
    let state = st.keys.create_purpose_token(None, "discord_oauth_login_state", 600);
    Ok(Json(json!({"authorize_url": authorize_url(&id, &redirect, &state)})))
}

#[derive(Deserialize)]
struct CallbackQ {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

fn deep(link: &str, q: &str) -> Response {
    // Starlette's RedirectResponse is a 307.
    Redirect::temporary(&format!("{link}?{q}")).into_response()
}

async fn discord_exchange(st: &AppState, code: &str) -> anyhow::Result<Value> {
    let (id, secret, redirect) = discord_cfg(st).map_err(|_| anyhow::anyhow!("not configured"))?;
    let tok: Value = st
        .http
        .post("https://discord.com/api/oauth2/token")
        .header("User-Agent", "Lumisound-iOS-Bridge/1.0")
        .form(&[("client_id", id.as_str()), ("client_secret", &secret), ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", &redirect)])
        .timeout(Duration::from_secs(15))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let access = tok["access_token"].as_str().ok_or_else(|| anyhow::anyhow!("Discord token exchange returned no access_token"))?;
    Ok(st
        .http
        .get("https://discord.com/api/users/@me")
        .bearer_auth(access)
        .header("User-Agent", "Lumisound-iOS-Bridge/1.0")
        .timeout(Duration::from_secs(15))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?)
}

async fn discord_callback(State(st): State<AppState>, crate::extract::Q(q): crate::extract::Q<CallbackQ>) -> Response {
    let mut user_id: Option<String> = None;
    let mut login_flow = false;
    if let Some(s) = &q.state {
        user_id = st.keys.decode_purpose(s, "discord_oauth_state").and_then(|c| c.sub);
        if user_id.is_none() {
            login_flow = st.keys.decode_purpose(s, "discord_oauth_login_state").is_some();
        }
    }
    let link = if login_flow { DISCORD_LOGIN_LINK } else { DISCORD_VERIFY_LINK };
    let (Some(code), Some(_)) = (q.code.as_deref().filter(|c| !c.is_empty()).filter(|_| q.error.is_none()), q.state.as_ref()) else {
        let reason = q.error.clone().filter(|e| !e.is_empty()).unwrap_or_else(|| "missing_code".into());
        return deep(link, &format!("success=false&reason={reason}"));
    };
    if user_id.is_none() && !login_flow {
        return deep(link, "success=false&reason=expired_state");
    }
    let du = match discord_exchange(&st, code).await {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!("discord_oauth_callback: code exchange failed (login={login_flow}, user={user_id:?}): {e}");
            return deep(link, "success=false&reason=exchange_failed");
        }
    };
    let (Some(did), Some(dname)) = (du["id"].as_str().filter(|s| !s.is_empty()), du["username"].as_str().filter(|s| !s.is_empty())) else {
        return deep(link, "success=false&reason=invalid_response");
    };
    let display = match du["discriminator"].as_str() {
        Some(d) if !d.is_empty() && d != "0" => format!("{dname}#{d}"),
        _ => dname.to_string(),
    };
    let avatar = du["avatar"].as_str().map(str::to_string);
    let email = if du["verified"].as_bool().unwrap_or(false) { du["email"].as_str().map(str::to_string) } else { None };
    if login_flow {
        return match complete_discord_login(&st, did, &display, email).await {
            Ok(r) => r,
            Err(e) => {
                tracing::error!("discord sign-in failed: {:?}", e.detail);
                deep(DISCORD_LOGIN_LINK, "success=false&reason=invalid_response")
            }
        };
    }
    let uid = user_id.unwrap();
    let r = sqlx::query(
        "INSERT INTO ios_discord_verifications (user_id, discord_user_id, discord_username, discord_avatar_hash, verified_at) \
         VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP) ON CONFLICT (user_id) DO UPDATE SET discord_user_id = EXCLUDED.discord_user_id, \
         discord_username = EXCLUDED.discord_username, discord_avatar_hash = EXCLUDED.discord_avatar_hash, verified_at = CURRENT_TIMESTAMP",
    )
    .bind(&uid)
    .bind(did)
    .bind(&display)
    .bind(&avatar)
    .execute(&st.db)
    .await;
    if let Err(e) = r {
        tracing::warn!("discord_oauth_callback: verification upsert failed for user {uid}: {e}");
        return deep(DISCORD_VERIFY_LINK, "success=false&reason=already_linked_elsewhere");
    }
    crate::db::log_event(&st.db, "account", "discord_verified", Some(&uid), "info", "", Some(json!({"discord_username": display}))).await;
    deep(DISCORD_VERIFY_LINK, "success=true")
}

fn sanitize_discord_username(raw: &str) -> String {
    let cleaned: String = raw.chars().filter(|c| c.is_alphanumeric() || *c == '_').collect::<String>().to_lowercase();
    let cleaned = if cleaned.chars().count() < 3 {
        if cleaned.is_empty() { "user".to_string() } else { format!("{cleaned}user").chars().take(3).collect() }
    } else {
        cleaned
    };
    cleaned.chars().take(32).collect()
}

async fn complete_discord_login(st: &AppState, discord_id: &str, display: &str, email: Option<String>) -> ApiResult<Response> {
    let linked: Option<String> =
        sqlx::query_scalar("SELECT user_id FROM ios_discord_verifications WHERE discord_user_id = $1").bind(discord_id).fetch_optional(&st.db).await?;
    let user_id = if let Some(uid) = linked {
        let row: Option<(Option<bool>, Option<bool>)> =
            sqlx::query_as("SELECT is_active, totp_enabled FROM ios_users WHERE id = $1").bind(&uid).fetch_optional(&st.db).await?;
        let Some((active, totp_on)) = row else { return Ok(deep(DISCORD_LOGIN_LINK, "success=false&reason=invalid_response")) };
        if !active.unwrap_or(false) {
            return Ok(deep(DISCORD_LOGIN_LINK, "success=false&reason=account_disabled"));
        }
        sqlx::query("UPDATE ios_discord_verifications SET discord_username = $1 WHERE user_id = $2").bind(display).bind(&uid).execute(&st.db).await?;
        if let Some(e) = &email {
            if let Ok(norm) = email::normalize(Some(e), "Email").await {
                let r = sqlx::query(
                    "UPDATE ios_users SET email = $1 WHERE id = $2 AND email IS NULL AND NOT EXISTS (\
                       SELECT 1 FROM ios_users o WHERE lower(o.email) = lower($1) AND o.id <> $2)",
                )
                .bind(&norm)
                .bind(&uid)
                .execute(&st.db)
                .await?;
                if r.rows_affected() > 0 {
                    tracing::info!("discord sign-in: backfilled email for user {uid}");
                }
            }
        }
        if totp_on.unwrap_or(false) {
            log(st, "auth", "login_2fa_required", Some(&uid), "info", "Discord sign-in verified, awaiting TOTP code").await;
            let pending = st.keys.create_purpose_token(Some(&uid), "totp_pending", 300);
            return Ok(deep(DISCORD_LOGIN_LINK, &format!("success=true&requires_2fa=true&pending_token={pending}")));
        }
        uid
    } else {
        let uid = uuid::Uuid::new_v4().to_string();
        let random: [u8; 32] = rand::random();
        let hash = hash_password(hex::encode(random)).await?;
        let base = sanitize_discord_username(display);
        let mut username = base.clone();
        let mut n = 0;
        loop {
            let taken: Option<i32> = sqlx::query_scalar("SELECT 1 FROM ios_users WHERE username = $1").bind(&username).fetch_optional(&st.db).await?;
            if taken.is_none() {
                break;
            }
            n += 1;
            username = format!("{base}{n}");
        }
        let mut new_email: Option<String> = None;
        if let Some(e) = &email {
            match email::normalize(Some(e), "Email").await {
                Err(err) => tracing::info!("discord sign-in: unusable email from Discord ({:?})", err.detail),
                Ok(c) => {
                    let clash: Option<String> =
                        sqlx::query_scalar("SELECT id FROM ios_users WHERE lower(email) = lower($1)").bind(&c).fetch_optional(&st.db).await?;
                    if clash.is_some() {
                        tracing::info!("discord sign-in: Discord email already tied to another account; creating {username:?} without one");
                    } else {
                        new_email = Some(c);
                    }
                }
            }
        }
        let mut tx = st.db.begin().await?;
        sqlx::query("INSERT INTO ios_users (id, username, email, password_hash, display_name) VALUES ($1, $2, $3, $4, $5)")
            .bind(&uid)
            .bind(&username)
            .bind(&new_email)
            .bind(&hash)
            .bind(display)
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT INTO ios_user_settings (user_id) VALUES ($1)").bind(&uid).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO ios_discord_verifications (user_id, discord_user_id, discord_username, verified_at) VALUES ($1, $2, $3, CURRENT_TIMESTAMP)")
            .bind(&uid)
            .bind(discord_id)
            .bind(display)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        crate::db::log_event(&st.db, "account", "discord_verified", Some(&uid), "info", "", Some(json!({"discord_username": display}))).await;
        log(st, "auth", "register", Some(&uid), "info", &format!("new account auto-registered via Discord sign-in: {}", py_repr(&username))).await;
        uid
    };
    let token = new_session(st, &user_id, "Discord Sign-In").await?;
    sqlx::query("UPDATE ios_users SET last_login = NOW() WHERE id = $1").bind(&user_id).execute(&st.db).await?;
    log(st, "auth", "login_success", Some(&user_id), "info", "device='Discord Sign-In'").await;
    Ok(deep(DISCORD_LOGIN_LINK, &format!("success=true&token={token}")))
}

async fn discord_verification(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Option<Value> = sqlx::query_scalar(
        "SELECT json_build_object('verified', true, 'discord_username', discord_username, 'discord_avatar_hash', discord_avatar_hash, \
           'verified_at', lumi_iso(verified_at)) FROM ios_discord_verifications WHERE user_id = $1",
    )
    .bind(&u.id)
    .fetch_optional(&st.db)
    .await?;
    Ok(Json(v.unwrap_or_else(|| json!({"verified": false, "discord_username": null, "discord_avatar_hash": null, "verified_at": null}))))
}

async fn discord_unverify(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM ios_discord_verifications WHERE user_id = $1").bind(&u.id).execute(&st.db).await?;
    log(&st, "account", "discord_unverified", Some(&u.id), "info", "").await;
    Ok(StatusCode::NO_CONTENT)
}

const RELEASES_API: &str = "https://api.github.com/repos/VoxeliseStudios/Lumisound/releases";

/// GitHub's releases list (cached 5 min; the last good copy if GitHub fails).
async fn fetch_releases(st: &AppState) -> Value {
    if let Some(v) = st.release_cache.get(&()) {
        return v;
    }
    let mut req = st
        .http
        .get(RELEASES_API)
        .header("User-Agent", "Lumisound-Bridge")
        .header("Accept", "application/vnd.github+json")
        .timeout(Duration::from_secs(15));
    if let Some(t) = &st.cfg.github_releases_token {
        req = req.bearer_auth(t);
    }
    match req.send().await {
        Ok(r) if r.status().is_success() => match r.json::<Value>().await {
            Ok(v) => {
                st.release_cache.set((), v.clone());
                *st.release_stale.lock().unwrap() = Some(v.clone());
                return v;
            }
            Err(e) => tracing::warn!("GitHub releases decode failed: {e}"),
        },
        Ok(r) => tracing::warn!("GitHub releases fetch failed: HTTP {} (private repo needs GITHUB_RELEASES_TOKEN)", r.status()),
        Err(e) => tracing::warn!("GitHub releases fetch failed: {e}"),
    }
    st.release_stale.lock().unwrap().clone().unwrap_or(json!([]))
}

/// The address the caller reached this bridge on (behind the tunnel: https).
fn public_base(headers: &HeaderMap) -> String {
    let host = headers.get("x-forwarded-host").or_else(|| headers.get("host")).and_then(|v| v.to_str().ok()).unwrap_or("localhost");
    let proto = headers.get("x-forwarded-proto").and_then(|v| v.to_str().ok()).unwrap_or_else(|| {
        let h = host.split(':').next().unwrap_or("");
        if h == "localhost" || h.parse::<std::net::IpAddr>().is_ok() { "http" } else { "https" }
    });
    format!("{proto}://{host}")
}

async fn latest_release(State(st): State<AppState>, headers: HeaderMap) -> Json<Value> {
    let mut v = fetch_releases(&st).await;
    // The repo is private: GitHub's own asset links need a GitHub login, so
    // the app's "download update" goes through this bridge instead.
    let base = public_base(&headers);
    if let Some(list) = v.as_array_mut() {
        for rel in list {
            let Some(assets) = rel.get_mut("assets").and_then(Value::as_array_mut) else { continue };
            for a in assets {
                let (Some(id), Some(name)) = (a["id"].as_u64(), a["name"].as_str().map(str::to_string)) else { continue };
                if name.to_lowercase().ends_with(".ipa") {
                    a["browser_download_url"] = json!(format!("{base}/api/app/release-asset/{id}/{}", urlencoding::encode(&name)));
                }
            }
        }
    }
    Json(v)
}

/// Streams one of the listed releases' .ipa assets (public, like the
/// release downloads were before the repo went private). Only asset ids that
/// appear in the releases list are served.
async fn release_asset(State(st): State<AppState>, Path((id, _name)): Path<(u64, String)>) -> ApiResult<Response> {
    let releases = fetch_releases(&st).await;
    let asset = releases
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| r["assets"].as_array())
        .flatten()
        .find(|a| a["id"].as_u64() == Some(id) && a["name"].as_str().is_some_and(|n| n.to_lowercase().ends_with(".ipa")))
        .cloned()
        .ok_or_else(|| AppError::not_found("Unknown release asset"))?;
    let name = asset["name"].as_str().unwrap_or("Lumisound.ipa").replace(['"', '\\', '/'], "_");
    let mut req = st
        .http
        .get(format!("{RELEASES_API}/assets/{id}"))
        .header("User-Agent", "Lumisound-Bridge")
        .header("Accept", "application/octet-stream")
        .timeout(Duration::from_secs(900));
    if let Some(t) = &st.cfg.github_releases_token {
        req = req.bearer_auth(t);
    }
    let r = req.send().await.and_then(|r| r.error_for_status()).map_err(|e| {
        tracing::warn!("release asset {id} fetch failed: {e}");
        AppError::new(502, "Release download unavailable")
    })?;
    let mut res = Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/octet-stream")
        .header("content-disposition", format!("attachment; filename=\"{name}\""));
    if let Some(cl) = r.headers().get("content-length") {
        res = res.header("content-length", cl.clone());
    }
    let body = axum::body::Body::from_stream(futures_util::StreamExt::map(r.bytes_stream(), |c| c.map_err(std::io::Error::other)));
    Ok(res.body(body).unwrap())
}
