//! On-device analysis: symphonia decode + the same DSP the bridge runs
//! (lumisound-media::analysis). Results are cached in the core store keyed
//! by path, mtime and size so unchanged files are never re-analysed.

use crate::store;
use lumisound_media::{analysis as dsp, decode};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

static LOCK: Mutex<()> = Mutex::new(());
const BPM_CACHE: &str = "bpm_cache";

pub(crate) fn cache_key(path: &str) -> String {
    let m = std::fs::metadata(path).ok();
    let mtime = m.as_ref().and_then(|m| m.modified().ok()).and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    let size = m.map(|m| m.len()).unwrap_or(0);
    format!("{path}|{mtime}|{size}")
}

/// `.lms` files are unlocked into the playable cache first.
fn readable(path: &str, cache_dir: &str) -> String {
    crate::lock::lms_playable_path(path.to_string(), cache_dir.to_string())
}

/// Mono 16-bit PCM at `sample_rate` from `start_secs` for up to `max_secs`.
/// None when symphonia can't decode the file (e.g. Opus/WebM).
#[uniffi::export]
pub fn decode_mono(path: String, cache_dir: String, sample_rate: u32, start_secs: f64, max_secs: f64) -> Option<Vec<i16>> {
    let p = readable(&path, &cache_dir);
    decode::mono_pcm(Path::new(&p), sample_rate, Some(start_secs), Some(max_secs))
}

/// Duration in seconds from container metadata (0 when unknown).
#[uniffi::export]
pub fn probe_duration(path: String, cache_dir: String) -> f64 {
    decode::probe(Path::new(&readable(&path, &cache_dir))).map(|p| p.duration).unwrap_or(0.0)
}

/// Previously estimated tempo for this exact file, if any.
#[uniffi::export]
pub fn bpm_cached(path: String) -> Option<f64> {
    let m: HashMap<String, f64> = store::load(BPM_CACHE);
    m.get(&cache_key(&path)).copied()
}

/// Seed the cache from the Swift-era bpm_cache_v1.json (same key format).
#[uniffi::export]
pub fn bpm_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(BPM_CACHE) {
        return;
    }
    let m: HashMap<String, f64> = serde_json::from_slice(&json).unwrap_or_default();
    store::save(BPM_CACHE, &m);
}

/// Tempo of the first 60 s (energy-onset autocorrelation, 60–200 BPM, 0.1
/// precision) — `pcm` lets callers that already decoded skip the decode.
#[uniffi::export]
pub fn bpm_estimate(path: String, cache_dir: String, pcm: Option<Vec<i16>>) -> Option<f64> {
    if let Some(v) = bpm_cached(path.clone()) {
        return Some(v);
    }
    let samples = pcm.or_else(|| decode_mono(path.clone(), cache_dir, 11025, 0.0, 60.0))?;
    let v = dsp::bpm_simple(&samples)?;
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, f64> = store::load(BPM_CACHE);
    m.insert(cache_key(&path), v);
    store::save(BPM_CACHE, &m);
    Some(v)
}

/// Musical key ("A minor") and Camelot code ("8A") from the middle of the track.
#[derive(uniffi::Record, Clone, Debug)]
pub struct KeyEstimate {
    pub key: String,
    pub camelot: Option<String>,
}

#[uniffi::export]
pub fn key_estimate(path: String, cache_dir: String) -> Option<KeyEstimate> {
    let dur = probe_duration(path.clone(), cache_dir.clone());
    let start = if dur > 60.0 { (dur - 60.0) / 2.0 } else { 0.0 };
    let s = decode_mono(path, cache_dir, 11025, start, 60.0)?;
    let k = dsp::key_from_chroma(&dsp::chroma_vector(&s, 11025))?;
    let camelot = dsp::camelot(Some(&k)).map(str::to_string);
    Some(KeyEstimate { key: k, camelot })
}

#[uniffi::export]
pub fn camelot_compatible(a: Option<String>, b: Option<String>) -> bool {
    dsp::camelot_compatible(a.as_deref(), b.as_deref())
}

