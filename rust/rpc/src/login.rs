//! `lumisound-discord-rpc login`: exchanges email/username + password (+2FA)
//! for a 365-day Rich Presence token and stores only the token.

use serde_json::{Value, json};

const SETUP_DEVICE: &str = "Discord RPC Bridge (setup)";

fn device_name() -> String {
    let host = std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).ok().or_else(|| {
        std::process::Command::new("hostname").output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
    });
    match host.map(|h| h.split('.').next().unwrap_or("").trim().to_string()).filter(|h| !h.is_empty()) {
        Some(h) => format!("Discord RPC Bridge ({h})"),
        None => "Discord RPC Bridge".into(),
    }
}

fn post(http: &reqwest::blocking::Client, base: &str, path: &str, body: &Value, token: Option<&str>) -> Result<Value, String> {
    let mut rq = http.post(format!("{}{path}", base.trim_end_matches('/'))).header("User-Agent", "lumisound-rpc-login/2.0").json(body);
    if let Some(t) = token {
        rq = rq.bearer_auth(t);
    }
    let r = rq.send().map_err(|e| format!("Could not reach the Lumisound bridge at {base} ({e})."))?;
    let status = r.status().as_u16();
    let v: Value = r.json().unwrap_or(Value::Null);
    if !(200..300).contains(&status) {
        return Err(match v["detail"].as_str() {
            Some(d) => d.to_string(),
            None if status == 401 => "Invalid email/username or password.".into(),
            None if status == 429 => "Too many attempts -- wait a minute and try again.".into(),
            None => format!("HTTP {status} from the Lumisound bridge."),
        });
    }
    Ok(v)
}

fn prompt(label: &str) -> String {
    use std::io::Write;
    print!("{label}");
    let _ = std::io::stdout().flush();
    let mut s = String::new();
    let _ = std::io::stdin().read_line(&mut s);
    s.trim().to_string()
}

fn interactive(base: &str, identifier: Option<String>) -> Result<String, String> {
    let http = reqwest::blocking::Client::builder().timeout(std::time::Duration::from_secs(20)).build().map_err(|e| e.to_string())?;
    let id = identifier.filter(|s| !s.is_empty()).unwrap_or_else(|| prompt("Lumisound email or username: "));
    if id.is_empty() {
        return Err("No email/username entered.".into());
    }
    let pw = rpassword::prompt_password("Lumisound password (not shown): ").map_err(|e| e.to_string())?;
    if pw.is_empty() {
        return Err("No password entered.".into());
    }
    println!("Signing in...");
    let mut r = post(&http, base, "/auth/login", &json!({"username": id, "password": pw, "device_name": SETUP_DEVICE}), None)?;
    if r["requires_2fa"].as_bool() == Some(true) {
        let pending = r["pending_token"].as_str().ok_or("The bridge asked for 2FA but returned no pending token.")?.to_string();
        let code = prompt("Two-factor code (6 digits from your authenticator app): ").replace(' ', "");
        if code.is_empty() {
            return Err("No two-factor code entered.".into());
        }
        r = post(&http, base, "/auth/2fa/login", &json!({"pending_token": pending, "code": code, "device_name": SETUP_DEVICE}), None)?;
    }
    let session = r["token"].as_str().ok_or("Login succeeded but the bridge returned no token.")?.to_string();
    println!("Creating a Rich Presence token for this device...");
    let rpc = post(&http, base, "/user/rpc-token", &json!({"device_name": device_name()}), Some(&session)).map_err(|e| format!("Signed in, but could not create a Rich Presence token: {e}"))?;
    let token = rpc["token"].as_str().ok_or("The bridge returned no Rich Presence token.")?.to_string();
    let expires = rpc["expires_at"].as_str().map(|e| format!(" (expires {e})")).unwrap_or_default();
    println!("Token created for {}{expires}.", rpc["device_name"].as_str().map(str::to_string).unwrap_or_else(device_name));
    if post(&http, base, "/auth/logout", &json!({}), Some(&session)).is_err() {
        println!("Note: could not close the temporary sign-in session; you can revoke \"{SETUP_DEVICE}\" from Account -> Sessions.");
    }
    Ok(token)
}

pub fn main(args: &[String]) -> Result<(), String> {
    let mut bridge_url = None;
    let mut token = None;
    let mut identifier = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--bridge-url" => bridge_url = it.next().cloned(),
            "--token" => token = it.next().map(|t| t.trim().to_string()),
            "--identifier" => identifier = it.next().cloned(),
            other => return Err(format!("unknown argument {other}")),
        }
    }
    let base = bridge_url.clone().unwrap_or_else(|| crate::DEFAULT_BRIDGE_URL.into());
    let token = match token {
        Some(t) => t,
        None => interactive(&base, identifier)?,
    };
    let path = crate::default_config_path();
    let mut config: Value = std::fs::read_to_string(&path).ok().and_then(|s| serde_json::from_str(&s).ok()).filter(Value::is_object).unwrap_or_else(|| json!({}));
    config["access_token"] = json!(token);
    if config.get("poll_interval_seconds").is_none() {
        config["poll_interval_seconds"] = json!(1);
    }
    if let Some(b) = bridge_url {
        config["bridge_url"] = json!(b);
    }
    let o = config.as_object_mut().unwrap();
    if o.remove("password").is_some() {
        println!("Removed the password left in config.json by a previous setup.");
    }
    o.remove("username");
    crate::write_config(&path, &config).map_err(|e| e.to_string())?;
    println!("Wrote {}", path.display());
    Ok(())
}
