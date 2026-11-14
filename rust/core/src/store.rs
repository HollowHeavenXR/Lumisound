//! Small persistent documents (JSON, one file per namespace) in the app's
//! data directory, written atomically. Replaces UserDefaults blobs for
//! state the core owns (download ledger, failure cool-offs, histories…).
//!
//! Reads come from an in-memory cache. Writes update the cache at once and
//! go to disk on a background thread, coalesced over a short window, so a
//! caller on the main thread (a song starting, a skip) never waits on disk.
//! `core_flush` writes everything pending synchronously; the app calls it
//! when it goes to the background.

use serde::de::DeserializeOwned;
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Condvar, LazyLock, Mutex, RwLock};
use std::time::Duration;

static DIR: RwLock<Option<PathBuf>> = RwLock::new(None);
static CACHE: LazyLock<Mutex<HashMap<String, serde_json::Value>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
/// Parsed copies of the documents read through `load_shared`, dropped when
/// the namespace is saved. A lookup in a big cache (tempo, intro offsets,
/// skip counts: one entry per song) is then a hash probe; it used to copy
/// and re-parse the whole document on every call, on the caller's thread.
static TYPED: LazyLock<Mutex<HashMap<String, std::sync::Arc<dyn std::any::Any + Send + Sync>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// Namespaces waiting to be written, with the file each one goes to (taken
/// at save time, so a later `core_configure` can't redirect a pending write).
static DIRTY: Mutex<Vec<(String, PathBuf)>> = Mutex::new(Vec::new());
/// Counts saves, so `load_shared` can tell a save happened while it parsed.
static SAVES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static WAKE: Condvar = Condvar::new();
/// Serialises file writes between the writer thread and `core_flush`.
static WRITE: Mutex<()> = Mutex::new(());
/// How long the writer waits after the first change before writing, so a
/// burst of saves (a scan recording many tracks) becomes one write.
const COALESCE: Duration = Duration::from_millis(250);

static WRITER: LazyLock<()> = LazyLock::new(|| {
    let _ = std::thread::Builder::new().name("lumisound-store".into()).spawn(|| loop {
        {
            let mut d = DIRTY.lock().unwrap();
            while d.is_empty() {
                d = WAKE.wait(d).unwrap();
            }
        }
        std::thread::sleep(COALESCE);
        write_pending();
    });
});

/// Set once at launch: where core state lives (Application Support/Lumisound).
#[uniffi::export]
pub fn core_configure(data_dir: String) {
    core_flush();
    let p = PathBuf::from(data_dir);
    let _ = std::fs::create_dir_all(&p);
    *DIR.write().unwrap() = Some(p);
    CACHE.lock().unwrap().clear();
    TYPED.lock().unwrap().clear();
}

/// Write every pending change to disk now (app backgrounding / termination).
#[uniffi::export]
pub fn core_flush() {
    write_pending();
}

fn write_pending() {
    let _w = WRITE.lock().unwrap();
    let pending = std::mem::take(&mut *DIRTY.lock().unwrap());
    for (ns, p) in pending {
        // Serialise the newest cached value, not the one from save time.
        let bytes = CACHE.lock().unwrap().get(&ns).and_then(|v| serde_json::to_vec(v).ok());
        let Some(bytes) = bytes else { continue };
        write_atomic(&p, &bytes);
    }
}

fn write_atomic(p: &std::path::Path, bytes: &[u8]) {
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = p.with_extension("json.tmp");
    if std::fs::write(&tmp, bytes).is_ok() {
        let _ = std::fs::rename(&tmp, p);
    }
}

fn path(ns: &str) -> Option<PathBuf> {
    DIR.read().unwrap().as_ref().map(|d| d.join(format!("{ns}.json")))
}

/// True once a namespace has been written (used to run one-time migrations).
pub fn exists(ns: &str) -> bool {
    CACHE.lock().unwrap().contains_key(ns) || path(ns).is_some_and(|p| p.exists())
}

pub fn load<T: DeserializeOwned + Default>(ns: &str) -> T {
    if let Some(v) = CACHE.lock().unwrap().get(ns) {
        // Parsed straight from the cached value (no copy of the document).
        return T::deserialize(v).unwrap_or_default();
    }
    let v: serde_json::Value = path(ns).and_then(|p| std::fs::read(p).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(serde_json::Value::Null);
    let out = T::deserialize(&v).unwrap_or_default();
    CACHE.lock().unwrap().entry(ns.to_string()).or_insert(v);
    out
}

/// `load` for read-only lookups: the parsed document is shared until the
/// namespace is next saved. Use it wherever a caller reads one entry out of
/// a per-song map.
pub fn load_shared<T: DeserializeOwned + Default + Send + Sync + 'static>(ns: &str) -> std::sync::Arc<T> {
    if let Some(hit) = TYPED.lock().unwrap().get(ns).cloned().and_then(|a| a.downcast::<T>().ok()) {
        return hit;
    }
    let seen = SAVES.load(std::sync::atomic::Ordering::Acquire);
    let fresh = std::sync::Arc::new(load::<T>(ns));
    let mut typed = TYPED.lock().unwrap();
    // Keep it only if nothing was saved while it was being parsed (a save
    // in between would otherwise leave this stale copy behind for good).
    if SAVES.load(std::sync::atomic::Ordering::Acquire) == seen {
        typed.insert(ns.to_string(), fresh.clone());
    }
    fresh
}