/// 200 peak values in 0…1 over the whole track (8 kHz decode).
#[uniffi::export]
pub fn waveform_peaks(path: String, cache_dir: String) -> Option<Vec<f64>> {
    let s = decode::mono_pcm(Path::new(&readable(&path, &cache_dir)), 8000, None, None)?;
    dsp::waveform(&s)
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct TransitionInfo {
    pub trailing_silence_s: f64,
    pub outro_slope_db_per_s: f64,
    pub outro_cold_stop: bool,
    pub outro_tail_db: f64,
    pub intro_lead_in_s: f64,
    pub intro_onset_hardness: f64,
}

/// Outro fade/silence and intro lead-in (for crossfade/DJ transitions).
#[uniffi::export]
pub fn transition_profile(path: String, cache_dir: String) -> Option<TransitionInfo> {
    let p = readable(&path, &cache_dir);
    let dur = decode::probe(Path::new(&p)).map(|x| x.duration).unwrap_or(0.0);
    if dur < 8.0 {
        return None;
    }
    let look = dur.min(45.0);
    let tail = decode::mono_pcm(Path::new(&p), 8000, Some(dur - look), Some(look))?;
    let head = decode::mono_pcm(Path::new(&p), 8000, Some(0.0), Some(6.0))?;
    let t = dsp::transition_from(&tail, &head)?;
    Some(TransitionInfo {
        trailing_silence_s: t.trailing_silence_s,
        outro_slope_db_per_s: t.outro_slope_db_per_s,
        outro_cold_stop: t.outro_cold_stop,
        outro_tail_db: t.outro_tail_db,
        intro_lead_in_s: t.intro_lead_in_s,
        intro_onset_hardness: t.intro_onset_hardness,
    })
}

/// Per-EQ-band (32 Hz…16 kHz) energy vs the track mean, in dB.
#[uniffi::export]
pub fn spectral_profile(path: String, cache_dir: String) -> Option<Vec<f64>> {
    let p = readable(&path, &cache_dir);
    let dur = decode::probe(Path::new(&p)).map(|x| x.duration).unwrap_or(0.0);
    let start = if dur > 60.0 { (dur - 60.0) / 2.0 } else { 0.0 };
    let s = decode::mono_pcm(Path::new(&p), 32000, Some(start), Some(60.0))?;
    dsp::spectral_from(&s)
}

// ---- loudness normalization -------------------------------------------------------------------

const NORM_CACHE: &str = "normalization_gain";

fn norm_key(path: &str) -> String {
    let p = Path::new(path);
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or(path);
    match std::fs::metadata(p) {
        Ok(m) => {
            let ms = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0);
            format!("{name}_{}_{ms}", m.len())
        }
        Err(_) => name.to_string(),
    }
}

/// One-time import of the Swift-era normalization cache (same key format).
#[uniffi::export]
pub fn normalization_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(NORM_CACHE) {
        return;
    }
    let m: HashMap<String, f32> = serde_json::from_slice(&json).unwrap_or_default();
    store::save(NORM_CACHE, &m);
}

/// Gain (dB, -20…+12) that brings the middle 60 s of the track to -18 LUFS.
/// 0 when the file can't be analysed. Cached per file name/size/mtime.
#[uniffi::export]
pub fn normalization_gain(path: String, cache_dir: String) -> f32 {
    let key = norm_key(&path);
    {
        let m: HashMap<String, f32> = store::load(NORM_CACHE);
        if let Some(v) = m.get(&key) {
            return *v;
        }
    }
    let p = readable(&path, &cache_dir);
    let dur = decode::probe(Path::new(&p)).map(|x| x.duration).unwrap_or(0.0);
    let start = if dur > 60.0 { (dur - 60.0) / 2.0 } else { 0.0 };
    let g = decode::planar(Path::new(&p), Some(start), Some(60.0))
        .and_then(|(rate, ch)| dsp::integrated_lufs(rate, &ch))
        .map(|lufs| ((-18.0 - lufs).clamp(-20.0, 12.0)) as f32)
        .unwrap_or(0.0);
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, f32> = store::load(NORM_CACHE);
    if m.len() > 4000 {
        m.clear();
    }
    m.insert(key, g);
    store::save(NORM_CACHE, &m);
    g
}

/// True when the file decodes as audio for at least `min_secs` (corrupt /
/// truncated / non-audio files fail).
#[uniffi::export]
pub fn is_valid_audio(path: String, cache_dir: String, min_secs: f64) -> bool {
    let p = readable(&path, &cache_dir);
    decode::mono_pcm(Path::new(&p), 8000, Some(0.0), Some(min_secs.max(0.1))).is_some_and(|s| s.len() as f64 >= 8000.0 * min_secs.max(0.1) * 0.9)
}

