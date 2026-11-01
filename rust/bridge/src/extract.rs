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

/// JSON body like FastAPI: parsed whatever the Content-Type, 422 on bad input.
pub struct J<T>(pub T);

impl<S: Send + Sync, T: DeserializeOwned> axum::extract::FromRequest<S> for J<T> {
    type Rejection = AppError;
    async fn from_request(req: axum::extract::Request, state: &S) -> Result<Self, Self::Rejection> {
        let bytes = axum::body::Bytes::from_request(req, state)
            .await
            .map_err(|e| AppError::with_value(400, json!(e.body_text())))?;
        let de = &mut serde_json::Deserializer::from_slice(&bytes);
        match serde_path_to_error::deserialize::<_, T>(de) {
            Ok(v) => Ok(J(v)),
            Err(e) => {
                let loc: Vec<serde_json::Value> = std::iter::once(json!("body"))
                    .chain(e.path().to_string().split('.').filter(|s| !s.is_empty() && *s != "?").map(|s| json!(s)))
                    .collect();
                let msg = e.inner().to_string();
                // serde: "missing field `x` at line 1 column 17" -> FastAPI's shape.
                if let Some(f) = msg.strip_prefix("missing field `").and_then(|r| r.split('`').next()) {
                    let mut loc = loc;
                    loc.push(json!(f));
                    return Err(AppError::with_value(422, json!([{"type": "missing", "loc": loc, "msg": "Field required"}])));
                }
                Err(AppError::with_value(422, json!([{"type": "value_error", "loc": loc, "msg": msg}])))
            }
        }
    }
}
