//! Music Haptics: a tactile score for a track, built from a full-track
//! analysis, and a scheduler that plays it in step with what the listener
//! hears.
//!
//! Analysis (mono, 22.05 kHz) splits the signal into three bands and finds
//! onsets in each with a threshold that adapts to the track:
//!
//! - low  (< 150 Hz: kick, bass)        → deep, soft thump  (low sharpness)
//! - mid  (180 Hz – 1.8 kHz: snare, toms) → firm tap
//! - high (> 3.5 kHz: hats, claps, crack) → light, crisp tick (high sharpness)
//!
//! Hits that land together merge into one event (kick + clap feels like one
//! hit with both characters). Sustained bass (808s, bass drops) becomes a
//! continuous rumble that follows the bass envelope. Every event is scaled
//! by the local loudness of the mix, so breakdowns feel softer than drops,
//! and the density is capped so busy hi-hat patterns never turn into buzz.
//!
//! Swift only turns scheduled cues into Core Haptics events
//! (MusicHapticsService.swift).

use crate::analysis::cache_key;
use lumisound_media::decode;
use std::path::Path;
use std::sync::{Arc, Mutex};

/// Analysis sample rate.
pub const RATE: u32 = 22_050;
/// Envelope hop: 5 ms.
const HOP: usize = 110;
const HOP_SECS: f64 = HOP as f64 / RATE as f64;
/// Continuous events carry an intensity envelope sampled at this step and
/// are at most this long (Core Haptics curves take 16 control points).
pub const ENVELOPE_STEP: f64 = 0.05;
const MAX_CONTINUOUS: f64 = 0.75;
/// Cache format version (bump when the analysis changes).
const CACHE_NS: &str = "haptics_v1";

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HapticEvent {
    /// Track time (seconds).
    pub time: f64,
    /// 0 for a transient; length of a continuous rumble.
    pub duration: f64,
    pub intensity: f32,
    pub sharpness: f32,
    pub continuous: bool,
    /// Continuous only: intensity multipliers every ENVELOPE_STEP seconds.
    pub envelope: Vec<f32>,
}

#[derive(uniffi::Record, Clone, Debug, Default, PartialEq)]
pub struct HapticStats {
    pub duration: f64,
    pub transients: u32,
    pub low_hits: u32,
    pub mid_hits: u32,
    pub high_hits: u32,
    pub continuous_secs: f64,
    /// Analysis time over track length (only set when freshly analysed).
    pub analysis_x_realtime: f64,
}

/// A track's haptic score (events sorted by time).
#[derive(uniffi::Object, Debug)]
pub struct HapticScore {
    events: Vec<HapticEvent>,
    stats: HapticStats,
}

#[uniffi::export]
impl HapticScore {
    pub fn stats(&self) -> HapticStats {
        self.stats.clone()
    }
    pub fn event_count(&self) -> u32 {
        self.events.len() as u32
    }
    /// Events starting in [from, to).
    pub fn events_between(&self, from: f64, to: f64) -> Vec<HapticEvent> {
        self.range(from, to).to_vec()
    }
}

impl HapticScore {
    pub fn events(&self) -> &[HapticEvent] {
        &self.events
    }
    /// A score from already-built events (the Haptics Brain's corrections).
    pub fn from_events(events: Vec<HapticEvent>, stats: HapticStats) -> Self {
        Self { events, stats }
    }
    fn range(&self, from: f64, to: f64) -> &[HapticEvent] {
        let a = self.events.partition_point(|e| e.time < from);
        let b = self.events.partition_point(|e| e.time < to);
        &self.events[a..b.max(a)]
    }
}

// ---- entry points ------------------------------------------------------------------------------

/// The haptic score for a file (`.lms` read in place), from the cache or
/// freshly analysed. `pcm` = mono i16 at RATE for files the core can't
/// decode (decoded by AVFoundation). None when nothing could be decoded.
#[uniffi::export]
pub fn haptic_score(path: String, pcm: Option<Vec<i16>>) -> Option<Arc<HapticScore>> {
    let key = cache_key(&path);
    if let Some(s) = crate::blobcache::blob_cache_get(CACHE_NS.into(), key.clone()).and_then(|b| decode_score(&b)) {
        return Some(Arc::new(s));
    }
    let t = std::time::Instant::now();
    let mut score = match pcm {
        Some(s) => analyze(&s, RATE as f64),
        None => analyze_file(Path::new(&path), CHUNK_SECS)?,
    };
    if score.stats.duration > 0.0 {
        score.stats.analysis_x_realtime = score.stats.duration / t.elapsed().as_secs_f64().max(1e-6);
    }
    crate::blobcache::blob_cache_put(CACHE_NS.into(), key, encode_score(&score));
    Some(Arc::new(score))
}

/// Long tracks (DJ mixes, hour-long sets) are analysed in chunks of this
/// many seconds, so memory stays ~40 MB whatever the length.
pub const CHUNK_SECS: f64 = 300.0;
/// Context decoded on each side of a chunk (thresholds and envelopes settle).
const CHUNK_PAD: f64 = 3.0;