// ---- cached per-file results (path|mtime|size keys, like the Swift caches) ------------------

pub(crate) fn cached_f64(ns: &str, path: &str) -> Option<f64> {
    let m: HashMap<String, f64> = store::load(ns);
    m.get(&cache_key(path)).copied()
}

pub(crate) fn put_f64(ns: &str, path: &str, v: f64) {
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, f64> = store::load(ns);
    if m.len() > 5000 {
        m.clear();
    }
    m.insert(cache_key(path), v);
    store::save(ns, &m);
}

/// One-time import of a Swift-era `[String: Double]` cache file into `ns`.
#[uniffi::export]
pub fn analysis_import_legacy(namespace: String, json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(&namespace) {
        return;
    }
    let m: HashMap<String, f64> = serde_json::from_slice(&json).unwrap_or_default();
    store::save(&namespace, &m);
}

// ---- beat grid ----------------------------------------------------------------------------------

const BEAT_CACHE: &str = "beat_grid";

/// Onset times (seconds) quantised to the dominant pulse; empty = none found.
pub fn beat_grid_from(s: &[i16], sr: f64) -> Vec<f64> {
    if s.len() < (sr as usize) * 2 {
        return vec![];
    }
    let hop = ((sr as usize) / 100).max(1);
    let (bands, win) = (8usize, hop * 2);
    let bw = win / bands;
    let mut frames: Vec<[f64; 8]> = Vec::with_capacity(s.len() / hop);
    let mut off = 0;
    while off + win <= s.len() {
        let mut e = [0f64; 8];
        if bw > 0 {
            for (b, eb) in e.iter_mut().enumerate() {
                let start = off + b * bw;
                let end = (off + win).min(start + bw);
                if start < end {
                    *eb = s[start..end].iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / (end - start) as f64;
                }
            }
        }
        frames.push(e);
        off += hop;
    }
    if frames.len() <= 20 {
        return vec![];
    }
    let mut flux = vec![0f64; frames.len()];
    for i in 1..frames.len() {
        flux[i] = (0..bands).map(|b| (frames[i][b] - frames[i - 1][b]).max(0.0)).sum();
    }
    let (half, min_gap) = (50usize, 15i64);
    let fd = hop as f64 / sr;
    let mut onsets = Vec::new();
    let mut last = -min_gap;
    let mut scratch = Vec::with_capacity(half * 2);
    for i in 0..flux.len() {
        let (lo, hi) = (i.saturating_sub(half), (i + half).min(flux.len()));
        scratch.clear();
        scratch.extend_from_slice(&flux[lo..hi]);
        let k = (hi - lo) / 2;
        let med = *scratch.select_nth_unstable_by(k, |a, b| a.partial_cmp(b).unwrap()).1;
        if flux[i] <= med * 1.8 + 0.0001 || (i as i64) - last < min_gap {
            continue;
        }
        let (pl, ph) = (i.saturating_sub(2), (i + 3).min(flux.len()));
        if flux[i] != flux[pl..ph].iter().cloned().fold(f64::MIN, f64::max) {
            continue;
        }
        onsets.push(i as f64 * fd);
        last = i as i64;
    }
    quantize_to_pulse(onsets)
}

fn quantize_to_pulse(onsets: Vec<f64>) -> Vec<f64> {
    const TOL: f64 = 0.15;
    let Some(&lastt) = onsets.last() else { return onsets };
    if onsets.len() < 8 || lastt <= 0.0 {
        return onsets;
    }
    let grid = 100.0;
    let slots = (lastt * grid) as usize + 1;
    if slots <= 8 {
        return onsets;
    }
    let mut env = vec![0f64; slots];
    for o in &onsets {
        env[((o * grid) as usize).min(slots - 1)] = 1.0;
    }
    let min_lag = ((grid * 60.0 / 190.0) as usize).max(1);
    let max_lag = ((grid * 60.0 / 70.0) as usize).min(slots - 1);
    if max_lag <= min_lag {
        return onsets;
    }
    let (mut best_lag, mut best) = (min_lag, -1.0);
    for lag in min_lag..=max_lag {
        let score: f64 = (0..slots - lag).map(|i| env[i] * env[i + lag]).sum();
        if score > best {
            best = score;
            best_lag = lag;
        }
    }
    if best <= 0.0 {
        return onsets;
    }
    let period = best_lag as f64 / grid;
    let near = |o: f64, c: f64| {
        let d = ((o / period) % 1.0 - c).abs();
        d.min(1.0 - d) < TOL
    };
    let (mut phase, mut hits) = (0.0, -1i64);
    for step in 0..50 {
        let c = step as f64 / 50.0;
        let h = onsets.iter().filter(|o| near(**o, c)).count() as i64;
        if h > hits {
            hits = h;
            phase = c;
        }
    }
    let kept: Vec<f64> = onsets.iter().cloned().filter(|o| near(*o, phase)).collect();
    if kept.len() >= 4.max(onsets.len() / 8) { kept } else { onsets }
}

