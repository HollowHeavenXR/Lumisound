//! Engine health telemetry: everything that can make playback stutter,
//! glitch or fail, measured where it happens.
//!
//! The realtime side (mixer / output callback) only bumps atomics and pushes
//! `Incident`s through the existing lock-free event queue, so instrumentation
//! can never itself cause a dropout. The event thread timestamps incidents
//! into a bounded log; `report()` turns counters + incidents into a compact,
//! rate-limited summary the app uploads.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

/// What was going on when an incident happened.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PlaybackPhase {
    /// Steady playback of the current track.
    Playing,
    /// The first audio after a load or seek.
    Starting,
    /// Gapless hand-over to the queued track.
    Handover,
    /// Inside a crossfade (either deck).
    Crossfade,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum IncidentKind {
    /// The playing deck's buffer ran dry: audible silence/stutter. `value` = ms of silence.
    Underrun,
    /// A render callback took longer than its buffer's duration (risk of an
    /// OS-level glitch). `value` = callback ms, `budget_ms` = the buffer's duration.
    CallbackOverrun,
    /// The OS called the audio callback much later than expected (the
    /// device glitched or the process was starved). `value` = gap ms.
    LateCallback,
    /// The callback couldn't take the mixer lock and output silence. `value` = buffers.
    LockMiss,
    /// NaN/Inf samples reached the output (replaced with silence). `value` = samples.
    NonFinite,
    /// Output hit the safety clipper. `value` = samples clipped in the episode.
    Clipping,
    /// Corrupt packets skipped by the decoder. `value` = packets.
    DecodeErrors,
    /// The decoder failed before producing audio (track couldn't play).
    DeckFailed,
    /// The decoder stopped (read error) well before the track's end. `value` = seconds missing.
    DecodeStoppedEarly,
    /// First audio after load/seek took long. `value` = ms.
    SlowStart,
    /// The decoder ran under 4x real time (a deck may starve). `value` = speed x real time.
    SlowDecode,
    /// The output device reported an error (route lost, device reset).
    OutputError,
    /// The output stream could not be started.
    OutputStartFailed,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct EngineIncident {
    pub kind: IncidentKind,
    pub phase: PlaybackPhase,
    pub deck_id: u64,
    /// Track position (s) when it happened.
    pub position: f64,
    pub value: f64,
    pub budget_ms: f64,
    pub message: Option<String>,
    /// Unix seconds.
    pub at: f64,
}

/// Cumulative counters since start (or `reset`).
#[derive(uniffi::Record, Clone, Debug, Default, PartialEq)]
pub struct EngineHealth {
    pub sample_rate: u32,
    pub buffer_frames: u32,
    pub callbacks: u64,
    pub playing_seconds: f64,
    /// Mean / worst render time as a fraction of the buffer's duration.
    pub callback_load_avg: f64,
    pub callback_load_max: f64,
    pub callback_overruns: u64,
    pub late_callbacks: u64,
    pub lock_misses: u64,
    pub underrun_events: u64,
    pub underrun_ms: f64,
    pub nonfinite_samples: u64,
    pub clipped_samples: u64,
    pub decode_errors: u64,
    pub deck_failures: u64,
    pub decode_stopped_early: u64,
    pub slow_starts: u64,
    pub slow_decodes: u64,
    pub output_errors: u64,
    /// Worst first-audio latency after a load/seek (ms).
    pub start_latency_max_ms: f64,
    /// Slowest decoder speed seen (x real time; 0 = not measured yet).
    pub decode_speed_min: f64,
    pub incidents_dropped: u64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct IncidentSummary {
    pub kind: IncidentKind,
    pub phase: PlaybackPhase,
    pub count: u32,
    pub total: f64,
    pub worst: f64,
    pub first_at: f64,
    pub last_at: f64,
    pub example: EngineIncident,
}

/// Since the last `report()`: counter deltas, incidents grouped by kind and
/// phase, and whether anything is worth uploading.
#[derive(uniffi::Record, Clone, Debug)]
pub struct EngineReport {
    pub delta: EngineHealth,
    pub totals: EngineHealth,
    pub groups: Vec<IncidentSummary>,
    /// Something audible or failing happened (underrun, failure, output error…).
    pub has_problems: bool,
    /// Needs immediate attention (track failed, output lost, long dropout).
    pub severe: bool,
    pub seconds: f64,
}

#[derive(Default)]
pub struct Health {
    pub sample_rate: AtomicU64,
    pub buffer_frames: AtomicU64,
    pub callbacks: AtomicU64,
    pub playing_frames: AtomicU64,
    pub load_sum_micro: AtomicU64,
    pub load_max_micro: AtomicU64,
    pub callback_overruns: AtomicU64,
    pub late_callbacks: AtomicU64,
    pub lock_misses: AtomicU64,
    pub underrun_events: AtomicU64,
    pub underrun_frames: AtomicU64,
    pub nonfinite_samples: AtomicU64,
    pub clipped_samples: AtomicU64,
    pub decode_errors: AtomicU64,
    pub deck_failures: AtomicU64,
    pub decode_stopped_early: AtomicU64,
    pub slow_starts: AtomicU64,
    pub slow_decodes: AtomicU64,
    pub output_errors: AtomicU64,
    pub start_latency_max_us: AtomicU64,
    pub decode_speed_min_milli: AtomicU64,
    pub incidents_dropped: AtomicU64,
    log: Mutex<VecDeque<EngineIncident>>,
    last: Mutex<Option<(EngineHealth, f64)>>,
}

const LOG_CAP: usize = 256;
/// Thresholds.
pub const SLOW_START_MS: f64 = 400.0;
pub const SLOW_DECODE_X: f64 = 4.0;

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub fn atomic_max(a: &AtomicU64, v: u64) {
    let mut cur = a.load(Relaxed);
    while v > cur {
        match a.compare_exchange_weak(cur, v, Relaxed, Relaxed) {
            Ok(_) => return,
            Err(c) => cur = c,
        }
    }
}

/// Lowest non-zero value wins (0 = unset).
pub fn atomic_min_nonzero(a: &AtomicU64, v: u64) {
    if v == 0 {
        return;
    }
    let mut cur = a.load(Relaxed);
    while cur == 0 || v < cur {
        match a.compare_exchange_weak(cur, v, Relaxed, Relaxed) {
            Ok(_) => return,
            Err(c) => cur = c,
        }
    }
}

impl Health {
    /// Called off the realtime thread (event thread, output error callback).
    pub fn record(&self, mut i: EngineIncident) {
        if i.at == 0.0 {
            i.at = now();
        }
        let mut log = self.log.lock().unwrap();
        if log.len() >= LOG_CAP {
            log.pop_front();
            self.incidents_dropped.fetch_add(1, Relaxed);
        }
        log.push_back(i);
    }

    pub fn snapshot(&self) -> EngineHealth {
        let rate = self.sample_rate.load(Relaxed).max(1) as f64;
        let cb = self.callbacks.load(Relaxed);
        EngineHealth {
            sample_rate: self.sample_rate.load(Relaxed) as u32,
            buffer_frames: self.buffer_frames.load(Relaxed) as u32,
            callbacks: cb,
            playing_seconds: self.playing_frames.load(Relaxed) as f64 / rate,
            callback_load_avg: if cb > 0 { self.load_sum_micro.load(Relaxed) as f64 / 1e6 / cb as f64 } else { 0.0 },
            callback_load_max: self.load_max_micro.load(Relaxed) as f64 / 1e6,
            callback_overruns: self.callback_overruns.load(Relaxed),
            late_callbacks: self.late_callbacks.load(Relaxed),
            lock_misses: self.lock_misses.load(Relaxed),
            underrun_events: self.underrun_events.load(Relaxed),
            underrun_ms: self.underrun_frames.load(Relaxed) as f64 / rate * 1000.0,
            nonfinite_samples: self.nonfinite_samples.load(Relaxed),
            clipped_samples: self.clipped_samples.load(Relaxed),
            decode_errors: self.decode_errors.load(Relaxed),
            deck_failures: self.deck_failures.load(Relaxed),
            decode_stopped_early: self.decode_stopped_early.load(Relaxed),
            slow_starts: self.slow_starts.load(Relaxed),
            slow_decodes: self.slow_decodes.load(Relaxed),
            output_errors: self.output_errors.load(Relaxed),
            start_latency_max_ms: self.start_latency_max_us.load(Relaxed) as f64 / 1000.0,
            decode_speed_min: self.decode_speed_min_milli.load(Relaxed) as f64 / 1000.0,
            incidents_dropped: self.incidents_dropped.load(Relaxed),
        }
    }

    pub fn incidents(&self) -> Vec<EngineIncident> {
        self.log.lock().unwrap().iter().cloned().collect()
    }

    /// Counter deltas + grouped incidents since the previous call; drains the log.
    pub fn report(&self) -> EngineReport {
        let totals = self.snapshot();
        let t = now();
        let (prev, since) = self.last.lock().unwrap().replace((totals.clone(), t)).unwrap_or((EngineHealth { sample_rate: totals.sample_rate, buffer_frames: totals.buffer_frames, ..Default::default() }, t));
        let delta = diff(&totals, &prev);
        let incidents: Vec<EngineIncident> = self.log.lock().unwrap().drain(..).collect();
        let groups = group(&incidents);
        let severe = incidents.iter().any(|i| {
            matches!(i.kind, IncidentKind::DeckFailed | IncidentKind::OutputError | IncidentKind::OutputStartFailed | IncidentKind::DecodeStoppedEarly) || (i.kind == IncidentKind::Underrun && i.value >= 250.0)
        });
        let has_problems = severe
            || delta.underrun_events > 0
            || delta.callback_overruns > 0
            || delta.lock_misses > 0
            || delta.nonfinite_samples > 0
            || delta.decode_errors > 0
            || delta.slow_decodes > 0
            || delta.late_callbacks > 2
            || delta.slow_starts > 0;
        EngineReport { delta, totals, groups, has_problems, severe, seconds: (t - since).max(0.0) }
    }

    pub fn reset(&self) {
        for a in [
            &self.callbacks, &self.playing_frames, &self.load_sum_micro, &self.load_max_micro, &self.callback_overruns, &self.late_callbacks, &self.lock_misses, &self.underrun_events, &self.underrun_frames,
            &self.nonfinite_samples, &self.clipped_samples, &self.decode_errors, &self.deck_failures, &self.decode_stopped_early, &self.slow_starts, &self.slow_decodes, &self.output_errors,
            &self.start_latency_max_us, &self.decode_speed_min_milli, &self.incidents_dropped,
        ] {
            a.store(0, Relaxed);
        }
        self.log.lock().unwrap().clear();
        *self.last.lock().unwrap() = None;
    }
}

fn diff(a: &EngineHealth, b: &EngineHealth) -> EngineHealth {
    EngineHealth {
        sample_rate: a.sample_rate,
        buffer_frames: a.buffer_frames,
        callbacks: a.callbacks.saturating_sub(b.callbacks),
        playing_seconds: (a.playing_seconds - b.playing_seconds).max(0.0),
        callback_load_avg: a.callback_load_avg,
        callback_load_max: a.callback_load_max,
        callback_overruns: a.callback_overruns.saturating_sub(b.callback_overruns),
        late_callbacks: a.late_callbacks.saturating_sub(b.late_callbacks),
        lock_misses: a.lock_misses.saturating_sub(b.lock_misses),
        underrun_events: a.underrun_events.saturating_sub(b.underrun_events),
        underrun_ms: (a.underrun_ms - b.underrun_ms).max(0.0),
        nonfinite_samples: a.nonfinite_samples.saturating_sub(b.nonfinite_samples),
        clipped_samples: a.clipped_samples.saturating_sub(b.clipped_samples),
        decode_errors: a.decode_errors.saturating_sub(b.decode_errors),
        deck_failures: a.deck_failures.saturating_sub(b.deck_failures),
        decode_stopped_early: a.decode_stopped_early.saturating_sub(b.decode_stopped_early),
        slow_starts: a.slow_starts.saturating_sub(b.slow_starts),
        slow_decodes: a.slow_decodes.saturating_sub(b.slow_decodes),
        output_errors: a.output_errors.saturating_sub(b.output_errors),
        start_latency_max_ms: a.start_latency_max_ms,
        decode_speed_min: a.decode_speed_min,
        incidents_dropped: a.incidents_dropped.saturating_sub(b.incidents_dropped),
    }
}

fn group(incidents: &[EngineIncident]) -> Vec<IncidentSummary> {
    let mut out: Vec<IncidentSummary> = Vec::new();
    for i in incidents {
        match out.iter_mut().find(|g| g.kind == i.kind && g.phase == i.phase) {
            Some(g) => {
                g.count += 1;
                g.total += i.value;
                if i.value > g.worst {
                    g.worst = i.value;
                    g.example = i.clone();
                }
                g.last_at = i.at;
            }
            None => out.push(IncidentSummary { kind: i.kind, phase: i.phase, count: 1, total: i.value, worst: i.value, first_at: i.at, last_at: i.at, example: i.clone() }),
        }
    }
    out.sort_by(|a, b| b.count.cmp(&a.count));
    out
}

pub fn kind_name(k: IncidentKind) -> &'static str {
    match k {
        IncidentKind::Underrun => "underrun",
        IncidentKind::CallbackOverrun => "callback_overrun",
        IncidentKind::LateCallback => "late_callback",
        IncidentKind::LockMiss => "lock_miss",
        IncidentKind::NonFinite => "non_finite",
        IncidentKind::Clipping => "clipping",
        IncidentKind::DecodeErrors => "decode_errors",
        IncidentKind::DeckFailed => "deck_failed",
        IncidentKind::DecodeStoppedEarly => "decode_stopped_early",
        IncidentKind::SlowStart => "slow_start",
        IncidentKind::SlowDecode => "slow_decode",
        IncidentKind::OutputError => "output_error",
        IncidentKind::OutputStartFailed => "output_start_failed",
    }
}

pub fn phase_name(p: PlaybackPhase) -> &'static str {
    match p {
        PlaybackPhase::Playing => "playing",
        PlaybackPhase::Starting => "starting",
        PlaybackPhase::Handover => "handover",
        PlaybackPhase::Crossfade => "crossfade",
    }
}