/// Analyse a file in `chunk`-second pieces (one piece when it's shorter).
/// The file is decoded once, front to back; each piece is analysed with
/// CHUNK_PAD seconds of context on both sides and keeps only its own events.
pub fn analyze_file(path: &Path, chunk: f64) -> Option<HapticScore> {
    let total = decode::probe(path).map(|p| p.duration).unwrap_or(0.0);
    if total <= chunk * 1.5 {
        return decode::mono_pcm(path, RATE, None, None).map(|s| analyze(&s, RATE as f64));
    }
    let sr = RATE as usize;
    let (chunk_n, pad_n) = ((chunk * RATE as f64) as usize, (CHUNK_PAD * RATE as f64) as usize);
    let mut events = Vec::new();
    let mut stats = HapticStats::default();
    // `buf` holds samples from `buf_at`; the next piece starts at `start`.
    let mut buf: Vec<i16> = Vec::new();
    let (mut buf_at, mut start) = (0usize, 0usize);
    let piece = |buf: &[i16], buf_at: usize, start: usize, end: usize, events: &mut Vec<HapticEvent>, stats: &mut HapticStats| {
        let from = start.saturating_sub(pad_n);
        let to = (end + pad_n).min(buf_at + buf.len());
        let part = analyze(&buf[from - buf_at..to - buf_at], RATE as f64);
        let offset = from as f64 / sr as f64;
        let (s0, s1) = (start as f64 / sr as f64, end as f64 / sr as f64);
        for mut e in part.events {
            e.time += offset;
            if e.time >= s0 && e.time < s1 {
                if e.continuous {
                    stats.continuous_secs += e.duration;
                } else {
                    stats.transients += 1;
                }
                events.push(e);
            }
        }
        stats.low_hits += part.stats.low_hits;
        stats.mid_hits += part.stats.mid_hits;
        stats.high_hits += part.stats.high_hits;
    };
    let ok = decode::mono_pcm_blocks(path, RATE, sr * 10, |block| {
        buf.extend_from_slice(&block);
        while buf_at + buf.len() >= start + chunk_n + pad_n {
            piece(&buf, buf_at, start, start + chunk_n, &mut events, &mut stats);
            start += chunk_n;
            let keep_from = start.saturating_sub(pad_n);
            if keep_from > buf_at {
                buf.drain(..keep_from - buf_at);
                buf_at = keep_from;
            }
        }
        true
    });
    if !ok {
        return None;
    }
    let end = buf_at + buf.len();
    if end > start {
        piece(&buf, buf_at, start, end, &mut events, &mut stats);
    }
    stats.duration = end as f64 / sr as f64;
    Some(HapticScore { events, stats })
}

/// Cached score only (never decodes): instant, for the moment playback starts.
#[uniffi::export]
pub fn haptic_score_cached(path: String) -> Option<Arc<HapticScore>> {
    crate::blobcache::blob_cache_get(CACHE_NS.into(), cache_key(&path)).and_then(|b| decode_score(&b)).map(Arc::new)
}

// ---- analysis ----------------------------------------------------------------------------------

/// RBJ biquad (direct form I), f32.
#[derive(Clone, Copy)]
struct Biquad {
    b: [f32; 3],
    a: [f32; 2],
    x: [f32; 2],
    y: [f32; 2],
}

impl Biquad {
    fn new(kind: u8, f0: f64, q: f64, sr: f64) -> Self {
        let w = std::f64::consts::TAU * f0 / sr;
        let (s, c) = w.sin_cos();
        let alpha = s / (2.0 * q);
        let (b0, b1, b2) = match kind {
            0 => ((1.0 - c) / 2.0, 1.0 - c, (1.0 - c) / 2.0),    // low-pass
            _ => ((1.0 + c) / 2.0, -(1.0 + c), (1.0 + c) / 2.0), // high-pass
        };
        let a0 = 1.0 + alpha;
        Self { b: [(b0 / a0) as f32, (b1 / a0) as f32, (b2 / a0) as f32], a: [(-2.0 * c / a0) as f32, ((1.0 - alpha) / a0) as f32], x: [0.0; 2], y: [0.0; 2] }
    }
    #[inline]
    fn run(&mut self, v: f32) -> f32 {
        let y = self.b[0] * v + self.b[1] * self.x[0] + self.b[2] * self.x[1] - self.a[0] * self.y[0] - self.a[1] * self.y[1];
        self.x = [v, self.x[0]];
        self.y = [y, self.y[0]];
        y
    }
}

fn lp(f: f64, sr: f64) -> Biquad {
    Biquad::new(0, f, std::f64::consts::FRAC_1_SQRT_2, sr)
}
fn hp(f: f64, sr: f64) -> Biquad {
    Biquad::new(1, f, std::f64::consts::FRAC_1_SQRT_2, sr)
}

/// Filter chains per band (two cascaded stages = 4th order edges).
fn band_filters(sr: f64) -> [Vec<Biquad>; 3] {
    [
        vec![lp(150.0, sr), lp(150.0, sr), hp(30.0, sr)],
        vec![hp(180.0, sr), hp(180.0, sr), lp(1800.0, sr), lp(1800.0, sr)],
        vec![hp(3500.0, sr), hp(3500.0, sr)],
    ]
}

fn db(power: f64) -> f32 {
    (10.0 * (power + 1e-12).log10()) as f32
}

fn percentile(v: &[f32], p: f64) -> f32 {
    if v.is_empty() {
        return -120.0;
    }
    let mut s = v.to_vec();
    let k = ((s.len() - 1) as f64 * p.clamp(0.0, 1.0)).round() as usize;
    s.select_nth_unstable_by(k, |a, b| a.total_cmp(b));
    s[k]
}