/// Beat grid for the first 12 minutes, cached per file.
#[uniffi::export]
pub fn beat_grid(path: String, cache_dir: String, pcm: Option<Vec<i16>>) -> Vec<f64> {
    {
        let m: HashMap<String, Vec<f64>> = store::load(BEAT_CACHE);
        if let Some(v) = m.get(&cache_key(&path)) {
            return v.clone();
        }
    }
    let v = pcm.or_else(|| decode_mono(path.clone(), cache_dir, 11025, 0.0, 720.0)).map(|s| beat_grid_from(&s, 11025.0)).unwrap_or_default();
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, Vec<f64>> = store::load(BEAT_CACHE);
    if m.len() > 1500 {
        m.clear();
    }
    m.insert(cache_key(&path), v.clone());
    store::save(BEAT_CACHE, &m);
    v
}

#[uniffi::export]
pub fn beat_grid_cached(path: String) -> Option<Vec<f64>> {
    let m: HashMap<String, Vec<f64>> = store::load(BEAT_CACHE);
    m.get(&cache_key(&path)).cloned()
}

#[uniffi::export]
pub fn beat_grid_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(BEAT_CACHE) {
        return;
    }
    let m: HashMap<String, Vec<f64>> = serde_json::from_slice(&json).unwrap_or_default();
    store::save(BEAT_CACHE, &m);
}

#[cfg(test)]
mod beat_tests {
    #[test]
    fn finds_a_steady_pulse() {
        let sr = 11025usize;
        let mut s = vec![0i16; sr * 8];
        // Clicks every 0.5 s (120 BPM).
        for k in 0..16 {
            let at = k * sr / 2;
            for i in 0..200 {
                s[at + i] = (((i as f64) * 0.9).sin() * 20000.0) as i16;
            }
        }
        let g = super::beat_grid_from(&s, sr as f64);
        assert!(g.len() >= 12, "{g:?}");
        let gaps: Vec<f64> = g.windows(2).map(|w| w[1] - w[0]).collect();
        assert!(gaps.iter().all(|d| (d - 0.5).abs() < 0.05), "{gaps:?}");
    }
}

// ---- hum-to-search pitch contours ----------------------------------------------------------------

const PITCH_CACHE: &str = "pitch_contour";

fn acf_pitch(s: &[i16], start: usize, n: usize, sr: f64) -> Option<f32> {
    let (min_lag, max_lag) = ((sr / 1000.0) as usize, (sr / 80.0) as usize);
    if min_lag < 1 || max_lag >= n {
        return None;
    }
    let w: Vec<f64> = s[start..start + n].iter().map(|v| *v as f64).collect();
    let mean = w.iter().sum::<f64>() / n as f64;
    let w: Vec<f64> = w.iter().map(|v| v - mean).collect();
    let energy: f64 = w.iter().map(|v| v * v).sum();
    if energy <= 1_000_000.0 {
        return None;
    }
    let (mut best_lag, mut best) = (0usize, 0.0f64);
    for lag in min_lag..=max_lag {
        let sum: f64 = (0..n - lag).map(|k| w[k] * w[k + lag]).sum();
        if sum > best {
            best = sum;
            best_lag = lag;
        }
    }
    (best_lag > 0 && best / energy > 0.3).then(|| (sr / best_lag as f64) as f32)
}

