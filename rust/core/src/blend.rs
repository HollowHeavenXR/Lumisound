//! Lumisound Blend: the Smart Crossfade system.
//!
//! Two halves, both pure Rust:
//!
//! * `blend_profile` reads the first and last 40 s of a track once (cached)
//!   and measures what a DJ listens for: where the music really starts and
//!   ends, a regular beat grid with its downbeats (bar starts), a 3-band
//!   energy outline (bass / mids / highs), how the outro ends (cold stop,
//!   fade-out, full-energy sustain) and how the intro arrives (hard downbeat,
//!   soft entry, slow build), plus the key at each end.
//! * `blend_plan` turns two profiles into one transition: the exact track
//!   time the fade starts on the outgoing song (on a downbeat), how long it
//!   runs (whole bars when the tempos fit), where the incoming song starts so
//!   its downbeat lands on the outgoing one, the beat-match tempo ratio and
//!   the style — an equal-power blend, a bass swap (only one bassline at a
//!   time, swapped on a bar line, the way DJs avoid a muddy low end) or a
//!   short cut for cold stops.
//!
//! The engine runs the plan sample-accurately (`AudioEngine::queue_blend`):
//! the incoming deck is opened and buffered ahead, and the mixer starts the
//! fade the frame the outgoing deck reaches `out_start`.
//!
//! Replaces the Swift `SmartCrossfade` / tvOS `TVAutoCrossfade` heuristics,
//! which only scaled a fixed duration and started it a fixed time before the
//! end of the file.

use lumisound_media::analysis as dsp;
use lumisound_media::decode;
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Arc;

