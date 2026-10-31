//! Tokens and request authentication (port of auth.py + main.py's
//! check_auth / get_current_user / check_admin_or_operator).

use crate::error::AppError;
use crate::state::AppState;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use chrono::{Duration as ChronoDuration, Utc};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::{Duration, Instant};

pub const TOKEN_EXPIRE_DAYS: i64 = 30;
pub const OPERATOR_USER_ID: &str = "ca8a4c53-5603-472e-9287-5fb879f28090";
const SESSION_CACHE_TTL: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Claims {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sub: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jti: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub purpose: Option<String>,
    pub exp: i64,
    pub iat: i64,
}

pub struct Keys {
    enc: EncodingKey,
    dec: DecodingKey,
    validation: Validation,
}

impl Keys {
    pub fn new(secret: &str) -> Self {
        let mut validation = Validation::new(Algorithm::HS256);
        validation.leeway = 0;
        validation.required_spec_claims.clear();
        validation.required_spec_claims.insert("exp".into());
        Self {
            enc: EncodingKey::from_secret(secret.as_bytes()),
            dec: DecodingKey::from_secret(secret.as_bytes()),
            validation,
        }
    }

    fn encode(&self, sub: Option<&str>, jti: Option<&str>, purpose: Option<&str>, ttl: ChronoDuration) -> String {
        let now = Utc::now();
        let claims = Claims {
            sub: sub.map(str::to_string),
            jti: jti.map(str::to_string),
            purpose: purpose.map(str::to_string),
            exp: (now + ttl).timestamp(),
            iat: now.timestamp(),
        };
        jsonwebtoken::encode(&Header::new(Algorithm::HS256), &claims, &self.enc).expect("jwt encode")
    }

    pub fn decode(&self, token: &str) -> Option<Claims> {
        jsonwebtoken::decode::<Claims>(token, &self.dec, &self.validation).ok().map(|d| d.claims)
    }

    pub fn create_token(&self, user_id: &str, token_id: &str, expire_days: i64) -> String {
        self.encode(Some(user_id), Some(token_id), None, ChronoDuration::days(expire_days))
    }

    pub fn create_purpose_token(&self, user_id: Option<&str>, purpose: &str, seconds: i64) -> String {
        self.encode(user_id, None, Some(purpose), ChronoDuration::seconds(seconds))
    }

    /// Returns the subject of a token minted for `purpose` (totp_pending,
    /// discord_oauth_state, ...).
    pub fn decode_purpose(&self, token: &str, purpose: &str) -> Option<Claims> {
        self.decode(token).filter(|c| c.purpose.as_deref() == Some(purpose))
    }
}

pub async fn hash_password(password: String) -> anyhow::Result<String> {
    Ok(tokio::task::spawn_blocking(move || bcrypt::hash(password, bcrypt::DEFAULT_COST)).await??)
}

pub async fn verify_password(password: String, hashed: String) -> bool {
    tokio::task::spawn_blocking(move || bcrypt::verify(password, &hashed).unwrap_or(false))
        .await
        .unwrap_or(false)
}

fn bearer(parts: &Parts) -> Option<&str> {
    parts.headers.get("authorization")?.to_str().ok()?.strip_prefix("Bearer ")
}

impl AppState {
    /// Session row still live? Cached for 60s per token id, like the Python
    /// `_session_cache`, so revocation takes effect within a minute.
    pub async fn session_alive(&self, token_id: &str) -> Result<bool, AppError> {
        let now = Instant::now();
        if let Some(until) = self.session_cache.get(token_id) {
            if now < *until {
                return Ok(true);
            }
        }
        let alive: Option<i32> = sqlx::query_scalar(
            "SELECT 1 FROM ios_user_sessions WHERE token_id = $1 AND expires_at > NOW()",
        )
        .bind(token_id)
        .fetch_optional(&self.db)
        .await?;
        if alive.is_some() {
            self.session_cache.insert(token_id.to_string(), now + SESSION_CACHE_TTL);
            Ok(true)
        } else {
            self.session_cache.remove(token_id);
            Ok(false)
        }
    }

    pub fn forget_session(&self, token_id: &str) {
        self.session_cache.remove(token_id);
    }
}

