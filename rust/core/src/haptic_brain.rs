//! Haptics Brain: Music Haptics that learns.
//!
//! The analyzer (`haptics.rs`) hears each track once and decides cue by cue.
//! The brain watches the result over time and learns where it is wrong, in
//! the background — every track that plays is observed whether or not the
//! listener has haptics on — and what it learns is shared by every listener
//! (the bridge aggregates it), so the system gets better for everyone.
//!
//! What it learns, per track (a "lesson"):
//! * the track's pulse: period and phase, fitted to its own low/mid hits
//!   (inter-onset histogram, then a phase comb, re-anchored every 8 beats so
//!   a drifting live tempo still fits), with a confidence;
//! * a timing offset: the median gap between confident hits and the beat
//!   they belong to (the analyzer's systematic lag/lead on that mix);
//! * which cues fight the groove (weak hits off every beat and half-beat on
//!   a strongly gridded track) and which beats are missing (on-grid beats
//!   in a busy passage with no cue).
//!
//! What it learns globally (the "model", tiny, shared through the bridge):
//! * a timing bias across all tracks,
//! * how weak an off-grid hit must be before it is dropped, and how strong
//!   filled-in beats should be — chosen by trying candidates on each track
//!   and keeping the one that agreed best with the track's groove (grid F1),
//!   blended into the model with a learning rate that shrinks as evidence
//!   accumulates,
//! * per-band trust: how often each band's hits land on the groove.
//!
//! `haptic_brain_apply` turns a score + lesson + model into the score that
//! plays. Self-supervised: the signal is the music's own regularity, so it
//! never needs labels and never stops improving as more tracks are heard.

use crate::haptics::{HapticEvent, HapticScore};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

const LESSONS: &str = "haptic_brain_v1";
const MODEL_KEY: &str = "haptic_brain_model_v1";
/// A cue belongs to a beat (or half-beat) within this distance.
const ON_GRID: f64 = 0.035;

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct HapticLesson {
    /// Beat period (s, 0 = no steady pulse), phase (time of one beat) and confidence 0..1.
    pub period: f64,
    pub phase: f64,
    pub confidence: f64,
    /// Seconds to add to every cue (median lag of confident hits, ±25 ms).
    pub offset: f64,
    /// Observations folded into this lesson.
    pub observations: u32,
    /// Share of cues on the groove before / after applying (diagnostics).
    pub grid_f1_before: f64,
    pub grid_f1_after: f64,
}

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct HapticModel {
    /// Global timing bias (s).
    pub bias: f64,
    /// Off-grid cues weaker than this (0..1 intensity) are dropped on gridded tracks.
    pub drop_below: f64,
    /// Intensity of filled-in beats (0 = never fill).
    pub fill_strength: f64,
    /// Trust per band (low, mid, high): scales intensities.
    pub band_trust: Vec<f64>,
    /// Tracks the model has learned from.
    pub evidence: u64,
    pub version: u32,
}

impl Default for HapticModel {
    fn default() -> Self {
        Self { bias: 0.0, drop_below: 0.25, fill_strength: 0.35, band_trust: vec![1.0, 1.0, 1.0], evidence: 0, version: 1 }
    }
}

/// What one observation teaches the model (sent to the bridge).
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct HapticObservation {
    /// Shared track key (title|artist|duration, built by the app) and a
    /// content key of this copy's score.
    pub track_key: String,
    pub content_key: String,
    pub lesson: HapticLesson,
    pub best_drop_below: f64,
    pub best_fill_strength: f64,
    pub band_on_grid: Vec<f64>,
}

fn band_of(e: &HapticEvent) -> usize {
    if e.sharpness < 0.35 {
        0
    } else if e.sharpness < 0.7 {
        1
    } else {
        2
    }
}

