//! Download bookkeeping: the ledger (source id -> filename of the finished
//! file), in-flight claims (so two devices/tabs don't fetch the same track),
//! permanent-failure cool-offs, destination naming and format helpers.

use crate::store;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const LEDGER: &str = "download_ledger";
const IN_FLIGHT: &str = "download_inflight";
const FAILURES: &str = "download_failures";
const IN_FLIGHT_TTL: f64 = 5.0 * 60.0;

static LOCK: Mutex<()> = Mutex::new(());

#[derive(Serialize, Deserialize, Clone, Copy, Default)]
struct Failure {
    last_failed: f64,
    strikes: u32,
}

/// One-time import of the UserDefaults-era JSON blobs (ledger map, in-flight
/// map of unix seconds, failures map with Apple-epoch `lastFailed`).
#[uniffi::export]
pub fn downloads_import_legacy(ledger_json: Option<Vec<u8>>, failures_json: Option<Vec<u8>>) {
    let _g = LOCK.lock().unwrap();
    if !store::exists(LEDGER) {
        let m: HashMap<String, String> = ledger_json.and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        store::save(LEDGER, &m);
    }
    if !store::exists(FAILURES) {
        #[derive(Deserialize)]
        struct Legacy {
            #[serde(rename = "lastFailed")]
            last_failed: f64,
            strikes: u32,
        }
        let m: HashMap<String, Legacy> = failures_json.and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let conv: HashMap<String, Failure> = m.into_iter().map(|(k, v)| (k, Failure { last_failed: v.last_failed + store::APPLE_EPOCH, strikes: v.strikes })).collect();
        store::save(FAILURES, &conv);
    }
}

#[uniffi::export]
pub fn ledger_record(source_track_id: String, filename: String) {
    if source_track_id.is_empty() || filename.is_empty() {
        return;
    }
    let _g = LOCK.lock().unwrap();
    clear_failure(&source_track_id);
    let mut m: HashMap<String, String> = store::load(LEDGER);
    if m.get(&source_track_id) == Some(&filename) {
        return;
    }
    m.insert(source_track_id, filename);
    store::save(LEDGER, &m);
}

#[uniffi::export]
pub fn ledger_filename(source_track_id: String) -> Option<String> {
    let m: HashMap<String, String> = store::load(LEDGER);
    m.get(&source_track_id).cloned()
}

#[uniffi::export]
pub fn ledger_is_present(source_track_id: String, present_filenames: Vec<String>) -> bool {
    let m: HashMap<String, String> = store::load(LEDGER);
    m.get(&source_track_id).is_some_and(|f| present_filenames.contains(f))
}

/// Source ids whose ledgered file is still in the library.
#[uniffi::export]
pub fn ledger_present_ids(present_filenames: Vec<String>) -> Vec<String> {
    let present: HashSet<String> = present_filenames.into_iter().collect();
    let m: HashMap<String, String> = store::load(LEDGER);
    m.into_iter().filter(|(_, f)| present.contains(f)).map(|(k, _)| k).collect()
}

/// Claim a download; false if another claim is younger than 5 minutes.
#[uniffi::export]
pub fn ledger_begin(source_track_id: String) -> bool {
    if source_track_id.is_empty() {
        return true;
    }
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, f64> = store::load(IN_FLIGHT);
    let now = store::now();
    if m.get(&source_track_id).is_some_and(|t| now - t < IN_FLIGHT_TTL) {
        return false;
    }
    m.retain(|_, t| now - *t < IN_FLIGHT_TTL);
    m.insert(source_track_id, now);
    store::save(IN_FLIGHT, &m);
    true
}

#[uniffi::export]
pub fn ledger_end(source_track_id: String) {
    if source_track_id.is_empty() {
        return;
    }
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, f64> = store::load(IN_FLIGHT);
    if m.remove(&source_track_id).is_some() {
        store::save(IN_FLIGHT, &m);
    }
}

// ---- permanent failures ------------------------------------------------------------------------

fn cooloff(strikes: u32) -> f64 {
    const DAY: f64 = 86_400.0;
    match strikes {
        0 => 0.0,
        1 => DAY,
        2 => 3.0 * DAY,
        3 => 7.0 * DAY,
        _ => 30.0 * DAY,
    }
}

fn skip(f: &Failure, now: f64) -> bool {
    now - f.last_failed < cooloff(f.strikes)
}

fn clear_failure(id: &str) {
    let mut m: HashMap<String, Failure> = store::load(FAILURES);
    if m.remove(id).is_some() {
        store::save(FAILURES, &m);
    }
}

/// Inside its cool-off (1 day, 3 days, 1 week, then a month per strike).
#[uniffi::export]
pub fn failure_should_skip(source_track_id: String) -> bool {
    let m: HashMap<String, Failure> = store::load(FAILURES);
    m.get(&source_track_id).is_some_and(|f| skip(f, store::now()))
}

