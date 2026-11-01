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

// ---- time capsules --------------------------------------------------------------------------

const CAPSULES: &str = "time_capsules";

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug)]
pub struct TimeCapsuleRecord {
    pub id: String,
    pub name: String,
    pub message: String,
    pub song_ids: Vec<String>,
    pub created_at: f64,
    pub unlock_at: f64,
    pub opened_at: Option<f64>,
}

#[uniffi::export]
pub fn capsules_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(CAPSULES) {
        return;
    }
    #[derive(Deserialize)]
    struct L {
        id: String,
        name: String,
        #[serde(default)]
        message: String,
        #[serde(rename = "songIDs", default)]
        song_ids: Vec<String>,
        #[serde(rename = "createdAt")]
        created_at: f64,
        #[serde(rename = "unlockAt")]
        unlock_at: f64,
        #[serde(rename = "openedAt")]
        opened_at: Option<f64>,
    }
    let v: Vec<L> = serde_json::from_slice(&json).unwrap_or_default();
    let out: Vec<TimeCapsuleRecord> = v
        .into_iter()
        .map(|c| TimeCapsuleRecord { id: c.id, name: c.name, message: c.message, song_ids: c.song_ids, created_at: c.created_at + APPLE_EPOCH, unlock_at: c.unlock_at + APPLE_EPOCH, opened_at: c.opened_at.map(|d| d + APPLE_EPOCH) })
        .collect();
    store::save(CAPSULES, &out);
}

#[uniffi::export]
pub fn capsules_all() -> Vec<TimeCapsuleRecord> {
    store::load(CAPSULES)
}

/// Seal a new capsule (newest first); None when the name or songs are empty.
#[uniffi::export]
pub fn capsule_seal(name: String, message: String, song_ids: Vec<String>, unlock_at: f64) -> Option<TimeCapsuleRecord> {
    let name = name.trim().to_string();
    if name.is_empty() || song_ids.is_empty() {
        return None;
    }
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<TimeCapsuleRecord> = store::load(CAPSULES);
    let c = TimeCapsuleRecord { id: uuid::Uuid::new_v4().to_string().to_uppercase(), name, message, song_ids, created_at: now(), unlock_at, opened_at: None };
    v.insert(0, c.clone());
    store::save(CAPSULES, &v);
    Some(c)
}

#[uniffi::export]
pub fn capsule_mark_opened(id: String) {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<TimeCapsuleRecord> = store::load(CAPSULES);
    if let Some(c) = v.iter_mut().find(|c| c.id == id && c.opened_at.is_none()) {
        c.opened_at = Some(now());
        store::save(CAPSULES, &v);
    }
}

#[uniffi::export]
pub fn capsule_delete(id: String) {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<TimeCapsuleRecord> = store::load(CAPSULES);
    v.retain(|c| c.id != id);
    store::save(CAPSULES, &v);
}

// ---- deleted playlists (30-day trash) ---------------------------------------------------------

const TRASH: &str = "deleted_playlists";
const TRASH_DAYS: f64 = 30.0;

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug)]
pub struct TrashEntry {
    pub id: String,
    /// The playlist as the app encodes it (opaque to the core).
    pub playlist_json: String,
    pub deleted_at: f64,
}

#[uniffi::export]
pub fn trash_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(TRASH) {
        return;
    }
    let v: Vec<serde_json::Value> = serde_json::from_slice(&json).unwrap_or_default();
    let out: Vec<TrashEntry> = v
        .into_iter()
        .filter_map(|e| Some(TrashEntry { id: e["id"].as_str()?.to_string(), playlist_json: e["playlist"].to_string(), deleted_at: e["deletedAt"].as_f64()? + APPLE_EPOCH }))
        .collect();
    store::save(TRASH, &out);
}

fn trash_load_fresh() -> Vec<TrashEntry> {
    let mut v: Vec<TrashEntry> = store::load(TRASH);
    let cutoff = now() - TRASH_DAYS * 86_400.0;
    let before = v.len();
    v.retain(|e| e.deleted_at >= cutoff);
    if v.len() != before {
        store::save(TRASH, &v);
    }
    v
}

/// Entries newer than 30 days (expired ones are purged), newest first.
#[uniffi::export]
pub fn trash_entries() -> Vec<TrashEntry> {
    let _g = LOCK.lock().unwrap();
    trash_load_fresh()
}

#[uniffi::export]
pub fn trash_add(playlist_json: String) -> TrashEntry {
    let _g = LOCK.lock().unwrap();
    let mut v = trash_load_fresh();
    let e = TrashEntry { id: uuid::Uuid::new_v4().to_string().to_uppercase(), playlist_json, deleted_at: now() };
    v.insert(0, e.clone());
    store::save(TRASH, &v);
    e
}