/// Per-band level (dB per 5 ms hop) over `win` hops, plus the full-mix level.
fn envelopes(x: &[f32], sr: f64) -> ([Vec<f32>; 3], Vec<f32>) {
    let n = x.len() / HOP;
    let mut chains = band_filters(sr);
    let mut pow: [Vec<f64>; 3] = [vec![0.0; n], vec![0.0; n], vec![0.0; n]];
    let mut mix = vec![0.0f64; n];
    for (b, chain) in chains.iter_mut().enumerate() {
        for (i, v) in x[..n * HOP].iter().enumerate() {
            let mut y = *v;
            for f in chain.iter_mut() {
                y = f.run(y);
            }
            pow[b][i / HOP] += (y as f64) * (y as f64);
        }
    }
    for (i, v) in x[..n * HOP].iter().enumerate() {
        mix[i / HOP] += (*v as f64) * (*v as f64);
    }
    // Window lengths: low 20 ms (a 60 Hz cycle is 16 ms), others 10 ms, mix 50 ms.
    let smooth = |p: &[f64], w: usize| -> Vec<f32> {
        let mut out = Vec::with_capacity(p.len());
        let mut acc = 0.0;
        for i in 0..p.len() {
            acc += p[i];
            if i >= w {
                acc -= p[i - w];
            }
            let len = (i + 1).min(w) * HOP;
            out.push(db(acc.max(0.0) / len as f64));
        }
        out
    };
    ([smooth(&pow[0], 4), smooth(&pow[1], 2), smooth(&pow[2], 2)], smooth(&mix, 10))
}

/// Onset strength: rise (dB) over the recent maximum, `lag` hops back.
fn onset_function(e: &[f32], lag: usize) -> Vec<f32> {
    (0..e.len())
        .map(|i| {
            if i < lag + 2 {
                return 0.0;
            }
            let prev = e[i - lag - 2..=i - lag].iter().cloned().fold(f32::MIN, f32::max);
            (e[i] - prev).max(0.0)
        })
        .collect()
}

/// Running median of `v` over ±`half` hops, computed every `step` hops.
fn running_median(v: &[f32], half: usize, step: usize) -> Vec<f32> {
    let n = v.len();
    let mut grid = Vec::with_capacity(n / step + 2);
    let mut buf = Vec::with_capacity(2 * half + 1);
    let mut i = 0;
    while i < n + step {
        let c = i.min(n.saturating_sub(1));
        let (a, b) = (c.saturating_sub(half), (c + half + 1).min(n));
        buf.clear();
        buf.extend_from_slice(&v[a..b]);
        let k = buf.len() / 2;
        let m = if buf.is_empty() {
            0.0
        } else {
            *buf.select_nth_unstable_by(k, |x, y| x.total_cmp(y)).1
        };
        grid.push(m);
        i += step;
    }
    (0..n).map(|i| grid[i / step]).collect()
}

struct Onset {
    hop: usize,
    band: usize,
    /// 0..1 rank among this band's onsets.
    rank: f32,
}

#[derive(Clone, Copy)]
struct BandCfg {
    lag: usize,
    min_gap_hops: usize,
    /// Fixed part of the adaptive threshold (dB of rise).
    floor_db: f32,
}

const BANDS: [BandCfg; 3] = [
    BandCfg { lag: 4, min_gap_hops: 22, floor_db: 2.5 }, // low: 110 ms apart at most 9/s
    BandCfg { lag: 2, min_gap_hops: 18, floor_db: 2.5 }, // mid: 90 ms
    BandCfg { lag: 2, min_gap_hops: 15, floor_db: 3.5 }, // high: 75 ms
];

/// Adaptive threshold: local median + this share of the band's strong rises.
const SPREAD_K: f32 = 0.28;

/// (hop, strength, peak level dB) per onset.
fn pick_onsets(e: &[f32], odf: &[f32], band: usize, gate: &[bool], mix: &[f32]) -> Vec<(usize, f32, f32)> {
    let cfg = BANDS[band];
    let nonzero: Vec<f32> = odf.iter().cloned().filter(|v| *v > 0.5).collect();
    let spread = percentile(&nonzero, 0.9);
    let med = running_median(&odf, 100, 10); // ±0.5 s
    let level_floor = percentile(e, 0.5) - 6.0;
    let mut peaks: Vec<(usize, f32, f32)> = Vec::new();
    let w = 5; // local max within ±25 ms
    for i in w..odf.len().saturating_sub(w) {
        let v = odf[i];
        let thr = (med[i] + SPREAD_K * spread).max(cfg.floor_db);
        if v < thr || !gate[i] {
            continue;
        }
        if odf[i - w..=i + w].iter().any(|o| *o > v) {
            continue;
        }
        // The hit itself must reach a real level for this band (not a rise
        // out of the noise floor). Peak level within the next 30 ms.
        let peak = e[i..(i + 6).min(e.len())].iter().cloned().fold(f32::MIN, f32::max);
        // …and be a real part of what's heard: within 26 dB of the mix.
        let mix_peak = mix[i..(i + 10).min(mix.len())].iter().cloned().fold(f32::MIN, f32::max);
        if peak < level_floor || peak < mix_peak - 26.0 {
            continue;
        }
        let strength = v + 0.5 * (peak - level_floor).max(0.0);
        if let Some(last) = peaks.last_mut() {
            if i - last.0 < cfg.min_gap_hops {
                if strength > last.1 {
                    *last = (i, strength, peak);
                }
                continue;
            }
        }
        peaks.push((i, strength, peak));
    }
    peaks
}

