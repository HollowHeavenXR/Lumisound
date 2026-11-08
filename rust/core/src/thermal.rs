//! Heat governor policy: how much optional work the app may do given the
//! device's thermal state, Low Power Mode and whether it's in the foreground.
//! Optional = visual motion (Ken Burns, aura), spectrum analysis rate, and
//! deferrable analysis jobs. Playback itself is never throttled.

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThermalLevel {
    Nominal,
    Fair,
    Serious,
    Critical,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ThermalPolicy {
    /// Spectrum analysis rate while a visualizer is on screen (0 = off).
    pub visualizer_hz: f64,
    /// Rate for features that only need slow levels (smart crossfade,
    /// auto EQ) — and the cap whenever no visualizer is visible.
    pub analysis_hz: f64,
    /// Animated backgrounds (Ken Burns, aura) may move.
    pub background_motion: bool,
    /// Frame rate for the animated backgrounds when they move.
    pub motion_fps: f64,
    /// Postpone deferrable heavy jobs (pre-analysis, mood analysis,
    /// conversion sweeps, metadata refresh).
    pub defer_heavy_work: bool,
    /// Short label for logs / telemetry.
    pub label: String,
}

/// `thermal`: ProcessInfo.ThermalState raw value (0 nominal … 3 critical).
#[uniffi::export]
pub fn thermal_level(raw: i64) -> ThermalLevel {
    match raw {
        i64::MIN..=0 => ThermalLevel::Nominal,
        1 => ThermalLevel::Fair,
        2 => ThermalLevel::Serious,
        _ => ThermalLevel::Critical,
    }
}

#[uniffi::export]
pub fn thermal_policy(level: ThermalLevel, low_power: bool, foreground: bool) -> ThermalPolicy {
    let (mut viz, mut analysis, mut motion, mut fps, mut defer) = match level {
        ThermalLevel::Nominal => (30.0, 5.0, true, 12.0, false),
        ThermalLevel::Fair => (20.0, 4.0, true, 8.0, false),
        ThermalLevel::Serious => (10.0, 2.0, false, 0.0, true),
        ThermalLevel::Critical => (0.0, 1.0, false, 0.0, true),
    };
    if low_power {
        viz = f64::min(viz, 15.0);
        analysis = f64::min(analysis, 2.0);
        motion = false;
        fps = 0.0;
        defer = true;
    }
    if !foreground {
        // Nothing is on screen: no visualizer, no motion; slow levels only.
        viz = 0.0;
        analysis = f64::min(analysis, 2.0);
        motion = false;
        fps = 0.0;
    }
    let label = format!(
        "{}{}{}",
        match level {
            ThermalLevel::Nominal => "nominal",
            ThermalLevel::Fair => "fair",
            ThermalLevel::Serious => "serious",
            ThermalLevel::Critical => "critical",
        },
        if low_power { "+lowpower" } else { "" },
        if foreground { "" } else { "+background" }
    );
    ThermalPolicy { visualizer_hz: viz, analysis_hz: analysis, background_motion: motion, motion_fps: fps, defer_heavy_work: defer, label }
}

/// Rate the spectrum analyzer should run at: the visualizer rate while one
/// is visible, otherwise the slow-levels rate if any feature needs levels.
#[uniffi::export]
pub fn thermal_analyzer_hz(policy: ThermalPolicy, visualizer_visible: bool, levels_needed: bool) -> f64 {
    if visualizer_visible && policy.visualizer_hz > 0.0 {
        policy.visualizer_hz
    } else if levels_needed || visualizer_visible {
        policy.analysis_hz
    } else {
        0.0
    }
}

// ---- the governor (state, analyzer rate limit, headroom waits, stats) ---------------------------

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

/// Analysis reasons that draw on screen (need a smooth rate); the rest
/// (auto EQ, smart crossfade) only read slow levels.
const VISUAL_REASONS: &[&str] = &["liveSpectrumUI", "galleryReactiveBackground"];

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ThermalChange {
    pub policy: ThermalPolicy,
    /// The thermal state itself (or Low Power Mode) changed: worth a telemetry event.
    pub should_report: bool,
    /// "warning" at serious/critical, else "info".
    pub level: String,
    pub previous_label: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct JobDeferrals {
    pub job: String,
    pub deferred: u32,
    pub skipped: u32,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ThermalStats {
    pub policy: ThermalPolicy,
    pub thermal_raw: i64,
    pub low_power: bool,
    pub foreground: bool,
    /// Seconds spent at nominal / fair / serious / critical since launch.
    pub seconds_by_level: Vec<f64>,
    pub policy_changes: u32,
    pub analyzer_hz: f64,
    pub analysis_reasons: Vec<String>,
    pub deferrals: Vec<JobDeferrals>,
}

struct GovState {
    thermal_raw: i64,
    low_power: bool,
    foreground: bool,
    policy: ThermalPolicy,
    level_since: Instant,
    seconds_by_level: [f64; 4],
    policy_changes: u32,
    reasons: Vec<String>,
    analyzer_hz: f64,
    deferrals: HashMap<String, (u32, u32)>,
}

/// Heat governor. One per process (`thermal_governor()`); Swift feeds it the
/// system signals and asks it what optional work may run.
#[derive(uniffi::Object)]
pub struct ThermalGovernor {
    st: Mutex<GovState>,
    // Read per audio buffer on the tap thread: lock-free.
    analysis_off: AtomicBool,
    min_interval_ns: AtomicU64,
    last_sample_ns: AtomicU64,
    defer_heavy: AtomicBool,
    epoch: Instant,
}

static GOVERNOR: LazyLock<Arc<ThermalGovernor>> = LazyLock::new(|| {
    let policy = thermal_policy(ThermalLevel::Nominal, false, true);
    Arc::new(ThermalGovernor {
        st: Mutex::new(GovState {
            thermal_raw: 0,
            low_power: false,
            foreground: true,
            policy,
            level_since: Instant::now(),
            seconds_by_level: [0.0; 4],
            policy_changes: 0,
            reasons: vec![],
            analyzer_hz: 0.0,
            deferrals: HashMap::new(),
        }),
        analysis_off: AtomicBool::new(true),
        min_interval_ns: AtomicU64::new(u64::MAX),
        last_sample_ns: AtomicU64::new(0),
        defer_heavy: AtomicBool::new(false),
        epoch: Instant::now(),
    })
});

/// The process-wide governor.
#[uniffi::export]
pub fn thermal_governor() -> Arc<ThermalGovernor> {
    GOVERNOR.clone()
}

fn level_index(raw: i64) -> usize {
    raw.clamp(0, 3) as usize
}

impl ThermalGovernor {
    fn apply_rate(&self, st: &mut GovState) {
        let visible = st.reasons.iter().any(|r| VISUAL_REASONS.contains(&r.as_str()));
        let levels = st.reasons.iter().any(|r| !VISUAL_REASONS.contains(&r.as_str()));
        let hz = thermal_analyzer_hz(st.policy.clone(), visible, levels);
        st.analyzer_hz = hz;
        self.analysis_off.store(hz <= 0.0, Relaxed);
        self.min_interval_ns.store(if hz > 0.0 { (1e9 / hz) as u64 } else { u64::MAX }, Relaxed);
        self.defer_heavy.store(st.policy.defer_heavy_work, Relaxed);
    }

    fn note_deferral(&self, job: &str, skipped: bool) {
        let mut st = self.st.lock().unwrap();
        let e = st.deferrals.entry(job.to_string()).or_insert((0, 0));
        if skipped { e.1 += 1 } else { e.0 += 1 }
    }
}

#[uniffi::export]
impl ThermalGovernor {
    /// New system signals (ProcessInfo thermal state raw value, Low Power
    /// Mode, app in foreground). Returns the change when the policy moved.
    pub fn update(&self, thermal_raw: i64, low_power: bool, foreground: bool) -> Option<ThermalChange> {
        let mut st = self.st.lock().unwrap();
        let now = Instant::now();
        let idx = level_index(st.thermal_raw);
        st.seconds_by_level[idx] += now.duration_since(st.level_since).as_secs_f64();
        st.level_since = now;
        let thermal_changed = thermal_raw != st.thermal_raw || low_power != st.low_power;
        st.thermal_raw = thermal_raw;
        st.low_power = low_power;
        st.foreground = foreground;
        let next = thermal_policy(thermal_level(thermal_raw), low_power, foreground);
        if next == st.policy {
            return None;
        }
        let previous_label = std::mem::replace(&mut st.policy, next.clone()).label;
        st.policy_changes += 1;
        self.apply_rate(&mut st);
        Some(ThermalChange { policy: next, should_report: thermal_changed, level: if thermal_raw >= 2 { "warning".into() } else { "info".into() }, previous_label })
    }

    pub fn policy(&self) -> ThermalPolicy {
        self.st.lock().unwrap().policy.clone()
    }

    /// Which features currently want spectrum analysis (visualizer names
    /// like "liveSpectrumUI", or level readers like "autoEQ").
    pub fn set_analysis_reasons(&self, reasons: Vec<String>) {
        let mut st = self.st.lock().unwrap();
        st.reasons = reasons;
        self.apply_rate(&mut st);
    }

    /// Per audio buffer, on the tap thread: true when this buffer should be
    /// analyzed. Lock-free; most buffers are dropped here before any copying.
    pub fn wants_sample(&self) -> bool {
        if self.analysis_off.load(Relaxed) {
            return false;
        }
        let now = self.epoch.elapsed().as_nanos() as u64;
        let last = self.last_sample_ns.load(Relaxed);
        if now.saturating_sub(last) < self.min_interval_ns.load(Relaxed) {
            return false;
        }
        // One winner per interval even if two threads ask at once.
        self.last_sample_ns.compare_exchange(last, now, Relaxed, Relaxed).is_ok()
    }

    /// Deferrable heavy jobs check this before starting.
    pub fn defer_heavy_work(&self) -> bool {
        self.defer_heavy.load(Relaxed)
    }

    /// Waits (checking every 30 s) for thermal headroom, up to `max_wait_secs`.
    /// False = still hot: skip this round (the job's own schedule retries).
    pub async fn wait_for_headroom(&self, job: String, max_wait_secs: f64) -> bool {
        if !self.defer_heavy_work() {
            return true;
        }
        self.note_deferral(&job, false);
        let deadline = Instant::now() + Duration::from_secs_f64(max_wait_secs.max(0.0));
        let gov = thermal_governor();
        crate::on_rt(async move {
            loop {
                if !gov.defer_heavy_work() {
                    return true;
                }
                if Instant::now() >= deadline {
                    gov.note_deferral(&job, true);
                    return false;
                }
                tokio::time::sleep(Duration::from_secs(30).min(deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(10)))).await;
            }
        })
        .await
    }

    /// For telemetry: current state, time at each heat level, deferrals per job.
    pub fn stats(&self) -> ThermalStats {
        let st = self.st.lock().unwrap();
        let mut secs = st.seconds_by_level;
        secs[level_index(st.thermal_raw)] += st.level_since.elapsed().as_secs_f64();
        let mut deferrals: Vec<JobDeferrals> = st.deferrals.iter().map(|(j, (d, s))| JobDeferrals { job: j.clone(), deferred: *d, skipped: *s }).collect();
        deferrals.sort_by(|a, b| a.job.cmp(&b.job));
        ThermalStats {
            policy: st.policy.clone(),
            thermal_raw: st.thermal_raw,
            low_power: st.low_power,
            foreground: st.foreground,
            seconds_by_level: secs.to_vec(),
            policy_changes: st.policy_changes,
            analyzer_hz: st.analyzer_hz,
            analysis_reasons: st.reasons.clone(),
            deferrals,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn policy() {
        let n = thermal_policy(ThermalLevel::Nominal, false, true);
        assert!(n.background_motion && n.visualizer_hz == 30.0 && !n.defer_heavy_work);
        let s = thermal_policy(ThermalLevel::Serious, false, true);
        assert!(!s.background_motion && s.defer_heavy_work && s.visualizer_hz == 10.0);
        let bg = thermal_policy(ThermalLevel::Nominal, false, false);
        assert!(bg.visualizer_hz == 0.0 && !bg.background_motion && bg.label == "nominal+background");
        assert_eq!(thermal_analyzer_hz(bg.clone(), true, false), 2.0);
        assert_eq!(thermal_analyzer_hz(bg, false, false), 0.0);
        let lp = thermal_policy(ThermalLevel::Fair, true, true);
        assert!(!lp.background_motion && lp.defer_heavy_work && lp.visualizer_hz == 15.0);
        assert_eq!(thermal_level(3), ThermalLevel::Critical);
    }

    #[test]
    fn governor_state_rate_and_headroom() {
        let g = ThermalGovernor {
            st: Mutex::new(GovState { thermal_raw: 0, low_power: false, foreground: true, policy: thermal_policy(ThermalLevel::Nominal, false, true), level_since: Instant::now(), seconds_by_level: [0.0; 4], policy_changes: 0, reasons: vec![], analyzer_hz: 0.0, deferrals: HashMap::new() }),
            analysis_off: AtomicBool::new(true),
            min_interval_ns: AtomicU64::new(u64::MAX),
            last_sample_ns: AtomicU64::new(0),
            defer_heavy: AtomicBool::new(false),
            epoch: Instant::now(),
        };
        assert!(!g.wants_sample(), "nothing asked for analysis");
        g.set_analysis_reasons(vec!["liveSpectrumUI".into()]);
        assert_eq!(g.stats().analyzer_hz, 30.0);
        std::thread::sleep(Duration::from_millis(40));
        assert!(g.wants_sample());
        assert!(!g.wants_sample(), "rate limited");
        // Background: visualizer hidden -> slow levels only.
        let c = g.update(0, false, false).unwrap();
        assert!(!c.should_report && c.policy.label == "nominal+background");
        assert_eq!(g.stats().analyzer_hz, 2.0);
        assert!(g.update(0, false, false).is_none(), "no change, no event");
        // Heats up: reported, heavy work deferred.
        let c = g.update(2, false, true).unwrap();
        assert!(c.should_report && c.level == "warning" && g.defer_heavy_work());
        assert_eq!(g.stats().analyzer_hz, 10.0);
        g.note_deferral("mood", false);
        g.note_deferral("mood", true);
        let s = g.stats();
        assert_eq!(s.deferrals, vec![JobDeferrals { job: "mood".into(), deferred: 1, skipped: 1 }]);
        assert_eq!(s.policy_changes, 2);
        assert_eq!(s.seconds_by_level.len(), 4);
    }
}
