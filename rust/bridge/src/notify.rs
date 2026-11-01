//! In-app notifications, the /ws/live hub, push, and user webhooks.

use crate::state::AppState;
use dashmap::DashMap;
use serde_json::{Value, json};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

/// user id -> open /ws/live sockets (each an outbound text channel).
#[derive(Default)]
pub struct LiveHub {
    conns: DashMap<String, Vec<(u64, mpsc::UnboundedSender<String>)>>,
    next: std::sync::atomic::AtomicU64,
}

impl LiveHub {
    pub fn register(&self, user_id: &str) -> (u64, mpsc::UnboundedReceiver<String>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let id = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.conns.entry(user_id.to_string()).or_default().push((id, tx));
        (id, rx)
    }

    pub fn unregister(&self, user_id: &str, id: u64) {
        if let Some(mut v) = self.conns.get_mut(user_id) {
            v.retain(|(i, _)| *i != id);
        }
        self.conns.remove_if(user_id, |_, v| v.is_empty());
    }

    pub fn is_online(&self, user_id: &str) -> bool {
        self.conns.contains_key(user_id)
    }

    pub fn push(&self, user_id: &str, event: &Value) {
        let Some(mut v) = self.conns.get_mut(user_id) else { return };
        let text = event.to_string();
        v.retain(|(_, tx)| tx.send(text.clone()).is_ok());
        let empty = v.is_empty();
        drop(v);
        if empty {
            self.conns.remove_if(user_id, |_, v| v.is_empty());
        }
    }
}

impl AppState {
    pub fn push_live(&self, user_id: &str, event: Value) {
        self.live.push(user_id, &event);
    }

    pub async fn push_live_to_friends(&self, user_id: &str, event: Value) {
        let friends: Vec<String> = sqlx::query_scalar("SELECT friend_id FROM ios_social_friends WHERE user_id = $1")
            .bind(user_id)
            .fetch_all(&self.db)
            .await
            .unwrap_or_default();
        for f in friends {
            self.live.push(&f, &event);
        }
    }

    /// `_create_notification`.
    pub async fn create_notification(
        &self,
        user_id: &str,
        type_: &str,
        title: &str,
        body: &str,
        data: Value,
        content_available: bool,
    ) -> anyhow::Result<String> {
        let id = uuid::Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO ios_notifications (id, user_id, type, title, body, data_json) VALUES ($1, $2, $3, $4, $5, $6)")
            .bind(&id)
            .bind(user_id)
            .bind(type_)
            .bind(title)
            .bind(body)
            .bind(data.to_string())
            .execute(&self.db)
            .await?;
        let st = self.clone();
        let (u, t, ti, b) = (user_id.to_string(), type_.to_string(), title.to_string(), body.to_string());
        tokio::spawn(async move { st.send_push_best_effort(&u, &t, &ti, &b, &data, content_available).await });
        self.push_live(
            user_id,
            json!({"type": "notification", "notification_id": id, "notification_type": type_, "title": title, "body": body}),
        );
        Ok(id)
    }

    /// `_notify_download_ready_coalesced`: one "N Downloads Ready" notification per 10 minutes.
    pub async fn notify_download_ready(&self, user_id: &str, display_title: &str, job_id: &str, source_track_id: &str) -> anyhow::Result<()> {
        let existing: Option<(String, Option<String>)> = sqlx::query_as(
            "SELECT id, data_json::text FROM ios_notifications \
             WHERE user_id = $1 AND type = 'download_ready' AND read_at IS NULL \
               AND created_at > NOW() - make_interval(secs => 600) \
             ORDER BY created_at DESC LIMIT 1",
        )
        .bind(user_id)
        .fetch_optional(&self.db)
        .await?;
        let now = Instant::now();
        let may_push = {
            let mut last = self.download_push_at.entry(user_id.to_string()).or_insert(now - Duration::from_secs(3600));
            let ok = now.duration_since(*last) >= Duration::from_secs(60);
            if ok {
                *last = now;
            }
            ok
        };
        if let Some((nid, raw)) = existing {
            let mut data: Value = raw.and_then(|r| serde_json::from_str(&r).ok()).filter(Value::is_object).unwrap_or_else(|| json!({}));
            let count = data["count"].as_i64().filter(|c| *c > 0).unwrap_or(1) + 1;
            data["count"] = json!(count);
            data["job_id"] = json!(job_id);
            data["source_track_id"] = json!(source_track_id);
            data["latest_title"] = json!(display_title);
            let title = format!("{count} Downloads Ready");
            let body = format!("“{display_title}” and {} more are ready to add to your library", count - 1);
            sqlx::query("UPDATE ios_notifications SET title = $1, body = $2, data_json = $3, created_at = NOW() WHERE id = $4")
                .bind(&title)
                .bind(&body)
                .bind(data.to_string())
                .bind(&nid)
                .execute(&self.db)
                .await?;
            if may_push {
                let st = self.clone();
                let (u, t, b, d) = (user_id.to_string(), title.clone(), body.clone(), data.clone());
                tokio::spawn(async move { st.send_push_best_effort(&u, "download_ready", &t, &b, &d, true).await });
            }
            self.push_live(
                user_id,
                json!({"type": "notification", "notification_id": nid, "notification_type": "download_ready", "title": title, "body": body}),
            );
            return Ok(());
        }
        self.create_notification(
            user_id,
            "download_ready",
            "Download Ready",
            &format!("“{display_title}” is ready to add to your library"),
            json!({"job_id": job_id, "source_track_id": source_track_id, "count": 1}),
            may_push,
        )
        .await?;
        Ok(())
    }

