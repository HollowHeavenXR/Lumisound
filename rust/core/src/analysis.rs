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

fn cache_key(path: &str) -> String {
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