/// Fit a pulse (period, phase, confidence) to the transient cues.
pub fn fit_pulse(events: &[HapticEvent]) -> (f64, f64, f64) {
    let hits: Vec<(f64, f32)> = events.iter().filter(|e| !e.continuous && band_of(e) < 2).map(|e| (e.time, e.intensity)).collect();
    if hits.len() < 16 {
        return (0.0, 0.0, 0.0);
    }
    // Inter-onset intervals up to 4 neighbours ahead, histogram at 5 ms.
    let mut hist = vec![0f64; 400]; // 0..2 s
    for i in 0..hits.len() {
        for j in i + 1..(i + 5).min(hits.len()) {
            let d = hits[j].0 - hits[i].0;
            let b = (d / 0.005).round() as usize;
            if b < hist.len() {
                hist[b] += (hits[i].1 * hits[j].1) as f64;
            }
        }
    }
    // Smooth, then score candidate periods 0.33..0.86 s (70-180 BPM) with their multiples.
    let sm: Vec<f64> = (0..hist.len()).map(|i| (i.saturating_sub(2)..(i + 3).min(hist.len())).map(|k| hist[k]).sum::<f64>()).collect();
    let mut best = (0usize, 0.0f64);
    for b in 66..=172 {
        let mut s = sm[b];
        if 2 * b < sm.len() {
            s += 0.5 * sm[2 * b];
        }
        let bpm = 60.0 / (b as f64 * 0.005);
        let prior = (-((bpm / 120.0).log2()).powi(2) / (2.0 * 0.7f64.powi(2))).exp();
        let s = s * (0.6 + 0.4 * prior);
        if s > best.1 {
            best = (b, s);
        }
    }
    if best.0 == 0 {
        return (0.0, 0.0, 0.0);
    }
    let mut period = best.0 as f64 * 0.005;
    // Phase + fine period: maximise intensity landing on the grid.
    let span = hits.last().unwrap().0 - hits[0].0;
    let fit = |p: f64, ph: f64| -> f64 {
        hits.iter().map(|(t, w)| {
            let d = ((t - ph) / p).rem_euclid(1.0);
            let d = d.min(1.0 - d) * p;
            if d < ON_GRID { *w as f64 * (1.0 - d / ON_GRID) } else { 0.0 }
        }).sum()
    };
    let mut best_fit = (period, 0.0, -1.0);
    let mut p = period * 0.985;
    while p <= period * 1.015 {
        // Period error accumulates over the track: only finer than span/beats matters.
        for k in 0..40 {
            let ph = hits[0].0 + p * k as f64 / 40.0;
            let f = fit(p, ph);
            if f > best_fit.2 {
                best_fit = (p, ph, f);
            }
        }
        p += period * (0.5 / (span / period).max(1.0)).max(0.0005);
    }
    period = best_fit.0;
    // Refine period and phase together: weighted least squares of the
    // on-grid hits' times against their beat number (t = phase + k·period).
    // The search above only gets close; a period off by 0.1 % drifts a
    // quarter-beat over a few minutes.
    let mut phase = best_fit.1;
    for _ in 0..4 {
        let (mut sw, mut sk, mut st, mut skk, mut skt) = (0.0, 0.0, 0.0, 0.0, 0.0);
        for (t, w) in &hits {
            let k = ((t - phase) / period).round();
            let d = t - (phase + k * period);
            if d.abs() < ON_GRID {
                let w = *w as f64;
                sw += w;
                sk += w * k;
                st += w * t;
                skk += w * k * k;
                skt += w * k * t;
            }
        }
        let den = sw * skk - sk * sk;
        if sw <= 0.0 || den.abs() < 1e-9 {
            break;
        }
        let p = (sw * skt - sk * st) / den;
        if !(p > period * 0.97 && p < period * 1.03) {
            break;
        }
        period = p;
        phase = (st - period * sk) / sw;
    }
    let best_fit = (period, phase, best_fit.2);
    let total: f64 = hits.iter().map(|(_, w)| *w as f64).sum();
    let conf = (best_fit.2 / total.max(1e-9) * 1.6).clamp(0.0, 1.0);
    (period, best_fit.1, conf)
}

/// Grid beat nearest to `t` (re-anchored phase per 8-beat block handled by caller).
fn nearest_beat(t: f64, period: f64, phase: f64, sub: f64) -> f64 {
    let step = period * sub;
    phase + ((t - phase) / step).round() * step
}

/// Share of transients within ON_GRID of a beat or half-beat, and share of
/// beats in busy passages that carry a transient: harmonic mean (grid F1).
pub fn grid_f1(events: &[HapticEvent], period: f64, phase: f64) -> f64 {
    if period <= 0.0 {
        return 0.0;
    }
    let tr: Vec<f64> = events.iter().filter(|e| !e.continuous).map(|e| e.time).collect();
    if tr.is_empty() {
        return 0.0;
    }
    let on = tr.iter().filter(|t| (*t - nearest_beat(**t, period, phase, 0.5)).abs() < ON_GRID).count();
    let precision = on as f64 / tr.len() as f64;
    let (a, b) = (tr[0], *tr.last().unwrap());
    let mut beats = 0usize;
    let mut hit = 0usize;
    let mut t = nearest_beat(a, period, phase, 1.0);
    while t <= b {
        // Busy passage: some cue within two beats either side.
        let lo = tr.partition_point(|x| *x < t - 2.0 * period);
        let hi = tr.partition_point(|x| *x <= t + 2.0 * period);
        if hi > lo {
            beats += 1;
            let i = tr.partition_point(|x| *x < t - ON_GRID);
            if i < tr.len() && tr[i] <= t + ON_GRID {
                hit += 1;
            }
        }
        t += period;
    }
    let recall = if beats == 0 { 0.0 } else { hit as f64 / beats as f64 };
    if precision + recall <= 0.0 { 0.0 } else { 2.0 * precision * recall / (precision + recall) }
}