pub fn save<T: Serialize>(ns: &str, value: &T) {
    let Ok(v) = serde_json::to_value(value) else { return };
    {
        // Both under the value lock, so a reader can't pair the new value
        // with a stale parsed copy.
        let mut c = CACHE.lock().unwrap();
        c.insert(ns.to_string(), v);
        let mut typed = TYPED.lock().unwrap();
        SAVES.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        typed.remove(ns);
    }
    let Some(p) = path(ns) else { return };
    LazyLock::force(&WRITER);
    let mut d = DIRTY.lock().unwrap();
    if !d.iter().any(|(n, q)| n == ns && *q == p) {
        d.push((ns.to_string(), p));
    }
    WAKE.notify_one();
}

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Apple reference date (2001-01-01) offset, for importing JSONEncoder dates.
pub const APPLE_EPOCH: f64 = 978_307_200.0;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_reach_disk_in_background_and_on_flush() {
        let d = std::env::temp_dir().join(format!("store-wb-{}", uuid::Uuid::new_v4().simple()));
        let f = d.join("wb_test.json");
        std::fs::create_dir_all(&d).unwrap();
        // Use the private path directly so this test doesn't race other
        // tests over the global data dir.
        CACHE.lock().unwrap().insert("wb_test".into(), serde_json::json!({"n": 1}));
        DIRTY.lock().unwrap().push(("wb_test".into(), f.clone()));
        WAKE.notify_one();
        core_flush();
        assert_eq!(std::fs::read_to_string(&f).unwrap(), r#"{"n":1}"#);
        // Coalesced: two changes, newest value wins.
        CACHE.lock().unwrap().insert("wb_test".into(), serde_json::json!({"n": 2}));
        DIRTY.lock().unwrap().push(("wb_test".into(), f.clone()));
        CACHE.lock().unwrap().insert("wb_test".into(), serde_json::json!({"n": 3}));
        LazyLock::force(&WRITER);
        WAKE.notify_one();
        for _ in 0..40 {
            if std::fs::read_to_string(&f).ok().as_deref() == Some(r#"{"n":3}"#) {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        assert_eq!(std::fs::read_to_string(&f).unwrap(), r#"{"n":3}"#);
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn shared_reads_follow_saves() {
        let ns = format!("shared-{}", uuid::Uuid::new_v4().simple());
        let mut m: HashMap<String, f64> = HashMap::new();
        m.insert("a".into(), 1.0);
        save(&ns, &m);
        let first = load_shared::<HashMap<String, f64>>(&ns);
        assert_eq!(first.get("a"), Some(&1.0));
        // Same parsed copy until the next save.
        assert!(std::sync::Arc::ptr_eq(&first, &load_shared::<HashMap<String, f64>>(&ns)));
        m.insert("b".into(), 2.0);
        save(&ns, &m);
        let second = load_shared::<HashMap<String, f64>>(&ns);
        assert_eq!(second.get("b"), Some(&2.0));
        assert_eq!(load::<HashMap<String, f64>>(&ns).len(), 2);
        // A different type for the same namespace re-parses instead of failing.
        assert_eq!(load_shared::<HashMap<String, serde_json::Value>>(&ns).len(), 2);
    }

    #[test]
    fn a_lookup_in_a_large_map_is_cheap() {
        let ns = format!("big-{}", uuid::Uuid::new_v4().simple());
        let m: HashMap<String, f64> = (0..6000).map(|i| (format!("/var/mobile/Containers/Data/Application/Documents/Imported Music/Folder {}/Track number {i}.opus.lms|1731400000|4812345", i % 40), i as f64)).collect();
        save(&ns, &m);
        let t = std::time::Instant::now();
        let mut hits = 0;
        for i in 0..6000 {
            let k = format!("/var/mobile/Containers/Data/Application/Documents/Imported Music/Folder {}/Track number {i}.opus.lms|1731400000|4812345", i % 40);
            let mut doc = load_shared::<HashMap<String, f64>>(&ns);
            if doc.is_empty() {
                // Another test reconfigured the (process-wide) store, which
                // drops unsaved documents; put it back and carry on.
                save(&ns, &m);
                doc = load_shared::<HashMap<String, f64>>(&ns);
            }
            hits += usize::from(doc.contains_key(&k));
        }
        assert_eq!(hits, 6000);
        // 6000 lookups: was 6000 full copies + parses of a 6000-entry map.
        assert!(t.elapsed() < Duration::from_millis(if cfg!(debug_assertions) { 1500 } else { 250 }), "{:?}", t.elapsed());
    }
}
