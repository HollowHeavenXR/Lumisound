//! Server-side track analysis (ports of main.py's _measure_loudness /
//! _estimate_bpm / _estimate_key / _compute_waveform and locked_media.py's
//! BPM, transition and spectral profiles, and artwork recovery).
//!
//! Decoding stays with the ffmpeg CLI (it reads every container/codec the
//! apps can upload, Opus/WebM included). The upload path decodes a file once
//! through a split filter graph instead of four separate ffmpeg runs.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

/// Python's round(x, n): correctly rounded from the exact binary value,
/// ties to even. Rust's fixed-precision formatting does the same.
pub fn pyround(x: f64, nd: i32) -> f64 {
    if !x.is_finite() {
        return x;
    }
    format!("{:.*}", nd.max(0) as usize, x).parse().unwrap_or(x)
}

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

/// `_estimate_bpm` (main.py): energy-onset autocorrelation on 11025 Hz mono.
pub fn bpm_simple(s: &[i16]) -> Option<f64> {
    if s.len() * 2 < 11025 * 2 * 4 {
        return None;
    }
    let sr = 11025usize;
    let w = sr / 50;
    let mut energies = Vec::new();
    let mut i = 0;
    while i + w < s.len() {
        let sum: i64 = s[i..i + w].iter().map(|x| (*x as i64) * (*x as i64)).sum();
        energies.push(sum as f64 / w as f64);
        i += w;
    }
    if energies.len() < 20 {
        return None;
    }
    let onsets: Vec<f64> = (1..energies.len()).map(|i| (energies[i] - energies[i - 1]).max(0.0)).collect();
    let fr = sr as f64 / w as f64;
    let min_lag = ((fr * 60.0 / 200.0) as usize).max(1);
    let max_lag = ((fr * 60.0 / 60.0) as usize).min(onsets.len() - 1);
    if min_lag >= max_lag {
        return None;
    }
    let (mut best_lag, mut best) = (0usize, -1.0f64);
    for lag in min_lag..=max_lag {
        let score: f64 = (lag..onsets.len()).map(|i| onsets[i] * onsets[i - lag]).sum();
        if score > best {
            best = score;
            best_lag = lag;
        }
    }
    if best_lag == 0 {
        return None;
    }
    Some(pyround(60.0 * fr / best_lag as f64, 1))
}

/// `_compute_waveform`: 200 peak values in 0..1.
pub fn waveform(s: &[i16]) -> Option<Vec<f64>> {
    if s.is_empty() {
        return None;
    }
    let bucket = (s.len() / 200).max(1);
    Some(
        s.chunks(bucket)
            .take(200)
            .map(|c| pyround(c.iter().map(|x| (*x as i32).abs()).max().unwrap_or(0) as f64 / 32768.0, 4))
            .collect(),
    )
}

const KS_MAJOR: [f64; 12] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const KS_MINOR: [f64; 12] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
const PITCH: [&str; 12] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];

fn goertzel(s: &[i16], sr: f64, f: f64) -> f64 {
    let w = 2.0 * std::f64::consts::PI * f / sr;
    let c = 2.0 * w.cos();
    let (mut q1, mut q2) = (0.0f64, 0.0f64);
    for x in s {
        let q0 = c * q1 - q2 + *x as f64;
        q2 = q1;
        q1 = q0;
    }
    q1 * q1 + q2 * q2 - q1 * q2 * c
}

pub fn chroma_vector(s: &[i16], sr: u32) -> [f64; 12] {
    let mut chroma = [0.0; 12];
    let nyq = sr as f64 / 2.0;
    for octave in 2..5 {
        for pitch in 0..12 {
            let f = 440.0 * 2f64.powf(((pitch as f64 - 9.0) + ((octave as f64 - 4.0) * 12.0)) / 12.0);
            if f >= nyq {
                continue;
            }
            chroma[pitch] += goertzel(s, sr as f64, f);
        }
    }
    chroma
}

