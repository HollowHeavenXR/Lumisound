//! Real-track check of the Lumisound Audio Engine and its effects.
//!
//!   LUMI_CLOUD_DIR=<dir of .lms / audio files> cargo test --release -p lumisound-core \
//!       --test engine_cloud -- --nocapture --test-threads=1
//!
//! Each file is unlocked the way the app does it, then rendered through the
//! engine's offline path (same mixer/DSP the phone runs) once per effect
//! setting. Every render is checked for NaN/Inf, clipping, dropouts (the
//! track position must keep pace with the output), and a measurement that
//! shows the effect is doing what it should. Skipped when the env var is unset.

use lumisound_core::engine::{AudioEngine, EngineListener};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct Events(Mutex<Vec<String>>);
impl EngineListener for Events {
    fn on_track_ended(&self, id: u64) {
        self.0.lock().unwrap().push(format!("end{id}"));
    }
    fn on_track_started(&self, id: u64) {
        self.0.lock().unwrap().push(format!("start{id}"));
    }
    fn on_track_failed(&self, id: u64) {
        self.0.lock().unwrap().push(format!("fail{id}"));
    }
}

const START: f64 = 30.0;
const SECS: f64 = 20.0;
const CHUNK: usize = 1024;

#[derive(Clone, Debug)]
struct Cfg {
    name: &'static str,
    speed: f64,
    pitch: f64,
    eq: Option<Vec<f32>>,
    reverb: f32,
    preset: &'static str,
    mono: bool,
    night: bool,
    spatial_yaw: Option<f32>,
    pan_hz: f32,
    trem: (f32, f32),
    vib: (f32, f32),
}

fn base(name: &'static str) -> Cfg {
    Cfg { name, speed: 1.0, pitch: 0.0, eq: None, reverb: 0.0, preset: "mediumHall", mono: false, night: false, spatial_yaw: None, pan_hz: 0.0, trem: (0.0, 0.0), vib: (0.0, 0.0) }
}

fn configs() -> Vec<Cfg> {
    let mut v = vec![base("baseline")];
    v.push(Cfg { pan_hz: 0.2, ..base("8d (0.2 Hz)") });
    v.push(Cfg { reverb: 0.5, preset: "largeHall", ..base("reverb largeHall 50%") });
    v.push(Cfg { reverb: 0.35, preset: "smallRoom", ..base("reverb smallRoom 35%") });
    v.push(Cfg { eq: Some(vec![9.0, 9.0, 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]), ..base("eq bass boost") });
    v.push(Cfg { eq: Some(vec![0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 6.0, 9.0, 9.0]), ..base("eq treble boost") });
    v.push(Cfg { night: true, ..base("night mode") });
    v.push(Cfg { mono: true, ..base("mono") });
    v.push(Cfg { spatial_yaw: Some(0.0), ..base("spatial (yaw 0)") });
    v.push(Cfg { spatial_yaw: Some(60.0), ..base("spatial (yaw 60)") });
    v.push(Cfg { trem: (4.0, 0.45), ..base("tremolo 4 Hz") });
    v.push(Cfg { vib: (4.5, 0.35), ..base("vibrato 4.5 Hz") });
    v.push(Cfg { speed: 1.25, ..base("speed 1.25x") });
    v.push(Cfg { speed: 0.8, ..base("speed 0.8x") });
    v.push(Cfg { pitch: 4.0, ..base("pitch +4 st") });
    v.push(Cfg {
        pan_hz: 0.2,
        reverb: 0.4,
        preset: "largeRoom",
        eq: Some(vec![6.0, 6.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 2.0]),
        night: true,
        trem: (4.0, 0.3),
        ..base("everything on")
    });
    v
}

struct Render {
    health: lumisound_core::engine::health::EngineHealth,
    out: Vec<f32>,
    rate: f64,
    pos_start: f64,
    pos_end: f64,
    dsp_secs: f64,
}

