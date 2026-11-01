//! Server-side track analysis (ports of main.py's _measure_loudness /
//! _estimate_bpm / _estimate_key / _compute_waveform and locked_media.py's
//! BPM, transition and spectral profiles, and artwork recovery).
//!
//! Decoding stays with the ffmpeg CLI (it reads every container/codec the
//! apps can upload, Opus/WebM included). The upload path decodes a file once
//! through a split filter graph instead of four separate ffmpeg runs.

pub use lumisound_media::analysis::*;

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

async fn run(args: &[String], timeout: Duration) -> Option<std::process::Output> {
    let fut = Command::new("ffmpeg").args(args).stdin(Stdio::null()).kill_on_drop(true).output();
    tokio::time::timeout(timeout, fut).await.ok()?.ok()
}

/// ffprobe format duration in seconds (0 on failure).
pub async fn duration_of(p: &Path) -> f64 {
    let fut = Command::new("ffprobe")
        .args(["-v", "quiet", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1"])
        .arg(p)
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(Duration::from_secs(30), fut).await {
        Ok(Ok(o)) => String::from_utf8_lossy(&o.stdout).trim().parse().unwrap_or(0.0),
        _ => 0.0,
    }
}

/// Mono s16le PCM at `rate`, optionally from `start` for `len` seconds.
pub async fn pcm(p: &Path, rate: u32, start: Option<f64>, len: Option<f64>, timeout: Duration) -> Option<Vec<i16>> {
    let mut a: Vec<String> = ["-v", "quiet"].map(String::from).to_vec();
    if let Some(s) = start {
        a.extend(["-ss".into(), py_num(s.max(0.0))]);
    }
    a.extend(["-i".into(), p.to_string_lossy().into()]);
    if let Some(l) = len {
        a.extend(["-t".into(), py_num(l)]);
    }
    a.extend(["-ac", "1", "-ar"].map(String::from));
    a.push(rate.to_string());
    a.extend(["-f", "s16le", "-"].map(String::from));
    let o = run(&a, timeout).await?;
    if !o.status.success() || o.stdout.is_empty() {
        return None;
    }
    Some(to_i16(&o.stdout))
}

fn py_num(f: f64) -> String {
    crate::probe::py_float(f)
}

fn to_i16(b: &[u8]) -> Vec<i16> {
    b.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]])).collect()
}

pub struct UploadAnalysis {
    pub loudness_lufs: Option<f64>,
    pub bpm: Option<f64>,
    pub musical_key: Option<String>,
    pub waveform: Option<Vec<f64>>,
}

/// One decode for loudness (loudnorm, as before), BPM + waveform (11025 Hz
/// mono) and key (5512 Hz mono, first 20 s).
pub async fn analyze_upload(p: &Path) -> UploadAnalysis {
    let key_tmp = std::env::temp_dir().join(format!("lms-key-{}.pcm", uuid::Uuid::new_v4().simple()));
    let graph = "[0:a:0]asplit=3[l][w][k];[l]loudnorm=print_format=json[lo];\
                 [w]aresample=11025,aformat=sample_fmts=s16:channel_layouts=mono[wo];\
                 [k]atrim=0:20,aresample=5512,aformat=sample_fmts=s16:channel_layouts=mono[ko]";
    let args: Vec<String> = [
        "-hide_banner", "-nostats", "-i", &p.to_string_lossy(), "-filter_complex", graph,
        "-map", "[lo]", "-f", "null", "-",
        "-map", "[wo]", "-f", "s16le", "pipe:1",
        "-map", "[ko]", "-f", "s16le", "-y", &key_tmp.to_string_lossy(),
    ]
    .map(String::from)
    .to_vec();
    let out = run(&args, Duration::from_secs(120)).await;
    let key_pcm = tokio::fs::read(&key_tmp).await.ok();
    let _ = tokio::fs::remove_file(&key_tmp).await;
    let Some(out) = out.filter(|o| o.status.success()) else {
        tracing::warn!("analyze_upload: ffmpeg decode failed for {}", p.display());
        return UploadAnalysis { loudness_lufs: None, bpm: None, musical_key: None, waveform: None };
    };
    let stderr = String::from_utf8_lossy(&out.stderr);
    let loudness = parse_loudnorm(&stderr);
    let mono = to_i16(&out.stdout);
    let key_samples = key_pcm.map(|b| to_i16(&b)).unwrap_or_default();
    tokio::task::spawn_blocking(move || {
        let sixty = &mono[..mono.len().min(11025 * 60)];
        UploadAnalysis {
            loudness_lufs: loudness,
            bpm: bpm_simple(sixty),
            waveform: waveform(&mono),
            musical_key: if key_samples.len() * 2 < 5512 * 2 * 4 { None } else { key_from_chroma(&chroma_vector(&key_samples, 5512)) },
        }
    })
    .await
    .unwrap_or(UploadAnalysis { loudness_lufs: loudness, bpm: None, musical_key: None, waveform: None })
}

