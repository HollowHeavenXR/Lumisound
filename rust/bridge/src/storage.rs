//! Per-user cloud music storage: paths, readable views of stored files
//! (gzip-compressed and/or `.lms`-locked), media types, quotas.

use crate::state::AppState;
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::{Component, Path, PathBuf};

pub use lumisound_media::AUDIO_EXTS;
pub const DEFAULT_QUOTA_BYTES: i64 = 10 * 1024 * 1024 * 1024;

pub struct Readable {
    path: PathBuf,
    tmp: bool,
}

impl Readable {
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for Readable {
    fn drop(&mut self) {
        if self.tmp {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

pub fn is_gzip(p: &Path) -> bool {
    let mut b = [0u8; 2];
    std::fs::File::open(p).and_then(|mut f| f.read_exact(&mut b)).is_ok() && b == [0x1f, 0x8b]
}

pub fn is_audio_ext(p: &Path) -> bool {
    p.extension().and_then(|e| e.to_str()).is_some_and(|e| AUDIO_EXTS.contains(&e.to_lowercase().as_str()))
}

/// Extension a decoder should see: the inner one for `x.opus.lms`.
pub fn inner_suffix(p: &Path) -> String {
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
    if let Some(i) = crate::lock::inner_ext(name) {
        return format!(".{i}");
    }
    p.extension().and_then(|e| e.to_str()).map(|e| format!(".{e}")).unwrap_or_default()
}

fn decode_to(src: &Path, out: &mut std::fs::File) -> std::io::Result<()> {
    // gzip-stored upload -> decompress; then a locked payload -> unmask.
    if is_gzip(src) {
        let mut d = flate2::read::GzDecoder::new(std::io::BufReader::new(std::fs::File::open(src)?));
        let mut head = [0u8; crate::lock::HEADER2_LEN];
        let mut n = 0;
        while n < head.len() {
            match d.read(&mut head[n..])? {
                0 => break,
                k => n += k,
            }
        }
        if let Some(h) = crate::lock::parse_header(&head[..n]) {
            // v1 header is 8 bytes: what we read past it is already payload.
            let mut off = 0u64;
            if n > h.payload_offset {
                let mut first = head[h.payload_offset..n].to_vec();
                crate::lock::apply_mask(&mut first, 0);
                std::io::Write::write_all(out, &first)?;
                off = (n - h.payload_offset) as u64;
            }
            let mut buf = vec![0u8; 1 << 20];
            loop {
                let k = d.read(&mut buf)?;
                if k == 0 {
                    break;
                }
                crate::lock::apply_mask(&mut buf[..k], off);
                std::io::Write::write_all(out, &buf[..k])?;
                off += k as u64;
            }
        } else {
            std::io::Write::write_all(out, &head[..n])?;
            std::io::copy(&mut d, out)?;
        }
        return Ok(());
    }
    crate::lock::unmask_into(src, out)
}

/// A path ffmpeg/ffprobe can read: the file itself when it is plain, else a
/// temp copy (decompressed/unmasked) removed on drop. Never modifies `p`.
pub async fn readable_copy(p: &Path) -> Readable {
    let src = p.to_path_buf();
    tokio::task::spawn_blocking(move || {
        if !is_gzip(&src) && !crate::lock::is_locked(&src) {
            return Readable { path: src, tmp: false };
        }
        let suffix = inner_suffix(&src);
        let tmp = std::env::temp_dir().join(format!("lms-{}{suffix}", uuid::Uuid::new_v4().simple()));
        let ok = std::fs::File::create(&tmp).and_then(|mut f| decode_to(&src, &mut f)).is_ok();
        if ok {
            Readable { path: tmp, tmp: true }
        } else {
            let _ = std::fs::remove_file(&tmp);
            Readable { path: src, tmp: false }
        }
    })
    .await
    .unwrap_or_else(|_| Readable { path: p.to_path_buf(), tmp: false })
}

/// Gzip-only view (what /user/music/stream serves: locked bytes stay locked,
/// the client unlocks them).
pub async fn materialize_gzip(p: &Path) -> Readable {
    let src = p.to_path_buf();
    tokio::task::spawn_blocking(move || {
        if !is_gzip(&src) {
            return Readable { path: src, tmp: false };
        }
        let suffix = src.extension().and_then(|e| e.to_str()).map(|e| format!(".{e}")).unwrap_or_default();
        let tmp = std::env::temp_dir().join(format!("lms-gz-{}{suffix}", uuid::Uuid::new_v4().simple()));
        let ok = std::fs::File::open(&src)
            .and_then(|f| {
                let mut d = flate2::read::GzDecoder::new(std::io::BufReader::new(f));
                let mut out = std::fs::File::create(&tmp)?;
                std::io::copy(&mut d, &mut out).map(|_| ())
            })
            .is_ok();
        if ok { Readable { path: tmp, tmp: true } } else { let _ = std::fs::remove_file(&tmp); Readable { path: src, tmp: false } }
    })
    .await
    .unwrap_or_else(|_| Readable { path: p.to_path_buf(), tmp: false })
}

/// `root/rel`, refusing anything that escapes `root` (lexically, and through
/// symlinks when the target exists). None = access denied.
pub fn safe_join(root: &Path, rel: &str) -> Option<PathBuf> {
    let mut out = root.to_path_buf();
    for c in Path::new(rel).components() {
        match c {
            Component::Normal(s) => out.push(s),
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() || !out.starts_with(root) {
                    return None;
                }
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    if !out.starts_with(root) {
        return None;
    }
    if let Ok(real) = std::fs::canonicalize(&out) {
        let real_root = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
        if !real.starts_with(&real_root) {
            return None;
        }
    }
    Some(out)
}

/// `_stable_id`: first 16 hex chars of sha256(absolute path).
pub fn stable_id(abs: &Path) -> String {
    hex::encode(Sha256::digest(abs.to_string_lossy().as_bytes()))[..16].to_string()
}

pub fn audio_media_type(ext: &str) -> &'static str {
    match ext {
        "opus" | "ogg" => "audio/ogg",
        "mp3" => "audio/mpeg",
        "m4a" | "m4v" | "mp4" => "audio/mp4",
        "aac" => "audio/aac",
        "flac" => "audio/flac",
        "wav" => "audio/wav",
        "aif" | "aiff" => "audio/aiff",
        "caf" => "audio/x-caf",
        _ => "application/octet-stream",
    }
}

/// Recursively list files under `dir` (blocking).
pub fn walk_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            match e.file_type() {
                Ok(t) if t.is_dir() => stack.push(e.path()),
                Ok(t) if t.is_file() => out.push(e.path()),
                Ok(t) if t.is_symlink() => {
                    if e.path().is_file() {
                        out.push(e.path())
                    } else if e.path().is_dir() {
                        stack.push(e.path())
                    }
                }
                _ => {}
            }
        }
    }
    out
}

/// Bytes available to unprivileged users on the filesystem holding `p`.
pub fn free_bytes(p: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(p.as_os_str().as_bytes()).ok()?;
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut s) } != 0 {
        return None;
    }
    Some(s.f_bavail as u64 * s.f_frsize as u64)
}

