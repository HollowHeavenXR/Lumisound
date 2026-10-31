//! Pass-through to the legacy Python bridge for routes not ported yet.
//! Streams both directions (big uploads, audio streams) and relays
//! WebSocket upgrades.

use crate::error::AppError;
use crate::state::AppState;
use axum::body::Body;
use axum::extract::ws::{Message as AMsg, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, FromRequestParts, Request, State};
use axum::http::{HeaderMap, HeaderName, StatusCode};
use axum::response::{IntoResponse, Response};
use futures_util::{SinkExt, StreamExt, TryStreamExt};
use std::net::SocketAddr;
use tokio_tungstenite::tungstenite::{self, Message as TMsg};

const HOP: &[&str] = &[
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade", "host",
];

fn is_hop(name: &HeaderName) -> bool {
    HOP.contains(&name.as_str())
}

pub async fn fallback(State(st): State<AppState>, req: Request) -> Response {
    let Some(base) = st.cfg.legacy_url.clone() else {
        return AppError::not_found("Not Found").into_response();
    };
    let is_ws = req
        .headers()
        .get("upgrade")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.eq_ignore_ascii_case("websocket"));
    if is_ws {
        return websocket(st, base, req).await;
    }
    match forward(&st, &base, req).await {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("legacy proxy failed: {e:#}");
            (StatusCode::BAD_GATEWAY, axum::Json(serde_json::json!({"detail": "Bridge upstream unavailable"}))).into_response()
        }
    }
}

async fn forward(st: &AppState, base: &str, req: Request) -> anyhow::Result<Response> {
    let (parts, body) = req.into_parts();
    let path_q = parts.uri.path_and_query().map(|p| p.as_str()).unwrap_or("/");
    let url = format!("{base}{path_q}");
    let peer = parts.extensions.get::<ConnectInfo<SocketAddr>>().map(|c| c.0);

    let mut headers = HeaderMap::new();
    for (k, v) in parts.headers.iter() {
        if !is_hop(k) {
            headers.append(k.clone(), v.clone());
        }
    }
    // Keep the client's address visible to the legacy server's rate limits.
    if !headers.contains_key("x-forwarded-for") {
        if let Some(p) = peer {
            headers.insert("x-forwarded-for", p.ip().to_string().parse()?);
        }
    }
    let stream = body.into_data_stream().map_err(std::io::Error::other);
    let upstream = st
        .legacy
        .request(parts.method.clone(), &url)
        .headers(headers)
        .body(reqwest::Body::wrap_stream(stream))
        .send()
        .await?;

    let mut res = Response::builder().status(upstream.status().as_u16());
    {
        let h = res.headers_mut().unwrap();
        for (k, v) in upstream.headers().iter() {
            if !is_hop(k) {
                h.append(k.clone(), v.clone());
            }
        }
    }
    Ok(res.body(Body::from_stream(upstream.bytes_stream()))?)
}

async fn websocket(st: AppState, base: String, req: Request) -> Response {
    let path_q = req.uri().path_and_query().map(|p| p.to_string()).unwrap_or_else(|| "/".into());
    let fwd_headers: Vec<(String, String)> = req
        .headers()
        .iter()
        .filter(|(k, _)| matches!(k.as_str(), "authorization" | "x-forwarded-for" | "user-agent" | "cookie" | "origin"))
        .filter_map(|(k, v)| Some((k.to_string(), v.to_str().ok()?.to_string())))
        .collect();
    let (mut parts, _body) = req.into_parts();
    let upgrade = match WebSocketUpgrade::from_request_parts(&mut parts, &st).await {
        Ok(u) => u,
        Err(e) => return e.into_response(),
    };
    let ws_base = base.replacen("http", "ws", 1);
    upgrade.on_upgrade(move |client| async move {
        let mut rq = match tungstenite::client::IntoClientRequest::into_client_request(format!("{ws_base}{path_q}")) {
            Ok(r) => r,
            Err(_) => return,
        };
        for (k, v) in fwd_headers {
            if let (Ok(k), Ok(v)) = (HeaderName::try_from(k), v.parse()) {
                rq.headers_mut().insert(k, v);
            }
        }
        match tokio_tungstenite::connect_async(rq).await {
            Ok((upstream, _)) => relay(client, upstream).await,
            Err(e) => tracing::warn!("legacy websocket connect failed: {e}"),
        }
    })
}

async fn relay(
    client: WebSocket,
    upstream: tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
) {
    let (mut c_tx, mut c_rx) = client.split();
    let (mut u_tx, mut u_rx) = upstream.split();
    let up = async {
        while let Some(Ok(m)) = c_rx.next().await {
            let m = match m {
                AMsg::Text(t) => TMsg::Text(t.as_str().into()),
                AMsg::Binary(b) => TMsg::Binary(b),
                AMsg::Ping(p) => TMsg::Ping(p),
                AMsg::Pong(p) => TMsg::Pong(p),
                AMsg::Close(_) => break,
            };
            if u_tx.send(m).await.is_err() {
                break;
            }
        }
        let _ = u_tx.close().await;
    };
    let down = async {
        while let Some(Ok(m)) = u_rx.next().await {
            let m = match m {
                TMsg::Text(t) => AMsg::Text(t.as_str().into()),
                TMsg::Binary(b) => AMsg::Binary(b),
                TMsg::Ping(p) => AMsg::Ping(p),
                TMsg::Pong(p) => AMsg::Pong(p),
                TMsg::Close(_) | TMsg::Frame(_) => break,
            };
            if c_tx.send(m).await.is_err() {
                break;
            }
        }
        let _ = c_tx.close().await;
    };
    tokio::select! { _ = up => {}, _ = down => {} }
}