fn parse_loudnorm(stderr: &str) -> Option<f64> {
    let s = stderr.rfind('{')?;
    let e = stderr.rfind('}')?;
    if e < s {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(&stderr[s..=e]).ok()?;
    match &v["input_i"] {
        serde_json::Value::String(x) => x.trim().parse().ok(),
        serde_json::Value::Number(n) => n.as_f64(),
        _ => None,
    }
    .filter(|x: &f64| x.is_finite())
}


/// locked_media.estimate_bpm: spectral-flux autocorrelation over the middle
/// 120 s, folded into 70–140.
pub async fn estimate_bpm(readable: &Path) -> Option<f64> {
    let dur = duration_of(readable).await;
    let start = if dur > 120.0 { ((dur - 120.0) / 2.0).max(0.0) } else { 0.0 };
    let s = pcm(readable, 11025, Some(start), Some(120.0), Duration::from_secs(180)).await?;
    tokio::task::spawn_blocking(move || bpm_flux(&s)).await.ok().flatten()
}

/// locked_media.transition_profile: outro fade/silence + intro lead-in.
pub async fn transition_profile(readable: &Path) -> Option<TransitionProfile> {
    let dur = duration_of(readable).await;
    if dur < 8.0 {
        return None;
    }
    let look = dur.min(45.0);
    let tail = pcm(readable, 8000, Some(dur - look), Some(look), Duration::from_secs(120)).await?;
    let head = pcm(readable, 8000, Some(0.0), Some(6.0), Duration::from_secs(120)).await?;
    tokio::task::spawn_blocking(move || transition_from(&tail, &head)).await.ok().flatten()
}

/// locked_media.spectral_profile: per-EQ-band energy density relative to
/// the track's mean, in dB (middle 60 s, 32 kHz, 4096-point Hann FFT).
pub async fn spectral_profile(readable: &Path) -> Option<Vec<f64>> {
    let dur = duration_of(readable).await;
    let start = if dur > 60.0 { ((dur - 60.0) / 2.0).max(0.0) } else { 0.0 };
    let s = pcm(readable, 32000, Some(start), Some(60.0), Duration::from_secs(180)).await?;
    tokio::task::spawn_blocking(move || spectral_from(&s)).await.ok().flatten()
}

const MIN_IMAGE: usize = 2048;

/// Raw first attached picture (`-vcodec copy`), as /user/music/artwork serves it.
pub async fn embedded_artwork_copy(readable: &Path) -> Result<Vec<u8>, &'static str> {
    let args: Vec<String> =
        ["-i", &readable.to_string_lossy(), "-map", "0:v", "-frames:v", "1", "-f", "image2", "-vcodec", "copy", "-"].map(String::from).to_vec();
    match tokio::time::timeout(Duration::from_secs(10), Command::new("ffmpeg").args(&args).stdin(Stdio::null()).kill_on_drop(true).output()).await {
        Err(_) => Err("timeout"),
        Ok(Err(_)) => Err("error"),
        Ok(Ok(o)) => Ok(o.stdout),
    }
}