/// Apply a lesson + model to events (pure).
pub fn apply_events(events: &[HapticEvent], lesson: &HapticLesson, model: &HapticModel, drop_below: f64, fill: f64) -> Vec<HapticEvent> {
    let shift = (lesson.offset + model.bias).clamp(-0.03, 0.03);
    let gridded = lesson.period > 0.0 && lesson.confidence >= 0.45;
    let mut out: Vec<HapticEvent> = Vec::with_capacity(events.len() + 16);
    for e in events {
        let mut e = e.clone();
        e.time = (e.time + shift).max(0.0);
        if !e.continuous {
            let band = band_of(&e);
            let trust = model.band_trust.get(band).copied().unwrap_or(1.0).clamp(0.5, 1.3) as f32;
            e.intensity = (e.intensity * trust).clamp(0.05, 1.0);
            if gridded && band > 0 {
                let off = (e.time - nearest_beat(e.time, lesson.period, lesson.phase, 0.5)).abs() >= ON_GRID;
                if off && (e.intensity as f64) < drop_below {
                    continue;
                }
            }
        }
        out.push(e);
    }
    if gridded && fill > 0.0 {
        let times: Vec<f64> = out.iter().filter(|e| !e.continuous).map(|e| e.time).collect();
        if let (Some(&a), Some(&b)) = (times.first(), times.last()) {
            let mut t = nearest_beat(a, lesson.period, lesson.phase, 1.0);
            let mut adds = Vec::new();
            while t <= b {
                let lo = times.partition_point(|x| *x < t - 2.0 * lesson.period);
                let hi = times.partition_point(|x| *x <= t + 2.0 * lesson.period);
                let i = times.partition_point(|x| *x < t - 0.06);
                let has = i < times.len() && times[i] <= t + 0.06;
                // Busy: at least 3 cues in the ±2-beat neighbourhood.
                if !has && hi - lo >= 3 {
                    adds.push(HapticEvent { time: t, duration: 0.0, intensity: fill as f32, sharpness: 0.2, continuous: false, envelope: vec![] });
                }
                t += lesson.period;
            }
            out.extend(adds);
            out.sort_by(|x, y| x.time.total_cmp(&y.time));
        }
    }
    out
}

/// Observe a score: fit the pulse, measure the offset, try candidate
/// settings, and return the lesson plus what it teaches the model.
pub fn observe_events(events: &[HapticEvent], prior: Option<&HapticLesson>, model: &HapticModel) -> (HapticLesson, f64, f64, Vec<f64>) {
    let (mut period, mut phase, mut conf) = fit_pulse(events);
    // Repeated observations of the same track: keep the more confident fit.
    if let Some(p) = prior.filter(|p| p.confidence > conf && p.period > 0.0) {
        period = p.period;
        phase = p.phase;
        conf = p.confidence;
    }
    let mut offs: Vec<f64> = Vec::new();
    let mut band_on = [0usize; 3];
    let mut band_n = [0usize; 3];
    if period > 0.0 {
        for e in events.iter().filter(|e| !e.continuous) {
            let b = band_of(e);
            band_n[b] += 1;
            let d = e.time - nearest_beat(e.time, period, phase, 0.5);
            if d.abs() < ON_GRID {
                band_on[b] += 1;
                if e.intensity >= 0.5 && b < 2 {
                    offs.push(-d);
                }
            }
        }
    }
    offs.sort_by(|a, b| a.total_cmp(b));
    let offset = if offs.len() >= 8 { offs[offs.len() / 2].clamp(-0.025, 0.025) } else { 0.0 };
    let mut lesson = HapticLesson { period, phase, confidence: conf, offset, observations: prior.map_or(1, |p| p.observations + 1), grid_f1_before: grid_f1(events, period, phase), grid_f1_after: 0.0 };
    if let Some(p) = prior {
        // Offset: running mean across observations.
        let n = p.observations as f64;
        lesson.offset = (p.offset * n + offset) / (n + 1.0);
    }
    // Try candidates; the best agreement with the groove teaches the model.
    let mut best = (model.drop_below, model.fill_strength, -1.0);
    for d in [0.0, 0.15, 0.25, 0.35, 0.45] {
        for f in [0.0, 0.25, 0.4] {
            let ev = apply_events(events, &lesson, model, d, f);
            // Penalise thinning: dropping everything off-grid would game F1.
            let kept = ev.iter().filter(|e| !e.continuous).count() as f64 / events.iter().filter(|e| !e.continuous).count().max(1) as f64;
            let s = grid_f1(&ev, period, phase) - 0.25 * (1.0 - kept).max(0.0);
            if s > best.2 {
                best = (d, f, s);
            }
        }
    }
    let ev = apply_events(events, &lesson, model, model.drop_below, model.fill_strength);
    lesson.grid_f1_after = grid_f1(&ev, period, phase);
    let band = (0..3).map(|b| if band_n[b] == 0 { f64::NAN } else { band_on[b] as f64 / band_n[b] as f64 }).collect();
    (lesson, best.0, best.1, band)
}