fn rank(peaks: &[(usize, f32, f32)]) -> Vec<f32> {
    let mut idx: Vec<usize> = (0..peaks.len()).collect();
    idx.sort_by(|a, b| peaks[*a].1.total_cmp(&peaks[*b].1));
    let mut r = vec![0.0f32; peaks.len()];
    let n = (peaks.len().max(2) - 1) as f32;
    for (pos, i) in idx.into_iter().enumerate() {
        r[i] = pos as f32 / n;
    }
    r
}

/// Max transients per second (all bands) and hi-hat ticks per second.
const MAX_PER_SEC: usize = 12;
const MAX_HIGH_PER_SEC: usize = 6;

/// Thin `items` (time, priority) so no 1 s window holds more than `cap`,
/// dropping the lowest priority first. Returns kept flags.
fn thin(times: &[f64], prio: &[f32], cap: usize) -> Vec<bool> {
    let mut keep = vec![true; times.len()];
    let mut order: Vec<usize> = (0..times.len()).collect();
    order.sort_by(|a, b| prio[*b].total_cmp(&prio[*a]));
    // Greedy: accept strongest first while every window stays within cap.
    let mut accepted: Vec<f64> = Vec::new();
    for i in order {
        let t = times[i];
        let lo = accepted.partition_point(|x| *x < t - 1.0);
        let hi = accepted.partition_point(|x| *x <= t + 1.0);
        // Worst-case window containing t: count accepted within ±1 s, then
        // check every 1 s window through t.
        let near = &accepted[lo..hi];
        let mut ok = true;
        for &start in near.iter().chain(std::iter::once(&t)) {
            let ws = start.min(t);
            if t - ws > 1.0 {
                continue;
            }
            let we = ws + 1.0;
            let n = near.iter().filter(|x| **x >= ws && **x < we).count() + 1;
            if n > cap {
                ok = false;
                break;
            }
        }
        if ok {
            let at = accepted.partition_point(|x| *x < t);
            accepted.insert(at, t);
        } else {
            keep[i] = false;
        }
    }
    keep
}

