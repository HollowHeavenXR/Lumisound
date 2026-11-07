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

/// Read tags/artwork of `path` with `f`: a locked file is read in place
/// (unmasked on the fly — no copy of the whole track), with the unlocked
/// cache copy only as a fallback if that ever fails.
pub fn read_tags_with<T>(path: &str, cache_dir: &str, f: impl Fn(&Path) -> Option<T>) -> Option<T> {
    f(Path::new(path)).or_else(|| {
        lms_is_converted(path.to_string()).then(|| lms_playable_path(path.to_string(), cache_dir.to_string())).and_then(|p| f(Path::new(&p)))
    })
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

// MARK: - Conversion pipeline (lock -> verify -> replace)

/// Platform decoder check for containers the core can't decode itself
/// (Swift answers with AVAudioFile). Only asked on `Unsupported`.
#[uniffi::export(with_foreign)]
pub trait AudioVerifier: Send + Sync {
    fn is_valid_audio(&self, path: String) -> bool;
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct LmsConvertOutcome {
    /// The verified locked file, or nil when locking/verification failed.
    pub locked_path: Option<String>,
    /// An existing locked file at the destination verified and was kept.
    pub adopted: bool,
    pub before_bytes: i64,
    pub locked_bytes: i64,
    /// The plain original was deleted (false = left behind; the next scan
    /// cleans it up).
    pub original_removed: bool,
    /// What happened, for the log.
    pub detail: String,
}

fn size_of(p: &Path) -> i64 {
    std::fs::metadata(p).map(|m| m.len() as i64).unwrap_or(-1)
}

fn tmp_with_ext(tmp_dir: &Path, ext: &str) -> PathBuf {
    let name = uuid::Uuid::new_v4().to_string();
    if ext.is_empty() { tmp_dir.join(name) } else { tmp_dir.join(format!("{name}.{ext}")) }
}

/// Unlock `locked` to a temp file with the real audio extension and check it
/// decodes (core decoder, then `verifier` for containers it can't read).
fn round_trips(locked: &Path, ext: &str, tmp_dir: &Path, verifier: &Option<Arc<dyn AudioVerifier>>) -> bool {
    let _ = std::fs::create_dir_all(tmp_dir);
    let out = tmp_with_ext(tmp_dir, ext);
    let ok = fmt::unlock_file(locked, &out).is_ok() && {
        let p = out.to_string_lossy().to_string();
        match crate::analysis::validate_audio(p.clone(), tmp_dir.to_string_lossy().into(), None) {
            crate::analysis::AudioValidation::Valid => true,
            crate::analysis::AudioValidation::Unsupported => verifier.as_ref().is_some_and(|v| v.is_valid_audio(p)),
            _ => false,
        }
    };
    let _ = std::fs::remove_file(&out);
    ok
}

/// Locked file verifies by unlock + decode round trip.
#[uniffi::export]
pub fn lms_verify_round_trip(locked_path: String, tmp_dir: String, verifier: Option<Arc<dyn AudioVerifier>>) -> bool {
    let ext = lms_effective_extension(locked_path.clone());
    round_trips(Path::new(&locked_path), &ext, Path::new(&tmp_dir), &verifier)
}

/// Lock `plain_path` into `locked_path` as-is (no re-encode), verify the
/// round trip, then remove the original — never on faith. An existing file
/// at `locked_path` is verified and adopted, or discarded and redone if it
/// is a half-written leftover. A failed verify never leaves a locked file.
#[uniffi::export]
pub fn lms_convert(plain_path: String, locked_path: String, tmp_dir: String, verifier: Option<Arc<dyn AudioVerifier>>) -> LmsConvertOutcome {
    let (plain, locked, tmp) = (Path::new(&plain_path), Path::new(&locked_path), Path::new(&tmp_dir));
    let ext = plain.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let before = size_of(plain);
    let out = |locked_path: Option<String>, adopted, locked_bytes, original_removed, detail: String| LmsConvertOutcome { locked_path, adopted, before_bytes: before, locked_bytes, original_removed, detail };
    if lms_is_converted(plain_path.clone()) {
        return out(Some(plain_path), true, before, false, "already converted".into());
    }
    if locked.exists() {
        if round_trips(locked, &ext, tmp, &verifier) {
            return out(Some(locked_path.clone()), true, size_of(locked), false, "adopted existing locked file".into());
        }
        let _ = std::fs::remove_file(locked);
    }
    if fmt::lock_file(plain, locked).is_err() {
        return out(None, false, -1, false, "lock failed".into());
    }
    let locked_bytes = size_of(locked);
    if !round_trips(locked, &ext, tmp, &verifier) {
        let _ = std::fs::remove_file(locked);
        return out(None, false, locked_bytes, false, "locked file failed round-trip verification".into());
    }
    let removed = std::fs::remove_file(plain).is_ok();
    out(Some(locked_path.clone()), false, locked_bytes, removed, if removed { "converted".into() } else { "converted; original could not be removed".into() })
}

/// Migrate a `.lms`-named file that still holds plain (legacy) bytes into
/// the real lock in place: lock to a temp file, verify, then atomically
/// rename over `path`. `path` is untouched on any failure.
#[uniffi::export]
pub fn lms_relock_in_place(path: String, tmp_dir: String, verifier: Option<Arc<dyn AudioVerifier>>) -> bool {
    let p = Path::new(&path);
    if !lms_is_converted(path.clone()) || fmt::is_locked(p) {
        return false;
    }
    let tmp = Path::new(&tmp_dir);
    let _ = std::fs::create_dir_all(tmp);
    // Same directory as `path` so the final rename can't cross volumes.
    let staged = p.with_file_name(format!(".{}.relock", uuid::Uuid::new_v4()));
    let ext = lms_effective_extension(path.clone());
    // The vault tag is an xattr on the old inode; carry it to the new one.
    let tag = xattr_get(&path);
    let ok = fmt::lock_file(p, &staged).is_ok() && round_trips(&staged, if ext.is_empty() { "m4a" } else { &ext }, tmp, &verifier) && {
        if let Some(t) = &tag {
            xattr_set(&staged.to_string_lossy(), t);
        }
        std::fs::rename(&staged, p).is_ok()
    };
    if !ok {
        let _ = std::fs::remove_file(&staged);
    }
    ok
}

#[cfg(test)]
mod convert_tests {
    use super::*;

    fn wav(path: &Path) {
        let rate = 8000u32;
        let n = rate * 2;
        let mut b = Vec::new();
        b.extend_from_slice(b"RIFF");
        b.extend_from_slice(&(36 + n * 2).to_le_bytes());
        b.extend_from_slice(b"WAVEfmt ");
        b.extend_from_slice(&16u32.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&rate.to_le_bytes());
        b.extend_from_slice(&(rate * 2).to_le_bytes());
        b.extend_from_slice(&2u16.to_le_bytes());
        b.extend_from_slice(&16u16.to_le_bytes());
        b.extend_from_slice(b"data");
        b.extend_from_slice(&(n * 2).to_le_bytes());
        for i in 0..n {
            let v = ((i as f32 * 0.2).sin() * 8000.0) as i16;
            b.extend_from_slice(&v.to_le_bytes());
        }
        std::fs::write(path, b).unwrap();
    }

    #[test]
    fn convert_locks_verifies_and_removes_original() {
        let d = std::env::temp_dir().join(format!("lmsconv-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        let plain = d.join("a.wav");
        wav(&plain);
        let locked = d.join("a.wav.lms");
        let tmp = d.join("tmp").to_string_lossy().to_string();
        let o = lms_convert(plain.to_string_lossy().into(), locked.to_string_lossy().into(), tmp.clone(), None);
        assert_eq!(o.locked_path.as_deref(), Some(locked.to_str().unwrap()), "{}", o.detail);
        assert!(o.original_removed && !plain.exists() && fmt::is_locked(&locked));
        // Re-running with a fresh plain copy adopts the verified file.
        wav(&plain);
        let o2 = lms_convert(plain.to_string_lossy().into(), locked.to_string_lossy().into(), tmp.clone(), None);
        assert!(o2.adopted && plain.exists());
        // A corrupt leftover is replaced, not adopted.
        std::fs::write(&locked, b"LMSLOCK1garbage").unwrap();
        let o3 = lms_convert(plain.to_string_lossy().into(), locked.to_string_lossy().into(), tmp.clone(), None);
        assert!(!o3.adopted && o3.locked_path.is_some() && lms_verify_round_trip(locked.to_string_lossy().into(), tmp.clone(), None));
        // Legacy plain bytes under a .lms name get locked in place.
        let legacy = d.join("b.wav.lms");
        wav(&legacy);
        assert!(lms_relock_in_place(legacy.to_string_lossy().into(), tmp.clone(), None));
        assert!(fmt::is_locked(&legacy) && lms_verify_round_trip(legacy.to_string_lossy().into(), tmp, None));
        let _ = std::fs::remove_dir_all(d);
    }
}

// MARK: - Header flags (v2): engine-exclusive, lyrics synced

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LmsInfo {
    pub locked: bool,
    /// 0 = not locked, 1 = LMSLOCK1, 2 = LMSLOCK2.
    pub version: u8,
    /// Only the Lumisound Audio Engine may play it.
    pub engine_exclusive: bool,
    /// Its lyrics were force time-synced.
    pub lyrics_synced: bool,
}

#[uniffi::export]
pub fn lms_info(path: String) -> LmsInfo {
    match fmt::read_header(Path::new(&path)) {
        Some(h) => LmsInfo { locked: true, version: h.version, engine_exclusive: h.flags & fmt::FLAG_ENGINE_EXCLUSIVE != 0, lyrics_synced: h.flags & fmt::FLAG_LYRICS_SYNCED != 0 },
        None => LmsInfo { locked: false, version: 0, engine_exclusive: false, lyrics_synced: false },
    }
}

/// Set/clear header flags on a locked `.lms` file (None = leave as is).
/// Rewrites to a staged file beside it (payload copied byte for byte),
/// verifies the staged file still unlocks to playable audio, carries the
/// vault xattr over, then renames over the original: `path` is untouched
/// on any failure. Also drops a stale unlocked cache copy.
#[uniffi::export]
pub fn lms_set_flags(path: String, engine_exclusive: Option<bool>, lyrics_synced: Option<bool>, tmp_dir: String, verifier: Option<Arc<dyn AudioVerifier>>) -> bool {
    let p = Path::new(&path);
    let Some(h) = fmt::read_header(p) else { return false };
    let mut flags = h.flags;
    for (want, bit) in [(engine_exclusive, fmt::FLAG_ENGINE_EXCLUSIVE), (lyrics_synced, fmt::FLAG_LYRICS_SYNCED)] {
        match want {
            Some(true) => flags |= bit,
            Some(false) => flags &= !bit,
            None => {}
        }
    }
    if flags == h.flags {
        return true;
    }
    let staged = p.with_file_name(format!(".{}.reencode", uuid::Uuid::new_v4()));
    let ext = lms_effective_extension(path.clone());
    let tag = xattr_get(&path);
    let ok = fmt::rewrite_header(p, &staged, flags).is_ok() && round_trips(&staged, if ext.is_empty() { "m4a" } else { &ext }, Path::new(&tmp_dir), &verifier) && {
        if let Some(t) = &tag {
            xattr_set(&staged.to_string_lossy(), t);
        }
        std::fs::rename(&staged, p).is_ok()
    };
    if !ok {
        let _ = std::fs::remove_file(&staged);
    }
    ok
}

#[cfg(test)]
mod flag_tests {
    use super::*;

    #[test]
    fn exclusive_flag_reencode() {
        let d = std::env::temp_dir().join(format!("lmsflags-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        // A real (decodable) wav so the round-trip verification runs.
        let rate = 8000u32;
        let n = rate * 2;
        let mut b = Vec::new();
        b.extend_from_slice(b"RIFF");
        b.extend_from_slice(&(36 + n * 2).to_le_bytes());
        b.extend_from_slice(b"WAVEfmt ");
        b.extend_from_slice(&16u32.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&rate.to_le_bytes());
        b.extend_from_slice(&(rate * 2).to_le_bytes());
        b.extend_from_slice(&2u16.to_le_bytes());
        b.extend_from_slice(&16u16.to_le_bytes());
        b.extend_from_slice(b"data");
        b.extend_from_slice(&(n * 2).to_le_bytes());
        for i in 0..n {
            b.extend_from_slice(&(((i as f32 * 0.2).sin() * 8000.0) as i16).to_le_bytes());
        }
        let plain = d.join("s.wav");
        std::fs::write(&plain, &b).unwrap();
        let locked = d.join("s.wav.lms");
        assert!(lms_lock(plain.to_string_lossy().into(), locked.to_string_lossy().into()));
        let lp: String = locked.to_string_lossy().into();
        let tmp: String = d.join("tmp").to_string_lossy().into();
        assert_eq!(lms_info(lp.clone()), LmsInfo { locked: true, version: 1, engine_exclusive: false, lyrics_synced: false });
        assert!(lms_set_flags(lp.clone(), Some(true), None, tmp.clone(), None));
        assert_eq!(lms_info(lp.clone()), LmsInfo { locked: true, version: 2, engine_exclusive: true, lyrics_synced: false });
        assert!(lms_verify_round_trip(lp.clone(), tmp.clone(), None));
        assert!(lms_set_flags(lp.clone(), None, Some(true), tmp.clone(), None));
        assert!(lms_info(lp.clone()).lyrics_synced && lms_info(lp.clone()).engine_exclusive);
        let out = d.join("o.wav");
        assert!(lms_unlock(lp.clone(), out.to_string_lossy().into()));
        assert_eq!(std::fs::read(&out).unwrap(), b);
        assert!(!lms_set_flags(plain.to_string_lossy().into(), Some(true), None, tmp, None), "plain files have no header");
        let _ = std::fs::remove_dir_all(d);
    }
}