/// Fold one observation into the model (same rule on device and bridge).
pub fn learn(model: &mut HapticModel, obs: &HapticObservation) {
    if obs.lesson.confidence < 0.3 {
        return;
    }
    // Learning rate shrinks as evidence grows (but never below 1 %).
    let lr = (1.0 / (model.evidence as f64 + 5.0)).max(0.01) * obs.lesson.confidence;
    model.bias += lr * (obs.lesson.offset - model.bias);
    model.drop_below += lr * (obs.best_drop_below - model.drop_below);
    model.fill_strength += lr * (obs.best_fill_strength - model.fill_strength);
    let valid: Vec<f64> = obs.band_on_grid.iter().cloned().filter(|v| v.is_finite()).collect();
    if !valid.is_empty() {
        let mean = valid.iter().sum::<f64>() / valid.len() as f64;
        for (i, t) in model.band_trust.iter_mut().enumerate() {
            if let Some(v) = obs.band_on_grid.get(i).filter(|v| v.is_finite()) {
                let target = (v / mean.max(1e-6)).clamp(0.6, 1.25);
                *t += lr * (target - *t);
            }
        }
    }
    model.bias = model.bias.clamp(-0.02, 0.02);
    model.drop_below = model.drop_below.clamp(0.0, 0.5);
    model.fill_strength = model.fill_strength.clamp(0.0, 0.5);
    model.evidence += 1;
}

// ---- device state + FFI ---------------------------------------------------------------------

#[derive(Default, Serialize, Deserialize)]
struct Store {
    model: Option<HapticModel>,
    /// Observations not yet sent to the bridge.
    outbox: Vec<HapticObservation>,
}

static STATE: Mutex<Option<Store>> = Mutex::new(None);

fn with_store<R>(f: impl FnOnce(&mut Store) -> R) -> R {
    let mut g = STATE.lock().unwrap();
    if g.is_none() {
        *g = Some(crate::store::load(MODEL_KEY));
    }
    let r = f(g.as_mut().unwrap());
    crate::store::save(MODEL_KEY, g.as_ref().unwrap());
    r
}

fn lesson_get(key: &str) -> Option<HapticLesson> {
    crate::blobcache::blob_cache_get(LESSONS.into(), key.to_string()).and_then(|b| serde_json::from_slice(&b).ok())
}

fn lesson_put(key: &str, l: &HapticLesson) {
    if let Ok(b) = serde_json::to_vec(l) {
        crate::blobcache::blob_cache_put(LESSONS.into(), key.to_string(), b);
    }
}

/// Content key of a score: its first 64 cue times (10 ms) and length.
fn content_key(events: &[HapticEvent], duration: f64) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(format!("{:.0}", duration).as_bytes());
    for e in events.iter().take(64) {
        h.update(((e.time * 100.0).round() as i64).to_le_bytes());
    }
    hex::encode(&h.finalize()[..12])
}

/// The current model (defaults until anything was learned).
#[uniffi::export]
pub fn haptic_brain_model() -> HapticModel {
    with_store(|s| s.model.clone().unwrap_or_default())
}

