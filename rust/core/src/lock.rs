//! Lock system: the LMSLOCK1 `.lms` format (lock / unlock / playable cache)
//! and the track vault (AES-GCM sealed track-id + source tag, compatible
//! with the CryptoKit `AES.GCM.SealedBox.combined` blobs older builds wrote).

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine;
use lumisound_media::lock as fmt;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::SystemTime;

pub const MARKER: &str = "lms";

/// `x.m4a.lms` -> "m4a"; otherwise the plain extension, lowercased.
#[uniffi::export]
pub fn lms_effective_extension(path: String) -> String {
    let p = Path::new(&path);
    let outer = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    if outer != MARKER {
        return outer;
    }
    Path::new(p.file_stem().and_then(|s| s.to_str()).unwrap_or("")).extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase()
}

#[uniffi::export]
pub fn lms_is_converted(path: String) -> bool {
    Path::new(&path).extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case(MARKER))
}

/// True when the file starts with the LMSLOCK1 header (reads 8 bytes).
#[uniffi::export]
pub fn lms_is_locked(path: String) -> bool {
    fmt::is_locked(Path::new(&path))
}

/// Lock `plain_path` into `locked_path` (streamed, atomic). Never touches the source.
#[uniffi::export]
pub fn lms_lock(plain_path: String, locked_path: String) -> bool {
    fmt::lock_file(Path::new(&plain_path), Path::new(&locked_path)).is_ok()
}

/// Unlock into `out_path`; legacy un-masked `.lms` files are copied through.
#[uniffi::export]
pub fn lms_unlock(locked_path: String, out_path: String) -> bool {
    fmt::unlock_file(Path::new(&locked_path), Path::new(&out_path)).is_ok()
}

fn mtime(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

fn cache_path(locked: &Path, cache_dir: &Path) -> PathBuf {
    // "Song.m4a.lms" -> "<cache>/Song.m4a"
    cache_dir.join(locked.file_stem().unwrap_or_default())
}

static UNLOCK_LOCKS: LazyLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn path_lock(key: &str) -> Arc<Mutex<()>> {
    UNLOCK_LOCKS.lock().unwrap().entry(key.to_string()).or_default().clone()
}

/// A warm cache copy exists and is at least as new as the locked file.
#[uniffi::export]
pub fn lms_has_warm_cache(path: String, cache_dir: String) -> bool {
    let p = Path::new(&path);
    if !lms_is_converted(path.clone()) {
        return true;
    }
    let out = cache_path(p, Path::new(&cache_dir));
    matches!((mtime(p), mtime(&out)), (Some(src), Some(c)) if c >= src)
}

/// Directly playable path for `path`: itself when not converted, otherwise
/// an unlocked copy in `cache_dir` (reused while fresh). One unlock per file
/// at a time; falls back to the original path if unlocking fails twice.
#[uniffi::export]
pub fn lms_playable_path(path: String, cache_dir: String) -> String {
    if !lms_is_converted(path.clone()) {
        return path;
    }
    let guard = path_lock(&path);
    let _g = guard.lock().unwrap();
    let (p, dir) = (Path::new(&path), Path::new(&cache_dir));
    let _ = std::fs::create_dir_all(dir);
    let out = cache_path(p, dir);
    if let (Some(src), Some(c)) = (mtime(p), mtime(&out)) {
        if c >= src {
            return out.to_string_lossy().into_owned();
        }
    }
    for _ in 0..2 {
        let _ = std::fs::remove_file(&out);
        if fmt::unlock_file(p, &out).is_ok() {
            return out.to_string_lossy().into_owned();
        }
    }
    let _ = std::fs::remove_file(&out);
    path
}

// ---- track vault -----------------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct VaultPayload {
    pub v: i64,
    pub track_id: String,
    pub source_url: String,
}

fn vault_cipher() -> Aes256Gcm {
    let joined = ["lumi-vault", "2026", "\u{2665}", "com.lumisound.ios", "trackdata-v1"].join("::");
    let key = Sha256::digest(joined.as_bytes());
    Aes256Gcm::new_from_slice(&key).expect("32-byte key")
}

fn random_nonce() -> [u8; 12] {
    let mut n = [0u8; 12];
    let u = uuid::Uuid::new_v4();
    n.copy_from_slice(&u.as_bytes()[..12]);
    n
}

/// Seal `{v, trackID, sourceURL}` -> base64(nonce ‖ ciphertext ‖ tag).
#[uniffi::export]
pub fn vault_encrypt(track_id: String, source_url: String) -> Option<String> {
    let body = serde_json::json!({"v": 1, "trackID": track_id, "sourceURL": source_url}).to_string();
    let nonce = random_nonce();
    let ct = vault_cipher().encrypt(Nonce::from_slice(&nonce), body.as_bytes()).ok()?;
    let mut combined = nonce.to_vec();
    combined.extend_from_slice(&ct);
    Some(base64::engine::general_purpose::STANDARD.encode(combined))
}