/// Build the score from mono PCM.
pub fn analyze(pcm: &[i16], sr: f64) -> HapticScore {
    let duration = pcm.len() as f64 / sr;
    let x: Vec<f32> = pcm.iter().map(|v| *v as f32 / 32768.0).collect();
    let ([low, mid, high], mix) = envelopes(&x, sr);
    let n = mix.len();
    if n < 40 {
        return HapticScore { events: vec![], stats: HapticStats { duration, ..Default::default() } };
    }
    // Silence gate: nothing where the mix is far below the track's level.
    let mix_p50 = percentile(&mix, 0.5);
    let mix_p90 = percentile(&mix, 0.9);
    // Judged on the 50 ms right after each step (the level window trails, so
    // the step's own value still carries a sound that just ended).
    let gate_db = (mix_p50 - 30.0).max(-50.0);
    let gate: Vec<bool> = (0..n).map(|i| mix[(i + 10).min(n - 1)] > gate_db && mix[i.min(n - 1)].max(mix[(i + 5).min(n - 1)]) > gate_db - 6.0).collect();
    // Local dynamics (~1 s average of the mix level, in dB).
    let dynamics: Vec<f32> = {
        let w = 200usize;
        let mut acc = 0.0f64;
        let mut out = Vec::with_capacity(n);
        for i in 0..n {
            acc += mix[i] as f64;
            if i >= w {
                acc -= mix[i - w] as f64;
            }
            let avg = acc / (i + 1).min(w) as f64;
            out.push((((avg as f32 - mix_p90) / 18.0) + 1.0).clamp(0.35, 1.0));
        }
        out
    };

    let bands = [&low, &mid, &high];
    let mut onsets: Vec<Onset> = Vec::new();
    let mut counts = [0u32; 3];
    let odfs: Vec<Vec<f32>> = bands.iter().enumerate().map(|(b, e)| onset_function(e, BANDS[b].lag)).collect();
    let mut picked: Vec<Vec<(usize, f32, f32)>> = bands.iter().enumerate().map(|(b, e)| pick_onsets(e, &odfs[b], b, &gate, &mix)).collect();
    // Leakage: a hit that another band also rises with at the same moment
    // (±15 ms) while being more than 12 dB louder belongs to that band (a
    // hat's attack in the mids, a kick's click in the mids): dropped here.
    for (b, peaks) in picked.iter_mut().enumerate() {
        peaks.retain(|&(hop, _, level)| {
            !(0..3).any(|ob| {
                if ob == b {
                    return false;
                }
                let (a, z) = (hop.saturating_sub(3), (hop + 4).min(n));
                let rose = odfs[ob][a..z].iter().any(|v| *v >= 3.0);
                let louder = bands[ob][hop..(hop + 6).min(n)].iter().any(|v| *v > level + 12.0);
                rose && louder
            })
        });
    }
    for (b, peaks) in picked.into_iter().enumerate() {
        let ranks = rank(&peaks);
        // Hi-hats: keep the strongest few per second.
        let keep = if b == 2 {
            let t: Vec<f64> = peaks.iter().map(|p| p.0 as f64 * HOP_SECS).collect();
            thin(&t, &ranks, MAX_HIGH_PER_SEC)
        } else {
            vec![true; peaks.len()]
        };
        for (i, p) in peaks.iter().enumerate() {
            if keep[i] {
                onsets.push(Onset { hop: p.0, band: b, rank: ranks[i] });
                counts[b] += 1;
            }
        }
    }
    onsets.sort_by_key(|o| o.hop);

    // Merge hits within 30 ms into one event.
    struct Hit {
        hop: usize,
        intensity: f32,
        sharpness: f32,
    }
    let feel = |o: &Onset| -> (f32, f32) {
        let r = o.rank;
        match o.band {
            0 => (0.45 + 0.55 * r, 0.18 + 0.15 * r),
            1 => (0.35 + 0.45 * r, 0.5 + 0.1 * r),
            _ => (0.2 + 0.3 * r, 0.82 + 0.15 * r),
        }
    };
    let mut hits: Vec<Hit> = Vec::new();
    let mut group: Vec<(f32, f32)> = Vec::new();
    let mut group_hop = 0usize;
    let flush = |group: &mut Vec<(f32, f32)>, hop: usize, hits: &mut Vec<Hit>| {
        if group.is_empty() {
            return;
        }
        group.sort_by(|a, b| b.0.total_cmp(&a.0));
        let main = group[0].0;
        let extra: f32 = group[1..].iter().map(|g| g.0 * 0.15).sum();
        let wsum: f32 = group.iter().map(|g| g.0).sum();
        let sharp = group.iter().map(|g| g.0 * g.1).sum::<f32>() / wsum.max(1e-6);
        let dynv = dynamics[hop.min(dynamics.len() - 1)];
        hits.push(Hit { hop, intensity: ((main + extra).min(1.0) * dynv).clamp(0.08, 1.0), sharpness: sharp.clamp(0.0, 1.0) });
        group.clear();
    };
    for o in &onsets {
        if !group.is_empty() && o.hop - group_hop > 6 {
            flush(&mut group, group_hop, &mut hits);
        }
        if group.is_empty() {
            group_hop = o.hop;
        }
        group.push(feel(o));
    }
    flush(&mut group, group_hop, &mut hits);

    // Overall density cap.
    let times: Vec<f64> = hits.iter().map(|h| h.hop as f64 * HOP_SECS).collect();
    let prio: Vec<f32> = hits.iter().map(|h| h.intensity).collect();
    let keep = thin(&times, &prio, MAX_PER_SEC);
    let mut events: Vec<HapticEvent> = hits
        .iter()
        .zip(keep)
        .filter(|(_, k)| *k)
        .map(|(h, _)| HapticEvent { time: h.hop as f64 * HOP_SECS, duration: 0.0, intensity: h.intensity, sharpness: h.sharpness, continuous: false, envelope: vec![] })
        .collect();
    let transients = events.len() as u32;

    // Sustained bass → continuous rumble following the bass envelope.
    let low_p50 = percentile(&low, 0.5);
    let low_p70 = percentile(&low, 0.7);
    let low_p98 = percentile(&low, 0.98);
    let span = (low_p98 - low_p50).max(3.0);
    let sustained: Vec<bool> = (0..n).map(|i| gate[i] && low[i] >= low_p70 && low[i] >= mid[i] - 3.0).collect();
    let mut continuous_secs = 0.0;
    let mut i = 0;
    while i < n {
        if !sustained[i] {
            i += 1;
            continue;
        }
        // Run with gaps under 60 ms bridged.
        let start = i;
        let mut end = i;
        let mut gap = 0;
        while i < n {
            if sustained[i] {
                end = i;
                gap = 0;
            } else {
                gap += 1;
                if gap > 12 {
                    break;
                }
            }
            i += 1;
        }
        let len = (end - start + 1) as f64 * HOP_SECS;
        if len < 0.25 {
            continue;
        }
        continuous_secs += len;
        let step_hops = (ENVELOPE_STEP / HOP_SECS).round() as usize;
        let mut t0 = start;
        while t0 <= end {
            let piece_end = (t0 + (MAX_CONTINUOUS / HOP_SECS) as usize).min(end + 1);
            let env: Vec<f32> = (t0..piece_end).step_by(step_hops).map(|h| ((low[h] - low_p50) / span).clamp(0.15, 1.0)).collect();
            let dynv = dynamics[t0];
            events.push(HapticEvent {
                time: t0 as f64 * HOP_SECS,
                duration: (piece_end - t0) as f64 * HOP_SECS,
                intensity: (0.38 * dynv).clamp(0.1, 0.4),
                sharpness: 0.08,
                continuous: true,
                envelope: env,
            });
            t0 = piece_end;
        }
    }
    events.sort_by(|a, b| a.time.total_cmp(&b.time));
    let stats = HapticStats { duration, transients, low_hits: counts[0], mid_hits: counts[1], high_hits: counts[2], continuous_secs, analysis_x_realtime: 0.0 };
    HapticScore { events, stats }
}

// ---- cache encoding ----------------------------------------------------------------------------

const MAGIC: &[u8; 4] = b"LHS1";

fn encode_score(s: &HapticScore) -> Vec<u8> {
    let mut b = Vec::with_capacity(16 + s.events.len() * 12);
    b.extend_from_slice(MAGIC);
    b.extend_from_slice(&(s.stats.duration as f32).to_le_bytes());
    for v in [s.stats.low_hits, s.stats.mid_hits, s.stats.high_hits] {
        b.extend_from_slice(&v.to_le_bytes());
    }
    b.extend_from_slice(&(s.events.len() as u32).to_le_bytes());
    for e in &s.events {
        b.extend_from_slice(&(e.time as f32).to_le_bytes());
        b.extend_from_slice(&(e.duration as f32).to_le_bytes());
        b.push((e.intensity.clamp(0.0, 1.0) * 255.0).round() as u8);
        b.push((e.sharpness.clamp(0.0, 1.0) * 255.0).round() as u8);
        b.push(e.continuous as u8);
        b.push(e.envelope.len().min(255) as u8);
        b.extend(e.envelope.iter().take(255).map(|v| (v.clamp(0.0, 1.0) * 255.0).round() as u8));
    }
    b
}

