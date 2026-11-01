//! Cache/storage housekeeping: recursive size scans, clearing cache folders,
//! temp-download cleanup and orphaned-file detection. Swift passes the
//! platform directories (Caches, tmp, Documents) and shows the numbers.

use std::collections::HashSet;
use std::path::Path;

#[derive(uniffi::Record, Clone, Debug, Default, PartialEq)]
pub struct DirStats {
    pub files: u64,
    pub bytes: u64,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct OrphanScan {
    pub paths: Vec<String>,
    pub bytes: u64,
}

fn hidden(p: &Path) -> bool {
    p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with('.'))
}

/// Regular files under `dir` (hidden entries skipped), depth-first, no symlink following.
fn walk(dir: &Path, f: &mut dyn FnMut(&Path, u64)) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if hidden(&p) {
            continue;
        }
        let Ok(t) = e.file_type() else { continue };
        if t.is_dir() {
            walk(&p, f);
        } else if t.is_file() {
            f(&p, e.metadata().map(|m| m.len()).unwrap_or(0));
        }
    }
}

/// File count and total bytes under `dir` (recursive). Zero if missing.
#[uniffi::export]
pub fn cache_dir_stats(dir: String) -> DirStats {
    let mut s = DirStats::default();
    walk(Path::new(&dir), &mut |_, n| {
        s.files += 1;
        s.bytes += n;
    });
    s
}

/// Stats summed over the direct children of `dir` whose name starts with `prefix`.
#[uniffi::export]
pub fn cache_prefixed_stats(dir: String, prefix: String) -> DirStats {
    let mut s = DirStats::default();
    let Ok(rd) = std::fs::read_dir(&dir) else { return s };
    for e in rd.flatten() {
        let p = e.path();
        if hidden(&p) || !p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with(&prefix)) {
            continue;
        }
        if p.is_dir() {
            let d = cache_dir_stats(p.to_string_lossy().into_owned());
            s.files += d.files;
            s.bytes += d.bytes;
        } else if let Ok(m) = e.metadata() {
            s.files += 1;
            s.bytes += m.len();
        }
    }
    s
}

fn remove(p: &Path) {
    let _ = if p.is_dir() { std::fs::remove_dir_all(p) } else { std::fs::remove_file(p) };
}

/// Delete everything inside `dir` (not `dir` itself; hidden entries kept).
#[uniffi::export]
pub fn cache_clear_contents(dir: String) {
    let Ok(rd) = std::fs::read_dir(&dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if !hidden(&p) {
            remove(&p);
        }
    }
}

/// Delete the direct children of `dir` whose name starts with `prefix`.
#[uniffi::export]
pub fn cache_remove_prefixed(dir: String, prefix: String) {
    let Ok(rd) = std::fs::read_dir(&dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if !hidden(&p) && p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with(&prefix)) {
            remove(&p);
        }
    }
}

/// Files under `music_dir` whose filename no library song references.
#[uniffi::export]
pub fn cache_find_orphans(music_dir: String, known_filenames: Vec<String>) -> OrphanScan {
    let known: HashSet<String> = known_filenames.into_iter().collect();
    let mut out = OrphanScan::default();
    walk(Path::new(&music_dir), &mut |p, n| {
        if !p.file_name().and_then(|f| f.to_str()).is_some_and(|f| known.contains(f)) {
            out.paths.push(p.to_string_lossy().into_owned());
            out.bytes += n;
        }
    });
    out.paths.sort();
    out
}

/// Remove each path (files or folders); returns how many went.
#[uniffi::export]
pub fn cache_remove_paths(paths: Vec<String>) -> u32 {
    paths.iter().filter(|p| {
        let p = Path::new(p);
        p.exists() && { remove(p); !p.exists() }
    }).count() as u32
}

/// "12.4 MB" (decimal units like the Files app; KB minimum).
#[uniffi::export]
pub fn format_bytes(bytes: u64) -> String {
    let b = bytes as f64;
    if b < 1e6 {
        let kb = (b / 1e3).round() as u64;
        return format!("{} KB", if bytes > 0 { kb.max(1) } else { 0 });
    }
    if b < 1e9 {
        return format!("{:.1} MB", b / 1e6);
    }
    format!("{:.2} GB", b / 1e9)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scans_clears_and_finds_orphans() {
        let d = std::env::temp_dir().join(format!("cache-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(d.join("sub")).unwrap();
        std::fs::write(d.join("a.m4a"), vec![0u8; 100]).unwrap();
        std::fs::write(d.join("sub/b.m4a"), vec![0u8; 50]).unwrap();
        std::fs::write(d.join(".hidden"), vec![0u8; 999]).unwrap();
        std::fs::create_dir_all(d.join("dl_x")).unwrap();
        std::fs::write(d.join("dl_x/p"), vec![0u8; 7]).unwrap();
        let ds = d.to_string_lossy().to_string();
        assert_eq!(cache_dir_stats(ds.clone()), DirStats { files: 3, bytes: 157 });
        assert_eq!(cache_prefixed_stats(ds.clone(), "dl_".into()), DirStats { files: 1, bytes: 7 });
        let o = cache_find_orphans(ds.clone(), vec!["a.m4a".into(), "p".into()]);
        assert_eq!(o.paths.len(), 1);
        assert!(o.paths[0].ends_with("sub/b.m4a") && o.bytes == 50);
        cache_remove_prefixed(ds.clone(), "dl_".into());
        assert!(!d.join("dl_x").exists());
        assert_eq!(cache_remove_paths(o.paths), 1);
        cache_clear_contents(ds.clone());
        assert!(d.join(".hidden").exists() && !d.join("a.m4a").exists() && !d.join("sub").exists());
        assert_eq!(format_bytes(12_400_000), "12.4 MB");
        assert_eq!(format_bytes(500), "1 KB");
        let _ = std::fs::remove_dir_all(d);
    }
}