/// Remove and return the playlist JSON (restore), or just drop it (purge).
#[uniffi::export]
pub fn trash_take(entry_id: String) -> Option<String> {
    let _g = LOCK.lock().unwrap();
    let mut v = trash_load_fresh();
    let i = v.iter().position(|e| e.id == entry_id)?;
    let e = v.remove(i);
    store::save(TRASH, &v);
    Some(e.playlist_json)
}

#[uniffi::export]
pub fn trash_purge_all() {
    let _g = LOCK.lock().unwrap();
    store::save(TRASH, &Vec::<TrashEntry>::new());
}

// ---- weekly listening goal ------------------------------------------------------------------

const GOAL: &str = "listening_goal";

#[derive(Serialize, Deserialize, Default)]
struct Goal {
    target_minutes: Option<i64>,
    congratulated_week: Option<String>,
}

/// ISO-8601 week key ("2026-W44") in UTC.
pub fn iso_week_key(unix: f64) -> String {
    use chrono::Datelike;
    let d = chrono::DateTime::from_timestamp(unix as i64, 0).unwrap_or_default().date_naive();
    let w = d.iso_week();
    format!("{}-W{}", w.year(), w.week())
}

#[uniffi::export]
pub fn goal_import_legacy(target_minutes: i64, congratulated_week: Option<String>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(GOAL) {
        return;
    }
    store::save(GOAL, &Goal { target_minutes: (target_minutes > 0).then_some(target_minutes), congratulated_week });
}

#[uniffi::export]
pub fn goal_target() -> Option<i64> {
    let g: Goal = store::load(GOAL);
    g.target_minutes.filter(|t| *t > 0)
}

#[uniffi::export]
pub fn goal_set_target(minutes: Option<i64>) {
    let _g = LOCK.lock().unwrap();
    let mut g: Goal = store::load(GOAL);
    g.target_minutes = minutes.filter(|m| *m > 0);
    store::save(GOAL, &g);
}

/// True once per ISO week, the first time progress reaches the target.
#[uniffi::export]
pub fn goal_should_congratulate(progress_minutes: i64) -> bool {
    let _g = LOCK.lock().unwrap();
    let mut g: Goal = store::load(GOAL);
    let Some(t) = g.target_minutes.filter(|t| *t > 0) else { return false };
    if progress_minutes < t {
        return false;
    }
    let wk = iso_week_key(now());
    if g.congratulated_week.as_deref() == Some(&wk) {
        return false;
    }
    g.congratulated_week = Some(wk);
    store::save(GOAL, &g);
    true
}

// ---- recently deleted songs (files moved into a trash folder for 30 days) -----------------------

const RD: &str = "recently_deleted";
const RD_RETENTION: f64 = 30.0 * 86_400.0;

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug)]
pub struct DeletedSong {
    pub id: String,
    /// The Song as the app encodes it (opaque to the core).
    pub song_json: String,
    pub trash_filename: String,
    pub deleted_at: f64,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct RestoredSong {
    pub song_json: String,
    pub path: String,
}

fn move_file(src: &std::path::Path, dst: &std::path::Path) -> std::io::Result<()> {
    match std::fs::rename(src, dst) {
        Ok(()) => Ok(()),
        Err(_) => {
            std::fs::copy(src, dst)?;
            std::fs::remove_file(src)
        }
    }
}

#[uniffi::export]
pub fn deleted_songs_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(RD) {
        return;
    }
    let v: Vec<serde_json::Value> = serde_json::from_slice(&json).unwrap_or_default();
    let out: Vec<DeletedSong> = v
        .into_iter()
        .filter_map(|e| {
            Some(DeletedSong { id: e["id"].as_str()?.to_string(), song_json: e["song"].to_string(), trash_filename: e["trashFilename"].as_str()?.to_string(), deleted_at: e["deletedAt"].as_f64()? + APPLE_EPOCH })
        })
        .collect();
    store::save(RD, &out);
}

#[uniffi::export]
pub fn deleted_songs() -> Vec<DeletedSong> {
    store::load(RD)
}

/// Move `src_path` into `trash_dir` and remember the song; false if the move failed.
#[uniffi::export]
pub fn deleted_song_trash(song_id: String, song_json: String, src_path: String, trash_dir: String) -> bool {
    let src = std::path::Path::new(&src_path);
    let _ = std::fs::create_dir_all(&trash_dir);
    let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("");
    let name = format!("{}.{ext}", uuid::Uuid::new_v4().to_string().to_uppercase());
    if move_file(src, &std::path::Path::new(&trash_dir).join(&name)).is_err() {
        return false;
    }
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<DeletedSong> = store::load(RD);
    v.push(DeletedSong { id: song_id, song_json, trash_filename: name, deleted_at: now() });
    store::save(RD, &v);
    true
}