fn corr(a: &[f64], b: &[f64]) -> f64 {
    let ma = a.iter().sum::<f64>() / a.len() as f64;
    let mb = b.iter().sum::<f64>() / b.len() as f64;
    let num: f64 = a.iter().zip(b).map(|(x, y)| (x - ma) * (y - mb)).sum();
    let den = (a.iter().map(|x| (x - ma).powi(2)).sum::<f64>() * b.iter().map(|y| (y - mb).powi(2)).sum::<f64>()).sqrt();
    if den != 0.0 { num / den } else { 0.0 }
}

pub fn key_from_chroma(c: &[f64; 12]) -> Option<String> {
    if c.iter().all(|x| *x == 0.0) {
        return None;
    }
    let (mut best, mut score) = (None, -2.0);
    for root in 0..12 {
        let rot: Vec<f64> = c[root..].iter().chain(c[..root].iter()).copied().collect();
        let ma = corr(&rot, &KS_MAJOR);
        let mi = corr(&rot, &KS_MINOR);
        if ma > score {
            score = ma;
            best = Some(format!("{} major", PITCH[root]));
        }
        if mi > score {
            score = mi;
            best = Some(format!("{} minor", PITCH[root]));
        }
    }
    best
}

pub fn camelot(key: Option<&str>) -> Option<&'static str> {
    let parts: Vec<&str> = key?.split_whitespace().collect();
    if parts.len() != 2 {
        return None;
    }
    let major = [("C", "8B"), ("G", "9B"), ("D", "10B"), ("A", "11B"), ("E", "12B"), ("B", "1B"), ("F#", "2B"), ("C#", "3B"), ("G#", "4B"), ("D#", "5B"), ("A#", "6B"), ("F", "7B")];
    let minor = [("A", "8A"), ("E", "9A"), ("B", "10A"), ("F#", "11A"), ("C#", "12A"), ("G#", "1A"), ("D#", "2A"), ("A#", "3A"), ("F", "4A"), ("C", "5A"), ("G", "6A"), ("D", "7A")];
    let table: &[(&str, &str)] = match parts[1].to_lowercase().as_str() {
        "major" => &major,
        "minor" => &minor,
        _ => return None,
    };
    table.iter().find(|(p, _)| *p == parts[0]).map(|(_, c)| *c)
}

pub fn camelot_compatible(a: Option<&str>, b: Option<&str>) -> bool {
    let (Some(a), Some(b)) = (a, b) else { return false };
    if a == b {
        return true;
    }
    let split = |s: &str| -> Option<(i32, char)> { Some((s[..s.len() - 1].parse().ok()?, s.chars().last()?)) };
    let (Some((na, la)), Some((nb, lb))) = (split(a), split(b)) else { return false };
    if la == lb {
        let d = (na - nb).abs() % 12;
        return d == 1 || d == 11;
    }
    na == nb
}

// ---- locked_media.py ports --------------------------------------------------------------------

/// locked_media.estimate_bpm: spectral-flux autocorrelation over the middle
/// 120 s, folded into 70–140.
pub async fn estimate_bpm(readable: &Path) -> Option<f64> {
    let dur = duration_of(readable).await;
    let start = if dur > 120.0 { ((dur - 120.0) / 2.0).max(0.0) } else { 0.0 };
    let s = pcm(readable, 11025, Some(start), Some(120.0), Duration::from_secs(180)).await?;
    tokio::task::spawn_blocking(move || bpm_flux(&s)).await.ok().flatten()
}