/// locked_media.extract_artwork on an already-readable copy: embedded cover
/// (re-encoded to JPEG), else the LUMISOUND_THUMBNAIL tag (URL or base64).
pub async fn recover_artwork(http: &reqwest::Client, readable: &Path) -> (Option<Vec<u8>>, &'static str) {
    for map in ["0:v:0", "0:V:0"] {
        let tmp = std::env::temp_dir().join(format!("lms-art-{}.jpg", uuid::Uuid::new_v4().simple()));
        let args: Vec<String> = [
            "-v", "quiet", "-y", "-i", &readable.to_string_lossy(), "-map", map, "-c:v", "mjpeg", "-frames:v", "1", "-f", "image2",
            &tmp.to_string_lossy(),
        ]
        .map(String::from)
        .to_vec();
        let ok = run(&args, Duration::from_secs(60)).await.is_some_and(|o| o.status.success());
        let data = if ok { tokio::fs::read(&tmp).await.unwrap_or_default() } else { Vec::new() };
        let _ = tokio::fs::remove_file(&tmp).await;
        if data.len() > MIN_IMAGE {
            return (Some(data), "embedded");
        }
    }
    let fut = Command::new("ffprobe").args(["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams"]).arg(readable).kill_on_drop(true).output();
    let Ok(Ok(o)) = tokio::time::timeout(Duration::from_secs(30), fut).await else { return (None, "none") };
    let v: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_default();
    let mut thumb: Option<String> = None;
    let mut look = |tags: &serde_json::Value| {
        if let Some(obj) = tags.as_object() {
            for (k, val) in obj {
                if k.eq_ignore_ascii_case("lumisound_thumbnail") {
                    if let Some(s) = val.as_str() {
                        thumb.get_or_insert(s.trim().to_string());
                    }
                }
            }
        }
    };
    look(&v["format"]["tags"]);
    for s in v["streams"].as_array().into_iter().flatten() {
        look(&s["tags"]);
    }
    let Some(value) = thumb.filter(|t| !t.is_empty()) else { return (None, "none") };
    if value.starts_with("http") {
        if let Some(d) = fetch_image(http, &value).await {
            return (Some(d), "tag");
        }
        if value.contains("/vi/") {
            let stem = value.rsplit_once('/').map(|x| x.0).unwrap_or(&value);
            for size in ["maxresdefault", "sddefault", "hqdefault", "mqdefault", "default"] {
                if let Some(d) = fetch_image(http, &format!("{stem}/{size}.jpg")).await {
                    return (Some(d), "tag");
                }
            }
        }
        return (None, "none");
    }
    use base64::Engine;
    let payload = if value.starts_with("data:") { value.split_once(',').map(|x| x.1).unwrap_or("") } else { value.as_str() };
    if let Ok(d) = base64::engine::general_purpose::STANDARD.decode(payload.trim()) {
        if d.starts_with(&[0xff, 0xd8]) || d.starts_with(b"\x89PNG\r\n\x1a\n") {
            return (Some(d), "tag");
        }
    }
    (None, "none")
}

async fn fetch_image(http: &reqwest::Client, url: &str) -> Option<Vec<u8>> {
    let r = http.get(url).header("User-Agent", "Lumisound/artwork").timeout(Duration::from_secs(20)).send().await.ok()?;
    if r.status().as_u16() != 200 {
        return None;
    }
    let b = r.bytes().await.ok()?;
    (b.len() > MIN_IMAGE).then(|| b.to_vec())
}


#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rounding() {
        assert_eq!(pyround(2.5, 0), 2.0);
        assert_eq!(pyround(0.125, 2), 0.12);
        assert_eq!(pyround(120.04, 1), 120.0);
        assert_eq!(pyround(2.675, 2), 2.67);
        assert_eq!(pyround(10.235, 2), 10.23);
        assert_eq!(pyround(-0.905, 2), -0.91);
    }
    #[test]
    fn camelot_rules() {
        assert_eq!(camelot(Some("A minor")), Some("8A"));
        assert!(camelot_compatible(Some("8A"), Some("9A")));
        assert!(camelot_compatible(Some("8A"), Some("8B")));
        assert!(!camelot_compatible(Some("8A"), Some("10A")));
    }
    #[test]
    fn click_track_bpm() {
        // 120 BPM clicks at 11025 Hz for 20 s.
        let sr = 11025;
        let mut s = vec![0i16; sr * 20];
        let period = sr / 2;
        for b in (0..s.len()).step_by(period) {
            for i in 0..200.min(s.len() - b) {
                s[b + i] = if i % 2 == 0 { 20000 } else { -20000 };
            }
        }
        let bpm = bpm_simple(&s).unwrap();
        assert!((bpm - 120.0).abs() < 3.0, "{bpm}");
        let bpm2 = bpm_flux(&s).unwrap();
        assert!((bpm2 - 120.0).abs() < 3.0, "{bpm2}");
    }
}
