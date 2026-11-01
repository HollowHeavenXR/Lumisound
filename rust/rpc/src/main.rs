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

/// Discord activity for a playback state, or None to clear it.
pub fn build_activity(state: &Value, large_image: Option<&str>, small_image: Option<&str>, show_buttons: bool, show_when_paused: bool) -> Option<Value> {
    let title = state["title"].as_str().filter(|t| !t.is_empty())?;
    let playing = state["is_playing"].as_bool().unwrap_or(false);
    if !playing && !show_when_paused {
        return None;
    }
    let sampled = sampled_at(state);
    if sampled.is_some_and(|s| now() - s > STALE_AFTER_SECS) {
        return None;
    }
    let cut = |s: &str| s.chars().take(128).collect::<String>();
    let mut a = json!({"type": 2, "details": cut(title)});
    if let Some(artist) = state["artist"].as_str().filter(|s| !s.is_empty()) {
        a["state"] = json!(cut(&format!("by {artist}")));
    }
    if playing {
        let pos = state["position_seconds"].as_f64().unwrap_or(0.0);
        a["timestamps"] = json!({"start": (sampled.unwrap_or_else(now) - pos) as i64});
    }
    let art = state["artwork_url"].as_str().filter(|s| !s.is_empty());
    let mut assets = serde_json::Map::new();
    if let Some(img) = art.or(large_image) {
        assets.insert("large_image".into(), json!(img));
        assets.insert("large_text".into(), json!(if art.is_some() { cut(title) } else { "Lumisound".into() }));
    }
    if let (Some(small), Some(_)) = (small_image, art) {
        assets.insert("small_image".into(), json!(small));
        assets.insert("small_text".into(), json!(if playing { "Playing" } else { "Paused" }));
    }
    if !assets.is_empty() {
        a["assets"] = Value::Object(assets);
    }
    if show_buttons {
        if let Some(url) = state["track_url"].as_str().filter(|s| !s.is_empty()) {
            a["buttons"] = json!([{"label": "Listen", "url": url}]);
        }
    }
    Some(a)
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
    let (mut last_sig, mut last_sent) = (None::<(String, String)>, 0.0f64);
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
        let activity = build_activity(&state, large.as_deref(), small.as_deref(), show_buttons, show_paused);
        let sig = activity.as_ref().map(|a| (a["details"].as_str().unwrap_or("").to_string(), a["state"].as_str().unwrap_or("").to_string()));
        let t = now();
        if sig != last_sig || t - last_sent >= MIN_SEND_INTERVAL_SECS {
            match conn.set_activity(activity) {
                Ok(()) => {
                    last_sent = t;
                    last_sig = sig;
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
        let st = json!({"title": "Song", "artist": "Band", "is_playing": true, "position_seconds": 10.0, "artwork_url": "https://a/b.jpg", "track_url": "https://x"});
        let a = build_activity(&st, Some("lumisound"), Some("playpause-small"), true, false).unwrap();
        assert_eq!(a["state"], "by Band");
        assert_eq!(a["assets"]["large_image"], "https://a/b.jpg");
        assert_eq!(a["assets"]["small_text"], "Playing");
        assert_eq!(a["buttons"][0]["label"], "Listen");
        assert!(build_activity(&json!({"title": "S", "is_playing": false}), None, None, true, false).is_none());
        let stale = json!({"title": "S", "is_playing": true, "updated_at": "2020-01-01T00:00:00+00:00"});
        assert!(build_activity(&stale, None, None, true, false).is_none());
    }
}