/// `_loudness_gain_db`: toward -14 LUFS, clamped to ±12 dB.
pub fn gain_db(lufs: Option<f64>) -> Option<f64> {
    lufs.map(|l| ((-14.0 - l).clamp(-12.0, 12.0) * 100.0).round() / 100.0)
}

impl AppState {
    pub fn user_music_root(&self) -> Option<PathBuf> {
        if let Some(d) = &self.cfg.user_music_dir {
            return Some(std::fs::canonicalize(d).unwrap_or_else(|_| PathBuf::from(d)));
        }
        let s = self.cfg.server_music_dir.as_ref()?;
        let p = Path::new(s).join("users");
        Some(std::fs::canonicalize(&p).unwrap_or(p))
    }

    /// Every drive that can hold user libraries, main root first.
    pub fn user_music_roots(&self) -> Vec<PathBuf> {
        let mut v: Vec<PathBuf> = self.user_music_root().into_iter().collect();
        for d in &self.cfg.user_music_extra_dirs {
            let p = std::fs::canonicalize(d).unwrap_or_else(|_| PathBuf::from(d));
            if !v.contains(&p) && p.is_dir() {
                v.push(p);
            }
        }
        v
    }

    /// A user's library folder: wherever it already is, else (new user) on
    /// the drive with the most free space.
    pub fn user_music_dir(&self, user_id: &str) -> Option<PathBuf> {
        let roots = self.user_music_roots();
        if roots.len() <= 1 || user_id.is_empty() || user_id.contains('/') || user_id.contains("..") {
            return Some(self.user_music_root()?.join(user_id));
        }
        if let Some(existing) = roots.iter().map(|r| r.join(user_id)).find(|p| p.is_dir()) {
            return Some(existing);
        }
        let best = roots.iter().max_by_key(|r| free_bytes(r).unwrap_or(0))?;
        Some(best.join(user_id))
    }

