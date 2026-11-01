//! Compares symphonia BPM with the bridge's ffmpeg path on a real file:
//! LUMI_TEST_AUDIO=/path/to/track.mp3 cargo test -p lumisound-media -- --nocapture
#[test]
fn bpm_on_real_file() {
    let Ok(p) = std::env::var("LUMI_TEST_AUDIO") else { return };
    let s = lumisound_media::decode::mono_pcm(std::path::Path::new(&p), 11025, Some(0.0), Some(60.0)).expect("decode");
    println!("samples={} bpm={:?}", s.len(), lumisound_media::analysis::bpm_simple(&s));
    let d = lumisound_media::decode::probe(std::path::Path::new(&p)).unwrap();
    println!("duration={:.2} rate={} ch={}", d.duration, d.sample_rate, d.channels);
}

#[test]
fn bpm_ffmpeg_raw() {
    let Ok(p) = std::env::var("LUMI_TEST_RAW") else { return };
    let b = std::fs::read(p).unwrap();
    let s: Vec<i16> = b.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]])).collect();
    println!("ffmpeg samples={} bpm={:?}", s.len(), lumisound_media::analysis::bpm_simple(&s));
}