/// Move the file back into `restore_dir` (as `original_name`, de-duplicated)
/// and return the stored song + its new path.
#[uniffi::export]
pub fn deleted_song_restore(entry_id: String, trash_dir: String, restore_dir: String, original_name: Option<String>) -> Option<RestoredSong> {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<DeletedSong> = store::load(RD);
    let i = v.iter().position(|e| e.id == entry_id)?;
    let src = std::path::Path::new(&trash_dir).join(&v[i].trash_filename);
    if !src.exists() {
        v.remove(i);
        store::save(RD, &v);
        return None;
    }
    let _ = std::fs::create_dir_all(&restore_dir);
    let name = original_name.filter(|n| !n.is_empty()).unwrap_or_else(|| v[i].trash_filename.clone());
    let dest = crate::downloads::unique_destination(std::path::Path::new(&restore_dir).join(&name).to_string_lossy().into_owned());
    move_file(&src, std::path::Path::new(&dest)).ok()?;
    let e = v.remove(i);
    store::save(RD, &v);
    Some(RestoredSong { song_json: e.song_json, path: dest })
}

#[uniffi::export]
pub fn deleted_song_purge(entry_id: String, trash_dir: String) {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<DeletedSong> = store::load(RD);
    if let Some(i) = v.iter().position(|e| e.id == entry_id) {
        let _ = std::fs::remove_file(std::path::Path::new(&trash_dir).join(&v[i].trash_filename));
        v.remove(i);
        store::save(RD, &v);
    }
}

#[uniffi::export]
pub fn deleted_songs_purge_all(trash_dir: String) {
    let _g = LOCK.lock().unwrap();
    let v: Vec<DeletedSong> = store::load(RD);
    for e in &v {
        let _ = std::fs::remove_file(std::path::Path::new(&trash_dir).join(&e.trash_filename));
    }
    store::save(RD, &Vec::<DeletedSong>::new());
}

/// Purge entries older than 30 days; returns how many were removed.
#[uniffi::export]
pub fn deleted_songs_purge_expired(trash_dir: String) -> u32 {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<DeletedSong> = store::load(RD);
    let cutoff = now() - RD_RETENTION;
    let (old, keep): (Vec<DeletedSong>, Vec<DeletedSong>) = v.drain(..).partition(|e| e.deleted_at < cutoff);
    for e in &old {
        let _ = std::fs::remove_file(std::path::Path::new(&trash_dir).join(&e.trash_filename));
    }
    if !old.is_empty() {
        store::save(RD, &keep);
    }
    old.len() as u32
}

// ---- AI metadata-resolve suggestion cache ----------------------------------------------------

const SUGGEST: &str = "intelligence_suggestions";

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug)]
pub struct CachedSuggestion {
    pub title: String,
    pub artist: String,
    pub memory_id: Option<i64>,
}

#[uniffi::export]
pub fn suggestions_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(SUGGEST) {
        return;
    }
    let m: HashMap<String, HashMap<String, String>> = serde_json::from_slice(&json).unwrap_or_default();
    let out: HashMap<String, CachedSuggestion> = m
        .into_iter()
        .filter_map(|(k, e)| Some((k, CachedSuggestion { title: e.get("title")?.clone(), artist: e.get("artist")?.clone(), memory_id: e.get("memory_id").and_then(|m| m.parse().ok()) })))
        .collect();
    store::save(SUGGEST, &out);
}

#[uniffi::export]
pub fn suggestion_lookup(filename: String) -> Option<CachedSuggestion> {
    let m: HashMap<String, CachedSuggestion> = store::load(SUGGEST);
    m.get(&filename).cloned()
}

#[uniffi::export]
pub fn suggestion_store(filename: String, title: String, artist: String, memory_id: Option<i64>) {
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, CachedSuggestion> = store::load(SUGGEST);
    m.insert(filename, CachedSuggestion { title, artist, memory_id });
    store::save(SUGGEST, &m);
}

// ---- tracked (auto-downloading) playlists -----------------------------------------------------

const TRACKED: &str = "tracked_playlists";

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct TrackedPlaylistRecord {
    pub id: String,
    pub url: String,
    pub name: String,
    pub thumbnail_url: String,
    pub date_added: f64,
    pub last_track_count: i64,
    pub auto_download: Option<bool>,
    pub last_auto_check: Option<f64>,
    pub destination_folder: Option<String>,
}

