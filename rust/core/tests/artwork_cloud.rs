//! Embedded artwork on real library tracks.
//!   LUMI_CLOUD_DIR=<dir of .lms copies> cargo test --release -p lumisound-core --test artwork_cloud -- --nocapture
use std::time::Instant;

#[test]
fn embedded_artwork_on_cloud_tracks() {
    let Ok(dir) = std::env::var("LUMI_CLOUD_DIR") else { return };
    let cache = std::env::temp_dir().join(format!("artcache-{}", std::process::id()));
    std::fs::create_dir_all(&cache).unwrap();
    let mut files: Vec<_> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "lms")).collect();
    files.sort();
    assert!(!files.is_empty());
    let mut found = 0;
    for f in &files {
        let p = f.to_string_lossy().to_string();
        let c = cache.to_string_lossy().to_string();
        let t = Instant::now();
        let art = lumisound_core::library::artwork_embedded(p.clone(), c.clone());
        let cold = t.elapsed().as_secs_f64();
        let t = Instant::now();
        let again = lumisound_core::library::artwork_embedded(p.clone(), c.clone());
        let warm = t.elapsed().as_secs_f64();
        let processed = art.as_ref().and_then(|a| lumisound_core::library::artwork_process(a.clone(), 600));
        let size = std::fs::metadata(f).map(|m| m.len()).unwrap_or(0);
        eprintln!(
            "{}: {:.1} MB, art {} bytes, processed {} bytes, cold {:.2}s, warm {:.3}s, same {}",
            f.file_name().unwrap().to_string_lossy(),
            size as f64 / 1e6,
            art.as_ref().map_or(0, |a| a.len()),
            processed.as_ref().map_or(0, |a| a.len()),
            cold,
            warm,
            art == again
        );
        if art.is_some() {
            found += 1;
            assert!(processed.is_some(), "embedded art didn't decode");
        }
    }
    eprintln!("{found}/{} tracks have embedded artwork", files.len());
    let _ = std::fs::remove_dir_all(&cache);
}