fn decode_score(b: &[u8]) -> Option<HapticScore> {
    if b.len() < 24 || &b[..4] != MAGIC {
        return None;
    }
    let f32_at = |i: usize| -> Option<f32> { Some(f32::from_le_bytes(b.get(i..i + 4)?.try_into().ok()?)) };
    let u32_at = |i: usize| -> Option<u32> { Some(u32::from_le_bytes(b.get(i..i + 4)?.try_into().ok()?)) };
    let duration = f32_at(4)? as f64;
    let (low_hits, mid_hits, high_hits) = (u32_at(8)?, u32_at(12)?, u32_at(16)?);
    let n = u32_at(20)? as usize;
    let mut events = Vec::with_capacity(n.min(1 << 20));
    let mut p = 24;
    let mut transients = 0;
    let mut continuous_secs = 0.0;
    for _ in 0..n {
        let time = f32_at(p)? as f64;
        let dur = f32_at(p + 4)? as f64;
        let head = b.get(p + 8..p + 12)?;
        let env_len = head[3] as usize;
        let env = b.get(p + 12..p + 12 + env_len)?.iter().map(|v| *v as f32 / 255.0).collect();
        p += 12 + env_len;
        let continuous = head[2] != 0;
        if continuous {
            continuous_secs += dur;
        } else {
            transients += 1;
        }
        events.push(HapticEvent { time, duration: dur, intensity: head[0] as f32 / 255.0, sharpness: head[1] as f32 / 255.0, continuous, envelope: env });
    }
    Some(HapticScore { events, stats: HapticStats { duration, transients, low_hits, mid_hits, high_hits, continuous_secs, analysis_x_realtime: 0.0 } })
}

// ---- scheduling --------------------------------------------------------------------------------

/// A score event, timed relative to "now" for Core Haptics.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HapticCue {
    /// Seconds from now.
    pub at: f64,
    pub duration: f64,
    pub intensity: f32,
    pub sharpness: f32,
    pub continuous: bool,
    pub envelope: Vec<f32>,
    /// Seconds between envelope points (already scaled by playback speed).
    pub envelope_step: f64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HapticBatch {
    /// The listener jumped (seek, skip back, track restart): cancel cues
    /// already handed to Core Haptics before playing these.
    pub reset: bool,
    pub cues: Vec<HapticCue>,
}

#[derive(Default)]
struct Cursor {
    /// Track time scheduled up to.
    until: Option<f64>,
    last_heard: Option<f64>,
}

/// Plays a score in step with playback: call `next` a few times a second
/// with the engine position; it returns the cues for the next stretch.
#[derive(uniffi::Object)]
pub struct HapticScheduler {
    score: Arc<HapticScore>,
    cursor: Mutex<Cursor>,
}

#[uniffi::export]
impl HapticScheduler {
    #[uniffi::constructor]
    pub fn new(score: Arc<HapticScore>) -> Arc<Self> {
        Arc::new(Self { score, cursor: Mutex::new(Cursor::default()) })
    }

    /// `position`: track time the engine has rendered up to. `output_latency`:
    /// seconds from render to the listener's ears (device buffer + route,
    /// e.g. ~0.3 s on Bluetooth). `speed`: playback rate. `lookahead`:
    /// seconds of cues to hand over. `strength`: 0.3–1.5 user scale.
    pub fn next(&self, position: f64, output_latency: f64, speed: f64, lookahead: f64, strength: f32) -> HapticBatch {
        let speed = if speed.is_finite() && speed > 0.05 { speed } else { 1.0 };
        let heard = position - output_latency.max(0.0) * speed;
        let mut c = self.cursor.lock().unwrap();
        let mut reset = false;
        if let Some(last) = c.last_heard {
            // Backwards, or forward much faster than playback: a jump.
            if heard < last - 0.15 || heard > last + 2.0 {
                reset = true;
                c.until = None;
            }
        }
        c.last_heard = Some(heard);
        let from = c.until.map_or(heard, |u| u.max(heard));
        let to = heard + lookahead.max(0.05) * speed;
        if to <= from {
            return HapticBatch { reset, cues: vec![] };
        }
        c.until = Some(to);
        let scale = strength.clamp(0.0, 2.0);
        let cues = self
            .score
            .range(from, to)
            .iter()
            .map(|e| HapticCue {
                at: (e.time - heard) / speed,
                duration: e.duration / speed,
                intensity: (e.intensity * scale).clamp(0.0, 1.0),
                sharpness: e.sharpness,
                continuous: e.continuous,
                envelope: e.envelope.clone(),
                envelope_step: ENVELOPE_STEP / speed,
            })
            .collect();
        HapticBatch { reset, cues }
    }

