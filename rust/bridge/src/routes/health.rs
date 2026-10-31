use crate::state::AppState;
use axum::extract::State;
use axum::routing::get;
use axum::{Json, Router};
use serde_json::{Value, json};

pub fn routes() -> Router<AppState> {
    Router::new().route("/health", get(health))
}

async fn health(State(st): State<AppState>) -> Json<Value> {
    Json(json!({ "status": "ok", "version": "1.0.0", "yt_dlp_version": st.ytdlp_version, "engine": "rust" }))
}
