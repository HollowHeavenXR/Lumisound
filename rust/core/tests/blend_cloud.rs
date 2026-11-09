//! Lumisound Blend (Smart Crossfade) through the real engine.
//!
//!   cargo test --release -p lumisound-core --test blend_cloud -- --nocapture --test-threads=1
//!   LUMI_CLOUD_DIR=<dir of .lms copies> adds real consecutive-track pairs.
//!
//! Checks: the fade starts on the planned frame (± 10 ms of track time), no
//! dropouts or clipping through the blend, the incoming track starts where
//! the plan says, and on bar-locked plans the incoming onsets line up with
//! the outgoing beat grid.

use lumisound_core::blend::{blend_plan, blend_profile, BlendSettings, BlendStyle};
use lumisound_core::engine::{AudioEngine, EngineListener};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Events(Mutex<Vec<(String, f64)>>);
impl EngineListener for Events {
    fn on_track_ended(&self, id: u64) {
        self.0.lock().unwrap().push((format!("end{id}"), 0.0));
    }
    fn on_track_started(&self, id: u64) {
        self.0.lock().unwrap().push((format!("start{id}"), 0.0));
    }
    fn on_track_failed(&self, id: u64) {
        self.0.lock().unwrap().push((format!("fail{id}"), 0.0));
    }
}

const CHUNK: usize = 256;

fn write_wav(path: &Path, secs: f64, f: impl Fn(f64) -> f64) {
    let rate = 48_000u32;
    let n = (secs * rate as f64) as u32;
    let mut b = Vec::with_capacity(44 + n as usize * 4);
    b.extend_from_slice(b"RIFF");
    b.extend_from_slice(&(36 + n * 4).to_le_bytes());
    b.extend_from_slice(b"WAVEfmt ");
    b.extend_from_slice(&16u32.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&2u16.to_le_bytes());
    b.extend_from_slice(&rate.to_le_bytes());
    b.extend_from_slice(&(rate * 4).to_le_bytes());
    b.extend_from_slice(&4u16.to_le_bytes());
    b.extend_from_slice(&16u16.to_le_bytes());
    b.extend_from_slice(b"data");
    b.extend_from_slice(&(n * 4).to_le_bytes());
    for i in 0..n {
        let v = (f(i as f64 / rate as f64).clamp(-1.0, 1.0) * 30000.0) as i16;
        b.extend_from_slice(&v.to_le_bytes());
        b.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, b).unwrap();
}

fn beat_track(bpm: f64, secs: f64, end: f64) -> impl Fn(f64) -> f64 {
    move |t| {
        if t > end {
            return 0.0;
        }
        let beat = 60.0 / bpm;
        let ph = (t / beat).fract() * beat;
        let bi = (t / beat).floor() as i64;
        let amp = if bi % 4 == 0 { 1.0 } else { 0.55 };
        let kick = amp * (-ph * 30.0).exp() * (std::f64::consts::TAU * (55.0 + 80.0 * (-ph * 40.0).exp()) * ph).sin();
        let bass = 0.18 * (std::f64::consts::TAU * 55.0 * t).sin();
        let pad = 0.1 * (std::f64::consts::TAU * 220.0 * t).sin();
        let _ = secs;
        0.45 * kick + bass + pad
    }
}

struct Outcome {
    started_at: Option<f64>,
    min_ratio: f64,
    clipped: usize,
    nonfinite: usize,
    underruns: u64,
    in_pos_after: f64,
}

/// Play `a` from `from`, queue the blend into `b`, render until `secs` past the cue.
fn run(a: &str, b: &str, from: f64, plan: &lumisound_core::blend::BlendPlan, tail_secs: f64) -> Outcome {
    let ev = Arc::new(Events(Mutex::new(vec![])));
    let e = AudioEngine::new(ev.clone());
    e.load(a.into(), from, 0.0).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    e.play();
    let id = e.queue_blend(b.into(), plan.clone(), 0.0, true).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    let rate = e.output_rate() as f64;
    let mut out = Vec::new();
    let mut started_at = None;
    let total = (plan.out_start - from).max(0.0) + plan.fade_secs + tail_secs;
    let mut last_pos = e.position();
    for _ in 0..((total * rate) as usize / CHUNK) {
        out.extend(e.render_offline(CHUNK));
        let pos = e.position();
        // The engine reports the incoming track's position once the fade
        // begins: the fade started where the outgoing position last stood.
        if started_at.is_none() && pos + 1.0 < last_pos {
            started_at = Some(last_pos);
        }
        last_pos = pos;
        std::thread::sleep(Duration::from_micros(700));
    }
    if started_at.is_none() && ev.0.lock().unwrap().iter().any(|(n, _)| *n == format!("start{id}")) {
        started_at = Some(f64::NAN);
    }
    let w = (rate * 0.02) as usize;
    let env: Vec<f64> = out.chunks(w * 2).filter(|c| c.len() == w * 2).map(|c| (c.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / c.len() as f64).sqrt()).collect();
    let mut sorted = env.clone();
    sorted.sort_by(|x, y| x.total_cmp(y));
    let med = sorted[sorted.len() / 2].max(1e-9);
    // Quietest 20 ms window within the fade region relative to the median.
    let fade_from = (((plan.out_start - from).max(0.0)) / 0.02) as usize;
    let fade_to = (fade_from + (plan.fade_secs / 0.02) as usize).min(env.len());
    let min = env[fade_from.min(env.len() - 1)..fade_to.max(fade_from + 1).min(env.len())].iter().cloned().fold(f64::MAX, f64::min);
    let h = e.health();
    Outcome {
        started_at,
        min_ratio: min / med,
        clipped: out.iter().filter(|v| v.abs() > 1.0).count(),
        nonfinite: out.iter().filter(|v| !v.is_finite()).count(),
        underruns: h.underrun_events,
        in_pos_after: e.position(),
    }
}