/// Semitone contour (relative to the median F0) from 128 ms ACF windows.
pub fn contour_from(s: &[i16], sr: f64) -> Option<Vec<f32>> {
    let (n, hop) = (1024usize, 512usize);
    if s.len() < n {
        return None;
    }
    let mut f0 = Vec::new();
    let mut i = 0;
    while i + n <= s.len() {
        if let Some(f) = acf_pitch(s, i, n, sr) {
            f0.push(f);
        }
        i += hop;
    }
    if f0.len() < 8 {
        return None;
    }
    let mut sorted = f0.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let med = sorted[sorted.len() / 2];
    (med > 0.0).then(|| f0.iter().map(|f| 12.0 * (f / med).log2()).collect())
}

/// Contour of the first `max_secs` (8 kHz). Library tracks are cached;
/// pass `cache = false` for one-off recordings (the hum itself).
#[uniffi::export]
pub fn pitch_contour(path: String, cache_dir: String, pcm: Option<Vec<i16>>, max_secs: f64, cache: bool) -> Option<Vec<f32>> {
    if cache {
        let m: HashMap<String, Vec<f32>> = store::load(PITCH_CACHE);
        if let Some(v) = m.get(&cache_key(&path)) {
            return Some(v.clone());
        }
    }
    let s = pcm.or_else(|| decode_mono(path.clone(), cache_dir, 8000, 0.0, max_secs))?;
    let c = contour_from(&s, 8000.0)?;
    if cache {
        let _g = LOCK.lock().unwrap();
        let mut m: HashMap<String, Vec<f32>> = store::load(PITCH_CACHE);
        if m.len() > 5000 {
            m.clear();
        }
        m.insert(cache_key(&path), c.clone());
        store::save(PITCH_CACHE, &m);
    }
    Some(c)
}

#[uniffi::export]
pub fn pitch_contour_cached(path: String) -> Option<Vec<f32>> {
    let m: HashMap<String, Vec<f32>> = store::load(PITCH_CACHE);
    m.get(&cache_key(&path)).cloned()
}

#[uniffi::export]
pub fn pitch_contour_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(PITCH_CACHE) {
        return;
    }
    let m: HashMap<String, Vec<f32>> = serde_json::from_slice(&json).unwrap_or_default();
    store::save(PITCH_CACHE, &m);
}

/// Best Pearson correlation of the query against any window of the
/// candidate (stride 4 frames), floored at 0.
#[uniffi::export]
pub fn pitch_match_score(query: Vec<f32>, candidate: Vec<f32>) -> f32 {
    if query.len() < 4 || candidate.len() < query.len() {
        return 0.0;
    }
    let qm = query.iter().sum::<f32>() / query.len() as f32;
    let qn: Vec<f32> = query.iter().map(|q| q - qm).collect();
    let qnorm = qn.iter().map(|q| q * q).sum::<f32>().sqrt();
    if qnorm <= 0.0 {
        return 0.0;
    }
    let mut best = 0f32;
    let mut off = 0;
    while off + query.len() <= candidate.len() {
        let sl = &candidate[off..off + query.len()];
        let sm = sl.iter().sum::<f32>() / sl.len() as f32;
        let (mut dot, mut ss) = (0f32, 0f32);
        for (q, c) in qn.iter().zip(sl) {
            let cn = c - sm;
            dot += q * cn;
            ss += cn * cn;
        }
        let sn = ss.sqrt();
        if sn > 0.0 {
            best = best.max(dot / (qnorm * sn));
        }
        off += 4;
    }
    best.max(0.0)
}

// ---- acoustic fingerprint (duplicate finder) ------------------------------------------------------

const FP_CACHE: &str = "audio_fingerprint";
const FP_FFT: usize = 2048;
const FP_BANDS: usize = 48;
const FP_SEGMENTS: usize = 18;