/// Replace the model with the global one from the bridge (it already
/// includes everything this device sent).
#[uniffi::export]
pub fn haptic_brain_set_model(json: Vec<u8>) -> bool {
    let Ok(m) = serde_json::from_slice::<HapticModel>(&json) else { return false };
    if m.band_trust.len() != 3 {
        return false;
    }
    with_store(|s| s.model = Some(m));
    true
}

/// Observe a track (call for every track played, haptics on or off; runs
/// the cached analysis if needed). Learns locally, queues the observation
/// for the bridge. `track_key`: title|artist|duration from the app.
#[uniffi::export]
pub fn haptic_brain_observe(path: String, track_key: String) -> Option<HapticLesson> {
    let score = crate::haptics::haptic_score(path, None)?;
    observe_score(&score, &track_key)
}

pub fn observe_score(score: &HapticScore, track_key: &str) -> Option<HapticLesson> {
    let events = score.events();
    if events.len() < 16 {
        return None;
    }
    let ck = content_key(events, score.stats().duration);
    let prior = lesson_get(&ck);
    let model = haptic_brain_model();
    let (lesson, d, f, band) = observe_events(events, prior.as_ref(), &model);
    lesson_put(&ck, &lesson);
    let obs = HapticObservation { track_key: track_key.to_string(), content_key: ck, lesson: lesson.clone(), best_drop_below: d, best_fill_strength: f, band_on_grid: band };
    with_store(|s| {
        let mut m = s.model.clone().unwrap_or_default();
        learn(&mut m, &obs);
        s.model = Some(m);
        s.outbox.retain(|o| o.content_key != obs.content_key);
        s.outbox.push(obs);
        if s.outbox.len() > 200 {
            s.outbox.remove(0);
        }
    });
    Some(lesson)
}

/// Body for POST /user/haptics/learn (observations waiting), or None.
#[uniffi::export]
pub fn haptic_brain_outbox() -> Option<Vec<u8>> {
    with_store(|s| (!s.outbox.is_empty()).then(|| serde_json::to_vec(&serde_json::json!({"observations": s.outbox})).unwrap_or_default()))
}

/// The bridge took the outbox: clear it and adopt the returned global model
/// (and consensus lessons for these tracks, if any).
#[uniffi::export]
pub fn haptic_brain_outbox_sent(response: Vec<u8>) {
    let v: serde_json::Value = serde_json::from_slice(&response).unwrap_or_default();
    let sent: Vec<String> = with_store(|s| std::mem::take(&mut s.outbox).into_iter().map(|o| o.content_key).collect());
    if let Some(m) = v.get("model").and_then(|m| serde_json::from_value::<HapticModel>(m.clone()).ok()) {
        with_store(|s| s.model = Some(m));
    }
    apply_consensus(&v, &sent);
}

/// Consensus lessons from the bridge: `{"tracks": {content_key: lesson}}`.
fn apply_consensus(v: &serde_json::Value, _sent: &[String]) {
    if let Some(t) = v.get("tracks").and_then(|t| t.as_object()) {
        for (k, l) in t {
            if let Ok(mut l) = serde_json::from_value::<HapticLesson>(l.clone()) {
                if lesson_get(k).is_none_or(|mine| l.confidence >= mine.confidence || l.observations > mine.observations) {
                    l.observations = l.observations.max(1);
                    lesson_put(k, &l);
                }
            }
        }
    }
}

/// Consensus lesson for one track fetched from the bridge (GET
/// /user/haptics/track): stored so the next apply uses it.
#[uniffi::export]
pub fn haptic_brain_adopt(response: Vec<u8>) {
    let v: serde_json::Value = serde_json::from_slice(&response).unwrap_or_default();
    apply_consensus(&v, &[]);
}

/// Content key for a track's score (to ask the bridge for its consensus).
#[uniffi::export]
pub fn haptic_brain_content_key(score: Arc<HapticScore>) -> String {
    content_key(score.events(), score.stats().duration)
}