/// A signed-in account (`Depends(get_current_user)`).
#[derive(Debug, Clone)]
pub struct User {
    pub id: String,
    pub token_id: Option<String>,
    pub claims: Claims,
}

impl User {
    pub fn payload(&self) -> Value {
        serde_json::to_value(&self.claims).unwrap_or(Value::Null)
    }
}

impl FromRequestParts<AppState> for User {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let token = bearer(parts).ok_or_else(|| AppError::unauthorized("Authentication required"))?;
        let claims = state.keys.decode(token).ok_or_else(|| {
            tracing::warn!("JWT decode failed for token (invalid or expired)");
            AppError::unauthorized("Invalid or expired token")
        })?;
        // Short-lived purpose tokens (2FA pending, OAuth state) are not
        // sessions. The Python bridge accepted them here; that let a
        // half-finished 2FA login act as the account.
        if claims.purpose.is_some() {
            return Err(AppError::unauthorized("Invalid or expired token"));
        }
        let id = claims.sub.clone().ok_or_else(|| AppError::unauthorized("Invalid or expired token"))?;
        if let Some(jti) = &claims.jti {
            if !state.session_alive(jti).await? {
                return Err(AppError::unauthorized("Session has been revoked"));
            }
        }
        Ok(User { id, token_id: claims.jti.clone(), claims })
    }
}

/// Optional account: `Some` for a valid session, `None` otherwise.
pub struct MaybeUser(pub Option<User>);

impl FromRequestParts<AppState> for MaybeUser {
    type Rejection = AppError;
    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        Ok(MaybeUser(User::from_request_parts(parts, state).await.ok()))
    }
}

/// `Depends(check_auth)`: the shared app API key, when one is configured.
pub struct ApiKey;

impl FromRequestParts<AppState> for ApiKey {
    type Rejection = AppError;
    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        if state.cfg.api_key.is_empty() {
            return Ok(ApiKey);
        }
        match bearer(parts) {
            None => Err(AppError::unauthorized("Missing Authorization header")),
            Some(t) if t == state.cfg.api_key => Ok(ApiKey),
            Some(_) => Err(AppError::forbidden("Invalid API key")),
        }
    }
}

/// `Depends(check_admin_or_operator)`: the operator's own session, or ADMIN_TOKEN.
pub struct Admin;

impl FromRequestParts<AppState> for Admin {
    type Rejection = AppError;
    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let token = bearer(parts);
        if let Some(c) = token.and_then(|t| state.keys.decode(t)) {
            if c.sub.as_deref() == Some(OPERATOR_USER_ID) && c.purpose.is_none() {
                let jti = c.jti.ok_or_else(|| AppError::unauthorized("Malformed session token"))?;
                let alive: Option<i32> = sqlx::query_scalar(
                    "SELECT 1 FROM ios_user_sessions WHERE token_id = $1 AND expires_at > NOW()",
                )
                .bind(&jti)
                .fetch_optional(&state.db)
                .await?;
                return if alive.is_some() { Ok(Admin) } else { Err(AppError::unauthorized("Session has been revoked")) };
            }
        }
        if state.cfg.admin_token.is_empty() {
            return Err(AppError::new(503, "Admin dashboard not configured (set ADMIN_TOKEN)"));
        }
        if token == Some(state.cfg.admin_token.as_str()) {
            Ok(Admin)
        } else {
            Err(AppError::unauthorized("Invalid admin credentials"))
        }
    }
}

/// `X-Account-Token` header's account id (used by API-key routes that can
/// optionally attribute work to an account).
pub fn account_token_user_id(state: &AppState, headers: &axum::http::HeaderMap) -> Option<String> {
    let t = headers.get("x-account-token")?.to_str().ok()?;
    if t.is_empty() {
        return None;
    }
    state.keys.decode(t)?.sub
}

/// Client IP as the Python bridge computed it: last X-Forwarded-For hop
/// (cloudflared appends the real client), else the socket peer.
pub fn client_ip(headers: &axum::http::HeaderMap, peer: Option<std::net::SocketAddr>) -> String {
    if let Some(xff) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
        if let Some(last) = xff.split(',').map(str::trim).filter(|p| !p.is_empty()).last() {
            return last.to_string();
        }
    }
    peer.map(|p| p.ip().to_string()).unwrap_or_else(|| "unknown".into())
}
