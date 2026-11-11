//! Lumisound Discord Rich Presence daemon. Polls the bridge for the account's
//! playback state and mirrors it into Discord through the local IPC socket
//! (named pipe on Windows). `lumisound-discord-rpc login` performs the
//! one-time sign-in and stores a long-lived Rich Presence token.

mod ipc;
mod login;

use serde_json::{Value, json};
use std::path::PathBuf;
use std::time::{Duration, Instant};

pub const DEFAULT_BRIDGE_URL: &str = "https://lumisound-bridge.xenusanimations.studio";
const STALE_AFTER_SECS: f64 = 120.0;
const MIN_SEND_INTERVAL_SECS: f64 = 4.5;

pub fn log(msg: &str) {
    println!("{}  {msg}", chrono::Local::now().format("%Y-%m-%d %H:%M:%S"));
}

/// Same lookup order as the Python daemon so existing installs keep working.
pub fn default_config_path() -> PathBuf {
    if let Ok(p) = std::env::var("LUMISOUND_RPC_CONFIG") {
        return PathBuf::from(p);
    }
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from).unwrap_or_default();
    let legacy = home.join(".config").join("lumisound-discord-rpc").join("config.json");
    if cfg!(windows) {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            let win = PathBuf::from(appdata).join("lumisound-discord-rpc").join("config.json");
            return if legacy.exists() && !win.exists() { legacy } else { win };
        }
        return legacy;
    }
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
        return PathBuf::from(xdg).join("lumisound-discord-rpc").join("config.json");
    }
    legacy
}

pub fn write_config(path: &PathBuf, config: &Value) -> std::io::Result<()> {
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d)?;
    }
    std::fs::write(path, serde_json::to_string_pretty(config).unwrap_or_default() + "\n")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

struct Bridge {
    base: String,
    token: Option<String>,
    http: reqwest::blocking::Client,
}

impl Bridge {
    fn get(&self, path: &str) -> Result<Value, String> {
        let mut rq = self.http.get(format!("{}{path}", self.base)).header("User-Agent", "lumisound-discord-rpc/2.0");
        if let Some(t) = &self.token {
            rq = rq.bearer_auth(t);
        }
        let r = rq.send().map_err(|e| e.to_string())?;
        let status = r.status().as_u16();
        if status == 401 {
            return Err("401: the Rich Presence token was revoked or expired — run `lumisound-discord-rpc login`".into());
        }
        if !(200..300).contains(&status) {
            return Err(format!("HTTP {status}"));
        }
        r.json().map_err(|e| e.to_string())
    }
}

fn sampled_at(state: &Value) -> Option<f64> {
    let raw = state["updated_at"].as_str()?;
    chrono::DateTime::parse_from_rfc3339(raw).ok().map(|d| d.timestamp_millis() as f64 / 1000.0)
}

fn now() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64 / 1000.0
}