#[uniffi::export]
pub fn vault_decrypt(blob: String) -> Option<VaultPayload> {
    let combined = base64::engine::general_purpose::STANDARD.decode(blob.trim()).ok()?;
    if combined.len() < 12 + 16 {
        return None;
    }
    let (nonce, ct) = combined.split_at(12);
    let plain = vault_cipher().decrypt(Nonce::from_slice(nonce), ct).ok()?;
    let v: serde_json::Value = serde_json::from_slice(&plain).ok()?;
    Some(VaultPayload {
        v: v["v"].as_i64().unwrap_or(1),
        track_id: v["trackID"].as_str()?.to_string(),
        source_url: v["sourceURL"].as_str()?.to_string(),
    })
}

// ---- track tag (vault blob in the `com.lumisound.trackdata` xattr) ---------------------------

const TAG_ATTR: &str = "com.lumisound.trackdata";

#[cfg(target_vendor = "apple")]
fn xattr_set(path: &str, value: &[u8]) -> bool {
    let (Ok(p), Ok(n)) = (std::ffi::CString::new(path), std::ffi::CString::new(TAG_ATTR)) else { return false };
    unsafe { libc::setxattr(p.as_ptr(), n.as_ptr(), value.as_ptr().cast(), value.len(), 0, 0) == 0 }
}

#[cfg(target_vendor = "apple")]
fn xattr_get(path: &str) -> Option<Vec<u8>> {
    let (p, n) = (std::ffi::CString::new(path).ok()?, std::ffi::CString::new(TAG_ATTR).ok()?);
    let size = unsafe { libc::getxattr(p.as_ptr(), n.as_ptr(), std::ptr::null_mut(), 0, 0, 0) };
    if size <= 0 {
        return None;
    }
    let mut buf = vec![0u8; size as usize];
    let got = unsafe { libc::getxattr(p.as_ptr(), n.as_ptr(), buf.as_mut_ptr().cast(), buf.len(), 0, 0) };
    (got > 0).then(|| {
        buf.truncate(got as usize);
        buf
    })
}

#[cfg(not(target_vendor = "apple"))]
fn xattr_set(path: &str, value: &[u8]) -> bool {
    let (Ok(p), Ok(n)) = (std::ffi::CString::new(path), std::ffi::CString::new(format!("user.{TAG_ATTR}"))) else { return false };
    unsafe { libc::setxattr(p.as_ptr(), n.as_ptr(), value.as_ptr().cast(), value.len(), 0) == 0 }
}

#[cfg(not(target_vendor = "apple"))]
fn xattr_get(path: &str) -> Option<Vec<u8>> {
    let (p, n) = (std::ffi::CString::new(path).ok()?, std::ffi::CString::new(format!("user.{TAG_ATTR}")).ok()?);
    let size = unsafe { libc::getxattr(p.as_ptr(), n.as_ptr(), std::ptr::null_mut(), 0) };
    if size <= 0 {
        return None;
    }
    let mut buf = vec![0u8; size as usize];
    let got = unsafe { libc::getxattr(p.as_ptr(), n.as_ptr(), buf.as_mut_ptr().cast(), buf.len()) };
    (got > 0).then(|| {
        buf.truncate(got as usize);
        buf
    })
}

/// Seal the track id + source into the file's xattr (survives renames and
/// re-locks; not copied by AirDrop/Files exports).
#[uniffi::export]
pub fn track_tag(path: String, track_id: String, source_url: String) -> bool {
    vault_encrypt(track_id, source_url).is_some_and(|blob| xattr_set(&path, blob.as_bytes()))
}

#[uniffi::export]
pub fn track_read_tag(path: String) -> Option<VaultPayload> {
    let raw = xattr_get(&path)?;
    vault_decrypt(String::from_utf8(raw).ok()?)
}

#[uniffi::export]
pub fn track_is_tagged(path: String) -> bool {
    xattr_get(&path).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn vault_roundtrip() {
        let b = vault_encrypt("youtube:abc".into(), "https://youtu.be/abc".into()).unwrap();
        let p = vault_decrypt(b).unwrap();
        assert_eq!(p.track_id, "youtube:abc");
        assert_eq!(p.source_url, "https://youtu.be/abc");
    }
    #[test]
    fn effective_ext() {
        assert_eq!(lms_effective_extension("/a/Song.m4a.lms".into()), "m4a");
        assert_eq!(lms_effective_extension("/a/Song.MP3".into()), "mp3");
    }
}
