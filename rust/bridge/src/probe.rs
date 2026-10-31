//! ffprobe helpers: integrity checks for downloads, and the tag cache the
//! library scans use (same JSON file as the Python bridge's _FfprobeCache).

use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;
use tokio::process::Command;

async fn ffprobe_json(path: &Path, timeout: Duration) -> Option<Value> {
    let fut = Command::new("ffprobe")
        .args(["-v", "quiet", "-print_format", "json", "-show_streams", "-show_format"])
        .arg(path)
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(timeout, fut).await.ok()?.ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}

/// `_verify_downloaded_audio`: has an audio stream with a real duration,
/// and (when known) is not truncated by more than max(10s, 15%).
pub async fn verify_audio(path: &Path, expected: Option<f64>) -> bool {
    let Some(d) = ffprobe_json(path, Duration::from_secs(15)).await else { return false };
    let has_audio = d["streams"].as_array().is_some_and(|s| s.iter().any(|s| s["codec_type"] == "audio"));
    let dur = d["format"]["duration"].as_str().and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
    if !(has_audio && dur > 0.0) {
        return false;
    }
    if let Some(e) = expected.filter(|e| *e > 0.0) {
        let tol = (e * 0.15).max(10.0);
        if dur < e - tol {
            tracing::warn!("verify_audio: {} decoded to {dur:.1}s, expected ~{e:.1}s (tolerance {tol:.1}s) — treating as truncated", path.display());
            return false;
        }
    }
    true
}

pub struct TagCache {
    path: String,
    data: Mutex<HashMap<String, Value>>,
    dirty: std::sync::atomic::AtomicBool,
    sem: tokio::sync::Semaphore,
}

impl TagCache {
    pub fn load(path: String) -> Self {
        let data: HashMap<String, Value> = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        tracing::info!("ffprobe cache loaded: {} entries from {path}", data.len());
        Self { path, data: Mutex::new(data), dirty: false.into(), sem: tokio::sync::Semaphore::new(4) }
    }

    fn key(abs: &Path) -> Option<String> {
        let m = std::fs::metadata(abs).ok()?;
        let mtime = m.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64();
        // Python's str(float) for st_mtime: repr of the float.
        Some(format!("{}|{}|{}", abs.display(), py_float(mtime), m.len()))
    }

    /// `_ffprobe_tags`. `readable` is the path to probe (a decompressed copy
    /// for gzip-stored files); `abs` is the stored file the cache keys on.
    pub async fn tags(&self, abs: &Path, readable: &Path) -> Value {
        let key = Self::key(abs);
        if let Some(k) = &key {
            if let Some(v) = self.data.lock().unwrap().get(k) {
                if v.get("lumisound_id").is_some() && v.get("sample_rate").is_some() {
                    return v.clone();
                }
            }
        }
        let _p = self.sem.acquire().await;
        let Some(d) = ffprobe_json(readable, Duration::from_secs(10)).await else { return json!({}) };
        let streams = d["streams"].as_array().cloned().unwrap_or_default();
        let audio = streams.iter().find(|s| s["codec_type"] == "audio").cloned().unwrap_or(json!({}));
        let has_artwork = streams.iter().any(|s| matches!(s["codec_name"].as_str(), Some("png" | "mjpeg")));
        let mut tags: HashMap<String, Value> = HashMap::new();
        for src in [&audio["tags"], &d["format"]["tags"]] {
            if let Some(o) = src.as_object() {
                for (k, v) in o {
                    tags.insert(k.to_lowercase(), v.clone());
                }
            }
        }
        let t = |k: &str| tags.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
        let dur = audio["duration"].as_str().or(d["format"]["duration"].as_str()).and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
        let sr = audio["sample_rate"].as_str().and_then(|s| s.parse::<i64>().ok());
        let r = json!({
            "title": t("title").or_else(|| t("name")).unwrap_or_default(),
            "artist": t("artist").or_else(|| t("album_artist")).unwrap_or_default(),
            "album": t("album").unwrap_or_default(),
            "genre": t("genre").unwrap_or_default(),
            "track_number": t("track").or_else(|| t("tracknumber")).unwrap_or_default(),
            "duration": dur,
            "has_artwork": has_artwork,
            "lumisound_id": t("lumisound_id").unwrap_or_default(),
            "sample_rate": sr,
        });
        if let Some(k) = key {
            self.data.lock().unwrap().insert(k, r.clone());
            self.dirty.store(true, std::sync::atomic::Ordering::Relaxed);
        }
        r
    }

    pub async fn flush(&self) {
        if !self.dirty.swap(false, std::sync::atomic::Ordering::Relaxed) {
            return;
        }
        let bytes = serde_json::to_vec(&*self.data.lock().unwrap()).unwrap_or_default();
        let tmp = format!("{}.tmp", self.path);
        if let Err(e) = tokio::fs::write(&tmp, &bytes).await.and(tokio::fs::rename(&tmp, &self.path).await) {
            tracing::warn!("ffprobe cache flush failed: {e}");
            self.dirty.store(true, std::sync::atomic::Ordering::Relaxed);
        }
    }
}

/// Python's repr(float): shortest round-trip, always with a decimal point.
pub fn py_float(f: f64) -> String {
    let s = format!("{f}");
    if s.contains('.') || s.contains('e') || s.contains("inf") || s.contains("NaN") { s } else { format!("{s}.0") }
}