/// YouTube video id from an `i.ytimg.com` / `img.youtube.com` thumbnail URL.
fn youtube_thumb_id(url: &str) -> Option<&str> {
    let rest = ["https://i.ytimg.com/vi/", "https://img.youtube.com/vi/", "https://i.ytimg.com/vi_webp/"].iter().find_map(|p| url.strip_prefix(p))?;
    let id = rest.split('/').next()?;
    (id.len() == 11 && id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')).then_some(id)
}

/// The art URL Discord should show. Discord draws presence art square and
/// crops anything else, so a YouTube thumbnail is swapped for the bridge's
/// shaped copy (`/api/rp-art/yt/{id}.jpg`): the full 16:9 frame over a
/// blurred fill instead of the middle third of it. Bridge-hosted art
/// (`/api/rp-artwork/...`) is already shaped when it is uploaded.
pub fn presence_art(art: &str, bridge_base: &str) -> String {
    match youtube_thumb_id(art) {
        Some(id) if !bridge_base.is_empty() => format!("{bridge_base}/api/rp-art/yt/{id}.jpg"),
        _ => art.to_string(),
    }
}

/// Third line of the card (Discord shows the large image's text there). It
/// used to repeat the title; now it says how the track is being played, e.g.
/// "Rust engine · LMS OPUS · 48 kHz · 124 BPM".
fn info_line(state: &Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    match state["engine"].as_str().map(str::trim).filter(|s| !s.is_empty()) {
        Some(e) => parts.push(e.to_string()),
        None => parts.push("Lumisound".into()),
    }
    if let Some(bpm) = state["bpm"].as_f64().filter(|b| b.is_finite() && *b > 0.0) {
        let tag = format!("{} BPM", bpm.round() as i64);
        if !parts.iter().any(|p| p.contains("BPM")) {
            parts.push(tag);
        }
    }
    parts.join(" · ")
}

/// Discord activity for a playback state, or None to clear it.
pub fn build_activity(state: &Value, bridge_base: &str, large_image: Option<&str>, small_image: Option<&str>, show_buttons: bool, show_when_paused: bool) -> Option<Value> {
    let title = state["title"].as_str().map(str::trim).filter(|t| !t.is_empty())?;
    let playing = state["is_playing"].as_bool().unwrap_or(false);
    if !playing && !show_when_paused {
        return None;
    }
    let sampled = sampled_at(state);
    if sampled.is_some_and(|s| now() - s > STALE_AFTER_SECS) {
        return None;
    }
    // Discord wants 2..=128 characters per text field.
    let cut = |s: &str| {
        let t: String = s.chars().take(128).collect();
        if t.chars().count() < 2 { format!("{t} ") } else { t }
    };
    let mut a = json!({"type": 2, "details": cut(title)});
    if let Some(artist) = state["artist"].as_str().map(str::trim).filter(|s| !s.is_empty()) {
        a["state"] = json!(cut(&format!("by {artist}")));
    }
    if playing {
        let pos = state["position_seconds"].as_f64().unwrap_or(0.0).max(0.0);
        let start = sampled.unwrap_or_else(now) - pos;
        let mut ts = json!({"start": (start * 1000.0).round() as i64});
        // With an end as well, Discord draws the progress bar and both times
        // for a Listening activity, matching the app's own scrubber.
        if let Some(dur) = state["duration_seconds"].as_f64().filter(|d| d.is_finite() && *d > pos && *d > 1.0) {
            ts["end"] = json!(((start + dur) * 1000.0).round() as i64);
        }
        a["timestamps"] = ts;
    }
    let art = state["artwork_url"].as_str().filter(|s| s.starts_with("https://") || s.starts_with("http://")).map(|s| presence_art(s, bridge_base));
    let mut assets = serde_json::Map::new();
    if let Some(img) = art.as_deref().or(large_image) {
        assets.insert("large_image".into(), json!(img));
        assets.insert("large_text".into(), json!(cut(&info_line(state))));
    }
    if let (Some(small), Some(_)) = (small_image, art.as_deref()) {
        assets.insert("small_image".into(), json!(small));
        assets.insert("small_text".into(), json!(if playing { "Playing on Lumisound" } else { "Paused" }));
    }
    if !assets.is_empty() {
        a["assets"] = Value::Object(assets);
    }
    if show_buttons {
        if let Some(url) = state["track_url"].as_str().filter(|s| s.starts_with("https://")) {
            a["buttons"] = json!([{"label": "Listen", "url": url}]);
        }
    }
    Some(a)
}

/// What decides whether an activity must be re-sent right away: any text or
/// art change, play/pause, or a timeline jump (seek) of more than 1.5 s.
fn needs_send(prev: Option<&Value>, next: Option<&Value>) -> bool {
    match (prev, next) {
        (None, None) => false,
        (Some(p), Some(n)) => {
            let strip = |v: &Value| {
                let mut v = v.clone();
                v.as_object_mut().map(|o| o.remove("timestamps"));
                v
            };
            if strip(p) != strip(n) {
                return true;
            }
            let ms = |v: &Value, k: &str| v["timestamps"][k].as_i64();
            let jump = |k: &str| match (ms(p, k), ms(n, k)) {
                (Some(a), Some(b)) => (a - b).abs() > 1500,
                (a, b) => a.is_some() != b.is_some(),
            };
            jump("start") || jump("end")
        }
        _ => true,
    }
}

fn run() -> Result<(), String> {
    let path = default_config_path();
    let raw = std::fs::read_to_string(&path).map_err(|_| format!("No config at {} — run `lumisound-discord-rpc login` first.", path.display()))?;
    let config: Value = serde_json::from_str(&raw).map_err(|e| format!("config.json is not valid JSON: {e}"))?;
    let bridge = Bridge {
        base: config["bridge_url"].as_str().unwrap_or(DEFAULT_BRIDGE_URL).trim_end_matches('/').to_string(),
        token: config["access_token"].as_str().map(str::to_string),
        http: reqwest::blocking::Client::builder().timeout(Duration::from_secs(10)).build().map_err(|e| e.to_string())?,
    };
    if bridge.token.is_none() {
        return Err("config.json has no access_token — run `lumisound-discord-rpc login`.".into());
    }
    let mut rpc = loop {
        match bridge.get("/user/discord-rpc-config") {
            Ok(v) => break v,
            Err(e) => {
                log(&format!("bridge not ready ({e}); retrying in 10s"));
                std::thread::sleep(Duration::from_secs(10));
            }
        }
    };
    let pick = |k: &str, rpc: &Value| config[k].as_str().or(rpc[k].as_str()).map(str::to_string);
    let mut client_id = pick("discord_client_id", &rpc).ok_or("no Discord client id (set discord_client_id)")?;
    let poll = Duration::from_secs_f64(config["poll_interval_seconds"].as_f64().unwrap_or(1.0).max(0.5));
    let mut conn = ipc::Ipc::new(&client_id);
    let (mut last_activity, mut last_sent) = (None::<Value>, 0.0f64);
    let mut last_rpc_check = Instant::now();
    log(&format!("Lumisound Rich Presence running (bridge {})", bridge.base));
    loop {
        if last_rpc_check.elapsed() > Duration::from_secs(300) {
            if let Ok(n) = bridge.get("/user/discord-rpc-config") {
                if let Some(id) = pick("discord_client_id", &n).filter(|id| *id != client_id) {
                    log("Discord client id changed; reconnecting");
                    client_id = id;
                    conn.close();
                    conn = ipc::Ipc::new(&client_id);
                }
                rpc = n;
            }
            last_rpc_check = Instant::now();
        }
        if rpc["enabled"].as_bool() == Some(false) {
            if conn.connected() {
                let _ = conn.set_activity(None);
                conn.close();
            }
            std::thread::sleep(poll);
            continue;
        }
        if !conn.connected() {
            if let Err(e) = conn.connect() {
                let _ = e;
                std::thread::sleep(poll);
                continue;
            }
        }
        let state = match bridge.get("/user/playback-state") {
            Ok(s) => s,
            Err(e) => {
                log(&format!("bridge request failed ({e}); retrying"));
                std::thread::sleep(poll.max(Duration::from_secs(5)));
                continue;
            }
        };
        let (large, small) = (pick("large_image", &rpc), pick("small_image", &rpc));
        let show_buttons = config["show_buttons"].as_bool().or(rpc["show_buttons"].as_bool()).unwrap_or(true);
        let show_paused = config["show_when_paused"].as_bool().unwrap_or(false);
        let activity = build_activity(&state, &bridge.base, large.as_deref(), small.as_deref(), show_buttons, show_paused);
        let t = now();
        // Changes go out at once (Discord allows 5 updates per 20 s, and a
        // track change or seek is rare enough); otherwise refresh every few
        // seconds so a restarted Discord client picks the card back up.
        let changed = needs_send(last_activity.as_ref(), activity.as_ref());
        if changed || (activity.is_some() && t - last_sent >= MIN_SEND_INTERVAL_SECS * 3.0) {
            match conn.set_activity(activity.clone()) {
                Ok(()) => {
                    last_sent = t;
                    last_activity = activity;
                }
                Err(e) => {
                    log(&format!("Discord IPC write failed ({e}); reconnecting"));
                    conn.close();
                }
            }
        }
        std::thread::sleep(poll);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let r = match args.first().map(String::as_str) {
        Some("login") => login::main(&args[1..]),
        Some("--help") | Some("-h") => {
            println!("lumisound-discord-rpc            run the Rich Presence daemon\nlumisound-discord-rpc login [--bridge-url URL] [--token TOKEN] [--identifier EMAIL_OR_USERNAME]");
            Ok(())
        }
        _ => run(),
    };
    if let Err(e) = r {
        eprintln!("Error: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn activity_shape() {
        let st = json!({"title": "Song", "artist": "Band", "is_playing": true, "position_seconds": 10.0, "duration_seconds": 200.0,
            "artwork_url": "https://a/b.jpg", "track_url": "https://x", "engine": "Rust engine · LMS OPUS · 48 kHz", "bpm": 123.6});
        let a = build_activity(&st, "https://br", Some("lumisound"), Some("playpause-small"), true, false).unwrap();
        assert_eq!(a["state"], "by Band");
        assert_eq!(a["assets"]["large_image"], "https://a/b.jpg");
        // The third line is engine info, never the title again.
        assert_eq!(a["assets"]["large_text"], "Rust engine · LMS OPUS · 48 kHz · 124 BPM");
        assert_ne!(a["assets"]["large_text"], a["details"]);
        assert_eq!(a["assets"]["small_text"], "Playing on Lumisound");
        assert_eq!(a["buttons"][0]["label"], "Listen");
        let ts = &a["timestamps"];
        assert_eq!(ts["end"].as_i64().unwrap() - ts["start"].as_i64().unwrap(), 200_000);
        assert!(build_activity(&json!({"title": "S", "is_playing": false}), "", None, None, true, false).is_none());
        let stale = json!({"title": "S", "is_playing": true, "updated_at": "2020-01-01T00:00:00+00:00"});
        assert!(build_activity(&stale, "", None, None, true, false).is_none());
        // No engine reported (older app): still not the title.
        let old = json!({"title": "Song", "is_playing": true, "artwork_url": "https://a/b.jpg"});
        assert_eq!(build_activity(&old, "", None, None, true, false).unwrap()["assets"]["large_text"], "Lumisound");
    }

    #[test]
    fn youtube_art_goes_through_bridge() {
        assert_eq!(presence_art("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", "https://br"), "https://br/api/rp-art/yt/dQw4w9WgXcQ.jpg");
        assert_eq!(presence_art("https://br/api/rp-artwork/ab.jpg", "https://br"), "https://br/api/rp-artwork/ab.jpg");
        assert_eq!(presence_art("https://i.ytimg.com/vi/bad/hq.jpg", "https://br"), "https://i.ytimg.com/vi/bad/hq.jpg");
    }

    #[test]
    fn resend_rules() {
        let a = json!({"details": "S", "timestamps": {"start": 1000, "end": 5000}});
        let jitter = json!({"details": "S", "timestamps": {"start": 1400, "end": 5400}});
        let seek = json!({"details": "S", "timestamps": {"start": 30000, "end": 34000}});
        assert!(!needs_send(Some(&a), Some(&jitter)));
        assert!(needs_send(Some(&a), Some(&seek)));
        assert!(needs_send(Some(&a), None));
        assert!(needs_send(Some(&a), Some(&json!({"details": "T", "timestamps": {"start": 1000, "end": 5000}}))));
    }
}