#[uniffi::export]
pub fn failure_record(source_track_id: String) {
    if source_track_id.is_empty() {
        return;
    }
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, Failure> = store::load(FAILURES);
    let now = store::now();
    let e = m.entry(source_track_id).or_default();
    e.strikes += 1;
    e.last_failed = now;
    let cutoff = now - cooloff(u32::MAX);
    m.retain(|_, f| f.last_failed > cutoff);
    store::save(FAILURES, &m);
}

#[uniffi::export]
pub fn failure_clear(source_track_id: String) {
    let _g = LOCK.lock().unwrap();
    clear_failure(&source_track_id);
}

#[uniffi::export]
pub fn failure_clear_all() {
    let _g = LOCK.lock().unwrap();
    store::save(FAILURES, &HashMap::<String, Failure>::new());
}

#[uniffi::export]
pub fn failure_suppressed_count(source_track_ids: Vec<String>) -> u32 {
    let m: HashMap<String, Failure> = store::load(FAILURES);
    let now = store::now();
    source_track_ids.iter().filter(|id| m.get(*id).is_some_and(|f| skip(f, now))).count() as u32
}

#[uniffi::export]
pub fn failure_suppressed_total() -> u32 {
    let m: HashMap<String, Failure> = store::load(FAILURES);
    let now = store::now();
    m.values().filter(|f| skip(f, now)).count() as u32
}

// ---- naming / formats ------------------------------------------------------------------------

/// Bridge download format -> file extension.
#[uniffi::export]
pub fn download_extension(format: String) -> String {
    match format.as_str() {
        "mp3" | "flac" | "opus" | "wav" => format,
        _ => "m4a".into(),
    }
}

#[uniffi::export]
pub fn content_type_extension(content_type: Option<String>) -> Option<String> {
    let base = content_type?.split(';').next()?.trim().to_lowercase();
    Some(
        match base.as_str() {
            "audio/mpeg" => "mp3",
            "audio/mp4" => "m4a",
            "audio/flac" => "flac",
            "audio/ogg" => "opus",
            "audio/wav" | "audio/x-wav" | "audio/wave" => "wav",
            "audio/webm" => "webm",
            _ => return None,
        }
        .into(),
    )
}

/// First free "<name> (n).ext" next to `preferred` (preferred itself if free).
#[uniffi::export]
pub fn unique_destination(preferred: String) -> String {
    let p = Path::new(&preferred);
    if !p.exists() {
        return preferred;
    }
    let dir = p.parent().map(Path::to_path_buf).unwrap_or_default();
    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("");
    let base = p.file_stem().and_then(|s| s.to_str()).unwrap_or("track");
    let mut n = 2;
    loop {
        let name = if ext.is_empty() { format!("{base} ({n})") } else { format!("{base} ({n}).{ext}") };
        let c: PathBuf = dir.join(name);
        if !c.exists() {
            return c.to_string_lossy().into_owned();
        }
        n += 1;
    }
}

/// Filesystem-safe filename from a title (no path separators/control chars,
/// trimmed, ≤ 240 UTF-8 bytes on a char boundary).
#[uniffi::export]
pub fn safe_filename(title: String) -> String {
    let cleaned: String = title
        .chars()
        .map(|c| if matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') || c.is_control() { '-' } else { c })
        .collect();
    let mut s = cleaned.trim().trim_matches('.').to_string();
    if s.is_empty() {
        s = "track".into();
    }
    let mut end = s.len().min(240);
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ledger_and_failures() {
        let d = std::env::temp_dir().join(format!("core-store-{}", uuid::Uuid::new_v4().simple()));
        store::core_configure(d.to_string_lossy().into_owned());
        downloads_import_legacy(Some(br#"{"youtube:a":"A.m4a"}"#.to_vec()), Some(br#"{"youtube:b":{"lastFailed":0,"strikes":1}}"#.to_vec()));
        assert_eq!(ledger_filename("youtube:a".into()).as_deref(), Some("A.m4a"));
        assert!(!failure_should_skip("youtube:b".into()));
        failure_record("youtube:c".into());
        assert!(failure_should_skip("youtube:c".into()));
        ledger_record("youtube:c".into(), "C.m4a".into());
        assert!(!failure_should_skip("youtube:c".into()));
        assert!(ledger_begin("x".into()) && !ledger_begin("x".into()));
        ledger_end("x".into());
        assert!(ledger_begin("x".into()));
        assert_eq!(ledger_present_ids(vec!["C.m4a".into()]), vec!["youtube:c".to_string()]);
        assert_eq!(safe_filename("a/b: c?".into()), "a-b- c-");
        let _ = std::fs::remove_dir_all(d);
    }
}