    /// Forget the schedule (pause / stop): the next call starts fresh.
    pub fn reset(&self) {
        *self.cursor.lock().unwrap() = Cursor::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f64 = RATE as f64;

    fn add_kick(x: &mut [f32], t: f64, amp: f32) {
        let s = (t * SR) as usize;
        for i in 0..(0.18 * SR) as usize {
            if s + i >= x.len() {
                break;
            }
            let tt = i as f64 / SR;
            let f = 55.0 + 90.0 * (-tt * 30.0).exp();
            x[s + i] += amp * (std::f64::consts::TAU * f * tt).sin() as f32 * (-tt * 18.0).exp() as f32;
        }
    }

    fn add_hat(x: &mut [f32], t: f64, amp: f32, seed: &mut u64) {
        let s = (t * SR) as usize;
        let mut hpf = hp(6000.0, SR);
        for i in 0..(0.04 * SR) as usize {
            if s + i >= x.len() {
                break;
            }
            *seed ^= *seed << 13;
            *seed ^= *seed >> 7;
            *seed ^= *seed << 17;
            let n = (*seed as f64 / u64::MAX as f64 * 2.0 - 1.0) as f32;
            let tt = i as f64 / SR;
            x[s + i] += amp * hpf.run(n) * (-tt * 120.0).exp() as f32;
        }
    }

    fn pcm(x: &[f32]) -> Vec<i16> {
        x.iter().map(|v| (v.clamp(-1.0, 1.0) * 32767.0) as i16).collect()
    }

    /// 2 s silence, then 8 s of kicks on the beat (120 BPM) with hats on the off-beats.
    fn groove() -> (Vec<i16>, Vec<f64>, Vec<f64>) {
        let mut x = vec![0f32; (10.0 * SR) as usize];
        let mut seed = 0x9E37_79B9_7F4A_7C15u64;
        let (mut kicks, mut hats) = (vec![], vec![]);
        let mut t = 2.0;
        while t < 9.8 {
            add_kick(&mut x, t, 0.8);
            kicks.push(t);
            add_hat(&mut x, t + 0.25, 0.25, &mut seed);
            hats.push(t + 0.25);
            t += 0.5;
        }
        (pcm(&x), kicks, hats)
    }

    fn near<'a>(s: &'a HapticScore, t: f64, tol: f64) -> Option<&'a HapticEvent> {
        s.events().iter().filter(|e| !e.continuous).find(|e| (e.time - t).abs() <= tol)
    }

    #[test]
    fn kicks_are_deep_hats_are_crisp_and_silence_is_still() {
        let (p, kicks, hats) = groove();
        let s = analyze(&p, SR);
        let found = kicks.iter().filter(|k| near(&s, **k, 0.02).is_some()).count();
        assert!(found as f64 >= kicks.len() as f64 * 0.9, "kicks {found}/{}", kicks.len());
        let hat_found = hats.iter().filter(|h| near(&s, **h, 0.02).is_some()).count();
        assert!(hat_found as f64 >= hats.len() as f64 * 0.8, "hats {hat_found}/{}", hats.len());
        let kick_sharp: f32 = kicks.iter().filter_map(|k| near(&s, *k, 0.02)).map(|e| e.sharpness).sum::<f32>() / found as f32;
        let hat_sharp: f32 = hats.iter().filter_map(|h| near(&s, *h, 0.02)).map(|e| e.sharpness).sum::<f32>() / hat_found.max(1) as f32;
        assert!(kick_sharp < 0.45 && hat_sharp > 0.7, "sharpness kick {kick_sharp} hat {hat_sharp}");
        let kick_int: f32 = kicks.iter().filter_map(|k| near(&s, *k, 0.02)).map(|e| e.intensity).sum::<f32>() / found as f32;
        let hat_int: f32 = hats.iter().filter_map(|h| near(&s, *h, 0.02)).map(|e| e.intensity).sum::<f32>() / hat_found.max(1) as f32;
        assert!(kick_int > hat_int + 0.15, "kick {kick_int} vs hat {hat_int}");
        assert!(s.events().iter().all(|e| e.time > 1.95), "events in the silent lead-in");
        // Timing: every transient lands within 20 ms of a real hit.
        let all: Vec<f64> = kicks.iter().chain(hats.iter()).cloned().collect();
        for e in s.events().iter().filter(|e| !e.continuous) {
            assert!(all.iter().any(|t| (e.time - t).abs() <= 0.02), "stray event at {:.3}", e.time);
        }
    }

    #[test]
    fn sustained_bass_becomes_a_rumble_with_an_envelope() {
        let mut x = vec![0f32; (6.0 * SR) as usize];
        for (i, v) in x.iter_mut().enumerate().skip((1.0 * SR) as usize).take((3.0 * SR) as usize) {
            let t = i as f64 / SR;
            *v = 0.6 * (std::f64::consts::TAU * 50.0 * t).sin() as f32;
        }
        // Some quieter mid content around it so the bass level stands out.
        for (i, v) in x.iter_mut().enumerate() {
            let t = i as f64 / SR;
            *v += 0.02 * (std::f64::consts::TAU * 700.0 * t).sin() as f32;
        }
        let s = analyze(&pcm(&x), SR);
        let cont: Vec<_> = s.events().iter().filter(|e| e.continuous).collect();
        let secs: f64 = cont.iter().map(|e| e.duration).sum();
        assert!((2.5..=3.3).contains(&secs), "rumble {secs:.2}s");
        assert!(cont.iter().all(|e| e.duration <= MAX_CONTINUOUS + 1e-9 && e.envelope.len() <= 16 && !e.envelope.is_empty()));
        assert!(cont.first().unwrap().time > 0.9 && cont.first().unwrap().time < 1.15);
    }

    #[test]
    fn dense_hats_are_thinned_and_density_capped() {
        let mut x = vec![0f32; (6.0 * SR) as usize];
        let mut seed = 7u64;
        let mut t = 0.5;
        while t < 5.5 {
            add_hat(&mut x, t, 0.3, &mut seed);
            t += 1.0 / 16.0; // 16 ticks a second
        }
        let s = analyze(&pcm(&x), SR);
        for w in 0..5 {
            let n = s.events().iter().filter(|e| e.time >= w as f64 + 0.5 && e.time < w as f64 + 1.5).count();
            assert!(n <= MAX_HIGH_PER_SEC, "window {w}: {n} ticks");
        }
        assert!(s.stats.transients >= 20, "{}", s.stats.transients);
    }

    #[test]
    fn cache_round_trip() {
        let (p, ..) = groove();
        let mut s = analyze(&p, SR);
        s.events.push(HapticEvent { time: 9.0, duration: 0.5, intensity: 0.3, sharpness: 0.1, continuous: true, envelope: vec![0.2, 0.6, 1.0] });
        let d = decode_score(&encode_score(&s)).unwrap();
        assert_eq!(d.events.len(), s.events.len());
        for (a, b) in d.events.iter().zip(&s.events) {
            assert!((a.time - b.time).abs() < 1e-4 && (a.intensity - b.intensity).abs() < 0.01 && a.continuous == b.continuous);
            assert_eq!(a.envelope.len(), b.envelope.len());
        }
        assert!(decode_score(b"junk").is_none());
        assert!(decode_score(&encode_score(&s)[..30]).is_none());
    }

    #[test]
    fn scheduler_follows_playback_latency_speed_and_seeks() {
        let ev = |t: f64| HapticEvent { time: t, duration: 0.0, intensity: 0.5, sharpness: 0.5, continuous: false, envelope: vec![] };
        let score = Arc::new(HapticScore { events: (0..100).map(|i| ev(i as f64 * 0.1)).collect(), stats: HapticStats::default() });
        let s = HapticScheduler::new(score);
        // Rendered to 2.3 s, 0.3 s latency: heard 2.0 s. Lookahead 0.5 s.
        let b = s.next(2.3, 0.3, 1.0, 0.5, 1.0);
        assert!(!b.reset);
        assert_eq!(b.cues.len(), 5); // 2.0 .. 2.4
        assert!(b.cues[0].at.abs() < 1e-9 && (b.cues[4].at - 0.4).abs() < 1e-9);
        // 0.2 s later: only new events (no repeats).
        let b = s.next(2.5, 0.3, 1.0, 0.5, 1.0);
        assert_eq!(b.cues.len(), 2); // 2.5, 2.6
        assert!((b.cues[0].at - 0.3).abs() < 1e-9);
        // Seek back: reset, events from the new spot.
        let b = s.next(1.3, 0.3, 1.0, 0.5, 2.0);
        assert!(b.reset);
        assert_eq!(b.cues.len(), 5);
        assert!(b.cues.iter().all(|c| c.intensity == 1.0)); // strength 2.0 clamps
        // Double speed: track time runs twice as fast; latency covers more track.
        s.reset();
        let b = s.next(5.0, 0.25, 2.0, 0.5, 1.0); // heard 4.5, covers 4.5..5.5
        assert_eq!(b.cues.len(), 10);
        assert!((b.cues[9].at - 0.45).abs() < 1e-9);
    }
}