#[uniffi::export]
pub fn tracked_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(TRACKED) {
        return;
    }
    let v: Vec<serde_json::Value> = serde_json::from_slice(&json).unwrap_or_default();
    let out: Vec<TrackedPlaylistRecord> = v
        .into_iter()
        .filter_map(|e| {
            Some(TrackedPlaylistRecord {
                id: e["id"].as_str()?.to_string(),
                url: e["url"].as_str()?.to_string(),
                name: e["name"].as_str().unwrap_or("").to_string(),
                thumbnail_url: e["thumbnailURL"].as_str().unwrap_or("").to_string(),
                date_added: e["dateAdded"].as_f64().unwrap_or(0.0) + APPLE_EPOCH,
                last_track_count: e["lastTrackCount"].as_i64().unwrap_or(0),
                auto_download: e["autoDownload"].as_bool(),
                last_auto_check: e["lastAutoCheck"].as_f64().map(|d| d + APPLE_EPOCH),
                destination_folder: e["destinationFolder"].as_str().map(str::to_string),
            })
        })
        .collect();
    store::save(TRACKED, &out);
}

#[uniffi::export]
pub fn tracked_all() -> Vec<TrackedPlaylistRecord> {
    store::load(TRACKED)
}

/// "Playlist <first 8 of list=…>" or "Tracked Playlist".
pub fn tracked_default_name(url: &str) -> String {
    url::Url::parse(url)
        .ok()
        .and_then(|u| u.query_pairs().find(|(k, _)| k == "list").map(|(_, v)| v.into_owned()))
        .filter(|l| !l.is_empty())
        .map(|l| format!("Playlist {}", l.chars().take(8).collect::<String>()))
        .unwrap_or_else(|| "Tracked Playlist".into())
}

fn tracked_add_locked(v: &mut Vec<TrackedPlaylistRecord>, url: &str, name: &str, thumb: &str) -> bool {
    let url = url.trim();
    if url.is_empty() || v.iter().any(|p| p.url.to_lowercase() == url.to_lowercase()) {
        return false;
    }
    let name = name.trim();
    v.push(TrackedPlaylistRecord {
        id: uuid::Uuid::new_v4().to_string().to_uppercase(),
        url: url.to_string(),
        name: if name.is_empty() { tracked_default_name(url) } else { name.to_string() },
        thumbnail_url: thumb.to_string(),
        date_added: now(),
        last_track_count: 0,
        auto_download: None,
        last_auto_check: None,
        destination_folder: None,
    });
    true
}

/// Add a playlist URL (case-insensitive de-dup); false when empty or already tracked.
#[uniffi::export]
pub fn tracked_add(url: String, name: String, thumbnail_url: String) -> bool {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<TrackedPlaylistRecord> = store::load(TRACKED);
    let ok = tracked_add_locked(&mut v, &url, &name, &thumbnail_url);
    if ok {
        store::save(TRACKED, &v);
    }
    ok
}

#[uniffi::export]
pub fn tracked_remove(id: String) {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<TrackedPlaylistRecord> = store::load(TRACKED);
    v.retain(|p| p.id != id);
    store::save(TRACKED, &v);
}

/// Adds remote playlists not tracked here yet (keeping their auto-download
/// choice and folder).
#[uniffi::export]
pub fn tracked_merge(remote: Vec<TrackedPlaylistRecord>) {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<TrackedPlaylistRecord> = store::load(TRACKED);
    for r in remote {
        if !tracked_add_locked(&mut v, &r.url, &r.name, &r.thumbnail_url) {
            continue;
        }
        let last = v.last_mut().unwrap();
        if r.auto_download.is_some() {
            last.auto_download = r.auto_download;
        }
        if r.destination_folder.is_some() {
            last.destination_folder = r.destination_folder;
        }
    }
    store::save(TRACKED, &v);
}

fn tracked_edit(id: &str, f: impl FnOnce(&mut TrackedPlaylistRecord)) {
    let _g = LOCK.lock().unwrap();
    let mut v: Vec<TrackedPlaylistRecord> = store::load(TRACKED);
    if let Some(p) = v.iter_mut().find(|p| p.id == id) {
        f(p);
        store::save(TRACKED, &v);
    }
}

#[uniffi::export]
pub fn tracked_update_metadata(id: String, track_count: Option<i64>, thumbnail_url: Option<String>, name: Option<String>) {
    tracked_edit(&id, |p| {
        if let Some(c) = track_count {
            p.last_track_count = c;
        }
        if let Some(t) = thumbnail_url.filter(|t| !t.is_empty()) {
            p.thumbnail_url = t;
        }
        if let Some(n) = name.filter(|n| !n.is_empty()) {
            p.name = n;
        }
    });
}

#[uniffi::export]
pub fn tracked_set_auto_download(id: String, on: bool) {
    tracked_edit(&id, |p| p.auto_download = Some(on));
}

#[uniffi::export]
pub fn tracked_set_destination(id: String, folder: String) {
    tracked_edit(&id, |p| p.destination_folder = (!folder.is_empty()).then_some(folder));
}

#[uniffi::export]
pub fn tracked_mark_checked(id: String) {
    tracked_edit(&id, |p| p.last_auto_check = Some(now()));
}
