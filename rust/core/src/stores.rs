//! Per-song user state the app keeps locally and merges from sync: play
//! history (counts + last played), timestamp bookmarks, and resume points
//! for long tracks (audiobooks, mixes, podcasts-as-songs).

use crate::store::{self, APPLE_EPOCH, now};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

static LOCK: Mutex<()> = Mutex::new(());

// ---- play history ---------------------------------------------------------------------------

const HISTORY: &str = "play_history";

#[derive(Serialize, Deserialize, Clone, Copy, Default)]
struct Hist {
    count: i64,
    last: Option<f64>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct PlayHistoryRecord {
    pub song_id: String,
    pub play_count: i64,
    /// Unix seconds.
    pub last_played_at: Option<f64>,
}

fn rec(id: &str, h: &Hist) -> PlayHistoryRecord {
    PlayHistoryRecord { song_id: id.to_string(), play_count: h.count, last_played_at: h.last }
}

/// UserDefaults-era `[songID: {playCount, lastPlayedAt}]` (Apple-epoch dates).
#[uniffi::export]
pub fn play_history_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(HISTORY) {
        return;
    }
    #[derive(Deserialize)]
    struct L {
        #[serde(rename = "playCount", default)]
        play_count: i64,
        #[serde(rename = "lastPlayedAt")]
        last_played_at: Option<f64>,
    }
    let m: HashMap<String, L> = serde_json::from_slice(&json).unwrap_or_default();
    let out: HashMap<String, Hist> = m.into_iter().map(|(k, v)| (k, Hist { count: v.play_count, last: v.last_played_at.map(|d| d + APPLE_EPOCH) })).collect();
    store::save(HISTORY, &out);
}

#[uniffi::export]
pub fn play_history_all() -> Vec<PlayHistoryRecord> {
    let m: HashMap<String, Hist> = store::load(HISTORY);
    m.iter().map(|(k, v)| rec(k, v)).collect()
}

#[uniffi::export]
pub fn play_history_record(song_id: String) -> Option<PlayHistoryRecord> {
    if song_id.is_empty() {
        return None;
    }
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, Hist> = store::load(HISTORY);
    let e = m.entry(song_id.clone()).or_default();
    e.count += 1;
    e.last = Some(now());
    let r = rec(&song_id, e);
    store::save(HISTORY, &m);
    Some(r)
}

/// Keep the higher count and the later date per song; true when anything changed.
#[uniffi::export]
pub fn play_history_merge(remote: Vec<PlayHistoryRecord>) -> bool {
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, Hist> = store::load(HISTORY);
    let mut changed = false;
    for r in remote {
        let e = m.entry(r.song_id).or_default();
        if r.play_count > e.count {
            e.count = r.play_count;
            changed = true;
        }
        if let Some(d) = r.last_played_at {
            if d > e.last.unwrap_or(f64::MIN) {
                e.last = Some(d);
                changed = true;
            }
        }
    }
    if changed {
        store::save(HISTORY, &m);
    }
    changed
}

#[uniffi::export]
pub fn play_history_rekey(old_id: String, new_id: String) {
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, Hist> = store::load(HISTORY);
    if old_id != new_id {
        if let Some(e) = m.remove(&old_id) {
            m.insert(new_id, e);
            store::save(HISTORY, &m);
        }
    }
}

#[uniffi::export]
pub fn play_history_prune(valid_ids: Vec<String>) {
    let keep: HashSet<String> = valid_ids.into_iter().collect();
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, Hist> = store::load(HISTORY);
    let before = m.len();
    m.retain(|k, _| keep.contains(k));
    if m.len() != before {
        store::save(HISTORY, &m);
    }
}

// ---- bookmarks ------------------------------------------------------------------------------

const BOOKMARKS: &str = "bookmarks";

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct BookmarkRecord {
    pub song_id: String,
    pub id: String,
    pub timestamp: f64,
    pub label: String,
    /// Unix seconds.
    pub created_at: f64,
}

#[uniffi::export]
pub fn bookmarks_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(BOOKMARKS) {
        return;
    }
    #[derive(Deserialize)]
    struct L {
        id: String,
        timestamp: f64,
        #[serde(default)]
        label: String,
        #[serde(rename = "createdAt", default)]
        created_at: f64,
    }
    let m: HashMap<String, Vec<L>> = serde_json::from_slice(&json).unwrap_or_default();
    let out: Vec<BookmarkRecord> = m
        .into_iter()
        .flat_map(|(s, v)| v.into_iter().map(move |b| BookmarkRecord { song_id: s.clone(), id: b.id, timestamp: b.timestamp, label: b.label, created_at: b.created_at + APPLE_EPOCH }))
        .collect();
    store::save(BOOKMARKS, &out);
}

