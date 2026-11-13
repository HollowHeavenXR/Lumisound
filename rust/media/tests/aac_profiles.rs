//! AAC profiles symphonia's decoder refuses or mangles, now decoded by the
//! engine's AAC path (`aac::AacDecoder`): HE-AAC v1 (SBR), HE-AAC v2 (PS)
//! and 5.1 AAC folded to stereo. HE fixtures are encoded with syom; ffmpeg
//! cross-checks them so the test isn't syom grading its own homework.
//!
//!   cargo test -p lumisound-media --test aac_profiles -- --nocapture

use std::path::{Path, PathBuf};
use std::process::Command;

const RATE: u32 = 44_100;
const SECS: f64 = 3.0;

fn tone(f: f64) -> Vec<f32> {
    (0..(RATE as f64 * SECS) as usize).map(|i| (0.4 * (2.0 * std::f64::consts::PI * f * i as f64 / RATE as f64).sin()) as f32).collect()
}

fn power(x: &[f32], rate: u32, f: f64) -> f64 {
    let n = (rate as usize).min(x.len());
    let start = x.len().saturating_sub(n) / 2;
    let w = 2.0 * (2.0 * std::f64::consts::PI * f / rate as f64).cos();
    let (mut s1, mut s2) = (0.0f64, 0.0f64);
    for &v in &x[start..start + n] {
        let s0 = v as f64 + w * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    (s1 * s1 + s2 * s2 - w * s1 * s2) / (n as f64 * n as f64)
}

fn dir() -> PathBuf {
    let d = std::env::temp_dir().join(format!("lumi-aac-{}", std::process::id()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// HE-AAC encoded by syom (ADTS), muxed into M4A by ffmpeg (a real esds,
/// like iTunes / fdk files). None when ffmpeg isn't installed.
fn he_fixture(path: &Path, ps: bool) -> Option<()> {
    let mut o = syom::EncodeOptions::adts();
    o.he = true;
    o.ps = ps;
    // 440 Hz left, 6 kHz right (v1). The ASC describes a 22.05 kHz core;
    // only a decoder that runs SBR delivers 44.1 kHz output.
    let pcm = if ps { vec![tone(440.0), tone(440.0)] } else { vec![tone(440.0), tone(6000.0)] };
    let adts = path.with_extension("aac");
    syom::write_with(&adts, &pcm, RATE, &o).unwrap();
    let ok = Command::new("ffmpeg").args(["-hide_banner", "-loglevel", "error", "-y", "-i"]).arg(&adts).args(["-c", "copy"]).arg(path).status().is_ok_and(|s| s.success());
    ok.then_some(())
}

fn ffmpeg_ok() -> bool {
    Command::new("ffmpeg").arg("-version").output().is_ok_and(|o| o.status.success())
}

/// ffmpeg's view of a file: (rate, interleaved stereo f32).
fn ffmpeg_decode(path: &Path) -> Option<Vec<f32>> {
    let out = Command::new("ffmpeg").args(["-hide_banner", "-loglevel", "error", "-i"]).arg(path).args(["-ac", "2", "-ar", "44100", "-f", "f32le", "-"]).output().ok()?;
    out.status.success().then(|| out.stdout.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect())
}

#[test]
fn he_aac_v1_decodes_at_full_rate() {
    let p = dir().join("he1.m4a");
    if he_fixture(&p, false).is_none() {
        return;
    }
    let asc_ok = lumisound_media::decode::probe(&p).expect("probe");
    let (rate, ch) = lumisound_media::decode::planar(&p, None, None).expect("decode");
    eprintln!("HE-AAC v1: {rate} Hz, {} ch, {:.3}s (probe {:.3}s)", ch.len(), ch[0].len() as f64 / rate as f64, asc_ok.duration);
    assert_eq!(rate, 44_100, "SBR output rate");
    assert_eq!(ch.len(), 2);
    let len = ch[0].len() as f64 / rate as f64;
    // ADTS-sourced fixture: no gapless metadata, so the HE decoder's
    // priming (~110 ms at 44.1 kHz) stays in. Real iTunes / fdk M4As carry
    // iTunSMPB / an edit list, which `gapless` trims.
    assert!((len - SECS).abs() < 0.15, "length {len}");
    // The 6 kHz tone needs SBR: a core-only (22.05 kHz) decode can carry it,
    // so check the high band is really there and in the right channel.
    assert!(power(&ch[0], rate, 440.0) > 10.0 * power(&ch[0], rate, 6000.0), "left");
    assert!(power(&ch[1], rate, 6000.0) > 10.0 * power(&ch[1], rate, 440.0), "right");
    let f = ffmpeg_decode(&p).expect("ffmpeg decodes the fixture");
    let r: Vec<f32> = f.chunks(2).map(|c| c[1]).collect();
    assert!(power(&r, 44_100, 6000.0) > 10.0 * power(&r, 44_100, 440.0), "ffmpeg disagrees with the fixture");
}

#[test]
fn he_aac_v2_decodes_stereo() {
    let p = dir().join("he2.m4a");
    if he_fixture(&p, true).is_none() {
        return;
    }
    let (rate, ch) = lumisound_media::decode::planar(&p, None, None).expect("decode");
    eprintln!("HE-AAC v2: {rate} Hz, {} ch, {:.3}s", ch.len(), ch[0].len() as f64 / rate as f64);
    assert_eq!(rate, 44_100);
    assert_eq!(ch.len(), 2, "parametric stereo rebuilds two channels");
    for c in &ch {
        let p440 = power(c, rate, 440.0);
        assert!(p440 > 1e-3 && p440 > 10.0 * power(c, rate, 1000.0), "tone missing: {p440}");
    }
}

#[test]
fn surround_aac_folds_to_stereo() {
    if !ffmpeg_ok() {
        return;
    }
    let p = dir().join("51.m4a");
    // 440 Hz front-left, 1 kHz front-right, silence in C/LFE/BL/BR.
    let ok = Command::new("ffmpeg")
        .args(["-hide_banner", "-loglevel", "error", "-y",
               "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
               "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=3",
               "-filter_complex", "[0][1]amerge=inputs=2,pan=5.1|FL=c0|FR=c1[a]", "-map", "[a]", "-c:a", "aac", "-b:a", "384k"])
        .arg(&p)
        .status()
        .is_ok_and(|s| s.success());
    assert!(ok, "ffmpeg 5.1 fixture");
    let (rate, ch) = lumisound_media::decode::planar(&p, None, None).expect("5.1 AAC decodes");
    eprintln!("5.1 AAC: {rate} Hz, {} ch, {:.3}s", ch.len(), ch[0].len() as f64 / rate as f64);
    assert_eq!(ch.len(), 2);
    assert!(power(&ch[0], rate, 440.0) > 10.0 * power(&ch[0], rate, 1000.0), "front-left lands left");
    assert!(power(&ch[1], rate, 1000.0) > 10.0 * power(&ch[1], rate, 440.0), "front-right lands right");
    let len = ch[0].len() as f64 / rate as f64;
    assert!((len - SECS).abs() < 0.03, "length {len}");
}
