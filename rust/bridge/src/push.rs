//! Push delivery: APNs (HTTP/2 + ES256 provider token) and FCM HTTP v1
//! (service-account OAuth). Both are optional; unset env = quietly skipped.

use crate::state::AppState;
use base64::Engine;
use serde_json::{Value, json};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub struct Push {
    apns: Option<Apns>,
    fcm: Option<Fcm>,
    http: reqwest::Client,
}

struct Apns {
    key: jsonwebtoken::EncodingKey,
    key_id: String,
    team_id: String,
    topic: String,
    host: &'static str,
    token: Mutex<Option<(String, Instant)>>,
}

struct Fcm {
    email: String,
    key: jsonwebtoken::EncodingKey,
    project: String,
    token_uri: String,
    token: tokio::sync::Mutex<Option<(String, Instant)>>,
}

pub enum Outcome {
    Sent,
    DeadToken,
    Failed,
}

impl Push {
    pub fn new(cfg: &crate::config::Config) -> Self {
        let b64 = base64::engine::general_purpose::STANDARD;
        let apns = match (&cfg.apns_key_base64, &cfg.apns_key_id, &cfg.apns_team_id) {
            (Some(k), Some(id), Some(team)) => b64
                .decode(k.trim())
                .ok()
                .and_then(|pem| jsonwebtoken::EncodingKey::from_ec_pem(&pem).ok())
                .map(|key| Apns {
                    key,
                    key_id: id.clone(),
                    team_id: team.clone(),
                    topic: cfg.apns_topic.clone(),
                    host: if cfg.apns_use_sandbox { "https://api.sandbox.push.apple.com" } else { "https://api.push.apple.com" },
                    token: Mutex::new(None),
                })
                .or_else(|| {
                    tracing::warn!("APNs client init failed, push notifications disabled");
                    None
                }),
            _ => None,
        };
        let fcm = cfg.fcm_service_account_json_base64.as_ref().and_then(|b| {
            let sa: Value = serde_json::from_slice(&b64.decode(b.trim()).ok()?).ok()?;
            let key = jsonwebtoken::EncodingKey::from_rsa_pem(sa["private_key"].as_str()?.as_bytes()).ok()?;
            Some(Fcm {
                email: sa["client_email"].as_str()?.to_string(),
                key,
                project: sa["project_id"].as_str()?.to_string(),
                token_uri: sa["token_uri"].as_str().unwrap_or("https://oauth2.googleapis.com/token").to_string(),
                token: tokio::sync::Mutex::new(None),
            })
        });
        if cfg.fcm_service_account_json_base64.is_some() && fcm.is_none() {
            tracing::warn!("FCM app init failed, Android push notifications disabled");
        }
        let http = reqwest::Client::builder().timeout(Duration::from_secs(15)).build().expect("push client");
        Self { apns, fcm, http }
    }

    pub fn enabled(&self) -> bool {
        self.apns.is_some() || self.fcm.is_some()
    }

    pub fn has_apns(&self) -> bool {
        self.apns.is_some()
    }

    pub fn has_fcm(&self) -> bool {
        self.fcm.is_some()
    }

