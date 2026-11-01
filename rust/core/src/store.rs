//! Small persistent documents (JSON, one file per namespace) in the app's
//! data directory, written atomically. Replaces UserDefaults blobs for
//! state the core owns (download ledger, failure cool-offs, histories…).

use serde::Serialize;
use serde::de::DeserializeOwned;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex, RwLock};

static DIR: RwLock<Option<PathBuf>> = RwLock::new(None);
static CACHE: LazyLock<Mutex<HashMap<String, serde_json::Value>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// Set once at launch: where core state lives (Application Support/Lumisound).
#[uniffi::export]
pub fn core_configure(data_dir: String) {
    let p = PathBuf::from(data_dir);
    let _ = std::fs::create_dir_all(&p);
    *DIR.write().unwrap() = Some(p);
    CACHE.lock().unwrap().clear();
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
        return serde_json::from_value(v.clone()).unwrap_or_default();
    }
    let v: serde_json::Value = path(ns).and_then(|p| std::fs::read(p).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(serde_json::Value::Null);
    CACHE.lock().unwrap().insert(ns.to_string(), v.clone());
    serde_json::from_value(v).unwrap_or_default()
}

pub fn save<T: Serialize>(ns: &str, value: &T) {
    let Ok(v) = serde_json::to_value(value) else { return };
    CACHE.lock().unwrap().insert(ns.to_string(), v.clone());
    let Some(p) = path(ns) else { return };
    let tmp = p.with_extension("json.tmp");
    if std::fs::write(&tmp, serde_json::to_vec(&v).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(&tmp, &p);
    }
}

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Apple reference date (2001-01-01) offset, for importing JSONEncoder dates.
pub const APPLE_EPOCH: f64 = 978_307_200.0;
