//! Errors render the way FastAPI's HTTPException did: `{"detail": ...}`,
//! which is what every client parses.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};

#[derive(Debug)]
pub struct AppError {
    pub status: StatusCode,
    pub detail: Value,
}

pub type ApiResult<T> = Result<T, AppError>;

impl AppError {
    pub fn new(status: u16, detail: impl Into<String>) -> Self {
        Self { status: StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR), detail: Value::String(detail.into()) }
    }
    pub fn with_value(status: u16, detail: Value) -> Self {
        Self { status: StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR), detail }
    }
    pub fn bad_request(d: impl Into<String>) -> Self { Self::new(400, d) }
    pub fn unauthorized(d: impl Into<String>) -> Self { Self::new(401, d) }
    pub fn forbidden(d: impl Into<String>) -> Self { Self::new(403, d) }
    pub fn not_found(d: impl Into<String>) -> Self { Self::new(404, d) }
    pub fn internal(d: impl Into<String>) -> Self { Self::new(500, d) }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let mut res = (self.status, axum::Json(json!({ "detail": self.detail }))).into_response();
        if self.status == StatusCode::UNAUTHORIZED {
            // FastAPI's HTTPBearer adds this on 401s.
            res.headers_mut().insert("www-authenticate", "Bearer".parse().unwrap());
        }
        res
    }
}

impl From<sqlx::Error> for AppError {
    fn from(e: sqlx::Error) -> Self {
        tracing::error!("database error: {e}");
        AppError::internal("Internal Server Error")
    }
}

impl From<anyhow::Error> for AppError {
    fn from(e: anyhow::Error) -> Self {
        tracing::error!("internal error: {e:#}");
        AppError::internal("Internal Server Error")
    }
}

impl From<std::io::Error> for AppError {
    fn from(e: std::io::Error) -> Self {
        tracing::error!("io error: {e}");
        AppError::internal("Internal Server Error")
    }
}
