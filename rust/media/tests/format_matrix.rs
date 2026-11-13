//! Format coverage of the Lumisound engine's decode path (the same symphonia
//! probe + `opus::codecs()` registry the deck uses). Encodes a stereo
//! two-tone fixture (440 Hz left, 1 kHz right, 3 s) into every format the
//! app imports with ffmpeg, then checks each decodes with the right rate,
//! channel count, length and tones. Skipped when ffmpeg isn't installed.
//!
//!   cargo test -p lumisound-media --test format_matrix -- --nocapture

use std::path::{Path, PathBuf};
use std::process::Command;

const SECS: f64 = 3.0;
/// Decoded length must match within 15 ms (gapless: no priming or padding left in).
const TOLERANCE: f64 = 0.015;

/// (label, file name, ffmpeg codec args, required). `required` formats are
/// ones the app imports (import::SUPPORTED); the rest are reported only.
const CASES: &[(&str, &str, &[&str], bool)] = &[
    ("MP3", "t.mp3", &["-c:a", "libmp3lame", "-b:a", "192k"], true),
    ("AAC in M4A", "t.m4a", &["-c:a", "aac", "-b:a", "192k"], true),
    ("ALAC in M4A", "alac.m4a", &["-c:a", "alac"], true),
    ("AAC in MP4", "t.mp4", &["-c:a", "aac"], true),
    ("AAC in MOV", "t.mov", &["-c:a", "aac"], true),
    ("AAC in M4V", "t.m4v", &["-c:a", "aac"], true),
    ("Raw AAC (ADTS)", "t.aac", &["-c:a", "aac"], true),
    ("FLAC", "t.flac", &["-c:a", "flac"], true),
    ("WAV 16-bit", "s16.wav", &["-c:a", "pcm_s16le"], true),
    ("WAV 24-bit", "s24.wav", &["-c:a", "pcm_s24le"], true),
    ("WAV float", "f32.wav", &["-c:a", "pcm_f32le"], true),
    ("WAV IMA ADPCM", "adpcm.wav", &["-c:a", "adpcm_ima_wav"], true),
    ("WAV A-law", "alaw.wav", &["-c:a", "pcm_alaw"], true),
    ("WAV mu-law", "mulaw.wav", &["-c:a", "pcm_mulaw"], true),
    ("AIFF", "t.aiff", &["-c:a", "pcm_s16be"], true),
    ("AIF", "t.aif", &["-c:a", "pcm_s16be"], true),
    ("CAF PCM", "pcm.caf", &["-c:a", "pcm_s16le"], true),
    ("CAF ALAC", "alac.caf", &["-c:a", "alac"], true),
    ("Ogg Vorbis", "t.ogg", &["-c:a", "libvorbis"], true),
    ("Ogg Opus (.opus)", "t.opus", &["-c:a", "libopus", "-b:a", "128k"], true),
    ("Opus in .ogg", "opus.ogg", &["-c:a", "libopus"], true),
    ("WebM Opus", "t.webm", &["-c:a", "libopus"], true),
    ("WebM Vorbis", "vorbis.webm", &["-c:a", "libvorbis"], true),
    ("Matroska audio", "t.mka", &["-c:a", "libopus"], true),
    ("MP2", "t.mp2", &["-c:a", "mp2"], true),
    ("AC-3", "t.ac3", &["-c:a", "ac3"], false),
    ("E-AC-3", "t.eac3", &["-c:a", "eac3"], false),
    ("WMA", "t.wma", &["-c:a", "wmav2"], false),
    ("WavPack", "t.wv", &["-c:a", "wavpack"], false),
];

fn ffmpeg() -> bool {
    Command::new("ffmpeg").arg("-version").output().is_ok_and(|o| o.status.success())
}

fn make(dir: &Path, name: &str, codec: &[&str]) -> Option<PathBuf> {
    let out = dir.join(name);
    let ok = Command::new("ffmpeg")
        .args(["-hide_banner", "-loglevel", "error", "-y",
               "-f", "lavfi", "-i", &format!("sine=frequency=440:sample_rate=44100:duration={SECS}"),
               "-f", "lavfi", "-i", &format!("sine=frequency=1000:sample_rate=44100:duration={SECS}"),
               "-filter_complex", "[0][1]amerge=inputs=2,volume=0.5[a]", "-map", "[a]", "-vn"])
        .args(codec)
        .arg(&out)
        .status()
        .is_ok_and(|s| s.success());
    ok.then_some(out)
}

/// Relative power at `f` Hz (Goertzel over the middle second).
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

/// Why a decoded file is wrong, or None when it's right.
fn check(path: &Path) -> Result<String, String> {
    let probe = lumisound_media::decode::probe(path).ok_or("probe failed (container/codec not recognised)")?;
    let (rate, ch) = lumisound_media::decode::planar(path, None, None).ok_or("decode failed")?;
    if ch.len() != 2 {
        return Err(format!("{} channel(s), want 2", ch.len()));
    }
    let len = ch[0].len() as f64 / rate as f64;
    // Raw ADTS has no gapless metadata at all (priming + padding stay in).
    let raw_adts = path.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with(".aac") || n.ends_with(".aac.lms"));
    let tolerance = if raw_adts { 0.05 } else { TOLERANCE };
    if (len - SECS).abs() > tolerance {
        return Err(format!("decoded {len:.3}s, want {SECS}s"));
    }
    let (l440, l1k) = (power(&ch[0], rate, 440.0), power(&ch[0], rate, 1000.0));
    let (r440, r1k) = (power(&ch[1], rate, 440.0), power(&ch[1], rate, 1000.0));
    if l440 < 10.0 * l1k || r1k < 10.0 * r440 {
        return Err(format!("tones wrong: L 440/1k {:.1}, R 1k/440 {:.1}", l440 / l1k.max(1e-12), r1k / r440.max(1e-12)));
    }
    Ok(format!("{rate} Hz, {len:.3}s (probe {:.3}s)", probe.duration))
}

#[test]
fn every_imported_format_decodes() {
    if !ffmpeg() {
        eprintln!("ffmpeg not installed: skipping format matrix");
        return;
    }
    let dir = std::env::temp_dir().join(format!("lumi-formats-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut failures = Vec::new();
    for (label, name, codec, required) in CASES {
        let Some(path) = make(&dir, name, codec) else {
            eprintln!("{label:<18} (ffmpeg couldn't make it)");
            continue;
        };
        let res = check(&path);
        // Locked copy (.lms) of every required format must decode the same.
        let locked = if *required {
            let l = dir.join(format!("{name}.lms"));
            lumisound_media::lock::lock_file(&path, &l).unwrap();
            Some(check(&l))
        } else {
            None
        };
        match (&res, &locked) {
            (Ok(info), Some(Ok(_)) | None) => eprintln!("ok   {label:<18} {info}"),
            (Ok(_), Some(Err(e))) => eprintln!("FAIL {label:<18} locked: {e}"),
            (Err(e), _) => eprintln!("{}{label:<18} {e}", if *required { "FAIL " } else { "--   " }),
        }
        if *required && (res.is_err() || matches!(locked, Some(Err(_)))) {
            failures.push(*label);
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert!(failures.is_empty(), "formats the app imports that don't decode: {failures:?}");
}
