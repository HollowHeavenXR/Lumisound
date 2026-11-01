//! LUMI_OPUS_DIR=<dir with s.opus s.webm s_ff.raw> cargo test -p lumisound-media --test opus_decode -- --nocapture
#[test]
fn decodes_opus_like_ffmpeg() {
    let Ok(dir) = std::env::var("LUMI_OPUS_DIR") else { return };
    let ff: Vec<i16> = std::fs::read(format!("{dir}/s_ff.raw")).unwrap().chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]])).collect();
    for f in ["s.opus", "s.webm"] {
        let p = std::path::PathBuf::from(format!("{dir}/{f}"));
        let s = lumisound_media::decode::mono_pcm(&p, 11025, None, None).unwrap_or_else(|| panic!("{f} did not decode"));
        let rms = |v: &[i16]| (v.iter().map(|x| (*x as f64).powi(2)).sum::<f64>() / v.len() as f64).sqrt();
        println!("{f}: {} samples (ffmpeg {}), rms {:.0} (ffmpeg {:.0}), bpm {:?}", s.len(), ff.len(), rms(&s), rms(&ff), lumisound_media::analysis::bpm_simple(&s));
        assert!((s.len() as f64 - ff.len() as f64).abs() < 11025.0 * 0.1, "{f} length");
        assert!((rms(&s) / rms(&ff) - 1.0).abs() < 0.1, "{f} level");
    }
}
