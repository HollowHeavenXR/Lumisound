//! Gemini over REST (port of intelligence.call_intelligence and the
//! lyrics_ai transport): structured-JSON generateContent with retries,
//! per-task 429 cooldowns and optional inline image/audio parts.

use crate::state::AppState;
use base64::Engine;
use dashmap::DashMap;
use serde_json::{Value, json};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

pub const COOLDOWN: Duration = Duration::from_secs(300);
const RETRYABLE: [u16; 4] = [500, 502, 503, 504];

pub fn prompts() -> &'static Value {
    static P: OnceLock<Value> = OnceLock::new();
    P.get_or_init(|| serde_json::from_str(include_str!("prompts.json")).expect("prompts.json"))
}

pub fn prompt(name: &str) -> &'static str {
    prompts()[name].as_str().unwrap_or_default()
}

pub fn schema(name: &str) -> Value {
    prompts()[name].clone()
}

pub fn model() -> String {
    std::env::var("LUMISOUND_GEMINI_MODEL").unwrap_or_else(|_| "gemini-3.6-flash".into())
}

pub fn fallback_model() -> String {
    std::env::var("LUMISOUND_GEMINI_LYRICS_FALLBACK_MODEL").unwrap_or_else(|_| "gemini-3.5-flash".into())
}

/// Python json.dumps(v, sort_keys=...) with the default ", " / ": "
/// separators and ensure_ascii, so cache keys match the Python bridge.
pub fn py_dumps(v: &Value, sort_keys: bool) -> String {
    fn esc(s: &str, out: &mut String) {
        out.push('"');
        for c in s.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                '\u{8}' => out.push_str("\\b"),
                '\u{c}' => out.push_str("\\f"),
                c if (c as u32) < 0x20 || (c as u32) > 0x7e => {
                    let mut b = [0u16; 2];
                    for u in c.encode_utf16(&mut b) {
                        out.push_str(&format!("\\u{:04x}", u));
                    }
                }
                c => out.push(c),
            }
        }
        out.push('"');
    }
    fn go(v: &Value, sort: bool, out: &mut String) {
        match v {
            Value::Null => out.push_str("null"),
            Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Value::Number(n) => {
                if let Some(f) = n.as_f64().filter(|_| n.is_f64()) {
                    out.push_str(&crate::probe::py_float(f));
                } else {
                    out.push_str(&n.to_string());
                }
            }
            Value::String(s) => esc(s, out),
            Value::Array(a) => {
                out.push('[');
                for (i, x) in a.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    go(x, sort, out);
                }
                out.push(']');
            }
            Value::Object(o) => {
                out.push('{');
                let mut keys: Vec<&String> = o.keys().collect();
                if sort {
                    keys.sort();
                }
                for (i, k) in keys.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    esc(k, out);
                    out.push_str(": ");
                    go(&o[*k], sort, out);
                }
                out.push('}');
            }
        }
    }
    let mut s = String::new();
    go(v, sort_keys, &mut s);
    s
}

/// The REST API wants OpenAPI type names in upper case.
fn rest_schema(v: &Value) -> Value {
    match v {
        Value::Object(o) => Value::Object(
            o.iter()
                .map(|(k, x)| {
                    let x = if k == "type" { json!(x.as_str().unwrap_or("").to_uppercase()) } else { rest_schema(x) };
                    (k.clone(), x)
                })
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.iter().map(rest_schema).collect()),
        x => x.clone(),
    }
}

pub struct Gemini {
    pub cooldown: DashMap<String, Instant>,
}

pub enum CallError {
    Status(u16, String),
    Other(String),
}

impl Gemini {
    pub fn new() -> Self {
        Self { cooldown: DashMap::new() }
    }

    pub fn cooling(&self, task: &str) -> bool {
        self.cooldown.get(task).is_some_and(|t| Instant::now() < *t)
    }

    pub fn start_cooldown(&self, task: &str) {
        self.cooldown.insert(task.to_string(), Instant::now() + COOLDOWN);
    }
}

impl AppState {
    /// One generateContent request; returns the response text.
    pub async fn gemini_raw(&self, model: &str, system: &str, parts: Vec<Value>, schema: &Value, timeout: Duration) -> Result<String, CallError> {
        let key = self.cfg.gemini_api_key.clone().ok_or_else(|| CallError::Other("no key".into()))?;
        let body = json!({
            "systemInstruction": {"parts": [{"text": system}]},
            "contents": [{"role": "user", "parts": parts}],
            "generationConfig": {"responseMimeType": "application/json", "responseSchema": rest_schema(schema)},
        });
        let r = self
            .http
            .post(format!("https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"))
            .header("x-goog-api-key", key)
            .json(&body)
            .timeout(timeout)
            .send()
            .await
            .map_err(|e| CallError::Other(e.to_string()))?;
        let status = r.status().as_u16();
        let v: Value = r.json().await.unwrap_or_default();
        if !(200..300).contains(&status) {
            return Err(CallError::Status(status, v["error"]["message"].as_str().unwrap_or("").chars().take(300).collect()));
        }
        let text: String = v["candidates"][0]["content"]["parts"].as_array().into_iter().flatten().filter_map(|p| p["text"].as_str()).collect();
        let text = text.trim().to_string();
        if text.is_empty() {
            return Err(CallError::Other("Gemini returned an empty response".into()));
        }
        Ok(text)
    }

