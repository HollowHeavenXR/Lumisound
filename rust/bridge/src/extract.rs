//! Query extractor that rejects like FastAPI (422 + detail list).

use crate::error::AppError;
use axum::extract::{FromRequestParts, Query};
use axum::http::request::Parts;
use serde::de::DeserializeOwned;
use serde_json::json;

pub struct Q<T>(pub T);

impl<S: Send + Sync, T: DeserializeOwned> FromRequestParts<S> for Q<T> {
    type Rejection = AppError;
    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        match Query::<T>::from_request_parts(parts, state).await {
            Ok(Query(v)) => Ok(Q(v)),
            Err(e) => Err(AppError::with_value(422, json!([{"type": "query", "loc": ["query"], "msg": e.body_text()}]))),
        }
    }
}

/// 422 for an out-of-range query value (FastAPI ge/le/min_length).
pub fn invalid(field: &str, msg: &str) -> AppError {
    AppError::with_value(422, json!([{"type": "value_error", "loc": ["query", field], "msg": msg}]))
}

pub fn check_range(field: &str, v: i64, lo: i64, hi: i64) -> Result<(), AppError> {
    if v < lo {
        return Err(invalid(field, &format!("Input should be greater than or equal to {lo}")));
    }
    if v > hi {
        return Err(invalid(field, &format!("Input should be less than or equal to {hi}")));
    }
    Ok(())
}
