//! Per-user cloud music storage paths and readable views of stored files
//! (gzip-compressed uploads are decompressed to a temp copy on demand).

use crate::state::AppState;
use std::io::Read;
use std::path::{Path, PathBuf};

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

/// `_readable_user_music_file`.
pub async fn readable_copy(p: &Path) -> Readable {
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

impl AppState {
    pub fn user_music_root(&self) -> Option<PathBuf> {
        if let Some(d) = &self.cfg.user_music_dir {
            return Some(std::fs::canonicalize(d).unwrap_or_else(|_| PathBuf::from(d)));
        }
        let s = self.cfg.server_music_dir.as_ref()?;
        let p = Path::new(s).join("users");
        Some(std::fs::canonicalize(&p).unwrap_or(p))
    }

    pub fn user_music_dir(&self, user_id: &str) -> Option<PathBuf> {
        Some(self.user_music_root()?.join(user_id))
    }
}