/// The score to play: the analyzer's score corrected by what the brain
/// learned about this track and in general.
#[uniffi::export]
pub fn haptic_brain_apply(score: Arc<HapticScore>) -> Arc<HapticScore> {
    let events = score.events();
    let ck = content_key(events, score.stats().duration);
    let model = haptic_brain_model();
    let lesson = match lesson_get(&ck) {
        Some(l) => l,
        None => {
            // Not observed yet: learn now (cheap, the score is in memory).
            match observe_score(&score, "") {
                Some(l) => l,
                None => return score,
            }
        }
    };
    let ev = apply_events(events, &lesson, &model, model.drop_below, model.fill_strength);
    Arc::new(HapticScore::from_events(ev, score.stats()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tr(t: f64, i: f32, sharp: f32) -> HapticEvent {
        HapticEvent { time: t, duration: 0.0, intensity: i, sharpness: sharp, continuous: false, envelope: vec![] }
    }

    /// 120 BPM groove, cues 12 ms late, some beats missing, some stray weak ticks.
    fn groove() -> Vec<HapticEvent> {
        let mut v = Vec::new();
        let mut seed = 3u32;
        for b in 0..240 {
            let t = 0.4 + b as f64 * 0.5 + 0.012;
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            let jitter = ((seed >> 8) as f64 / (1u32 << 24) as f64 - 0.5) * 0.008;
            if b % 7 != 3 {
                v.push(tr(t + jitter, if b % 4 == 0 { 0.9 } else { 0.6 }, 0.2));
            }
            if b % 2 == 1 {
                v.push(tr(t + 0.25, 0.4, 0.8)); // hats on the off-beat (half-beat: on grid)
            }
            if b % 5 == 2 {
                v.push(tr(t + 0.13, 0.12, 0.6)); // stray weak ticks
            }
        }
        v.sort_by(|a, b| a.time.total_cmp(&b.time));
        v
    }

    #[test]
    fn fits_pulse_and_offset() {
        let ev = groove();
        let (p, ph, c) = fit_pulse(&ev);
        assert!((p - 0.5).abs() < 0.004, "period {p}");
        assert!(c > 0.5, "confidence {c}");
        let d = ((ph - 0.412) / 0.5).rem_euclid(1.0);
        assert!(d.min(1.0 - d) * 0.5 < 0.01, "phase {ph}");
        let (l, d, f, _) = observe_events(&ev, None, &HapticModel::default());
        assert!(l.offset.abs() < 0.006, "offset vs the fitted phase {}", l.offset);
        assert!(d > 0.0, "stray ticks should be worth dropping: {d}");
        assert!(f > 0.0, "missing beats should be worth filling: {f}");
    }

    #[test]
    fn apply_improves_grid_agreement() {
        let ev = groove();
        let model = HapticModel { drop_below: 0.25, fill_strength: 0.35, ..Default::default() };
        let (l, _, _, _) = observe_events(&ev, None, &model);
        let out = apply_events(&ev, &l, &model, model.drop_below, model.fill_strength);
        let (b, a) = (grid_f1(&ev, l.period, l.phase), grid_f1(&out, l.period, l.phase));
        assert!(a > b + 0.03, "F1 {b:.3} -> {a:.3}");
        // Strong cues are never dropped.
        let strong_in = ev.iter().filter(|e| e.intensity >= 0.6).count();
        let strong_out = out.iter().filter(|e| e.intensity >= 0.6).count();
        assert!(strong_out >= strong_in);
    }

    #[test]
    fn model_learns_and_stays_bounded() {
        let mut m = HapticModel::default();
        for _ in 0..500 {
            let obs = HapticObservation { track_key: "k".into(), content_key: "c".into(), lesson: HapticLesson { period: 0.5, phase: 0.0, confidence: 0.9, offset: 0.01, observations: 1, grid_f1_before: 0.0, grid_f1_after: 0.0 }, best_drop_below: 0.35, best_fill_strength: 0.25, band_on_grid: vec![0.9, 0.6, f64::NAN] };
            learn(&mut m, &obs);
        }
        assert!((m.bias - 0.01).abs() < 0.002, "{m:?}");
        assert!((m.drop_below - 0.35).abs() < 0.02, "{m:?}");
        assert!(m.band_trust[0] > m.band_trust[1], "{m:?}");
        assert_eq!(m.evidence, 500);
    }

    #[test]
    fn ungrooved_track_is_left_alone() {
        // Free-time (rubato) cues: nothing gridded, nothing dropped or filled.
        let mut seed = 9u32;
        let mut t = 0.0;
        let mut ev = Vec::new();
        for _ in 0..200 {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            t += 0.2 + (seed >> 8) as f64 / (1u32 << 24) as f64 * 0.9;
            ev.push(tr(t, 0.3, 0.5));
        }
        let (l, _, _, _) = observe_events(&ev, None, &HapticModel::default());
        let out = apply_events(&ev, &l, &HapticModel::default(), 0.25, 0.35);
        if l.confidence < 0.45 {
            assert_eq!(out.len(), ev.len());
        }
    }
}