fn render(path: &str, c: &Cfg) -> Render {
    let ev = Arc::new(Events(Mutex::new(vec![])));
    let e = AudioEngine::new(ev);
    if c.speed != 1.0 || c.pitch != 0.0 {
        e.set_speed_pitch(c.speed, c.pitch).unwrap();
    }
    if let Some(g) = &c.eq {
        e.set_eq(g.clone(), true);
    }
    e.set_effects(c.reverb, c.preset.into(), c.mono, c.night);
    if let Some(y) = c.spatial_yaw {
        e.set_spatial(true, y);
    }
    e.set_modulation(c.pan_hz, c.trem.0, c.trem.1, c.vib.0, c.vib.1);
    e.load(path.into(), START, 0.0).expect("load");
    std::thread::sleep(Duration::from_millis(400));
    e.play();
    let rate = e.output_rate() as f64;
    // Warm-up second (fades in, settles effect state) not measured.
    for _ in 0..(rate as usize / CHUNK) {
        e.render_offline(CHUNK);
        std::thread::sleep(Duration::from_millis(2));
    }
    let pos_start = e.position();
    let n = (SECS * rate) as usize / CHUNK;
    let mut out = Vec::with_capacity(n * CHUNK * 2);
    let mut dsp = Duration::ZERO;
    for _ in 0..n {
        let t = Instant::now();
        let b = e.render_offline(CHUNK);
        dsp += t.elapsed();
        out.extend(b);
        // ~4x real time: plenty of headroom for the decode threads.
        std::thread::sleep(Duration::from_millis(5));
    }
    std::thread::sleep(Duration::from_millis(50));
    Render { health: e.health(), out, rate, pos_start, pos_end: e.position(), dsp_secs: dsp.as_secs_f64() }
}

fn write_tone(path: &Path, hz: f64, secs: f64) {
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
        let v = ((std::f64::consts::TAU * hz * i as f64 / rate as f64).sin() * 0.4 * 32767.0) as i16;
        b.extend_from_slice(&v.to_le_bytes());
        b.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, b).unwrap();
}

// ---- measurements -----------------------------------------------------------------------------

fn channels(x: &[f32]) -> (Vec<f32>, Vec<f32>) {
    (x.iter().step_by(2).copied().collect(), x.iter().skip(1).step_by(2).copied().collect())
}

fn rms(x: &[f32]) -> f64 {
    (x.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / x.len().max(1) as f64).sqrt()
}

fn db(x: f64) -> f64 {
    20.0 * x.max(1e-12).log10()
}

fn windows(x: &[f32], w: usize) -> Vec<f64> {
    x.chunks(w).filter(|c| c.len() == w).map(rms).collect()
}

/// Strength of a sinusoid at `hz` in a series sampled at `fs` (normalised DFT magnitude / mean).
fn tone_strength(series: &[f64], fs: f64, hz: f64) -> f64 {
    let mean = series.iter().sum::<f64>() / series.len() as f64;
    let (mut re, mut im) = (0.0, 0.0);
    for (i, v) in series.iter().enumerate() {
        let a = std::f64::consts::TAU * hz * i as f64 / fs;
        re += (v - mean) * a.cos();
        im += (v - mean) * a.sin();
    }
    2.0 * (re * re + im * im).sqrt() / series.len() as f64 / mean.abs().max(1e-9)
}

/// Goertzel power at `hz`, summed over a few neighbouring bins (band energy).
fn band_db(x: &[f32], rate: f64, lo: f64, hi: f64) -> f64 {
    let n = 8192.min(x.len());
    let mut total = 0.0;
    let mut frames = 0;
    for blk in x.chunks(n).filter(|b| b.len() == n) {
        frames += 1;
        let mut f = lo;
        while f <= hi {
            let k = (f * n as f64 / rate).round();
            let w = std::f64::consts::TAU * k / n as f64;
            let coeff = 2.0 * w.cos();
            let (mut s1, mut s2) = (0.0, 0.0);
            for (i, v) in blk.iter().enumerate() {
                let hann = 0.5 - 0.5 * (std::f64::consts::TAU * i as f64 / n as f64).cos();
                let s = *v as f64 * hann + coeff * s1 - s2;
                s2 = s1;
                s1 = s;
            }
            total += s1 * s1 + s2 * s2 - coeff * s1 * s2;
            f += rate / n as f64;
        }
    }
    10.0 * (total / frames.max(1) as f64).max(1e-30).log10()
}

