//! /ws/live: the per-user event socket (presence, notifications, sync
//! nudges, listening rooms, appearance changes). Connects with the session
//! token, pings every 25 s, reconnects with exponential backoff (2 s -> 60 s)
//! and hands typed events to a Swift listener.

use crate::RT;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

#[derive(uniffi::Record, Clone, Debug)]
pub struct LivePresence {
    pub user_id: String,
    pub online: bool,
    pub is_playing: bool,
    pub now_playing_title: Option<String>,
    pub now_playing_artist: Option<String>,
    pub now_playing_artwork_url: Option<String>,
}

#[derive(uniffi::Enum, Clone, Debug)]
pub enum LiveEvent {
    Presence { presence: LivePresence },
    Notification,
    SyncChanged,
    /// room_state / room_chat / room_queue / room_members / room_closed (raw JSON).
    Room { kind: String, json: String },
    Appearance { style: String, density: String },
    Other { kind: String, json: String },
}

#[uniffi::export(with_foreign)]
pub trait LiveEventListener: Send + Sync {
    fn on_event(&self, event: LiveEvent);
    fn on_connection(&self, connected: bool);
}

pub fn parse_event(text: &str) -> Option<LiveEvent> {
    let v: Value = serde_json::from_str(text).ok()?;
    let kind = v["type"].as_str()?.to_string();
    let s = |k: &str| v[k].as_str().map(str::to_string);
    Some(match kind.as_str() {
        "presence" => LiveEvent::Presence {
            presence: LivePresence {
                user_id: s("user_id")?,
                online: v["online"].as_bool().unwrap_or(false),
                is_playing: v["is_playing"].as_bool().unwrap_or(false),
                now_playing_title: s("now_playing_title"),
                now_playing_artist: s("now_playing_artist"),
                now_playing_artwork_url: s("now_playing_artwork_url"),
            },
        },
        "notification" => LiveEvent::Notification,
        "sync_changed" => LiveEvent::SyncChanged,
        "room_state" | "room_chat" | "room_queue" | "room_members" | "room_closed" => LiveEvent::Room { kind, json: text.to_string() },
        "appearance_changed" => LiveEvent::Appearance { style: s("style")?, density: s("density").unwrap_or_else(|| "regular".into()) },
        _ => LiveEvent::Other { kind, json: text.to_string() },
    })
}

fn ws_url(bridge: &str, token: &str) -> Option<String> {
    let mut u = url::Url::parse(bridge).ok()?;
    let scheme = if u.scheme() == "http" { "ws" } else { "wss" };
    u.set_scheme(scheme).ok()?;
    u.set_path("/ws/live");
    u.query_pairs_mut().clear().append_pair("token", token);
    Some(u.to_string())
}

#[derive(uniffi::Object)]
pub struct LiveSocket {
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

#[uniffi::export]
impl LiveSocket {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self { task: Mutex::new(None) })
    }

    /// (Re)start for this bridge + session; replaces any running connection.
    pub fn start(&self, bridge_url: String, token: String, listener: Arc<dyn LiveEventListener>) {
        self.stop();
        let Some(url) = ws_url(&bridge_url, &token) else { return };
        let h = RT.spawn(run(url, listener));
        *self.task.lock().unwrap() = Some(h);
    }

    pub fn stop(&self) {
        if let Some(h) = self.task.lock().unwrap().take() {
            h.abort();
        }
    }
}

async fn run(url: String, listener: Arc<dyn LiveEventListener>) {
    let mut delay = 2.0f64;
    loop {
        match tokio_tungstenite::connect_async(&url).await {
            Ok((ws, _)) => {
                delay = 2.0;
                listener.on_connection(true);
                let (mut tx, mut rx) = ws.split();
                let mut ping = tokio::time::interval(Duration::from_secs(25));
                ping.tick().await;
                loop {
                    tokio::select! {
                        _ = ping.tick() => {
                            if tx.send(Message::Text("ping".into())).await.is_err() { break; }
                        }
                        m = rx.next() => match m {
                            Some(Ok(Message::Text(t))) => {
                                if let Some(ev) = parse_event(&t) { listener.on_event(ev); }
                            }
                            Some(Ok(Message::Ping(p))) => { let _ = tx.send(Message::Pong(p)).await; }
                            Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                            Some(Ok(_)) => {}
                        }
                    }
                }
                listener.on_connection(false);
            }
            Err(_) => listener.on_connection(false),
        }
        tokio::time::sleep(Duration::from_secs_f64(delay)).await;
        delay = (delay * 2.0).min(60.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_events() {
        assert!(matches!(parse_event(r#"{"type":"sync_changed"}"#), Some(LiveEvent::SyncChanged)));
        match parse_event(r#"{"type":"presence","user_id":"u","online":true,"now_playing_title":"T"}"#) {
            Some(LiveEvent::Presence { presence }) => assert!(presence.online && presence.now_playing_title.as_deref() == Some("T")),
            e => panic!("{e:?}"),
        }
        assert_eq!(ws_url("https://x.example", "a b").unwrap(), "wss://x.example/ws/live?token=a+b");
    }
}