/// Diagnostics for tests: why each band did or didn't fire around `times`.
#[doc(hidden)]
pub fn diagnose(pcm: &[i16], sr: f64, times: &[f64]) -> Vec<String> {
    let x: Vec<f32> = pcm.iter().map(|v| *v as f32 / 32768.0).collect();
    let ([low, mid, high], mix) = envelopes(&x, sr);
    let n = mix.len();
    let mix_p50 = percentile(&mix, 0.5);
    let gate_db = (mix_p50 - 30.0).max(-50.0);
    let bands = [&low, &mid, &high];
    let stats: Vec<(Vec<f32>, f32, Vec<f32>, f32)> = bands
        .iter()
        .enumerate()
        .map(|(b, e)| {
            let odf = onset_function(e, BANDS[b].lag);
            let nonzero: Vec<f32> = odf.iter().cloned().filter(|v| *v > 0.5).collect();
            let spread = percentile(&nonzero, 0.9);
            let med = running_median(&odf, 100, 10);
            (odf, spread, med, percentile(e, 0.5) - 6.0)
        })
        .collect();
    times
        .iter()
        .map(|t| {
            let i = ((t / HOP_SECS) as usize).min(n.saturating_sub(1));
            let mut line = format!("{t:7.2}s mix {:.0}dB(gate {:.0}, fwd {:.0})", mix[i], gate_db, mix[(i + 10).min(n - 1)]);
            for (b, (odf, spread, med, floor)) in stats.iter().enumerate() {
                let (a, z) = (i.saturating_sub(8), (i + 8).min(n));
                let (j, v) = (a..z).map(|j| (j, odf[j])).max_by(|p, q| p.1.total_cmp(&q.1)).unwrap();
                let thr = (med[j] + SPREAD_K * spread).max(BANDS[b].floor_db);
                let peak = bands[b][j..(j + 6).min(n)].iter().cloned().fold(f32::MIN, f32::max);
                line += &format!(" | {} odf {:.1}/thr {:.1} @{:+}ms lvl {:.0}/floor {:.0}", ["L", "M", "H"][b], v, thr, (j as i64 - i as i64) * 5, peak, floor);
            }
            line
        })
        .collect()
}