fn correlation(a: &[f32], b: &[f32]) -> f64 {
    let (ma, mb) = (a.iter().map(|v| *v as f64).sum::<f64>() / a.len() as f64, b.iter().map(|v| *v as f64).sum::<f64>() / b.len() as f64);
    let (mut sab, mut saa, mut sbb) = (0.0, 0.0, 0.0);
    for (x, y) in a.iter().zip(b) {
        let (x, y) = (*x as f64 - ma, *y as f64 - mb);
        sab += x * y;
        saa += x * x;
        sbb += y * y;
    }
    sab / (saa * sbb).sqrt().max(1e-12)
}

/// Lag (samples, R relative to L) maximising cross-correlation within ±`max`.
fn best_lag(l: &[f32], r: &[f32], max: i64) -> i64 {
    let n = l.len().min(48_000 * 4);
    let mut best = (0i64, f64::MIN);
    for lag in -max..=max {
        let mut s = 0.0;
        for i in (max as usize)..(n - max as usize) {
            s += l[i] as f64 * r[(i as i64 + lag) as usize] as f64;
        }
        if s > best.1 {
            best = (lag, s);
        }
    }
    best.0
}

fn zcr(x: &[f32]) -> f64 {
    x.windows(2).filter(|p| (p[0] >= 0.0) != (p[1] >= 0.0)).count() as f64 / x.len() as f64
}

#[derive(Default)]
struct Row {
    track: String,
    cfg: String,
    peak: f64,
    rms_db: f64,
    bad: usize,
    clipped: usize,
    pos_ratio: f64,
    rtf: f64,
    check: String,
    pass: bool,
}

