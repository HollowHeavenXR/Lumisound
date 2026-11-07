//! A small persistent cache for derived files the app shouldn't have to
//! rebuild: artwork, ready-to-draw thumbnails, anything keyed by a string.
//!
//! Why: the app kept its artwork in iOS's Caches directory, which the system
//! purges whenever storage runs low, and kept grid thumbnails in memory only
//! — so artwork kept "reloading" after relaunches and on nearly-full
//! devices. This store lives in Application Support (not purged), with a
//! size cap per namespace and least-recently-used eviction, so it can never
//! grow without bound.
//!
//! Layout: `<root>/<namespace>/<sha256(key)>.bin` + `<root>/<namespace>/index.json`
//! (key -> size, last access). Writes are atomic (temp + rename). The index
//! is saved after writes and at most every 30 s of reads.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
struct Entry {
    size: u64,
    /// Unix seconds of the last get/put.
    used: f64,
}

#[derive(Default)]
struct Space {
    entries: HashMap<String, Entry>,
    bytes: u64,
    cap: u64,
    dirty: bool,
    last_save: f64,
    loaded: bool,
}

#[derive(Default)]
struct Store {
    root: Option<PathBuf>,
    spaces: HashMap<String, Space>,
}

static STORE: LazyLock<Mutex<Store>> = LazyLock::new(Default::default);

/// Default per-namespace cap when none was set.
const DEFAULT_CAP: u64 = 128 * 1024 * 1024;

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn file_name(key: &str) -> String {
    format!("{}.bin", hex::encode(&Sha256::digest(key.as_bytes())[..16]))
}

fn ns_dir(root: &Path, ns: &str) -> PathBuf {
    root.join(ns.replace(['/', '\\', '.'], "_"))
}

impl Store {
    fn space(&mut self, ns: &str) -> Option<(PathBuf, &mut Space)> {
        let dir = ns_dir(self.root.as_ref()?, ns);
        let sp = self.spaces.entry(ns.to_string()).or_insert_with(|| Space { cap: DEFAULT_CAP, ..Default::default() });
        if !sp.loaded {
            sp.loaded = true;
            let _ = std::fs::create_dir_all(&dir);
            if let Ok(raw) = std::fs::read(dir.join("index.json")) {
                if let Ok(e) = serde_json::from_slice::<HashMap<String, Entry>>(&raw) {
                    // Drop entries whose file vanished.
                    sp.entries = e.into_iter().filter(|(k, _)| dir.join(file_name(k)).exists()).collect();
                    sp.bytes = sp.entries.values().map(|e| e.size).sum();
                }
            }
        }
        Some((dir, sp))
    }
}