#[uniffi::export]
pub fn bookmarks_all() -> Vec<BookmarkRecord> {
    store::load(BOOKMARKS)
}

#[uniffi::export]
pub fn bookmark_add(song_id: String, timestamp: f64, label: String) -> BookmarkRecord {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<BookmarkRecord> = store::load(BOOKMARKS);
    let b = BookmarkRecord { song_id, id: uuid::Uuid::new_v4().to_string().to_uppercase(), timestamp, label, created_at: now() };
    v.push(b.clone());
    store::save(BOOKMARKS, &v);
    b
}

#[uniffi::export]
pub fn bookmark_remove(song_id: String, bookmark_id: String) {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<BookmarkRecord> = store::load(BOOKMARKS);
    v.retain(|b| !(b.song_id == song_id && b.id == bookmark_id));
    store::save(BOOKMARKS, &v);
}

/// Adds remote bookmarks whose id isn't known locally; true when any were added.
#[uniffi::export]
pub fn bookmarks_merge(remote: Vec<BookmarkRecord>) -> bool {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<BookmarkRecord> = store::load(BOOKMARKS);
    let known: HashSet<(String, String)> = v.iter().map(|b| (b.song_id.clone(), b.id.clone())).collect();
    let add: Vec<BookmarkRecord> = remote.into_iter().filter(|b| !known.contains(&(b.song_id.clone(), b.id.clone()))).collect();
    if add.is_empty() {
        return false;
    }
    v.extend(add);
    store::save(BOOKMARKS, &v);
    true
}

// ---- long-track resume ----------------------------------------------------------------------

const RESUME: &str = "long_track_resume";
const MIN_DURATION: f64 = 20.0 * 60.0;
const NEAR_END: f64 = 30.0;

#[derive(Serialize, Deserialize, Clone, Copy)]
struct Resume {
    position: f64,
    updated_at: f64,
}

#[uniffi::export]
pub fn long_resume_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(RESUME) {
        return;
    }
    #[derive(Deserialize)]
    struct L {
        position: f64,
        #[serde(rename = "updatedAt", default)]
        updated_at: f64,
    }
    let m: HashMap<String, L> = serde_json::from_slice(&json).unwrap_or_default();
    let out: HashMap<String, Resume> = m.into_iter().map(|(k, v)| (k, Resume { position: v.position, updated_at: v.updated_at + APPLE_EPOCH })).collect();
    store::save(RESUME, &out);
}

/// Where to resume a ≥20-minute track (None near the start or the last 30 s).
#[uniffi::export]
pub fn long_resume_position(song_id: String, duration: f64) -> Option<f64> {
    if duration < MIN_DURATION {
        return None;
    }
    let m: HashMap<String, Resume> = store::load(RESUME);
    m.get(&song_id).map(|r| r.position).filter(|p| *p > 5.0 && *p < duration - NEAR_END)
}

#[uniffi::export]
pub fn long_resume_record(song_id: String, duration: f64, position: f64) {
    if duration < MIN_DURATION {
        return;
    }
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, Resume> = store::load(RESUME);
    m.insert(song_id, Resume { position, updated_at: now() });
    store::save(RESUME, &m);
}

#[uniffi::export]
pub fn long_resume_clear(song_id: String) {
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, Resume> = store::load(RESUME);
    if m.remove(&song_id).is_some() {
        store::save(RESUME, &m);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn history_bookmarks_resume() {
        let d = std::env::temp_dir().join(format!("stores-{}", uuid::Uuid::new_v4().simple()));
        store::core_configure(d.to_string_lossy().into());
        play_history_import_legacy(br#"{"a":{"playCount":3,"lastPlayedAt":100}}"#.to_vec());
        assert_eq!(play_history_record("a".into()).unwrap().play_count, 4);
        assert!(play_history_merge(vec![PlayHistoryRecord { song_id: "a".into(), play_count: 9, last_played_at: None }]));
        play_history_rekey("a".into(), "b".into());
        assert_eq!(play_history_all()[0].song_id, "b");
        let bm = bookmark_add("s".into(), 12.5, "drop".into());
        assert!(!bookmarks_merge(vec![bm.clone()]));
        bookmark_remove("s".into(), bm.id);
        assert!(bookmarks_all().is_empty());
        long_resume_record("x".into(), 3600.0, 600.0);
        assert_eq!(long_resume_position("x".into(), 3600.0), Some(600.0));
        long_resume_record("y".into(), 1210.0, 1190.0);
        assert_eq!(long_resume_position("y".into(), 1210.0), None); // inside the last 30 s
        let _ = std::fs::remove_dir_all(d);
    }
}
