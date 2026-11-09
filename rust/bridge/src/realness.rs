//! Account realness: is each account a real person using the app, and how
//! often are they on it?
//!
//! Checked from independent signals (no single one decides):
//! * device evidence — an APNs push token (only a real install of the app
//!   on a real iPhone/iPad/Apple TV can get one), app telemetry carrying a
//!   device model and OS version, known-device hashes;
//! * identity — Discord sign-in (an existing Discord account), email,
//!   avatar / display name / date of birth, two-factor;
//! * behaviour — plays spread over days and hours with natural listen
//!   lengths, a library or favorites built up, coming back after sign-up;
//! * abuse patterns — one device's push token on several accounts
//!   (multi-accounting), near-identical usernames from one device, plays
//!   with machine-constant listen lengths, round-the-clock playing, more
//!   plays a day than a person can listen to, bursts of sign-ups.
//!
//! Each account gets a 0-100 score, a verdict (real / likely_real /
//! unverified / suspicious), the reasons, and its activity: days active in
//! the last 7 and 30 days, average active days per week and last seen.
//! Stored daily in `ios_user_realness` (background loop "realness"); the
//! admin API serves it and `lumisound-bridge realness-report` prints it.
//! Nothing is disabled automatically: suspicious accounts are flagged for
//! a person to review.

use crate::state::AppState;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::HashMap;