    pub async fn send_push_best_effort(&self, user_id: &str, type_: &str, title: &str, body: &str, data: &Value, content_available: bool) {
        self.send_push(user_id, type_, title, body, data, content_available).await
    }

    /// `_fire_user_webhooks`.
    pub async fn fire_user_webhooks(&self, user_id: &str, event_type: &str, data: Value) {
        let urls: Vec<String> =
            sqlx::query_scalar("SELECT webhook_url FROM ios_user_webhooks WHERE user_id = $1 AND event_type = $2 AND enabled = TRUE")
                .bind(user_id)
                .bind(event_type)
                .fetch_all(&self.db)
                .await
                .unwrap_or_default();
        let ts = chrono::Utc::now().timestamp_micros() as f64 / 1e6;
        for url in urls {
            let body = json!({"event": event_type, "data": data, "timestamp": ts});
            let r = self
                .http
                .post(&url)
                .header("User-Agent", "Lumisound-iOS-Bridge/1.0")
                .json(&body)
                .timeout(Duration::from_secs(10))
                .send()
                .await;
            if let Err(e) = r {
                tracing::debug!("user webhook failed for event {event_type}: {e}");
            }
        }
    }

    /// `_fetch_and_cache_lyrics` (LRCLIB), used to warm lyrics after a download.
    pub async fn fetch_and_cache_lyrics(&self, title: &str, artist: &str, duration: Option<i64>) -> bool {
        let id = lyrics_cache_id(title, artist);
        let cached: Option<Option<bool>> = sqlx::query_scalar("SELECT found FROM ios_lyrics_cache WHERE id = $1")
            .bind(&id)
            .fetch_optional(&self.db)
            .await
            .ok()
            .flatten();
        if let Some(found) = cached {
            return found.unwrap_or(false);
        }
        let mut q = vec![("track_name", title.to_string()), ("artist_name", artist.to_string())];
        if let Some(d) = duration.filter(|d| *d > 0) {
            q.push(("duration", d.to_string()));
        }
        let data: Option<Value> = match self
            .http
            .get("https://lrclib.net/api/get")
            .query(&q)
            .header("User-Agent", "Lumisound-iOS-Bridge/1.0")
            .timeout(Duration::from_secs(10))
            .send()
            .await
        {
            Ok(r) if r.status().is_success() => r.json().await.ok(),
            _ => None,
        };
        let synced = data.as_ref().and_then(|d| d["syncedLyrics"].as_str()).filter(|s| !s.is_empty()).map(str::to_string);
        let plain = data.as_ref().and_then(|d| d["plainLyrics"].as_str()).filter(|s| !s.is_empty()).map(str::to_string);
        let found = synced.is_some() || plain.is_some();
        let r = sqlx::query(
            "INSERT INTO ios_lyrics_cache (id, title, artist, synced_lyrics, plain_lyrics, found) VALUES ($1, $2, $3, $4, $5, $6) \
             ON CONFLICT (id) DO UPDATE SET \
               synced_lyrics = CASE WHEN ios_lyrics_cache.is_user_submitted THEN ios_lyrics_cache.synced_lyrics ELSE EXCLUDED.synced_lyrics END, \
               plain_lyrics = CASE WHEN ios_lyrics_cache.is_user_submitted THEN ios_lyrics_cache.plain_lyrics ELSE EXCLUDED.plain_lyrics END, \
               found = CASE WHEN ios_lyrics_cache.is_user_submitted THEN ios_lyrics_cache.found ELSE EXCLUDED.found END",
        )
        .bind(&id)
        .bind(title)
        .bind(artist)
        .bind(synced)
        .bind(plain)
        .bind(found)
        .execute(&self.db)
        .await;
        if let Err(e) = r {
            tracing::warn!("lyrics cache write failed for {title}/{artist}: {e}");
        }
        found
    }
}

pub fn lyrics_cache_id(title: &str, artist: &str) -> String {
    use sha2::{Digest, Sha256};
    let key = format!("{}|{}", title.trim().to_lowercase(), artist.trim().to_lowercase());
    hex::encode(Sha256::digest(key.as_bytes()))
}