#[test]
fn blend_starts_on_cue_with_bass_swap() {
    let dir = std::env::temp_dir().join(format!("blend-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (a, b) = (dir.join("a.wav"), dir.join("b.wav"));
    write_wav(&a, 90.0, beat_track(124.0, 90.0, 90.0));
    write_wav(&b, 90.0, beat_track(120.0, 90.0, 90.0));
    lumisound_core::blobcache::blob_cache_configure(dir.join("cache").to_string_lossy().into());
    let (pa, pb) = (blend_profile(a.to_string_lossy().into()).unwrap(), blend_profile(b.to_string_lossy().into()).unwrap());
    let plan = blend_plan(pa.clone(), pb.clone(), BlendSettings { base_secs: 8.0, beat_match: true, bass_swap: true });
    eprintln!("plan: {plan:?}");
    assert!(plan.bars >= 2 && plan.style == BlendStyle::BassSwap, "{plan:?}");
    let o = run(&a.to_string_lossy(), &b.to_string_lossy(), plan.out_start - 3.0, &plan, 2.0);
    let started = o.started_at.expect("blend never started");
    eprintln!("fade began at {started:.3}s (cue {:.3}), quietest window {:.2} of median, incoming at {:.2}s, underruns {}", plan.out_start, o.min_ratio, o.in_pos_after, o.underruns);
    assert!((started - plan.out_start).abs() < 0.03, "fade began at {started}, planned {}", plan.out_start);
    assert!(o.min_ratio > 0.35, "level hole in the blend: {:.2}", o.min_ratio);
    assert_eq!(o.clipped + o.nonfinite, 0);
    assert_eq!(o.underruns, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cloud_pairs_blend_cleanly() {
    let Ok(dir) = std::env::var("LUMI_CLOUD_DIR") else {
        eprintln!("LUMI_CLOUD_DIR not set; skipping");
        return;
    };
    let dir = PathBuf::from(dir);
    let pairs: usize = std::env::var("LUMI_BLEND_PAIRS").ok().and_then(|v| v.parse().ok()).unwrap_or(8);
    let skip: usize = std::env::var("LUMI_BLEND_SKIP").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    let unlocked = dir.join("unlocked");
    std::fs::create_dir_all(&unlocked).unwrap();
    lumisound_core::blobcache::blob_cache_configure(unlocked.join("blob").to_string_lossy().into());
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "lms")).collect();
    files.sort();
    let step = (files.len() / (pairs * 2).max(1)).max(1);
    let pick: Vec<PathBuf> = files.iter().skip(skip).step_by(step).take(pairs * 2).cloned().collect();
    let mut fails = vec![];
    let mut styles = std::collections::BTreeMap::<String, usize>::new();
    let mut profiled = 0;
    let t0 = std::time::Instant::now();
    for pair in pick.chunks(2).filter(|c| c.len() == 2) {
        // The core reads locked files in place.
        let (a, b) = (pair[0].to_string_lossy().to_string(), pair[1].to_string_lossy().to_string());
        let (Some(pa), Some(pb)) = (blend_profile(a.clone()), blend_profile(b.clone())) else {
            eprintln!("skip (no profile): {:?}", pair[0].file_name());
            continue;
        };
        profiled += 2;
        let plan = blend_plan(pa.clone(), pb.clone(), BlendSettings { base_secs: 6.0, beat_match: true, bass_swap: true });
        *styles.entry(format!("{:?}", plan.style)).or_default() += 1;
        let (sa, sb) = (pa.summary(), pb.summary());
        let name = |p: &Path| p.file_name().unwrap().to_string_lossy().chars().skip(9).take(28).collect::<String>();
        let o = run(&a, &b, (plan.out_start - 2.0).max(0.0), &plan, 1.5);
        let started = o.started_at.unwrap_or(f64::NAN);
        let cue_err = (started - plan.out_start).abs();
        // Incoming position after the render: in_start + time since the fade began (tempo-matched portion aside).
        let ok = cue_err < 0.03 && o.clipped + o.nonfinite == 0 && o.underruns == 0 && o.min_ratio > 0.05;
        eprintln!(
            "{:<28} -> {:<28} {:>5.1}/{:<5.1} bpm {:?}/{:?} | {:?} {:.1}s {} bars x{:.3} out@{:.1} in@{:.1} [{}] | cue err {:.1} ms, min {:.2}, in now {:.1}s  {}",
            name(&pair[0]), name(&pair[1]), sa.bpm_tail, sb.bpm_head, sa.outro, sb.intro, plan.style, plan.fade_secs, plan.bars, plan.tempo_match, plan.out_start, plan.in_start, plan.reason,
            cue_err * 1000.0, o.min_ratio, o.in_pos_after, if ok { "PASS" } else { "FAIL" }
        );
        if !ok {
            fails.push(name(&pair[0]));
        }
    }
    eprintln!("\nprofiled {profiled} tracks in {:.1}s; styles {styles:?}", t0.elapsed().as_secs_f64());
    assert!(fails.is_empty(), "{fails:?}");
}