/// 18 segment vectors of 48 log-magnitude bands (quadratic band spacing),
/// each L2-normalised — the same profile the Swift/vDSP version produced.
pub fn fingerprint_from(s: &[i16]) -> Option<Vec<Vec<f32>>> {
    if s.len() < FP_FFT {
        return None;
    }
    let total = s.len() / FP_FFT;
    if total < FP_SEGMENTS {
        return None;
    }
    let half = FP_FFT / 2;
    let fft = rustfft::FftPlanner::<f32>::new().plan_fft_forward(FP_FFT);
    let mut acc = vec![vec![0f32; FP_BANDS]; FP_SEGMENTS];
    let mut counts = vec![0usize; FP_SEGMENTS];
    let mut buf = vec![rustfft::num_complex::Complex32::new(0.0, 0.0); FP_FFT];
    let ranges: Vec<(usize, usize)> = (0..FP_BANDS)
        .map(|b| {
            let lo = (((b as f64 / FP_BANDS as f64).powi(2) * half as f64) as usize).max(1);
            let hi = ((((b + 1) as f64 / FP_BANDS as f64).powi(2) * half as f64) as usize).min(half).max(lo + 1);
            (lo, hi)
        })
        .collect();
    for w in 0..total {
        let off = w * FP_FFT;
        for (i, c) in buf.iter_mut().enumerate() {
            *c = rustfft::num_complex::Complex32::new(s[off + i] as f32 / 32768.0, 0.0);
        }
        fft.process(&mut buf);
        let seg = (FP_SEGMENTS - 1).min(w * FP_SEGMENTS / total);
        for (b, (lo, hi)) in ranges.iter().enumerate() {
            if lo >= hi {
                continue;
            }
            let sum: f32 = buf[*lo..*hi].iter().map(|c| (c.norm_sqr() + 1.0).log10()).sum();
            acc[seg][b] += sum / (hi - lo) as f32;
        }
        counts[seg] += 1;
    }
    if counts.iter().any(|c| *c == 0) {
        return None;
    }
    acc.into_iter()
        .zip(counts)
        .map(|(v, n)| {
            let v: Vec<f32> = v.iter().map(|x| x / n as f32).collect();
            let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
            (norm > 0.0).then(|| v.iter().map(|x| x / norm).collect())
        })
        .collect()
}

/// Fingerprint of 45 s after an 8 s skip (when the track is long enough).
#[uniffi::export]
pub fn audio_fingerprint(path: String, cache_dir: String, pcm: Option<Vec<i16>>) -> Option<Vec<Vec<f32>>> {
    {
        let m: HashMap<String, Vec<Vec<f32>>> = store::load(FP_CACHE);
        if let Some(v) = m.get(&cache_key(&path)) {
            return Some(v.clone());
        }
    }
    let s = match pcm {
        Some(p) => p,
        None => {
            let dur = probe_duration(path.clone(), cache_dir.clone());
            let start = if dur > 13.0 { 8.0 } else { 0.0 };
            decode_mono(path.clone(), cache_dir, 11025, start, 45.0)?
        }
    };
    let v = fingerprint_from(&s)?;
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, Vec<Vec<f32>>> = store::load(FP_CACHE);
    if m.len() > 8000 {
        m.clear();
    }
    m.insert(cache_key(&path), v.clone());
    store::save(FP_CACHE, &m);
    Some(v)
}

#[uniffi::export]
pub fn audio_fingerprint_import_legacy(json: Vec<u8>) {
    let _g = LOCK.lock().unwrap();
    if store::exists(FP_CACHE) {
        return;
    }
    let m: HashMap<String, Vec<Vec<f32>>> = serde_json::from_slice(&json).unwrap_or_default();
    store::save(FP_CACHE, &m);
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let (mut d, mut ma, mut mb) = (0f32, 0f32, 0f32);
    for (x, y) in a.iter().zip(b) {
        d += x * y;
        ma += x * x;
        mb += y * y;
    }
    if ma <= 0.0 || mb <= 0.0 { 0.0 } else { d / (ma.sqrt() * mb.sqrt()) }
}

/// Best mean segment similarity over alignments of ±4 segments, requiring
/// ≥88% of overlapping segments to match at ≥0.985.
#[uniffi::export]
pub fn fingerprint_similarity(a: Vec<Vec<f32>>, b: Vec<Vec<f32>>) -> f32 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let mut best = 0f32;
    for shift in -4i64..=4 {
        let (a0, b0) = ((-shift).max(0) as usize, shift.max(0) as usize);
        if a0 >= a.len() || b0 >= b.len() {
            continue;
        }
        let overlap = (a.len() - a0).min(b.len() - b0);
        let (mut total, mut matching) = (0f32, 0usize);
        for i in 0..overlap {
            let s = cosine(&a[a0 + i], &b[b0 + i]);
            total += s;
            if s >= 0.985 {
                matching += 1;
            }
        }
        let need = (overlap as f32 * 0.88).ceil() as usize;
        if matching >= need {
            best = best.max(total / overlap as f32);
        }
    }
    best
}