#[derive(Debug, Clone, Default, sqlx::FromRow)]
pub struct Features {
    pub id: String,
    pub username: String,
    pub email: Option<String>,
    pub created_at: Option<chrono::NaiveDateTime>,
    pub last_login: Option<chrono::NaiveDateTime>,
    pub totp: bool,
    pub avatar: bool,
    pub dob: bool,
    pub dname: bool,
    pub models: i64,
    pub os_versions: i64,
    pub push_n: i64,
    pub tok_shared: i64,
    pub known_dev: i64,
    pub discord_sessions: i64,
    pub sessions: i64,
    pub plays: i64,
    pub play_days: i64,
    pub tracks: i64,
    pub listen_sd: f64,
    pub hours: i64,
    pub max_plays_day: i64,
    pub library: i64,
    pub favs: i64,
    pub cloud: i64,
    pub active_7: i64,
    pub active_30: i64,
    pub active_total: i64,
    pub first_seen: Option<chrono::NaiveDateTime>,
    pub last_seen: Option<chrono::NaiveDateTime>,
    pub same_minute_signups: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Verdict {
    pub user_id: String,
    pub username: String,
    pub score: i32,
    pub verdict: &'static str,
    pub reasons: Vec<String>,
    pub flags: Vec<String>,
    pub active_days_7: i64,
    pub active_days_30: i64,
    pub days_per_week: f64,
    pub frequency: &'static str,
    pub last_seen: Option<String>,
    pub created_at: Option<String>,
}

const FEATURES_SQL: &str = r#"
WITH acts AS (
    SELECT user_id, created_at::date d FROM ios_app_logs WHERE user_id IS NOT NULL
    UNION SELECT user_id, created_at::date FROM ios_app_event_log WHERE user_id IS NOT NULL
    UNION SELECT user_id, played_at::date FROM ios_play_history
    UNION SELECT user_id, created_at::date FROM ios_user_sessions
    UNION SELECT user_id, last_seen_at::date FROM ios_push_tokens WHERE last_seen_at IS NOT NULL
    UNION SELECT user_id, last_login::date FROM ios_users WHERE last_login IS NOT NULL
),
act AS (SELECT user_id,
            count(*) FILTER (WHERE d > now()::date - 7) a7,
            count(*) FILTER (WHERE d > now()::date - 30) a30,
            count(*) total, min(d) first_d, max(d) last_d FROM acts GROUP BY 1),
lastseen AS (SELECT user_id, max(t) t FROM (
    SELECT user_id, max(created_at) t FROM ios_app_logs WHERE user_id IS NOT NULL GROUP BY 1
    UNION ALL SELECT user_id, max(created_at) FROM ios_app_event_log WHERE user_id IS NOT NULL GROUP BY 1
    UNION ALL SELECT user_id, max(played_at) FROM ios_play_history GROUP BY 1
    UNION ALL SELECT user_id, max(last_seen_at) FROM ios_push_tokens GROUP BY 1
    UNION ALL SELECT id, last_login FROM ios_users) x GROUP BY 1),
dev AS (SELECT user_id, count(DISTINCT device_model) models, count(DISTINCT os_version) oses FROM (
    SELECT user_id, device_model, os_version FROM ios_app_logs WHERE user_id IS NOT NULL AND device_model IS NOT NULL AND device_model <> ''
    UNION SELECT user_id, detail->>'deviceModel', detail->>'osVersion' FROM ios_app_event_log WHERE user_id IS NOT NULL AND detail ? 'deviceModel') d GROUP BY 1),
tok AS (SELECT device_token, count(DISTINCT user_id) c FROM ios_push_tokens GROUP BY 1),
pt AS (SELECT p.user_id, count(*) n, max(t.c) shared FROM ios_push_tokens p JOIN tok t USING (device_token) GROUP BY 1),
kd AS (SELECT user_id, count(*) n FROM ios_known_devices GROUP BY 1),
ses AS (SELECT user_id, count(*) n, count(*) FILTER (WHERE device_name ILIKE 'Discord Sign-In%') discord FROM ios_user_sessions GROUP BY 1),
ph AS (SELECT user_id, count(*) n, count(DISTINCT played_at::date) days, count(DISTINCT lower(title)) tracks,
          coalesce(stddev_pop(listen_seconds), 0)::float8 sd, count(DISTINCT extract(hour FROM played_at)) hours FROM ios_play_history GROUP BY 1),
phd AS (SELECT user_id, max(n) mx FROM (SELECT user_id, played_at::date d, count(*) n FROM ios_play_history GROUP BY 1, 2) x GROUP BY 1),
lib AS (SELECT user_id, count(*) n FROM ios_user_library_inventory GROUP BY 1),
fav AS (SELECT user_id, count(*) n FROM ios_user_favorites GROUP BY 1),
md AS (SELECT user_id, count(*) n FROM ios_user_music_metadata GROUP BY 1),
burst AS (SELECT a.id, count(b.id) n FROM ios_users a JOIN ios_users b ON b.id <> a.id AND abs(extract(epoch FROM b.created_at - a.created_at)) < 60 GROUP BY 1)
SELECT u.id, u.username, u.email, u.created_at, u.last_login,
       coalesce(u.totp_enabled, false) totp, (u.avatar_url IS NOT NULL OR u.avatar_data IS NOT NULL) avatar,
       u.date_of_birth IS NOT NULL dob, coalesce(u.display_name, '') <> '' dname,
       coalesce(dev.models, 0) models, coalesce(dev.oses, 0) os_versions,
       coalesce(pt.n, 0) push_n, coalesce(pt.shared, 0) tok_shared, coalesce(kd.n, 0) known_dev,
       coalesce(ses.discord, 0) discord_sessions, coalesce(ses.n, 0) sessions,
       coalesce(ph.n, 0) plays, coalesce(ph.days, 0) play_days, coalesce(ph.tracks, 0) tracks, coalesce(ph.sd, 0) listen_sd,
       coalesce(ph.hours, 0) hours, coalesce(phd.mx, 0) max_plays_day,
       coalesce(lib.n, 0) library, coalesce(fav.n, 0) favs, coalesce(md.n, 0) cloud,
       coalesce(act.a7, 0) active_7, coalesce(act.a30, 0) active_30, coalesce(act.total, 0) active_total,
       act.first_d::timestamp first_seen, lastseen.t last_seen, coalesce(burst.n, 0) same_minute_signups
FROM ios_users u
LEFT JOIN dev ON dev.user_id = u.id LEFT JOIN pt ON pt.user_id = u.id LEFT JOIN kd ON kd.user_id = u.id
LEFT JOIN ses ON ses.user_id = u.id LEFT JOIN ph ON ph.user_id = u.id LEFT JOIN phd ON phd.user_id = u.id
LEFT JOIN lib ON lib.user_id = u.id LEFT JOIN fav ON fav.user_id = u.id LEFT JOIN md ON md.user_id = u.id
LEFT JOIN act ON act.user_id = u.id LEFT JOIN lastseen ON lastseen.user_id = u.id LEFT JOIN burst ON burst.id = u.id
ORDER BY u.created_at
"#;

/// Letters of a username without digits/punctuation ("cb54100" -> "cb").
fn stem(u: &str) -> String {
    u.to_lowercase().split('@').next().unwrap_or("").chars().filter(|c| c.is_ascii_alphabetic()).collect()
}

/// Score one account. `siblings`: other accounts sharing its username stem
/// (only counted when they also share a device or signed up within a day).
pub fn judge(f: &Features, siblings: usize, now: chrono::NaiveDateTime) -> Verdict {
    let mut score: i32 = 0;
    let mut reasons = Vec::new();
    let mut flags = Vec::new();
    let mut add = |pts: i32, why: &str, reasons: &mut Vec<String>| {
        score += pts;
        reasons.push(format!("{pts:+} {why}"));
    };
    // Device evidence.
    if f.push_n > 0 {
        add(25, "push token from a real installed device", &mut reasons);
    }
    if f.models > 0 {
        add(15, &format!("app telemetry from {} device model(s)", f.models), &mut reasons);
    }
    if f.known_dev > 0 {
        add(5, "known device", &mut reasons);
    }
    // Identity.
    if f.discord_sessions > 0 {
        add(10, "signed in with Discord", &mut reasons);
    }
    if f.email.as_deref().is_some_and(|e| e.contains('@')) {
        add(5, "email on file", &mut reasons);
    }
    if f.avatar || f.dname || f.dob {
        add(5, "profile filled in", &mut reasons);
    }
    if f.totp {
        add(5, "two-factor on", &mut reasons);
    }
    // Behaviour.
    if f.plays >= 20 && f.play_days >= 3 {
        add(15, &format!("{} plays over {} days", f.plays, f.play_days), &mut reasons);
    } else if f.plays >= 5 {
        add(7, &format!("{} plays", f.plays), &mut reasons);
    }
    if f.tracks >= 10 && f.hours >= 4 {
        add(5, "varied listening (songs and times of day)", &mut reasons);
    }
    if f.library + f.favs + f.cloud > 0 {
        add(10, "built a library / favorites", &mut reasons);
    }
    if f.active_total >= 3 {
        add(5, &format!("came back on {} different days", f.active_total), &mut reasons);
    }
    // Abuse patterns.
    if f.tok_shared > 1 {
        add(-15, &format!("device shared with {} other account(s)", f.tok_shared - 1), &mut reasons);
        flags.push("multi_account_device".to_string());
    }
    if siblings > 0 {
        add(-10, &format!("{siblings} near-identical username(s) from the same device or day"), &mut reasons);
        flags.push("username_cluster".to_string());
    }
    if f.plays >= 30 && f.listen_sd < 1.0 {
        add(-25, "every play the same length (scripted)", &mut reasons);
        flags.push("constant_listen_length".to_string());
    }
    if f.plays >= 200 && f.hours >= 23 && f.play_days <= 3 {
        add(-15, "playing round the clock", &mut reasons);
        flags.push("round_the_clock".to_string());
    }
    if f.max_plays_day > 700 {
        add(-20, &format!("{} plays in one day", f.max_plays_day), &mut reasons);
        flags.push("impossible_volume".to_string());
    }
    if f.same_minute_signups >= 2 {
        add(-15, &format!("signed up in a burst with {} other account(s)", f.same_minute_signups), &mut reasons);
        flags.push("signup_burst".to_string());
    }
    let device = f.push_n > 0 || f.models > 0;
    if !device && f.plays == 0 && f.library + f.favs + f.cloud == 0 {
        flags.push("no_device_no_activity".to_string());
    }
    let score = score.clamp(0, 100);
    let abuse = flags.iter().any(|x| x != "no_device_no_activity");
    let verdict = if abuse && score < 50 {
        "suspicious"
    } else if score >= 60 && device {
        "real"
    } else if score >= 35 && device {
        "likely_real"
    } else if !device && f.plays == 0 {
        "unverified"
    } else if score >= 35 {
        "likely_real"
    } else {
        "unverified"
    };
    // Frequency: active days per week since first seen (max 30 days back).
    let first = f.first_seen.or(f.created_at).unwrap_or(now);
    let weeks = ((now - first).num_days().clamp(1, 30) as f64 / 7.0).max(1.0 / 7.0);
    let per_week = (f.active_30 as f64 / weeks).min(7.0);
    let frequency = if f.active_7 >= 5 {
        "daily"
    } else if f.active_7 >= 2 || per_week >= 2.0 {
        "several times a week"
    } else if f.active_30 >= 2 {
        "a few times a month"
    } else if f.active_30 == 1 {
        "once this month"
    } else {
        "inactive 30+ days"
    };
    Verdict {
        user_id: f.id.clone(),
        username: f.username.clone(),
        score,
        verdict,
        reasons,
        flags,
        active_days_7: f.active_7,
        active_days_30: f.active_30,
        days_per_week: (per_week * 10.0).round() / 10.0,
        frequency,
        last_seen: f.last_seen.map(|t| t.format("%Y-%m-%d %H:%M").to_string()),
        created_at: f.created_at.map(|t| t.format("%Y-%m-%d").to_string()),
    }
}

/// Username clusters: accounts sharing a stem AND (a push token or a sign-up day).
async fn siblings(st: &AppState, feats: &[Features]) -> HashMap<String, usize> {
    let toks: Vec<(String, String)> = sqlx::query_as("SELECT user_id, device_token FROM ios_push_tokens").fetch_all(&st.db).await.unwrap_or_default();
    let mut by_user: HashMap<&str, Vec<&str>> = HashMap::new();
    for (u, t) in &toks {
        by_user.entry(u.as_str()).or_default().push(t.as_str());
    }
    let mut out = HashMap::new();
    for a in feats {
        let sa = stem(&a.username);
        if sa.len() < 2 {
            continue;
        }
        let n = feats
            .iter()
            .filter(|b| b.id != a.id && stem(&b.username) == sa)
            .filter(|b| {
                let same_day = matches!((a.created_at, b.created_at), (Some(x), Some(y)) if (x - y).num_hours().abs() < 24);
                let shared = by_user.get(a.id.as_str()).is_some_and(|ta| by_user.get(b.id.as_str()).is_some_and(|tb| ta.iter().any(|t| tb.contains(t))));
                same_day || shared
            })
            .count();
        if n > 0 {
            out.insert(a.id.clone(), n);
        }
    }
    out
}

pub async fn scan(st: &AppState) -> anyhow::Result<Vec<Verdict>> {
    let feats: Vec<Features> = sqlx::query_as(FEATURES_SQL).fetch_all(&st.db).await?;
    let sib = siblings(st, &feats).await;
    let now = chrono::Utc::now().naive_utc();
    Ok(feats.iter().map(|f| judge(f, sib.get(&f.id).copied().unwrap_or(0), now)).collect())
}

/// Run the scan and store it (one row per account, replaced each run).
pub async fn scan_and_store(st: &AppState) -> anyhow::Result<Value> {
    let v = scan(st).await?;
    let mut tx = st.db.begin().await?;
    for x in &v {
        sqlx::query(
            "INSERT INTO ios_user_realness (user_id, score, verdict, reasons, flags, active_days_7, active_days_30, days_per_week, frequency, last_seen, checked_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW()) \
             ON CONFLICT (user_id) DO UPDATE SET score = EXCLUDED.score, verdict = EXCLUDED.verdict, reasons = EXCLUDED.reasons, flags = EXCLUDED.flags, \
               active_days_7 = EXCLUDED.active_days_7, active_days_30 = EXCLUDED.active_days_30, days_per_week = EXCLUDED.days_per_week, \
               frequency = EXCLUDED.frequency, last_seen = EXCLUDED.last_seen, checked_at = NOW()",
        )
        .bind(&x.user_id)
        .bind(x.score)
        .bind(x.verdict)
        .bind(json!(x.reasons))
        .bind(json!(x.flags))
        .bind(x.active_days_7 as i32)
        .bind(x.active_days_30 as i32)
        .bind(x.days_per_week)
        .bind(x.frequency)
        .bind(&x.last_seen)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(summary(&v))
}

pub fn summary(v: &[Verdict]) -> Value {
    let mut by: HashMap<&str, usize> = HashMap::new();
    let mut freq: HashMap<&str, usize> = HashMap::new();
    let mut flags: HashMap<String, usize> = HashMap::new();
    for x in v {
        *by.entry(x.verdict).or_default() += 1;
        *freq.entry(x.frequency).or_default() += 1;
        for f in &x.flags {
            *flags.entry(f.clone()).or_default() += 1;
        }
    }
    json!({"accounts": v.len(), "verdicts": by, "frequency": freq, "flags": flags})
}

/// Daily scan (background loop "realness"); logs a warning when new
/// suspicious accounts appear.
pub async fn realness_loop(st: AppState) {
    tokio::time::sleep(std::time::Duration::from_secs(120)).await;
    loop {
        match scan_and_store(&st).await {
            Ok(s) => {
                tracing::info!("realness scan: {s}");
                if s["verdicts"]["suspicious"].as_u64().unwrap_or(0) > 0 {
                    crate::db::log_event(&st.db, "security", "realness_suspicious", None, "warning", "accounts flagged by the realness scan", Some(s)).await;
                }
            }
            Err(e) => tracing::warn!("realness scan failed: {e}"),
        }
        tokio::time::sleep(std::time::Duration::from_secs(24 * 3600)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> chrono::NaiveDateTime {
        chrono::NaiveDate::from_ymd_opt(2026, 11, 9).unwrap().and_hms_opt(12, 0, 0).unwrap()
    }

    #[test]
    fn heavy_real_user() {
        let f = Features { id: "a".into(), username: "Someone".into(), email: Some("x@icloud.com".into()), push_n: 3, models: 2, plays: 8000, play_days: 90, tracks: 900, listen_sd: 60.0, hours: 22, max_plays_day: 300, library: 5000, active_7: 6, active_30: 25, active_total: 90, avatar: true, ..Default::default() };
        let v = judge(&f, 0, now());
        assert_eq!(v.verdict, "real");
        assert_eq!(v.frequency, "daily");
    }

    #[test]
    fn multi_account_device_is_flagged() {
        let f = Features { id: "b".into(), username: "cb54100".into(), push_n: 1, tok_shared: 3, plays: 11, play_days: 1, active_total: 1, ..Default::default() };
        let v = judge(&f, 2, now());
        assert_eq!(v.verdict, "suspicious", "{v:?}");
        assert!(v.flags.contains(&"multi_account_device".to_string()));
    }

    #[test]
    fn scripted_plays_are_flagged() {
        let f = Features { id: "c".into(), username: "x".into(), push_n: 0, plays: 900, play_days: 2, max_plays_day: 800, listen_sd: 0.0, hours: 24, ..Default::default() };
        let v = judge(&f, 0, now());
        assert_eq!(v.verdict, "suspicious");
        assert!(v.flags.contains(&"constant_listen_length".to_string()));
    }

    #[test]
    fn signup_only_is_unverified_not_suspicious() {
        let f = Features { id: "d".into(), username: "newbie".into(), sessions: 1, ..Default::default() };
        let v = judge(&f, 0, now());
        assert_eq!(v.verdict, "unverified");
        assert_eq!(v.frequency, "inactive 30+ days");
    }
}