fn bpm_flux(s: &[i16]) -> Option<f64> {
    if s.len() * 2 < 4 * 11025 * 2 {
        return None;
    }
    let hop = 128;
    let frames = s.len() / hop;
    if frames < 64 {
        return None;
    }
    let energy: Vec<f32> = (0..frames)
        .map(|f| {
            let sum: f32 = s[f * hop..(f + 1) * hop].iter().map(|x| { let v = *x as f32 / 32768.0; v * v }).sum();
            (sum / hop as f32).sqrt()
        })
        .collect();
    let mut flux: Vec<f64> = (0..frames).map(|i| if i == 0 { 0.0 } else { (energy[i] - energy[i - 1]).max(0.0) as f64 }).collect();
    if flux.iter().cloned().fold(f64::MIN, f64::max) <= 0.0 {
        return None;
    }
    let mean = flux.iter().sum::<f64>() / flux.len() as f64;
    flux.iter_mut().for_each(|x| *x -= mean);
    let fr = 11025.0 / hop as f64;
    let min_lag = (fr * 60.0 / 200.0) as usize;
    let mut max_lag = (fr * 60.0 / 60.0) as usize;
    if max_lag >= flux.len() {
        max_lag = flux.len() - 1;
    }
    if min_lag < 1 || max_lag <= min_lag {
        return None;
    }
    let ac = |lag: usize| -> f64 { (lag..flux.len()).map(|i| flux[i] * flux[i - lag]).sum() };
    let c0 = ac(0);
    if c0 <= 0.0 {
        return None;
    }
    let (mut best, mut peak) = (0usize, f64::MIN);
    for lag in min_lag..=max_lag {
        let v = ac(lag);
        if v > peak {
            peak = v;
            best = lag;
        }
    }
    if peak / c0 < 0.10 {
        return None;
    }
    let mut bpm = 60.0 * fr / best as f64;
    while bpm > 140.0 && bpm / 2.0 >= 60.0 {
        bpm /= 2.0;
    }
    while bpm < 70.0 && bpm * 2.0 <= 200.0 {
        bpm *= 2.0;
    }
    if !(60.0..=200.0).contains(&bpm) {
        return None;
    }
    Some(pyround(bpm, 1))
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TransitionProfile {
    pub trailing_silence_s: f64,
    pub outro_slope_db_per_s: f64,
    pub outro_cold_stop: bool,
    pub outro_tail_db: f64,
    pub intro_lead_in_s: f64,
    pub intro_onset_hardness: f64,
}

fn envelope(s: &[i16]) -> Option<Vec<f64>> {
    let w = (8000.0 * 0.05) as usize;
    let frames = s.len() / w;
    if frames < 3 {
        return None;
    }
    Some(
        (0..frames)
            .map(|f| {
                let sum: f32 = s[f * w..(f + 1) * w].iter().map(|x| { let v = *x as f32 / 32768.0; v * v }).sum();
                (sum / w as f32).sqrt() as f64
            })
            .collect(),
    )
}

fn median(v: &[f64]) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = s.len();
    if n == 0 {
        return f64::NAN;
    }
    if n % 2 == 1 { s[n / 2] } else { (s[n / 2 - 1] + s[n / 2]) / 2.0 }
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

fn transition_from(tail_pcm: &[i16], head_pcm: &[i16]) -> Option<TransitionProfile> {
    let tail = envelope(tail_pcm)?;
    let head = envelope(head_pcm)?;
    let db = |x: f64| 20.0 * x.max(1e-5).log10();
    let win = 0.05;
    let tail_peak = tail.iter().cloned().fold(f64::MIN, f64::max);
    if tail_peak <= 0.0 {
        return None;
    }
    let threshold = (tail_peak * 0.01).max(0.0015);
    let last_music = tail.iter().rposition(|v| *v > threshold)?;
    let trailing = (tail.len() - 1 - last_music) as f64 * win;
    let music = &tail[..=last_music];
    let wf = (10.0 / win) as usize;
    let outro = if music.len() > wf { &music[music.len() - wf..] } else { music };
    let frames = outro.len();
    if frames < 4 {
        return None;
    }
    // Least-squares slope of dB over time (np.polyfit deg 1).
    let ys: Vec<f64> = outro.iter().map(|v| db(*v)).collect();
    let n = frames as f64;
    let ts: Vec<f64> = (0..frames).map(|i| i as f64 * win).collect();
    let (mt, my) = (ts.iter().sum::<f64>() / n, ys.iter().sum::<f64>() / n);
    let sxy: f64 = ts.iter().zip(&ys).map(|(t, y)| (t - mt) * (y - my)).sum();
    let sxx: f64 = ts.iter().map(|t| (t - mt).powi(2)).sum();
    let slope = if sxx > 0.0 { sxy / sxx } else { 0.0 };
    let tail_frames = 3usize.max((frames - 1).min((1.0 / win) as usize));
    let last = median(&outro[frames - tail_frames..]);
    let body = median(&outro[..(frames - tail_frames).max(1)]);
    let cold = db(body) - db(last) > 12.0 && slope > -2.0;
    let head_peak = head.iter().cloned().fold(f64::MIN, f64::max);
    let head_db: Vec<f64> = head.iter().map(|v| db(*v)).collect();
    let lead_th = db(head_peak) - 12.0;
    let first = head_db.iter().position(|d| *d >= lead_th);
    let lead_in = first.map(|i| i as f64 * win).unwrap_or(0.0);
    let onset = first.unwrap_or(0);
    let target = db(head_peak) - 3.0;
    let hardness = match head_db[onset..].iter().position(|d| *d >= target) {
        Some(r) => (1.0 - (r as f64 * win) / 2.0).clamp(0.0, 1.0),
        None => 0.0,
    };
    Some(TransitionProfile {
        trailing_silence_s: pyround(trailing, 2),
        outro_slope_db_per_s: pyround(slope, 2),
        outro_cold_stop: cold,
        outro_tail_db: pyround(db(last), 1),
        intro_lead_in_s: pyround(lead_in, 2),
        intro_onset_hardness: pyround(hardness, 3),
    })
}

pub const EQ_BANDS_HZ: [f64; 10] = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

/// locked_media.spectral_profile: per-EQ-band energy density relative to
/// the track's mean, in dB (middle 60 s, 32 kHz, 4096-point Hann FFT).
pub async fn spectral_profile(readable: &Path) -> Option<Vec<f64>> {
    let dur = duration_of(readable).await;
    let start = if dur > 60.0 { ((dur - 60.0) / 2.0).max(0.0) } else { 0.0 };
    let s = pcm(readable, 32000, Some(start), Some(60.0), Duration::from_secs(180)).await?;
    tokio::task::spawn_blocking(move || spectral_from(&s)).await.ok().flatten()
}

fn spectral_from(s: &[i16]) -> Option<Vec<f64>> {
    const N: usize = 4096;
    const SR: f64 = 32000.0;
    if s.len() * 2 < N * 4 {
        return None;
    }
    let x: Vec<f64> = s.iter().map(|v| *v as f64 / 32768.0).collect();
    let hop = N / 2;
    if x.len() < N {
        return None;
    }
    let frames = (x.len() - N) / hop;
    if frames < 4 {
        return None;
    }
    let window: Vec<f64> = (0..N).map(|n| 0.5 - 0.5 * (2.0 * std::f64::consts::PI * n as f64 / (N - 1) as f64).cos()).collect();
    let mut planner = rustfft::FftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(N);
    let bins = N / 2 + 1;
    let mut power = vec![0.0f64; bins];
    let mut buf = vec![rustfft::num_complex::Complex::new(0.0, 0.0); N];
    for f in 0..frames {
        for (i, b) in buf.iter_mut().enumerate() {
            *b = rustfft::num_complex::Complex::new(x[f * hop + i] * window[i], 0.0);
        }
        fft.process(&mut buf);
        for (k, p) in power.iter_mut().enumerate() {
            *p += buf[k].norm_sqr();
        }
    }
    power.iter_mut().for_each(|p| *p /= frames as f64);
    let total: f64 = power.iter().sum();
    if total <= 0.0 {
        return None;
    }
    let freqs: Vec<f64> = (0..bins).map(|k| k as f64 * SR / N as f64).collect();
    let r2 = std::f64::consts::SQRT_2;
    let refd = total / (bins as f64).max(1.0);
    Some(
        EQ_BANDS_HZ
            .iter()
            .map(|c| {
                let (lo, hi) = (c / r2, c * r2);
                let (mut band, mut width) = (0.0, 0usize);
                for (k, f) in freqs.iter().enumerate() {
                    if *f >= lo && *f < hi {
                        band += power[k];
                        width += 1;
                    }
                }
                if width == 0 {
                    return 0.0;
                }
                let density = band / (width as f64).max(1.0);
                pyround(10.0 * (density.max(1e-12) / refd.max(1e-12)).log10(), 2)
            })
            .collect(),
    )
}

// ---- artwork ----------------------------------------------------------------------------------

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