/// The report as JSON for the app's event log (`/api/log-event` detail):
/// counter deltas, totals that matter, and each incident group with its
/// worst example.
#[uniffi::export]
pub fn engine_report_json(report: EngineReport) -> String {
    let g: Vec<serde_json::Value> = report
        .groups
        .iter()
        .map(|g| {
            serde_json::json!({
                "kind": kind_name(g.kind), "phase": phase_name(g.phase), "count": g.count,
                "total": round(g.total), "worst": round(g.worst),
                "worstAt": round(g.example.position), "deck": g.example.deck_id,
                "budgetMs": round(g.example.budget_ms), "message": g.example.message,
            })
        })
        .collect();
    let d = &report.delta;
    serde_json::json!({
        "windowSeconds": round(report.seconds),
        "playingSeconds": round(d.playing_seconds),
        "sampleRate": d.sample_rate, "bufferFrames": d.buffer_frames,
        "callbacks": d.callbacks,
        "callbackLoadAvg": round(d.callback_load_avg), "callbackLoadMax": round(d.callback_load_max),
        "callbackOverruns": d.callback_overruns, "lateCallbacks": d.late_callbacks, "lockMisses": d.lock_misses,
        "underruns": d.underrun_events, "underrunMs": round(d.underrun_ms),
        "nonFiniteSamples": d.nonfinite_samples, "clippedSamples": d.clipped_samples,
        "decodeErrors": d.decode_errors, "deckFailures": d.deck_failures, "decodeStoppedEarly": d.decode_stopped_early,
        "slowStarts": d.slow_starts, "startLatencyMaxMs": round(report.totals.start_latency_max_ms),
        "slowDecodes": d.slow_decodes, "decodeSpeedMin": round(report.totals.decode_speed_min),
        "outputErrors": d.output_errors, "incidentsDropped": d.incidents_dropped,
        "severe": report.severe, "groups": g,
    })
    .to_string()
}

fn round(x: f64) -> f64 {
    (x * 100.0).round() / 100.0
}
