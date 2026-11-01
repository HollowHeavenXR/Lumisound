//! `/ws/live`: the per-user event socket (notifications, presence, sync
//! nudges, rooms) every app keeps open while foregrounded.

use crate::state::AppState;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::response::Response;
use axum::routing::get;
use axum::Router;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;

pub fn routes() -> Router<AppState> {
    Router::new().route("/ws/live", get(live))
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