#[test]
fn cloud_tracks_through_engine_and_effects() {
    let Ok(dir) = std::env::var("LUMI_CLOUD_DIR") else {
        eprintln!("LUMI_CLOUD_DIR not set; skipping");
        return;
    };
    let dir = PathBuf::from(dir);
    let unlocked = dir.join("unlocked");
    std::fs::create_dir_all(&unlocked).unwrap();
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.path()).filter(|p| p.is_file() && p.extension().is_some_and(|e| e == "lms")).collect();
    files.sort();
    assert!(!files.is_empty(), "LUMI_CLOUD_DIR has no .lms tracks: nothing would be tested");
    let mut tracks = Vec::new();
    for f in &files {
        let out = unlocked.join(f.file_stem().unwrap());
        assert!(lumisound_core::lock::lms_unlock(f.to_string_lossy().into(), out.to_string_lossy().into()), "unlock {f:?}");
        tracks.push(out);
    }

    let mut rows: Vec<Row> = Vec::new();
    for t in &tracks {
        let name = t.file_name().unwrap().to_string_lossy().to_string();
        let path = t.to_string_lossy().to_string();
        let dur = lumisound_core::analysis::probe_duration(path.clone(), unlocked.to_string_lossy().into());
        if dur < START + SECS + 5.0 {
            eprintln!("{name}: {dur:.0}s is too short, skipped");
            continue;
        }
        let mut baseline: Option<Render> = None;
        for c in configs() {
            let r = render(&path, &c);
            let (l, rr) = channels(&r.out);
            let peak = r.out.iter().fold(0f64, |m, v| m.max(v.abs() as f64));
            let bad = r.out.iter().filter(|v| !v.is_finite()).count();
            let clipped = r.out.iter().filter(|v| v.abs() > 1.0).count();
            let played = r.out.len() as f64 / 2.0 / r.rate;
            let pos_ratio = (r.pos_end - r.pos_start) / (played * c.speed);
            let rtf = r.dsp_secs / played;
            let check;
            // Telemetry must agree: no underruns or invalid samples when the output is clean.
            let mut pass = bad == 0 && clipped == 0 && (pos_ratio - 1.0).abs() < 0.02 && rms(&r.out) > 1e-4
                && r.health.underrun_events == 0 && r.health.nonfinite_samples == 0 && r.health.deck_failures == 0;
            let w = (r.rate * 0.05) as usize;
            match c.name {
                "baseline" => check = format!("L/R corr {:.2}", correlation(&l, &rr)),
                n if n.starts_with("8d") => {
                    let (el, er) = (windows(&l, w), windows(&rr, w));
                    let bal: Vec<f64> = el.iter().zip(&er).map(|(a, b)| (a - b) / (a + b).max(1e-9)).collect();
                    let mut s = bal.clone();
                    s.sort_by(|a, b| a.total_cmp(b));
                    let swing = s[s.len() * 95 / 100] - s[s.len() * 5 / 100];
                    let at = tone_strength(&bal.iter().map(|b| b + 2.0).collect::<Vec<_>>(), 20.0, c.pan_hz as f64);
                    check = format!("L/R balance swing {swing:.2}, rotation tone {at:.3}");
                    pass &= swing > 0.5;
                }
                n if n.starts_with("reverb") => {
                    let b = baseline.as_ref().unwrap();
                    let (bl, br) = channels(&b.out);
                    let (c0, c1) = (correlation(&bl, &br), correlation(&l, &rr));
                    let crest = |x: &[f32]| db(x.iter().fold(0f64, |m, v| m.max(v.abs() as f64))) - db(rms(x));
                    check = format!("L/R corr {c0:.2} -> {c1:.2}, crest {:.1} -> {:.1} dB", crest(&b.out), crest(&r.out));
                    pass &= c1 < c0 - 0.02 || c0 < 0.3;
                }
                n if n.starts_with("eq bass") => {
                    let b = &baseline.as_ref().unwrap().out;
                    let d = band_db(&l, r.rate, 40.0, 90.0) - band_db(&channels(b).0, r.rate, 40.0, 90.0);
                    check = format!("40-90 Hz {d:+.1} dB");
                    pass &= d > 4.0;
                }
                n if n.starts_with("eq treble") => {
                    let b = &baseline.as_ref().unwrap().out;
                    let d = band_db(&l, r.rate, 9000.0, 14000.0) - band_db(&channels(b).0, r.rate, 9000.0, 14000.0);
                    check = format!("9-14 kHz {d:+.1} dB");
                    pass &= d > 3.0;
                }
                "night mode" => {
                    let b = &baseline.as_ref().unwrap().out;
                    let spread = |x: &[f32]| {
                        let v: Vec<f64> = windows(x, w * 2).into_iter().filter(|r| *r > 1e-4).map(db).collect();
                        let mut s = v.clone();
                        s.sort_by(|a, b| a.total_cmp(b));
                        s[s.len() * 95 / 100] - s[s.len() * 10 / 100]
                    };
                    let (s0, s1) = (spread(b), spread(&r.out));
                    check = format!("loudness range {s0:.1} -> {s1:.1} dB");
                    pass &= s1 <= s0 + 0.2;
                }
                "mono" => {
                    let diff = l.iter().zip(&rr).fold(0f32, |m, (a, b)| m.max((a - b).abs()));
                    check = format!("max |L-R| {diff:.1e}");
                    pass &= diff < 1e-6;
                }
                n if n.starts_with("spatial") => {
                    let lag = best_lag(&l, &rr, 48);
                    let ild = db(rms(&l)) - db(rms(&rr));
                    check = format!("ITD lag {:.2} ms, ILD {ild:+.1} dB", lag as f64 / r.rate * 1000.0);
                    if c.spatial_yaw == Some(60.0) {
                        pass &= lag.abs() >= 8 || ild.abs() > 1.5;
                    } else {
                        pass &= lag.abs() <= 2 && ild.abs() < 1.5;
                    }
                }
                n if n.starts_with("tremolo") => {
                    let fine = (r.rate * 0.01) as usize;
                    let env = windows(&l, fine);
                    let base_env = windows(&channels(&baseline.as_ref().unwrap().out).0, fine);
                    let (t1, t0) = (tone_strength(&env, 100.0, 4.0), tone_strength(&base_env, 100.0, 4.0));
                    check = format!("4 Hz envelope {t0:.3} -> {t1:.3}");
                    pass &= t1 > t0 * 2.0;
                }
                n if n.starts_with("vibrato") => {
                    let b = &baseline.as_ref().unwrap().out;
                    let corr = correlation(&l[..48_000], &channels(b).0[..48_000]);
                    check = format!("corr vs dry {corr:.2} (modulated, same material)");
                    pass &= corr < 0.98;
                }
                n if n.starts_with("speed") || n.starts_with("pitch") => {
                    // Track time per output time must equal the speed (the
                    // generic pos check); pitch accuracy is measured on a pure
                    // tone below, where frequency is unambiguous.
                    check = format!("track/out time {:.3}x", (r.pos_end - r.pos_start) / played);
                }
                _ => check = format!("L/R corr {:.2}", correlation(&l, &rr)),
            }
            rows.push(Row { track: name.clone(), cfg: c.name.into(), peak, rms_db: db(rms(&r.out)), bad, clipped, pos_ratio, rtf, check, pass });
            let last = rows.last().unwrap();
            eprintln!("{:<14} {:<22} peak {:.2} rms {:>6.1} dB  pos {:.3}  dsp {:>5.1}% rt  {}  {}", last.track, last.cfg, last.peak, last.rms_db, last.pos_ratio, last.rtf * 100.0, if last.pass { "PASS" } else { "FAIL" }, last.check);
            if c.name == "baseline" {
                baseline = Some(r);
            }
        }
    }

    // Pitch accuracy on a pure 440 Hz tone: speed must keep pitch, pitch shift must move it.
    let tone = unlocked.join("tone440.wav");
    write_tone(&tone, 440.0, 80.0);
    for (speed, pitch, expect) in [(1.0, 0.0, 440.0), (1.25, 0.0, 440.0), (0.8, 0.0, 440.0), (1.0, 4.0, 440.0 * 2f64.powf(4.0 / 12.0)), (1.0, -5.0, 440.0 * 2f64.powf(-5.0 / 12.0)), (1.5, 3.0, 440.0 * 2f64.powf(3.0 / 12.0))] {
        let c = Cfg { speed, pitch, ..base("tone") };
        let r = render(&tone.to_string_lossy(), &c);
        let (l, _) = channels(&r.out);
        let hz = zcr(&l) * r.rate / 2.0;
        let played = r.out.len() as f64 / 2.0 / r.rate;
        let pos_ratio = (r.pos_end - r.pos_start) / (played * speed);
        let pass = (hz / expect - 1.0).abs() < 0.02 && (pos_ratio - 1.0).abs() < 0.02;
        eprintln!("tone speed {speed}x pitch {pitch:+} st: {hz:.1} Hz (expect {expect:.1}), pos {pos_ratio:.3}  {}", if pass { "PASS" } else { "FAIL" });
        rows.push(Row { track: "tone440".into(), cfg: format!("speed {speed} pitch {pitch}"), pos_ratio, check: format!("{hz:.1} Hz vs {expect:.1}"), pass, ..Default::default() });
    }

    // Starvation: render as fast as possible (no pacing), so the deck can
    // fall behind. Telemetry must account for exactly the audio that was lost.
    for t in tracks.iter().take(3) {
        let ev = Arc::new(Events(Mutex::new(vec![])));
        let e = AudioEngine::new(ev);
        e.set_speed_pitch(1.3, 2.0).unwrap(); // WSOLA + resampling: the heaviest decode path
        e.load(t.to_string_lossy().into(), START, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        e.play();
        let rate = e.output_rate() as f64;
        let n = (20.0 * rate) as usize / CHUNK;
        // Position is published by the render itself: take the baseline after one.
        e.render_offline(CHUNK);
        let p0 = e.position();
        e.reset_health();
        for _ in 0..n {
            e.render_offline(CHUNK);
        }
        std::thread::sleep(Duration::from_millis(50));
        let h = e.health();
        let played = (n * CHUNK) as f64 / rate;
        let lost = played - (e.position() - p0) / 1.3; // output seconds with no track audio
        let reported = h.underrun_ms / 1000.0;
        let incidents = e.incidents();
        let pass = (lost < 0.05 && h.underrun_events == 0) || (lost >= 0.05 && h.underrun_events > 0 && (reported - lost).abs() < 0.1 + lost * 0.05);
        eprintln!("starvation {}: lost {lost:.2}s of {played:.0}s, telemetry {reported:.2}s in {} underruns ({} incidents logged), worst {:.0} ms  {}",
            t.file_name().unwrap().to_string_lossy(), h.underrun_events, incidents.len(),
            incidents.iter().map(|i| i.value).fold(0.0, f64::max), if pass { "PASS" } else { "FAIL" });
        rows.push(Row { track: "starvation".into(), cfg: "unpaced".into(), pass, check: format!("lost {lost:.2}s, reported {reported:.2}s"), pos_ratio: 1.0, ..Default::default() });
    }

    // Crossfade + beat-match between consecutive tracks.
    for pair in tracks.windows(2).take(4) {
        let ev = Arc::new(Events(Mutex::new(vec![])));
        let e = AudioEngine::new(ev.clone());
        e.load(pair[0].to_string_lossy().into(), START, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(400));
        e.play();
        let rate = e.output_rate() as f64;
        let mut out = Vec::new();
        let pump = |e: &AudioEngine, secs: f64, out: &mut Vec<f32>| {
            for _ in 0..((secs * rate) as usize / CHUNK) {
                out.extend(e.render_offline(CHUNK));
                std::thread::sleep(Duration::from_millis(5));
            }
        };
        pump(&e, 2.0, &mut out);
        let id = e.crossfade_to(pair[1].to_string_lossy().into(), 4.0, START, 0.0, true, 1.06).unwrap();
        let mark = out.len();
        pump(&e, 6.0, &mut out);
        let w = (rate * 0.05) as usize;
        let env: Vec<f64> = windows(&out[mark..], w * 2);
        let mean = env.iter().sum::<f64>() / env.len() as f64;
        let min = env.iter().cloned().fold(f64::MAX, f64::min);
        let started = ev.0.lock().unwrap().contains(&format!("start{id}"));
        let bad = out.iter().filter(|v| !v.is_finite() || v.abs() > 1.0).count();
        let pass = started && bad == 0 && min > mean * 0.1;
        eprintln!(
            "crossfade {} -> {} (4 s, beat-match 1.06x): started {started}, min/mean window {:.2}, incoming pos {:.2}s  {}",
            pair[0].file_name().unwrap().to_string_lossy(),
            pair[1].file_name().unwrap().to_string_lossy(),
            min / mean,
            e.position(),
            if pass { "PASS" } else { "FAIL" }
        );
        rows.push(Row { track: "crossfade".into(), cfg: "beat-match".into(), pass, ..Default::default() });
    }

    let failed: Vec<&Row> = rows.iter().filter(|r| !r.pass).collect();
    let worst_rtf = rows.iter().map(|r| r.rtf).fold(0.0, f64::max);
    eprintln!("\n{} renders, {} failed, worst DSP cost {:.1}% of real time", rows.len(), failed.len(), worst_rtf * 100.0);
    for f in &failed {
        eprintln!("FAILED: {} / {}: {} (bad {}, clipped {}, pos {:.3})", f.track, f.cfg, f.check, f.bad, f.clipped, f.pos_ratio);
    }
    assert!(failed.is_empty());
    let _ = Path::new("");
}