    fn apns_token(a: &Apns) -> Option<String> {
        let mut g = a.token.lock().unwrap();
        if let Some((t, at)) = g.as_ref() {
            if at.elapsed() < Duration::from_secs(50 * 60) {
                return Some(t.clone());
            }
        }
        let mut h = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::ES256);
        h.kid = Some(a.key_id.clone());
        let t = jsonwebtoken::encode(&h, &json!({"iss": a.team_id, "iat": chrono::Utc::now().timestamp()}), &a.key).ok()?;
        *g = Some((t.clone(), Instant::now()));
        Some(t)
    }

    pub async fn apns(&self, device: &str, payload: &Value) -> Outcome {
        let Some(a) = &self.apns else { return Outcome::Failed };
        let Some(tok) = Self::apns_token(a) else { return Outcome::Failed };
        let r = self
            .http
            .post(format!("{}/3/device/{device}", a.host))
            .bearer_auth(tok)
            .header("apns-topic", &a.topic)
            .header("apns-push-type", "alert")
            .json(payload)
            .send()
            .await;
        match r {
            Ok(r) if r.status().is_success() => Outcome::Sent,
            Ok(r) => {
                let code = r.status().as_u16();
                let reason = r.json::<Value>().await.ok().and_then(|v| v["reason"].as_str().map(str::to_string)).unwrap_or_default();
                if code == 410 || reason == "Unregistered" || reason == "BadDeviceToken" { Outcome::DeadToken } else { Outcome::Failed }
            }
            Err(e) => {
                tracing::debug!("APNs send failed: {e}");
                Outcome::Failed
            }
        }
    }

    async fn fcm_token(&self, f: &Fcm) -> Option<String> {
        let mut g = f.token.lock().await;
        if let Some((t, exp)) = g.as_ref() {
            if Instant::now() < *exp {
                return Some(t.clone());
            }
        }
        let now = chrono::Utc::now().timestamp();
        let claims = json!({"iss": f.email, "scope": "https://www.googleapis.com/auth/firebase.messaging", "aud": f.token_uri, "iat": now, "exp": now + 3600});
        let assertion = jsonwebtoken::encode(&jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256), &claims, &f.key).ok()?;
        let v: Value = self
            .http
            .post(&f.token_uri)
            .form(&[("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"), ("assertion", assertion.as_str())])
            .send()
            .await
            .ok()?
            .json()
            .await
            .ok()?;
        let t = v["access_token"].as_str()?.to_string();
        let ttl = v["expires_in"].as_u64().unwrap_or(3600).saturating_sub(120);
        *g = Some((t.clone(), Instant::now() + Duration::from_secs(ttl)));
        Some(t)
    }

    /// FCM message: data values stringified (non-strings JSON-encoded), plus
    /// a visible notification unless this is a content-available push.
    pub async fn fcm(&self, device: &str, kind: &str, title: &str, body: &str, data: &Value, content_available: bool) -> Outcome {
        let Some(f) = &self.fcm else { return Outcome::Failed };
        let Some(tok) = self.fcm_token(f).await else { return Outcome::Failed };
        let mut d = serde_json::Map::new();
        d.insert("type".into(), json!(kind));
        if let Some(o) = data.as_object() {
            for (k, v) in o {
                d.insert(k.clone(), json!(match v { Value::String(s) => s.clone(), other => other.to_string() }));
            }
        }
        d.insert("title".into(), json!(title));
        d.insert("body".into(), json!(body));
        let mut msg = json!({"token": device, "data": d, "android": {"priority": "HIGH"}});
        if !content_available {
            msg["notification"] = json!({"title": title, "body": body});
        }
        let r = self
            .http
            .post(format!("https://fcm.googleapis.com/v1/projects/{}/messages:send", f.project))
            .bearer_auth(tok)
            .json(&json!({"message": msg}))
            .send()
            .await;
        match r {
            Ok(r) if r.status().is_success() => Outcome::Sent,
            Ok(r) => {
                let v: Value = r.json().await.unwrap_or_default();
                let unreg = v["error"]["details"].as_array().is_some_and(|a| a.iter().any(|e| e["errorCode"] == "UNREGISTERED"))
                    || v["error"]["status"] == "NOT_FOUND";
                if unreg { Outcome::DeadToken } else { Outcome::Failed }
            }
            Err(e) => {
                tracing::debug!("FCM send failed: {e}");
                Outcome::Failed
            }
        }
    }
}

impl AppState {
    /// `_send_push_best_effort`: every registered device of the user; dead tokens pruned.
    pub async fn send_push(&self, user_id: &str, kind: &str, title: &str, body: &str, data: &Value, content_available: bool) {
        if !self.push.enabled() {
            return;
        }
        let rows: Vec<(String, Option<String>)> = match sqlx::query_as("SELECT device_token, platform FROM ios_push_tokens WHERE user_id = $1").bind(user_id).fetch_all(&self.db).await {
            Ok(r) => r,
            Err(e) => {
                tracing::debug!("push token lookup failed: {e}");
                return;
            }
        };
        let mut dead = Vec::new();
        for (token, platform) in rows {
            let out = if platform.as_deref() == Some("android") {
                if !self.push.has_fcm() {
                    continue;
                }
                self.push.fcm(&token, kind, title, body, data, content_available).await
            } else {
                if !self.push.has_apns() {
                    continue;
                }
                let mut aps = json!({"alert": {"title": title, "body": body}, "sound": "default"});
                if content_available {
                    aps["content-available"] = json!(1);
                }
                self.push.apns(&token, &json!({"aps": aps, "type": kind, "data": if data.is_null() { json!({}) } else { data.clone() }})).await
            };
            if matches!(out, Outcome::DeadToken) {
                dead.push(token);
            }
        }
        if !dead.is_empty() {
            let _ = sqlx::query("DELETE FROM ios_push_tokens WHERE device_token = ANY($1)").bind(&dead).execute(&self.db).await;
        }
    }
}