// ---- live spectrum (visualizer) --------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug)]
pub struct Spectrum {
    /// Bar heights 0…1 (quadratic bin spacing).
    pub bars: Vec<f32>,
    pub bass: f32,
    pub mid: f32,
    pub treble: f32,
    pub overall: f32,
}

/// FFT of up to `fft_size` samples into `bar_count` log-scaled bars plus
/// bass (20–250 Hz) / mid (250 Hz–4 kHz) / treble (4–16 kHz) / overall.
#[uniffi::export]
pub fn spectrum(samples: Vec<f32>, sample_rate: f32, fft_size: u32, bar_count: u32) -> Spectrum {
    let n = fft_size.max(64) as usize;
    let half = n / 2;
    let mut buf: Vec<rustfft::num_complex::Complex32> = (0..n).map(|i| rustfft::num_complex::Complex32::new(samples.get(i).copied().unwrap_or(0.0), 0.0)).collect();
    rustfft::FftPlanner::<f32>::new().plan_fft_forward(n).process(&mut buf);
    let mag: Vec<f32> = buf[..half].iter().map(|c| c.norm_sqr()).collect();
    let norm = |v: f32| ((v + 1.0).log10() / 4.0).clamp(0.0, 1.0);
    let bc = bar_count.max(1) as usize;
    let bars = (0..bc)
        .map(|b| {
            let lo = (((b as f64 / bc as f64).powi(2) * half as f64) as usize).max(1);
            let hi = ((((b + 1) as f64 / bc as f64).powi(2) * half as f64) as usize).min(half).max(lo + 1);
            if lo >= hi || hi > half {
                return 0.0;
            }
            norm(mag[lo..hi].iter().sum::<f32>() / (hi - lo) as f32)
        })
        .collect();
    let sr = if sample_rate > 0.0 { sample_rate } else { 44_100.0 };
    let bin_hz = sr / n as f32;
    let band = |lo_hz: f32, hi_hz: f32| {
        let lo = ((lo_hz / bin_hz) as usize).max(1);
        let hi = ((hi_hz / bin_hz) as usize).min(half).max(lo + 1);
        if lo >= hi || hi > half { 0.0 } else { mag[lo..hi].iter().sum::<f32>() / (hi - lo) as f32 }
    };
    Spectrum {
        bars,
        bass: norm(band(20.0, 250.0)),
        mid: norm(band(250.0, 4000.0)),
        treble: norm(band(4000.0, (sr / 2.0).min(16_000.0))),
        overall: norm(mag.iter().sum::<f32>() / half.max(1) as f32),
    }
}

// ---- integrity check ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum AudioValidation {
    Valid,
    TooSmall,
    Unreadable { reason: String },
    Truncated { actual: f64, expected: f64 },
    /// The core can't decode this container (e.g. Opus) — ask AVFoundation.
    Unsupported,
}

/// Readable header, a decodable tail, and (when `expected_duration` is
/// given) no more than max(10 s, 15%) shorter than expected.
#[uniffi::export]
pub fn validate_audio(path: String, cache_dir: String, expected_duration: Option<f64>) -> AudioValidation {
    let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    if size == 0 && !Path::new(&path).exists() {
        return AudioValidation::Unreadable { reason: "could not read file attributes".into() };
    }
    if size < 1024 {
        return AudioValidation::TooSmall;
    }
    let p = readable(&path, &cache_dir);
    let Some(info) = decode::probe(Path::new(&p)) else { return AudioValidation::Unsupported };
    if info.duration <= 0.0 {
        // No frame count in the header (some MP3s): decode a little instead.
        return match decode::mono_pcm(Path::new(&p), 8000, None, Some(1.0)) {
            Some(_) => AudioValidation::Valid,
            None => AudioValidation::Unreadable { reason: "no decodable audio".into() },
        };
    }
    let tail_start = (info.duration - 0.6).max(0.0);
    if decode::mono_pcm(Path::new(&p), 8000, Some(tail_start), Some(0.5)).is_none() {
        return AudioValidation::Unreadable { reason: "tail read produced no audio frames".into() };
    }
    if let Some(exp) = expected_duration.filter(|e| *e > 0.0) {
        let tol = (exp * 0.15).max(10.0);
        if info.duration < exp - tol {
            return AudioValidation::Truncated { actual: info.duration, expected: exp };
        }
    }
    AudioValidation::Valid
}