    pub fn user_gallery_dir(&self, user_id: &str) -> Option<PathBuf> {
        Some(self.user_music_dir(user_id)?.join("gallery"))
    }

    pub async fn user_quota_bytes(&self, user_id: &str) -> i64 {
        let q: Option<Option<i64>> = sqlx::query_scalar("SELECT storage_quota_bytes FROM ios_user_settings WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(&self.db)
            .await
            .ok()
            .flatten();
        match q.flatten() {
            Some(q) if q != 0 => q,
            _ => self.cfg.user_music_quota_bytes,
        }
    }

    /// `_compute_storage_usage`.
    pub async fn storage_usage(&self, user_id: &str) -> anyhow::Result<serde_json::Value> {
        let (music_bytes, music_count): (i64, i64) = sqlx::query_as(
            "SELECT COALESCE(SUM(file_size_bytes), 0)::bigint, COUNT(*) FROM ios_user_music_metadata WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_one(&self.db)
        .await?;
        let mut gallery: i64 = 0;
        if let Some(g) = self.user_gallery_dir(user_id) {
            if let Ok(mut rd) = tokio::fs::read_dir(&g).await {
                while let Ok(Some(e)) = rd.next_entry().await {
                    if let Ok(m) = e.metadata().await {
                        if m.is_file() {
                            gallery += m.len() as i64;
                        }
                    }
                }
            }
        }
        Ok(serde_json::json!({"music_bytes": music_bytes, "music_count": music_count, "gallery_bytes": gallery, "used_bytes": music_bytes + gallery}))
    }

    /// 80% / 95% / 100% storage notifications, each tier once per process.
    pub async fn maybe_warn_storage_quota(&self, user_id: &str) {
        let quota = self.user_quota_bytes(user_id).await;
        if quota == 0 {
            return;
        }
        let Ok(usage) = self.storage_usage(user_id).await else { return };
        let used = usage["used_bytes"].as_i64().unwrap_or(0);
        let frac = used as f64 / quota as f64;
        let Some(tier) = [0.8, 0.95, 1.0].into_iter().filter(|t| frac >= *t).last() else { return };
        {
            let mut last = self.storage_tier_sent.entry(user_id.to_string()).or_insert(0.0);
            if tier <= *last {
                return;
            }
            *last = tier;
        }
        let (title, body) = if tier >= 1.0 {
            ("Storage full".to_string(), format!("You've used all {} of your cloud storage — new uploads will be rejected until you free some up.", format_bytes(quota)))
        } else {
            (format!("Storage {}% full", (tier * 100.0) as i64), format!("You've used {} of your {} quota.", format_bytes(used), format_bytes(quota)))
        };
        let _ = self
            .create_notification(user_id, "storage_quota_warning", &title, &body, serde_json::json!({"used_bytes": used, "quota_bytes": quota, "tier": tier}), false)
            .await;
    }
}

pub fn format_bytes(n: i64) -> String {
    let mut v = n as f64;
    for unit in ["B", "KB", "MB", "GB"] {
        if v < 1024.0 || unit == "GB" {
            return if unit == "B" { format!("{} {unit}", v as i64) } else { format!("{v:.1} {unit}") };
        }
        v /= 1024.0;
    }
    format!("{v:.1} GB")
}