fn save_index(dir: &Path, sp: &mut Space) {
    if let Ok(b) = serde_json::to_vec(&sp.entries) {
        let tmp = dir.join(format!(".index-{}.tmp", uuid::Uuid::new_v4().simple()));
        if std::fs::write(&tmp, b).is_ok() && std::fs::rename(&tmp, dir.join("index.json")).is_ok() {
            sp.dirty = false;
            sp.last_save = now();
        } else {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

fn evict(dir: &Path, sp: &mut Space) {
    if sp.bytes <= sp.cap {
        return;
    }
    let mut by_age: Vec<(String, f64, u64)> = sp.entries.iter().map(|(k, e)| (k.clone(), e.used, e.size)).collect();
    by_age.sort_by(|a, b| a.1.total_cmp(&b.1));
    // Evict down to 90% of the cap so we don't evict on every put.
    let target = sp.cap / 10 * 9;
    for (k, _, size) in by_age {
        if sp.bytes <= target {
            break;
        }
        let _ = std::fs::remove_file(dir.join(file_name(&k)));
        sp.entries.remove(&k);
        sp.bytes = sp.bytes.saturating_sub(size);
        sp.dirty = true;
    }
}

/// Where the store lives (call once at launch; Application Support).
#[uniffi::export]
pub fn blob_cache_configure(root_dir: String) {
    let mut s = STORE.lock().unwrap();
    let root = PathBuf::from(root_dir);
    let _ = std::fs::create_dir_all(&root);
    s.root = Some(root);
    s.spaces.clear();
}

/// Size cap for a namespace (bytes); evicts at once if over.
#[uniffi::export]
pub fn blob_cache_set_cap(namespace: String, max_bytes: u64) {
    let mut s = STORE.lock().unwrap();
    if let Some((dir, sp)) = s.space(&namespace) {
        sp.cap = max_bytes.max(1024 * 1024);
        evict(&dir, sp);
        if sp.dirty {
            save_index(&dir, sp);
        }
    }
}

/// Store `data` under `key` (replaces). False when unconfigured or the write failed.
#[uniffi::export]
pub fn blob_cache_put(namespace: String, key: String, data: Vec<u8>) -> bool {
    let mut s = STORE.lock().unwrap();
    let Some((dir, sp)) = s.space(&namespace) else { return false };
    let path = dir.join(file_name(&key));
    let tmp = dir.join(format!(".{}.tmp", uuid::Uuid::new_v4().simple()));
    if std::fs::write(&tmp, &data).is_err() || std::fs::rename(&tmp, &path).is_err() {
        let _ = std::fs::remove_file(&tmp);
        return false;
    }
    let size = data.len() as u64;
    if let Some(old) = sp.entries.insert(key, Entry { size, used: now() }) {
        sp.bytes = sp.bytes.saturating_sub(old.size);
    }
    sp.bytes += size;
    sp.dirty = true;
    evict(&dir, sp);
    save_index(&dir, sp);
    true
}

/// Path of the stored file for `key` (for zero-copy reads such as ImageIO
/// downsampling), marking it used. None on a miss.
#[uniffi::export]
pub fn blob_cache_path(namespace: String, key: String) -> Option<String> {
    let mut s = STORE.lock().unwrap();
    let (dir, sp) = s.space(&namespace)?;
    let e = sp.entries.get_mut(&key)?;
    let path = dir.join(file_name(&key));
    if !path.exists() {
        let size = e.size;
        sp.entries.remove(&key);
        sp.bytes = sp.bytes.saturating_sub(size);
        sp.dirty = true;
        return None;
    }
    e.used = now();
    sp.dirty = true;
    if now() - sp.last_save > 30.0 {
        save_index(&dir, sp);
    }
    Some(path.to_string_lossy().into_owned())
}

#[uniffi::export]
pub fn blob_cache_get(namespace: String, key: String) -> Option<Vec<u8>> {
    let p = blob_cache_path(namespace, key)?;
    std::fs::read(p).ok()
}

#[uniffi::export]
pub fn blob_cache_remove(namespace: String, key: String) {
    let mut s = STORE.lock().unwrap();
    if let Some((dir, sp)) = s.space(&namespace) {
        if let Some(e) = sp.entries.remove(&key) {
            let _ = std::fs::remove_file(dir.join(file_name(&key)));
            sp.bytes = sp.bytes.saturating_sub(e.size);
            save_index(&dir, sp);
        }
    }
}

/// Empty a namespace.
#[uniffi::export]
pub fn blob_cache_clear(namespace: String) {
    let mut s = STORE.lock().unwrap();
    if let Some((dir, sp)) = s.space(&namespace) {
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        sp.entries.clear();
        sp.bytes = 0;
        save_index(&dir, sp);
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct BlobCacheStats {
    pub entries: u64,
    pub bytes: u64,
    pub cap: u64,
}

#[uniffi::export]
pub fn blob_cache_stats(namespace: String) -> BlobCacheStats {
    let mut s = STORE.lock().unwrap();
    match s.space(&namespace) {
        Some((_, sp)) => BlobCacheStats { entries: sp.entries.len() as u64, bytes: sp.bytes, cap: sp.cap },
        None => BlobCacheStats { entries: 0, bytes: 0, cap: 0 },
    }
}

/// Persist pending index updates (e.g. when the app backgrounds).
#[uniffi::export]
pub fn blob_cache_flush() {
    let mut s = STORE.lock().unwrap();
    let Some(root) = s.root.clone() else { return };
    for (ns, sp) in s.spaces.iter_mut() {
        if sp.dirty {
            save_index(&ns_dir(&root, ns), sp);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn put_get_evict_persist() {
        let d = std::env::temp_dir().join(format!("blob-{}", uuid::Uuid::new_v4()));
        blob_cache_configure(d.to_string_lossy().into());
        let ns = "art".to_string();
        blob_cache_set_cap(ns.clone(), 1024 * 1024); // 1 MiB
        let chunk = vec![7u8; 300 * 1024];
        for i in 0..3 {
            assert!(blob_cache_put(ns.clone(), format!("song {i}/x?.jpg"), chunk.clone()));
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        // Touch song 0 so song 1 is the least recently used.
        assert_eq!(blob_cache_get(ns.clone(), "song 0/x?.jpg".into()).unwrap().len(), chunk.len());
        std::thread::sleep(std::time::Duration::from_millis(20));
        assert!(blob_cache_put(ns.clone(), "song 3/x?.jpg".into(), chunk.clone()));
        let st = blob_cache_stats(ns.clone());
        assert!(st.bytes <= 1024 * 1024, "{st:?}");
        assert!(blob_cache_get(ns.clone(), "song 1/x?.jpg".into()).is_none(), "LRU entry evicted");
        assert!(blob_cache_get(ns.clone(), "song 0/x?.jpg".into()).is_some());
        // Survives a "relaunch" (reconfigure reloads the index from disk).
        blob_cache_flush();
        blob_cache_configure(d.to_string_lossy().into());
        assert!(blob_cache_path(ns.clone(), "song 3/x?.jpg".into()).is_some());
        assert_eq!(blob_cache_stats(ns.clone()).entries, st.entries);
        blob_cache_remove(ns.clone(), "song 3/x?.jpg".into());
        assert!(blob_cache_get(ns.clone(), "song 3/x?.jpg".into()).is_none());
        blob_cache_clear(ns.clone());
        assert_eq!(blob_cache_stats(ns).entries, 0);
        let _ = std::fs::remove_dir_all(d);
    }
}
