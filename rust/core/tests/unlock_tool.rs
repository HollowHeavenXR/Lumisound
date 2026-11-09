//! Test helper: unlock named cloud copies for other tools (lyrics probe).
//!   LUMI_UNLOCK="<dir>|<name substring>;<name substring>" cargo test --release -p lumisound-core --test unlock_tool
use std::path::PathBuf;

#[test]
fn unlock_named() {
    let Ok(spec) = std::env::var("LUMI_UNLOCK") else { return };
    let (dir, names) = spec.split_once('|').unwrap();
    let out = PathBuf::from(dir).join("unlocked");
    std::fs::create_dir_all(&out).unwrap();
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        let n = p.file_name().unwrap().to_string_lossy().to_string();
        if n.ends_with(".lms") && names.split(';').any(|w| n.contains(w)) {
            let dst = out.join(p.file_stem().unwrap());
            assert!(lumisound_core::lock::lms_unlock(p.to_string_lossy().into(), dst.to_string_lossy().into()));
            eprintln!("unlocked {}", dst.display());
        }
    }
}