    async fn image_part(&self, url: &str) -> Option<Value> {
        let r = self.http.get(url).header("User-Agent", "Mozilla/5.0 (compatible; LumisoundBridge/1.0)").timeout(Duration::from_secs(10)).send().await.ok()?;
        let ct = r.headers().get("content-type").and_then(|v| v.to_str().ok()).map(|s| s.split(';').next().unwrap_or("").trim().to_string()).filter(|s| !s.is_empty()).unwrap_or_else(|| "image/jpeg".into());
        let b = r.bytes().await.ok()?;
        Some(json!({"inlineData": {"mimeType": ct, "data": base64::engine::general_purpose::STANDARD.encode(&b)}}))
    }

    /// `call_intelligence`: None when unconfigured, cooling down or failed.
    pub async fn intelligence(&self, task: &str, system_prompt: &str, input: &Value, schema: &Value, image_urls: &[String]) -> Option<Value> {
        self.cfg.gemini_api_key.as_ref()?;
        if self.gemini.cooling(task) {
            return None;
        }
        let mut parts = vec![json!({"text": py_dumps(input, false)})];
        for u in image_urls.iter().take(8) {
            match self.image_part(u).await {
                Some(p) => parts.push(p),
                None => tracing::warn!("failed to fetch image for vision input: {u}"),
            }
        }
        let system = format!("{}\n{}", prompt("ARIA_PERSONA"), system_prompt);
        let model = model();
        let mut last: Option<CallError> = None;
        for attempt in 0..3 {
            match self.gemini_raw(&model, &system, parts.clone(), schema, Duration::from_secs(120)).await {
                Ok(text) => match serde_json::from_str::<Value>(&text) {
                    Ok(v) => {
                        let (st, t, m) = (self.clone(), task.to_string(), model.clone());
                        tokio::spawn(async move { crate::db::log_event(&st.db, "intelligence", "analysis_completed", None, "info", "", Some(json!({"task": t, "model": m}))).await });
                        return Some(v);
                    }
                    Err(e) => {
                        last = Some(CallError::Other(e.to_string()));
                        break;
                    }
                },
                Err(CallError::Status(c, m)) if RETRYABLE.contains(&c) && attempt < 2 => {
                    let d = 1.5 * (attempt + 1) as f64;
                    tracing::info!("intelligence task {task} got {c}; retrying in {d:.1}s");
                    last = Some(CallError::Status(c, m));
                    tokio::time::sleep(Duration::from_secs_f64(d)).await;
                }
                Err(e) => {
                    last = Some(e);
                    break;
                }
            }
        }
        let (level, event, msg) = match &last {
            Some(CallError::Status(429, _)) => {
                self.gemini.start_cooldown(task);
                tracing::warn!("intelligence task {task} rate-limited; cooling down 300s");
                ("warn", "analysis_rate_limited", "cooling down 300s".to_string())
            }
            Some(CallError::Status(c, m)) => ("error", "analysis_failed", format!("{c} {m}")),
            Some(CallError::Other(m)) => ("error", "analysis_failed", m.clone()),
            None => ("error", "analysis_failed", "unknown".into()),
        };
        if event == "analysis_failed" {
            tracing::error!("intelligence task {task} failed: {msg}");
        }
        let (st, t) = (self.clone(), task.to_string());
        tokio::spawn(async move { crate::db::log_event(&st.db, "intelligence", event, None, level, &msg.chars().take(500).collect::<String>(), Some(json!({"task": t}))).await });
        None
    }

    pub async fn recent_corrections(&self, task: &str) -> Value {
        let rows: Vec<(String, String, String)> = sqlx::query_as(
            "SELECT input_json, ai_result_json, correction_json FROM ios_aria_memory WHERE task = $1 AND correction_json IS NOT NULL ORDER BY created_at DESC LIMIT 5",
        )
        .bind(task)
        .fetch_all(&self.db)
        .await
        .unwrap_or_default();
        Value::Array(
            rows.into_iter()
                .map(|(i, a, c)| {
                    let p = |s: &str| serde_json::from_str::<Value>(s).unwrap_or(Value::Null);
                    json!({"input": p(&i), "aria_picked": p(&a), "user_corrected_to": p(&c)})
                })
                .collect(),
        )
    }

    pub async fn record_suggestion(&self, task: &str, user: &str, input: &Value, result: &Value) -> Option<i64> {
        sqlx::query_scalar("INSERT INTO ios_aria_memory (user_id, task, input_json, ai_result_json) VALUES ($1, $2, $3, $4) RETURNING id::bigint")
            .bind(user)
            .bind(task)
            .bind(py_dumps(input, false))
            .bind(py_dumps(result, false))
            .fetch_one(&self.db)
            .await
            .map_err(|e| tracing::error!("failed to record ios_aria_memory suggestion for task {task}: {e}"))
            .ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dumps_like_python() {
        let v = json!({"b": 1, "a": [1.5, "é", null], "c": {"x": true}});
        assert_eq!(py_dumps(&v, true), r#"{"a": [1.5, "\u00e9", null], "b": 1, "c": {"x": true}}"#);
        assert!(prompt("ARIA_PERSONA").starts_with("You are Aria Lumi"));
    }
}
