//! Lyrics force-sync on real library tracks (locked `.lms` copies).
//!   LUMI_CLOUD_DIR=<dir> cargo test --release -p lumisound-core --test lyrics_cloud -- --nocapture
use std::time::Instant;

#[test]
fn force_sync_on_cloud_tracks() {
    let Ok(dir) = std::env::var("LUMI_CLOUD_DIR") else { return };
    let mut files: Vec<_> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "lms")).collect();
    files.sort();
    assert!(!files.is_empty(), "LUMI_CLOUD_DIR has no .lms tracks");
    let lyrics: String = (1..=24).map(|i| format!("this is line number {i} of the song we sing\n")).collect();
    for f in &files {
        let t = Instant::now();
        let r = lumisound_core::lyrics::lyrics_force_sync(f.to_string_lossy().into(), lyrics.clone()).expect("force sync");
        let secs = t.elapsed().as_secs_f64();
        assert_eq!(r.lines.len(), 24);
        assert!(!r.was_synced);
        assert!(r.lines.windows(2).all(|w| w[1].time > w[0].time), "{}: lines out of order", f.display());
        assert!(r.lrc.lines().count() == 24 && r.lrc.starts_with('['));
        eprintln!(
            "{}: {:.2}s to sync, singing {:.0}s, first line {:.1}s, last {:.1}s",
            f.file_name().unwrap().to_string_lossy(),
            secs,
            r.singing_seconds,
            r.lines[0].time,
            r.lines[23].time
        );
        // Must stay cheap enough to run in the background on a phone.
        assert!(secs < 10.0, "too slow: {secs:.1}s");
    }
    // Already-timed lyrics are kept as they are.
    let timed = "[00:01.00]a\n[00:05.50]b\n[00:09.00]c\n";
    let r = lumisound_core::lyrics::lyrics_force_sync(files[0].to_string_lossy().into(), timed.into()).unwrap();
    assert!(r.was_synced && r.lines[1].time == 5.5);
}