const SR: u32 = 11_025;
/// Envelope hop (samples) and frames per second (~50).
const HOP: usize = 221;
const FPS: f64 = SR as f64 / HOP as f64;
const LOOK: f64 = 40.0;
const CACHE_NS: &str = "blend_v1";

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum BlendOutro {
    /// Full energy right up to an abrupt end.
    ColdStop,
    /// Level falls away over the last seconds.
    FadeOut,
    /// Full energy until the file ends (loops, sustained endings).
    Sustain,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum BlendIntro {
    /// Full level within a beat of the first sound.
    Hard,
    /// Reaches full level within a few seconds.
    Soft,
    /// Long build (ambient / riser intros).
    Build,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum BlendStyle {
    /// Equal-power crossfade of the whole signal.
    EqualPower,
    /// Highs crossfade; the bass stays with the outgoing track until
    /// `swap_at`, then swaps to the incoming one within a beat.
    BassSwap,
    /// Short fade for a cold stop: the next track lands on the stop.
    Cut,
}

/// One end of a track (head or tail).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct EndShape {
    /// Absolute track time of the first envelope frame.
    pub t0: f64,
    /// Envelope in dB per band (low < 200 Hz, mid, high > 3 kHz), FPS frames.
    pub low: Vec<f32>,
    pub mid: Vec<f32>,
    pub high: Vec<f32>,
    /// Beat period (s, 0 = no steady pulse) and confidence 0..1.
    pub period: f64,
    pub confidence: f64,
    /// Absolute time of one downbeat (bar start); other bars are ± 4 beats.
    pub downbeat: f64,
    pub key: Option<String>,
}

/// A track's two ends, measured once. Opaque to Swift (it holds the band
/// envelopes); `summary()` gives the readable part.
#[derive(uniffi::Object, Clone, Debug, Serialize, Deserialize)]
pub struct BlendProfile {
    pub duration: f64,
    /// First and last moments of music (absolute seconds).
    pub music_start: f64,
    pub music_end: f64,
    pub outro: BlendOutro,
    pub intro: BlendIntro,
    /// Body level of each end (dB, full band).
    pub tail_body_db: f64,
    pub head_body_db: f64,
    /// Seconds from music start to full level.
    pub intro_rise_s: f64,
    /// Level slope over the last 8 s of music, dB/s.
    pub outro_slope_db: f64,
    pub bpm_tail: f64,
    pub bpm_head: f64,
    pub beat_confidence: f64,
    head: EndShape,
    tail: EndShape,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct BlendSummary {
    pub duration: f64,
    pub music_start: f64,
    pub music_end: f64,
    pub outro: BlendOutro,
    pub intro: BlendIntro,
    pub bpm_head: f64,
    pub bpm_tail: f64,
    pub beat_confidence: f64,
    pub key_head: Option<String>,
    pub key_tail: Option<String>,
}

#[uniffi::export]
impl BlendProfile {
    pub fn summary(&self) -> BlendSummary {
        BlendSummary {
            duration: self.duration,
            music_start: self.music_start,
            music_end: self.music_end,
            outro: self.outro,
            intro: self.intro,
            bpm_head: self.bpm_head,
            bpm_tail: self.bpm_tail,
            beat_confidence: self.beat_confidence,
            key_head: self.head.key.clone(),
            key_tail: self.tail.key.clone(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct BlendPlan {
    /// Outgoing track time (s) at which the fade starts.
    pub out_start: f64,
    /// Fade length in track seconds.
    pub fade_secs: f64,
    /// Incoming track start time (s).
    pub in_start: f64,
    /// Incoming tempo ratio through the first part of the fade (1 = off).
    pub tempo_match: f64,
    pub style: BlendStyle,
    /// Where (0..1 of the fade) the bass changes hands (BassSwap).
    pub swap_at: f64,
    /// Whole bars the fade spans (0 = not bar-locked).
    pub bars: u32,
    /// Why, for the log.
    pub reason: String,
}

fn cache_key(path: &str) -> String {
    let m = std::fs::metadata(path).ok();
    let mtime = m.as_ref().and_then(|m| m.modified().ok()).and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    format!("{path}|{mtime}|{}", m.map(|m| m.len()).unwrap_or(0))
}

/// Profile of a track (head + tail), cached per file. None for files that
/// can't be decoded or are shorter than 10 s.
#[uniffi::export]
pub fn blend_profile(path: String) -> Option<Arc<BlendProfile>> {
    let key = cache_key(&path);
    if let Some(p) = crate::blobcache::blob_cache_get(CACHE_NS.into(), key.clone()).and_then(|b| serde_json::from_slice::<BlendProfile>(&b).ok()) {
        return Some(Arc::new(p));
    }
    let dur = decode::probe(Path::new(&path)).map(|p| p.duration).unwrap_or(0.0);
    if dur < 10.0 {
        return None;
    }
    let look = LOOK.min(dur / 2.0);
    let head = decode::mono_pcm(Path::new(&path), SR, Some(0.0), Some(look))?;
    let tail_start = (dur - look).max(0.0);
    let tail = decode::mono_pcm(Path::new(&path), SR, Some(tail_start), Some(look + 1.0))?;
    let p = profile_from(&head, &tail, tail_start, dur);
    if let Ok(b) = serde_json::to_vec(&p) {
        crate::blobcache::blob_cache_put(CACHE_NS.into(), key, b);
    }
    Some(Arc::new(p))
}

/// Cached profile only (never decodes).
#[uniffi::export]
pub fn blend_profile_cached(path: String) -> Option<Arc<BlendProfile>> {
    crate::blobcache::blob_cache_get(CACHE_NS.into(), cache_key(&path)).and_then(|b| serde_json::from_slice(&b).ok()).map(Arc::new)
}

// ---- analysis ---------------------------------------------------------------------------------

struct Biquad {
    b: [f32; 3],
    a: [f32; 2],
    z: [f32; 2],
}

impl Biquad {
    fn lowpass(f: f32, sr: f32) -> Self {
        let w = std::f32::consts::TAU * f / sr;
        let (s, c) = w.sin_cos();
        let alpha = s / (2.0 * std::f32::consts::FRAC_1_SQRT_2);
        let a0 = 1.0 + alpha;
        Self { b: [(1.0 - c) / 2.0 / a0, (1.0 - c) / a0, (1.0 - c) / 2.0 / a0], a: [-2.0 * c / a0, (1.0 - alpha) / a0], z: [0.0; 2] }
    }
    fn highpass(f: f32, sr: f32) -> Self {
        let w = std::f32::consts::TAU * f / sr;
        let (s, c) = w.sin_cos();
        let alpha = s / (2.0 * std::f32::consts::FRAC_1_SQRT_2);
        let a0 = 1.0 + alpha;
        Self { b: [(1.0 + c) / 2.0 / a0, -(1.0 + c) / a0, (1.0 + c) / 2.0 / a0], a: [-2.0 * c / a0, (1.0 - alpha) / a0], z: [0.0; 2] }
    }
    #[inline]
    fn run(&mut self, x: f32) -> f32 {
        let y = self.b[0] * x + self.z[0];
        self.z[0] = self.b[1] * x - self.a[0] * y + self.z[1];
        self.z[1] = self.b[2] * x - self.a[1] * y;
        y
    }
}

/// (low, mid, high, full) envelopes in dB at FPS.
fn band_envelopes(s: &[i16]) -> [Vec<f32>; 4] {
    let hop = HOP;
    let sr = SR as f32;
    let (mut lp, mut hp) = (Biquad::lowpass(200.0, sr), Biquad::highpass(3000.0, sr));
    let (mut lp2, mut hp2) = (Biquad::lowpass(200.0, sr), Biquad::highpass(3000.0, sr));
    let mut out: [Vec<f32>; 4] = Default::default();
    let mut acc = [0f64; 4];
    let mut n = 0;
    for v in s {
        let x = *v as f32 / 32768.0;
        let lo = lp2.run(lp.run(x));
        let hi = hp2.run(hp.run(x));
        let mi = x - lo - hi;
        acc[0] += (lo * lo) as f64;
        acc[1] += (mi * mi) as f64;
        acc[2] += (hi * hi) as f64;
        acc[3] += (x * x) as f64;
        n += 1;
        if n == hop {
            for b in 0..4 {
                out[b].push((10.0 * (acc[b] / hop as f64).max(1e-12).log10()) as f32);
            }
            acc = [0.0; 4];
            n = 0;
        }
    }
    out
}

fn percentile(v: &[f32], p: f64) -> f32 {
    if v.is_empty() {
        return -120.0;
    }
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.total_cmp(b));
    s[((s.len() - 1) as f64 * p).round() as usize]
}

/// Regular beat grid from band envelopes: (period s, confidence, downbeat
/// frame index relative to the envelope start).
fn pulse(low: &[f32], mid: &[f32], high: &[f32]) -> (f64, f64, f64) {
    let n = low.len();
    if n < (FPS * 6.0) as usize {
        return (0.0, 0.0, 0.0);
    }
    // Onset strength: positive dB rise, bass weighted (kicks carry the bar).
    let mut od = vec![0f64; n];
    let mut accent = vec![0f64; n];
    // Rise of log-compressed amplitude (log(1 + 100·a)): loud onsets count
    // more than quiet ones. A plain dB rise made a soft off-beat hat after a
    // fully decayed kick look as strong as the kick, and the tempo locked to
    // 1.5 beats.
    let comp = |v: &[f32]| -> Vec<f64> { v.iter().map(|d| (1.0 + 100.0 * 10f64.powf(*d as f64 / 20.0)).ln()).collect() };
    let (cl, cm, ch) = (comp(low), comp(mid), comp(high));
    for i in 1..n {
        let r = |v: &[f64]| (v[i] - v[i - 1]).max(0.0);
        od[i] = 1.4 * r(&cl) + r(&cm) + 0.6 * r(&ch);
        accent[i] = r(&cl);
    }
    let mean = od.iter().sum::<f64>() / n as f64;
    for v in od.iter_mut() {
        *v = (*v - mean).max(0.0);
    }
    // Light smoothing so a beat period that falls between frames still
    // correlates (an unsmoothed envelope favoured whichever multiple of the
    // beat happened to land on whole frames).
    let sm: Vec<f64> = (0..n).map(|i| 0.25 * od[i.saturating_sub(1)] + 0.5 * od[i] + 0.25 * od[(i + 1).min(n - 1)]).collect();
    let at = |v: &[f64], x: f64| -> f64 {
        let i = x.floor() as usize;
        if i + 1 >= v.len() {
            return 0.0;
        }
        let f = x - i as f64;
        v[i] * (1.0 - f) + v[i + 1] * f
    };
    // Candidates: autocorrelation peaks over 70..180 BPM (quarter-frame lags).
    let (min_lag, max_lag) = (FPS * 60.0 / 180.0, FPS * 60.0 / 70.0);
    let energy: f64 = sm.iter().map(|v| v * v).sum::<f64>().max(1e-12);
    let acf = |lag: f64| -> f64 {
        let m = n as f64 - lag - 1.0;
        if m <= 0.0 {
            return 0.0;
        }
        (0..m as usize).map(|i| sm[i] * at(&sm, i as f64 + lag)).sum::<f64>() / energy
    };
    let mut lags = Vec::new();
    let mut l = min_lag - 0.25;
    while l <= max_lag + 0.25 {
        lags.push((l, acf(l)));
        l += 0.25;
    }
    let mut cands: Vec<(f64, f64)> = (1..lags.len() - 1).filter(|&i| lags[i].1 >= lags[i - 1].1 && lags[i].1 >= lags[i + 1].1 && lags[i].1 > 0.0).map(|i| lags[i]).collect();
    cands.sort_by(|a, b| b.1.total_cmp(&a.1));
    cands.truncate(6);
    if cands.is_empty() {
        return (0.0, 0.0, 0.0);
    }
    // Pulse salience: mean onset strength under an evenly spaced pulse train
    // at its best phase. The true beat lands every pulse on an onset; a
    // 1.5-beat or off-beat period alternates between hits and gaps.
    let mean_od = sm.iter().sum::<f64>() / n as f64;
    let salience = |p: f64| -> (f64, f64) {
        let mut best = (0.0, -1.0);
        for k in 0..32 {
            let ph = p * k as f64 / 32.0;
            let (mut s, mut c) = (0.0, 0.0);
            let mut t = ph;
            while t + 1.0 < n as f64 {
                s += at(&sm, t);
                c += 1.0;
                t += p;
            }
            let m = if c > 0.0 { s / c } else { 0.0 };
            if m > best.1 {
                best = (ph, m);
            }
        }
        best
    };
    let prior = |p: f64| {
        let bpm = 60.0 * FPS / p;
        (-((bpm / 120.0).log2()).powi(2) / (2.0 * 0.7f64.powi(2))).exp()
    };
    // Each candidate is refined (±3 %, 0.1 % steps) before candidates are
    // compared: a period 1 % off drifts a whole beat over a 40 s window and
    // its pulse train smears over everything.
    let refine = |lag: f64| -> (f64, f64, f64) {
        let mut b = (lag, 0.0, -1.0);
        let mut p = lag * 0.97;
        while p <= lag * 1.03 {
            let (ph, sal) = salience(p);
            if sal > b.2 {
                b = (p, ph, sal);
            }
            p += lag * 0.001;
        }
        b
    };
    let mut best = (0.0, 0.0, 0.0, 0.0, 0.0); // (period frames, score, phase, ac, salience)
    for (lag, ac) in &cands {
        let (p, ph, sal) = refine(*lag);
        let score = sal * (0.5 + 0.5 * prior(p));
        if std::env::var("BLEND_DEBUG").is_ok() {
            eprintln!("cand {:.1} bpm ac {ac:.3} sal {sal:.3} score {score:.3}", 60.0 * FPS / p);
        }
        if score > best.1 {
            best = (p, score, ph, *ac, sal);
        }
    }
    let period_f = best.0;
    let phase = (best.2, best.4);
    let conf_ac = best.3;
    let conf_sal = if mean_od > 0.0 { ((phase.1 / mean_od - 1.0) / 3.0).clamp(0.0, 1.0) } else { 0.0 };
    // Downbeat: of the 4 beat positions in a bar, the one with the most bass accent.
    let mut bar = [0f64; 4];
    let mut t = phase.0;
    let mut b = 0usize;
    while (t as usize) < n {
        let i = t.round() as usize;
        if i < n {
            bar[b % 4] += accent[i] + 0.5 * accent.get(i + 1).copied().unwrap_or(0.0);
        }
        t += period_f;
        b += 1;
    }
    let db = (0..4).max_by(|a, c| bar[*a].total_cmp(&bar[*c])).unwrap_or(0);
    let downbeat = phase.0 + db as f64 * period_f;
    // Confidence: how much of the onset energy repeats at the beat period.
    let conf = (0.5 * (conf_ac * 2.2).clamp(0.0, 1.0) + 0.5 * conf_sal).clamp(0.0, 1.0);
    (period_f / FPS, conf, downbeat)
}

fn shape(s: &[i16], t0: f64) -> (EndShape, Vec<f32>) {
    let [low, mid, high, full] = band_envelopes(s);
    let (period, confidence, db_frame) = pulse(&low, &mid, &high);
    let key = if s.len() > SR as usize * 8 { dsp::key_from_chroma(&dsp::chroma_vector(s, SR)) } else { None };
    (EndShape { t0, low, mid, high, period, confidence, downbeat: t0 + db_frame / FPS, key }, full)
}

pub(crate) fn profile_from(head: &[i16], tail: &[i16], tail_start: f64, duration: f64) -> BlendProfile {
    let (h, hfull) = shape(head, 0.0);
    let (t, tfull) = shape(tail, tail_start);
    let dt = 1.0 / FPS;
    // Music boundaries: 40 dB under each end's loud level (p95).
    let tail_top = percentile(&tfull, 0.95);
    let last = tfull.iter().rposition(|v| *v > tail_top - 40.0).unwrap_or(tfull.len().saturating_sub(1));
    let music_end = (tail_start + (last + 1) as f64 * dt).min(duration);
    let head_top = percentile(&hfull, 0.95);
    let first = hfull.iter().position(|v| *v > head_top - 40.0).unwrap_or(0);
    let music_start = first as f64 * dt;
    // Tail body and outro shape over the music only.
    let music = &tfull[..=last.min(tfull.len().saturating_sub(1))];
    let tail_body = percentile(music, 0.6) as f64;
    let w8 = ((8.0 * FPS) as usize).min(music.len());
    let seg = &music[music.len() - w8..];
    let slope = {
        let n = seg.len() as f64;
        let mt = (n - 1.0) / 2.0 * dt;
        let my = seg.iter().map(|v| *v as f64).sum::<f64>() / n.max(1.0);
        let (mut sxy, mut sxx) = (0.0, 0.0);
        for (i, v) in seg.iter().enumerate() {
            let x = i as f64 * dt - mt;
            sxy += x * (*v as f64 - my);
            sxx += x * x;
        }
        if sxx > 0.0 { sxy / sxx } else { 0.0 }
    };
    let last_half = &music[music.len().saturating_sub((0.5 * FPS) as usize)..];
    let end_level = percentile(last_half, 0.5) as f64;
    // A cold stop ends into real silence (>= 0.1 s): music that runs at
    // full level into the end of the file is a sustained ending (a loop or a
    // cut file) and wants the blend before the end, not a cut on it.
    let stops = silence_after(&tfull, last, tail_top);
    let outro = if stops && tail_body - end_level < 6.0 && slope > -1.0 {
        BlendOutro::ColdStop
    } else if slope < -1.2 || tail_body - end_level > 9.0 {
        BlendOutro::FadeOut
    } else {
        BlendOutro::Sustain
    };
    // Intro: time from first sound to within 3 dB of the head's body level.
    let hmusic = &hfull[first.min(hfull.len().saturating_sub(1))..];
    let head_body = percentile(hmusic, 0.6) as f64;
    let rise = hmusic.iter().position(|v| *v as f64 >= head_body - 3.0).map(|i| i as f64 * dt).unwrap_or(0.0);
    let intro = if rise <= 0.35 { BlendIntro::Hard } else if rise <= 4.0 { BlendIntro::Soft } else { BlendIntro::Build };
    BlendProfile {
        duration,
        music_start,
        music_end,
        outro,
        intro,
        tail_body_db: tail_body,
        head_body_db: head_body,
        intro_rise_s: rise,
        outro_slope_db: slope,
        bpm_tail: if t.period > 0.0 { 60.0 / t.period } else { 0.0 },
        bpm_head: if h.period > 0.0 { 60.0 / h.period } else { 0.0 },
        beat_confidence: h.confidence.min(t.confidence),
        head: h,
        tail: t,
    }
}

/// The music stops into at least 0.1 s of real silence.
fn silence_after(full: &[f32], last: usize, top: f32) -> bool {
    full.len() >= last + 1 + (0.1 * FPS) as usize && full[last + 1..].iter().all(|v| *v < top - 40.0)
}


// ---- planning ---------------------------------------------------------------------------------

/// Settings the planner honours.
#[derive(uniffi::Record, Clone, Debug)]
pub struct BlendSettings {
    /// The user's crossfade length (s): the target the plan bends around.
    pub base_secs: f64,
    /// Allow tempo matching.
    pub beat_match: bool,
    /// Allow bass swaps.
    pub bass_swap: bool,
}

fn bar_times(s: &EndShape, from: f64, to: f64) -> Vec<f64> {
    if s.period <= 0.0 {
        return vec![];
    }
    let bar = s.period * 4.0;
    let k0 = ((from - s.downbeat) / bar).ceil() as i64;
    let mut v = Vec::new();
    let mut k = k0;
    loop {
        let t = s.downbeat + k as f64 * bar;
        if t > to {
            break;
        }
        if t >= from {
            v.push(t);
        }
        k += 1;
    }
    v
}

/// Level (dB) of one band of an end shape at absolute time `t`.
fn level_at(s: &EndShape, band: &[f32], t: f64) -> f32 {
    let i = ((t - s.t0) * FPS).round();
    if i < 0.0 || band.is_empty() {
        return -120.0;
    }
    band[(i as usize).min(band.len() - 1)]
}

/// Mean level of a band over [a, b).
fn mean_level(s: &EndShape, band: &[f32], a: f64, b: f64) -> f32 {
    let (i0, i1) = (((a - s.t0) * FPS).max(0.0) as usize, (((b - s.t0) * FPS).max(0.0) as usize).min(band.len()));
    if i1 <= i0 {
        return level_at(s, band, a);
    }
    let lin: f64 = band[i0..i1].iter().map(|d| 10f64.powf(*d as f64 / 10.0)).sum::<f64>() / (i1 - i0) as f64;
    (10.0 * lin.max(1e-12).log10()) as f32
}

/// Tempo relation: Some(ratio incoming→outgoing, folded for half/double time)
/// when the two can be beat-matched within ±8 %.
fn tempo_fit(out_bpm: f64, in_bpm: f64) -> Option<f64> {
    if out_bpm <= 0.0 || in_bpm <= 0.0 {
        return None;
    }
    for k in [1.0, 2.0, 0.5] {
        let r = out_bpm / (in_bpm * k);
        if (r - 1.0).abs() <= 0.08 {
            return Some(r);
        }
    }
    None
}

/// The transition from `out` into `inc`.
#[uniffi::export]
pub fn blend_plan(out: Arc<BlendProfile>, inc: Arc<BlendProfile>, settings: BlendSettings) -> BlendPlan {
    plan(&out, &inc, &settings)
}

pub(crate) fn plan(out: &BlendProfile, inc: &BlendProfile, st: &BlendSettings) -> BlendPlan {
    let (os, is) = (&out.tail, &inc.head);
    let base = st.base_secs.clamp(0.5, 20.0);
    let mut reasons: Vec<String> = Vec::new();
    let end = out.music_end;
    // Never eat more than 12 % of either track.
    let cap = (out.duration * 0.12).min(inc.duration * 0.12).clamp(0.8, 16.0);
    let fit = if st.beat_match && out.beat_confidence >= 0.25 && inc.beat_confidence >= 0.25 { tempo_fit(out.bpm_tail, inc.bpm_head) } else { None };
    let (ca, cb) = (dsp::camelot(os.key.as_deref()), dsp::camelot(is.key.as_deref()));
    let keys_ok = ca.is_none() || cb.is_none() || dsp::camelot_compatible(ca, cb);
    if !keys_ok {
        reasons.push("key-clash".into());
    }
    let mut in_start = inc.music_start.max(0.0);
    let (mut out_start, mut fade, mut style, mut bars) = (end - base, base, BlendStyle::EqualPower, 0u32);

    match out.outro {
        BlendOutro::ColdStop => {
            // Let the stop be heard: a short overlap that ends on it, the next
            // track landing on its first downbeat right at the stop.
            fade = (base * 0.25).clamp(0.4, 1.5).min(cap);
            out_start = end - fade * 0.6;
            style = BlendStyle::Cut;
            if let Some(d) = bar_times(is, inc.music_start, inc.music_start + 8.0).first().filter(|_| inc.intro == BlendIntro::Build) {
                // A slow build is skipped to its first full bar.
                in_start = *d;
                reasons.push("skip-build".into());
            }
            reasons.push("cold-stop".into());
        }
        BlendOutro::FadeOut => {
            // Start where the outro has faded 6 dB under its body, on a downbeat.
            let six = find_fall(os, &os_full(os), out.tail_body_db as f32 - 6.0, end).unwrap_or(end - base);
            let start = snap_back(os, six, end - cap);
            // A steep fade still gets a real overlap (at least 60 % of the setting).
            fade = (end - start).max(base.min(cap) * 0.6).clamp(1.0, cap.max(1.0));
            out_start = end - fade;
            reasons.push("fade-out".into());
        }
        BlendOutro::Sustain => {
            reasons.push("full-energy-outro".into());
        }
    }

    // Bar-locked overlap when both pulses are steady and the tempos fit.
    if out.outro != BlendOutro::ColdStop {
        if let Some(r) = fit {
            let bar = os.period * 4.0;
            if bar > 0.0 {
                let want = fade.min(cap);
                let n = [1u32, 2, 4, 8, 16].into_iter().filter(|b| (*b as f64) * bar <= cap + 1e-6).min_by(|a, b| ((*a as f64 * bar) - want).abs().total_cmp(&((*b as f64 * bar) - want).abs())).unwrap_or(1);
                let target_start = end - n as f64 * bar;
                // The downbeat at or before the target, so the last bar ends on the music's end.
                let start = snap_back(os, target_start, target_start - bar);
                if start + 0.5 < end {
                    out_start = start;
                    fade = (n as f64 * bar).min(end - start + bar);
                    bars = n;
                    reasons.push(format!("{n}-bar"));
                }
            }
            // Incoming starts on its own downbeat so bar 1 lands on the outgoing bar line.
            if let Some(d) = bar_times(is, inc.music_start, inc.music_start + 12.0).first() {
                if inc.intro == BlendIntro::Build || *d - inc.music_start < 0.6 {
                    in_start = *d;
                } else if is.period > 0.0 {
                    // Keep a pickup before the first downbeat: start a whole bar earlier when possible.
                    let back = *d - is.period * 4.0;
                    in_start = if back >= inc.music_start - 0.05 { back } else { *d };
                }
            }
            let _ = r;
        } else if out.outro == BlendOutro::Sustain && out.beat_confidence >= 0.25 && inc.beat_confidence >= 0.25 && out.bpm_tail > 0.0 && inc.bpm_head > 0.0 {
            // Tempos fight: keep the overlap short so the beats don't flam.
            fade = (fade * 0.6).max(1.0);
            out_start = end - fade;
            reasons.push("tempo-clash".into());
        }
    }

    // Slow-build intro under a full-energy outro: let the build carry the
    // transition (longer, starting from its first sound).
    if inc.intro == BlendIntro::Build && out.outro == BlendOutro::Sustain && bars == 0 {
        fade = (fade * 1.35).min(cap);
        out_start = end - fade;
        reasons.push("build-intro".into());
    }
    // A fading outro is quiet under the incoming track: clashes don't matter there.
    if !keys_ok && out.outro == BlendOutro::Sustain {
        // Clashing keys: shorter overlap, the two harmonies meet only briefly.
        let shorter = (fade * 0.6).max(1.0);
        if bars > 1 {
            bars /= 2;
            fade = bars as f64 * os.period * 4.0;
        } else {
            fade = shorter;
        }
        out_start = end - fade;
    }

    // Bass swap: both sides carry real bass across the overlap.
    if style == BlendStyle::EqualPower && st.bass_swap && fade >= 2.0 {
        let o_low = mean_level(os, &os.low, out_start, out_start + fade);
        let o_full = mean_level(os, &os_full(os), out_start, out_start + fade);
        let i_low = mean_level(is, &is.low, in_start, in_start + fade);
        let i_full = mean_level(is, &is_full(is), in_start, in_start + fade);
        if o_low > o_full - 12.0 && i_low > i_full - 12.0 {
            style = BlendStyle::BassSwap;
            reasons.push("bass-swap".into());
        }
    }
    let swap_at = if style == BlendStyle::BassSwap && bars >= 2 {
        // On the bar line nearest the middle.
        let half = (bars / 2) as f64 / bars as f64;
        half
    } else {
        0.5
    };

    let tempo_match = match (fit, bars) {
        (Some(r), b) if b > 0 && (r - 1.0).abs() > 0.004 => {
            reasons.push(format!("beat-match x{r:.3}"));
            r.clamp(0.92, 1.08)
        }
        _ => 1.0,
    };
    fade = fade.clamp(0.3, 20.0);
    out_start = out_start.clamp(0.0, out.duration.max(0.0));
    if out.duration - end > 0.3 {
        reasons.push(format!("skip-{:.1}s-tail", out.duration - end));
    }
    if in_start > 0.3 {
        reasons.push(format!("in@{in_start:.1}s"));
    }
    BlendPlan { out_start, fade_secs: fade, in_start: in_start.max(0.0), tempo_match, style, swap_at, bars, reason: reasons.join(",") }
}

fn os_full(s: &EndShape) -> Vec<f32> {
    // Power sum of the bands ≈ full band.
    (0..s.low.len()).map(|i| {
        let p = 10f64.powf(s.low[i] as f64 / 10.0) + 10f64.powf(s.mid[i] as f64 / 10.0) + 10f64.powf(s.high[i] as f64 / 10.0);
        (10.0 * p.max(1e-12).log10()) as f32
    }).collect()
}
fn is_full(s: &EndShape) -> Vec<f32> {
    os_full(s)
}

/// First time (after which the level stays under `level` until `end`), smoothed over 1 s.
fn find_fall(s: &EndShape, full: &[f32], level: f32, end: f64) -> Option<f64> {
    let w = FPS as usize;
    let last = (((end - s.t0) * FPS) as usize).min(full.len());
    if last < w {
        return None;
    }
    let mut t = None;
    let mut i = last;
    while i >= w {
        let m = full[i - w..i].iter().map(|d| 10f64.powf(*d as f64 / 10.0)).sum::<f64>() / w as f64;
        if 10.0 * m.log10() > level as f64 {
            break;
        }
        t = Some(s.t0 + (i - w) as f64 / FPS);
        i -= w / 4;
    }
    t
}

/// The downbeat at or before `t` (no earlier than `floor`), or `t` itself
/// when there is no grid.
fn snap_back(s: &EndShape, t: f64, floor: f64) -> f64 {
    if s.period <= 0.0 {
        return t;
    }
    let bar = s.period * 4.0;
    let k = ((t - s.downbeat) / bar + 1e-6).floor();
    let d = s.downbeat + k * bar;
    if d >= floor - 1e-6 { d } else { t }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Synthetic track: kick on every beat (bar accent on beat 1), hats,
    /// a bass note and a pad. `env(t)` scales the level (fades / stops).
    fn track(secs: f64, bpm: f64, env: impl Fn(f64) -> f64) -> Vec<i16> {
        let n = (secs * SR as f64) as usize;
        let beat = 60.0 / bpm;
        (0..n).map(|i| {
            let t = i as f64 / SR as f64;
            let ph = (t / beat).fract() * beat;
            let bi = (t / beat).floor() as i64;
            let kick_amp = if bi % 4 == 0 { 1.0 } else { 0.55 };
            let kick = kick_amp * (-ph * 30.0).exp() * (std::f64::consts::TAU * (55.0 + 80.0 * (-ph * 40.0).exp()) * ph).sin();
            let hat_ph = (t / (beat / 2.0)).fract() * beat / 2.0;
            let hat = 0.08 * (-hat_ph * 120.0).exp() * (((i as f64 * 12.9898).sin() * 43758.5453).fract() * 2.0 - 1.0);
            let pad = 0.12 * (std::f64::consts::TAU * 220.0 * t).sin() + 0.08 * (std::f64::consts::TAU * 277.18 * t).sin();
            let bass = 0.2 * (std::f64::consts::TAU * 55.0 * t).sin();
            let v = (0.5 * kick + hat + pad + bass) * env(t);
            (v.clamp(-1.0, 1.0) * 30000.0) as i16
        }).collect()
    }

    fn profile(secs: f64, bpm: f64, env: impl Fn(f64) -> f64 + Copy) -> BlendProfile {
        let all = track(secs, bpm, env);
        let look = (LOOK * SR as f64) as usize;
        let head = all[..look.min(all.len())].to_vec();
        let ts = all.len().saturating_sub(look);
        profile_from(&head, &all[ts..], ts as f64 / SR as f64, secs)
    }

    #[test]
    fn finds_tempo_and_downbeat() {
        let p = profile(120.0, 124.0, |_| 1.0);
        assert!((p.bpm_head - 124.0).abs() < 2.0, "head bpm {}", p.bpm_head);
        assert!((p.bpm_tail - 124.0).abs() < 2.0, "tail bpm {}", p.bpm_tail);
        let beat = 60.0 / 124.0;
        // Downbeats of the synthetic track are at multiples of 4 beats.
        let bars = p.head.downbeat / (4.0 * beat);
        assert!((bars - bars.round()).abs() < 0.08, "downbeat {} not on a bar ({bars:.2} bars)", p.head.downbeat);
        assert_eq!(p.outro, BlendOutro::Sustain);
        assert_eq!(p.intro, BlendIntro::Hard);
    }

    #[test]
    fn classifies_fade_out_and_cold_stop() {
        let fade = profile(120.0, 120.0, |t| if t > 108.0 { (1.0 - (t - 108.0) / 12.0).max(0.0).powi(2) } else { 1.0 });
        assert_eq!(fade.outro, BlendOutro::FadeOut, "slope {}", fade.outro_slope_db);
        let cold = profile(120.0, 120.0, |t| if t > 116.0 { 0.0 } else { 1.0 });
        assert_eq!(cold.outro, BlendOutro::ColdStop);
        assert!((cold.music_end - 116.0).abs() < 0.2, "music end {}", cold.music_end);
        let build = profile(120.0, 120.0, |t| (t / 10.0).min(1.0));
        assert_eq!(build.intro, BlendIntro::Build, "rise {}", build.intro_rise_s);
    }

    #[test]
    fn plan_is_bar_locked_and_beat_matched() {
        let a = profile(150.0, 126.0, |_| 1.0);
        let b = profile(150.0, 122.0, |_| 1.0);
        let st = BlendSettings { base_secs: 8.0, beat_match: true, bass_swap: true };
        eprintln!("a: {:?}\nb: {:?}", a.summary(), b.summary());
        let p = plan(&a, &b, &st);
        let bar = 4.0 * 60.0 / a.bpm_tail;
        assert!(p.bars >= 2, "{p:?}");
        assert!((p.fade_secs - p.bars as f64 * bar).abs() < 0.05, "{p:?}");
        // Fade starts on an outgoing downbeat.
        let s = &a.tail;
        let k = (p.out_start - s.downbeat) / bar;
        assert!((k - k.round()).abs() < 0.02, "out_start {} not on a bar", p.out_start);
        assert!((p.tempo_match - 126.0 / 122.0).abs() < 0.02, "{p:?}");
        assert_eq!(p.style, BlendStyle::BassSwap);
        assert!(p.out_start + p.fade_secs <= a.music_end + bar + 1e-6);
    }

    #[test]
    fn cold_stop_lands_next_track_on_the_stop() {
        let a = profile(120.0, 120.0, |t| if t > 116.0 { 0.0 } else { 1.0 });
        let b = profile(120.0, 120.0, |_| 1.0);
        let p = plan(&a, &b, &BlendSettings { base_secs: 6.0, beat_match: true, bass_swap: true });
        assert_eq!(p.style, BlendStyle::Cut);
        assert!(p.fade_secs <= 1.5);
        assert!((p.out_start + p.fade_secs * 0.6 - a.music_end).abs() < 0.05, "{p:?}");
    }

    #[test]
    fn tempo_clash_shortens_and_skips_beat_match() {
        let a = profile(150.0, 128.0, |_| 1.0);
        let b = profile(150.0, 97.0, |_| 1.0);
        let p = plan(&a, &b, &BlendSettings { base_secs: 8.0, beat_match: true, bass_swap: false });
        assert_eq!(p.tempo_match, 1.0, "{p:?}");
        assert!(p.fade_secs < 8.0, "{p:?}");
        assert!(p.reason.contains("tempo-clash"), "{p:?}");
    }

    #[test]
    fn trailing_silence_is_skipped() {
        let a = profile(120.0, 120.0, |t| if t > 100.0 { 0.0 } else { 1.0 });
        let b = profile(120.0, 120.0, |_| 1.0);
        let p = plan(&a, &b, &BlendSettings { base_secs: 6.0, beat_match: true, bass_swap: true });
        assert!(p.out_start < 100.5, "fade starts in the dead air: {p:?}");
    }
}
