//! App logging: buffered upload to the bridge's `/internal/logs` (every 15 s,
//! immediately on errors, requeued on failure), identical-repeat collapsing,
//! the bug-report "recent activity" buffer, crash breadcrumbs that survive a
//! crash and get reported on the next launch, and one-off structured events
//! for `/api/log-event`. Swift only forwards calls (and prints in DEBUG).

use crate::store;
use serde::Serialize;
use serde_json::{Map, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

const MAX_BUFFER: usize = 1_000;
const MAX_RECENT: usize = 50;
const MAX_BREADCRUMBS: usize = 12;
const REPEAT_WINDOW: Duration = Duration::from_secs(60);
const FLUSH_EVERY: Duration = Duration::from_secs(15);
const BREADCRUMBS: &str = "crash_breadcrumbs";

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
struct Entry {
    level: String,
    category: String,
    message: String,
    file: String,
    line: i64,
    timestamp: String,
    extra: HashMap<String, String>,
    device_model: String,
    os_version: String,
    app_version: String,
    user_id: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct LogContext {
    pub bridge_url: String,
    pub platform: String,
    pub device_model: String,
    pub os_version: String,
    pub app_version: String,
    pub build: String,
}

#[derive(Default)]
struct State {
    ctx: Option<LogContext>,
    buffer: VecDeque<Entry>,
    recent: VecDeque<Entry>,
    first_seen: HashMap<(String, String, String), Instant>,
    suppressed: HashMap<(String, String, String), u32>,
    breadcrumbs: Vec<String>,
    flush_loop: bool,
    /// Events logged before `logger_configure` (sent once it runs).
    pending_events: Vec<PendingEvent>,
}

struct PendingEvent {
    category: String,
    event: String,
    level: String,
    message: String,
    detail_json: Option<String>,
    auth_token: Option<String>,
}

static ST: LazyLock<Mutex<State>> = LazyLock::new(Default::default);

/// ISO 8601 with milliseconds (bursts of events within one second stay ordered).
#[uniffi::export]
pub fn log_timestamp_now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// Digits normalised out, first 120 chars: lines differing only by an id,
/// level reading or byte count count as the same message.
fn signature(m: &str) -> String {
    m.chars().map(|c| if c.is_numeric() { '#' } else { c }).take(120).collect()
}

impl State {
    fn push_buffer(&mut self, e: Entry) {
        self.buffer.push_back(e);
        while self.buffer.len() > MAX_BUFFER {
            self.buffer.pop_front();
        }
    }

    /// True when `e` is a repeat inside the window (dropped from upload). When
    /// a window closes, a "(repeated Nx …)" line reports what was swallowed.
    fn collapse(&mut self, e: &Entry, local_only: bool, now: Instant) -> bool {
        let key = (e.level.clone(), e.category.clone(), signature(&e.message));
        let Some(first) = self.first_seen.get(&key).copied() else {
            self.first_seen.insert(key, now);
            return false;
        };
        if now.duration_since(first) < REPEAT_WINDOW {
            *self.suppressed.entry(key).or_default() += 1;
            return true;
        }
        let n = self.suppressed.remove(&key).unwrap_or(0);
        self.first_seen.insert(key, now);
        if n > 0 && !local_only {
            let mut s = e.clone();
            s.message = format!("(repeated {n}x in the last {}s) {}", REPEAT_WINDOW.as_secs(), e.message);
            s.timestamp = log_timestamp_now();
            self.push_buffer(s);
        }
        false
    }

    fn append(&mut self, e: Entry, local_only: bool) {
        let collapsed = self.collapse(&e, local_only, Instant::now());
        if !local_only && !collapsed {
            self.push_buffer(e.clone());
        }
        self.recent.push_back(e);
        while self.recent.len() > MAX_RECENT {
            self.recent.pop_front();
        }
    }

    fn entry(&self, level: &str, category: &str, message: String, file: &str, line: i64, extra: HashMap<String, String>, user_id: Option<String>) -> Entry {
        let c = self.ctx.clone().unwrap_or_default();
        let file = std::path::Path::new(file).file_name().and_then(|f| f.to_str()).unwrap_or(file).to_string();
        Entry { level: level.into(), category: category.into(), message, file, line, timestamp: log_timestamp_now(), extra, device_model: c.device_model, os_version: c.os_version, app_version: c.app_version, user_id }
    }
}

/// Call once at launch. Reports a breadcrumb trail left by a session that
/// never shut down cleanly (`legacy_breadcrumbs`: the UserDefaults-era
/// trail, imported once), logs "App launched" and starts the flush loop.
#[uniffi::export]
pub fn logger_configure(ctx: LogContext, legacy_breadcrumbs: Vec<String>) {
    let mut s = ST.lock().unwrap();
    if s.ctx.is_some() {
        return;
    }
    s.ctx = Some(ctx);
    let mut prior: Vec<String> = store::load(BREADCRUMBS);
    if prior.is_empty() {
        prior = legacy_breadcrumbs;
    }
    if !prior.is_empty() {
        let e = s.entry("warning", "app", format!("Possible unclean shutdown — last actions before previous session ended: {}", prior.join("  →  ")), "AppLogger.swift", 0, HashMap::new(), None);
        s.append(e, false);
        store::save(BREADCRUMBS, &Vec::<String>::new());
    }
    let e = s.entry("info", "app", "App launched".into(), "LumisoundApp.swift", 0, HashMap::new(), None);
    s.append(e, false);
    let pending = std::mem::take(&mut s.pending_events);
    drop(s);
    for p in pending {
        logger_event(p.category, p.event, p.level, p.message, p.detail_json, p.auth_token);
    }
    let mut s = ST.lock().unwrap();
    if !s.flush_loop {
        s.flush_loop = true;
        crate::RT.spawn(async {
            let mut tick = tokio::time::interval(FLUSH_EVERY);
            loop {
                tick.tick().await;
                flush().await;
            }
        });
    }
}

/// Record one log line. Errors trigger an immediate upload. `local_only`
/// lines stay on the device (recent-activity buffer only).
#[uniffi::export]
pub fn logger_log(level: String, category: String, message: String, file: String, line: i64, extra: HashMap<String, String>, local_only: bool, user_id: Option<String>) {
    {
        let mut s = ST.lock().unwrap();
        let e = s.entry(&level, &category, message, &file, line, extra, user_id);
        s.append(e, local_only);
    }
    if level == "error" {
        crate::RT.spawn(flush());
    }
}

/// A discrete significant action, persisted immediately so a crash leaves it
/// on disk for the next launch to report.
#[uniffi::export]
pub fn logger_breadcrumb(event: String) {
    let mut s = ST.lock().unwrap();
    s.breadcrumbs.push(format!("{} — {event}", log_timestamp_now()));
    let n = s.breadcrumbs.len();
    if n > MAX_BREADCRUMBS {
        s.breadcrumbs.drain(..n - MAX_BREADCRUMBS);
    }
    store::save(BREADCRUMBS, &s.breadcrumbs);
}

/// Breadcrumbs plus the last 50 log lines, for bug reports.
#[uniffi::export]
pub fn logger_recent_activity() -> String {
    let s = ST.lock().unwrap();
    let mut lines = Vec::new();
    if !s.breadcrumbs.is_empty() {
        lines.push("Recent activity:".to_string());
        lines.extend(s.breadcrumbs.iter().cloned());
    }
    if !s.recent.is_empty() {
        lines.push("Recent logs:".to_string());
        lines.extend(s.recent.iter().map(|e| format!("[{}][{}] {}", e.level, e.category, e.message)));
    }
    lines.join("\n")
}

fn base_url(s: &State) -> Option<String> {
    let b = s.ctx.as_ref()?.bridge_url.trim_matches('/').to_string();
    (!b.is_empty()).then_some(b)
}

/// Upload the buffer now. Anything that fails (transport or non-2xx — the
/// endpoint answers 204) goes back to the front of the buffer.
#[uniffi::export]
pub async fn logger_flush() {
    crate::on_rt(flush()).await
}

async fn flush() {
    let (entries, url) = {
        let mut s = ST.lock().unwrap();
        let Some(base) = base_url(&s) else { return };
        if s.buffer.is_empty() {
            return;
        }
        (std::mem::take(&mut s.buffer), format!("{base}/internal/logs"))
    };
    let list: Vec<&Entry> = entries.iter().collect();
    let ok = match crate::client::http_client().post(&url).timeout(Duration::from_secs(10)).json(&list).send().await {
        Ok(r) => r.status().is_success(),
        Err(_) => false,
    };
    if !ok {
        let mut s = ST.lock().unwrap();
        let room = MAX_BUFFER.saturating_sub(s.buffer.len());
        let keep: Vec<Entry> = entries.into_iter().rev().take(room).collect();
        for e in keep {
            s.buffer.push_front(e);
        }
    }
}

/// One structured event to `/api/log-event` (fire-and-forget, never
/// retried). `detail_json` is an object; platform/build/OS are stamped on.
#[uniffi::export]
pub fn logger_event(category: String, event: String, level: String, message: String, detail_json: Option<String>, auth_token: Option<String>) {
    let (url, ctx) = {
        let mut s = ST.lock().unwrap();
        let Some(base) = base_url(&s) else {
            if s.ctx.is_none() && s.pending_events.len() < 50 {
                s.pending_events.push(PendingEvent { category, event, level, message, detail_json, auth_token });
            }
            return;
        };
        (format!("{base}/api/log-event"), s.ctx.clone().unwrap_or_default())
    };
    let mut detail: Map<String, Value> = detail_json.and_then(|j| serde_json::from_str(&j).ok()).unwrap_or_default();
    detail.insert("platform".into(), Value::String(ctx.platform));
    detail.insert("appVersion".into(), Value::String(ctx.app_version));
    detail.insert("build".into(), Value::String(ctx.build));
    detail.insert("deviceModel".into(), Value::String(ctx.device_model));
    if ctx.platform == "tvos" {
        // tvOS events have always carried this name; keep queries working.
        detail.insert("tvosVersion".into(), Value::String(ctx.os_version.clone()));
    }
    detail.insert("osVersion".into(), Value::String(ctx.os_version));
    let body = serde_json::json!({"category": category, "event": event, "level": level, "message": message, "detail": detail});
    crate::RT.spawn(async move {
        let mut rq = crate::client::http_client().post(&url).timeout(Duration::from_secs(10)).json(&body);
        if let Some(t) = auth_token {
            rq = rq.bearer_auth(t);
        }
        let _ = rq.send().await;
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collapses_repeats_and_reports_count() {
        let mut s = State::default();
        let mk = |m: &str| Entry { level: "info".into(), category: "c".into(), message: m.into(), file: "f".into(), line: 1, timestamp: String::new(), extra: HashMap::new(), device_model: String::new(), os_version: String::new(), app_version: String::new(), user_id: None };
        let t0 = Instant::now();
        assert!(!s.collapse(&mk("job 1 done"), false, t0));
        assert!(s.collapse(&mk("job 2 done"), false, t0 + Duration::from_secs(5)));
        assert!(s.collapse(&mk("job 3 done"), false, t0 + Duration::from_secs(10)));
        assert!(!s.collapse(&mk("other"), false, t0 + Duration::from_secs(10)));
        assert!(!s.collapse(&mk("job 4 done"), false, t0 + Duration::from_secs(61)));
        assert_eq!(s.buffer.len(), 1);
        assert!(s.buffer[0].message.starts_with("(repeated 2x in the last 60s) job 4 done"));
        assert_eq!(signature("a1b22"), "a#b##");
    }

    #[test]
    fn recent_buffer_and_local_only() {
        let mut s = State::default();
        for i in 0..60 {
            let e = s.entry("info", "c", format!("unique message {}", "x".repeat(i)), "/a/b/File.swift", 3, HashMap::new(), None);
            s.append(e, i % 2 == 0);
        }
        assert_eq!(s.recent.len(), MAX_RECENT);
        assert_eq!(s.buffer.len(), 30);
        assert_eq!(s.recent[0].file, "File.swift");
        let ts = log_timestamp_now();
        assert!(ts.ends_with('Z') && ts.contains('.'), "{ts}");
    }
}
