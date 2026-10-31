//! `/ws/live` (per-user event socket) and the internal endpoint the legacy
//! Python bridge uses to publish into it while both servers run.

use crate::error::AppError;
use crate::state::AppState;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::Value;

pub fn routes() -> Router<AppState> {
    Router::new().route("/ws/live", get(live)).route("/internal/live-push", post(internal_push))
}

#[derive(Deserialize)]
struct LiveQ {
    token: Option<String>,
}

async fn live(State(st): State<AppState>, ws: WebSocketUpgrade, Query(q): Query<LiveQ>) -> Response {
    let user = q.token.as_deref().and_then(|t| st.keys.decode(t)).filter(|c| c.purpose.is_none()).and_then(|c| c.sub);
    ws.on_upgrade(move |socket| async move {
        match user {
            Some(u) => serve(st, u, socket).await,
            None => {
                let mut s = socket;
                let _ = s
                    .send(Message::Close(Some(axum::extract::ws::CloseFrame { code: 4401, reason: "".into() })))
                    .await;
            }
        }
    })
}

async fn serve(st: AppState, user: String, socket: WebSocket) {
    let (id, mut rx) = st.live.register(&user);
    let (mut tx, mut inbound) = socket.split();
    let writer = async {
        while let Some(text) = rx.recv().await {
            if tx.send(Message::Text(text.into())).await.is_err() {
                break;
            }
        }
    };
    // The client never sends anything meaningful; reading keeps pings
    // answered and notices the disconnect.
    let reader = async { while let Some(Ok(m)) = inbound.next().await { if matches!(m, Message::Close(_)) { break; } } };
    tokio::select! { _ = writer => {}, _ = reader => {} }
    st.live.unregister(&user, id);
}

#[derive(Deserialize)]
struct PushBody {
    user_ids: Vec<String>,
    event: Value,
}

async fn internal_push(State(st): State<AppState>, headers: HeaderMap, Json(b): Json<PushBody>) -> Result<impl IntoResponse, AppError> {
    let ok = headers.get("x-internal-token").and_then(|v| v.to_str().ok()) == Some(st.internal_token.as_str());
    if !ok {
        return Err(AppError::forbidden("Forbidden"));
    }
    for u in &b.user_ids {
        st.live.push(u, &b.event);
    }
    Ok(axum::http::StatusCode::NO_CONTENT)
}
