//! Pitch-shift clarity check: level dips and wobble a pitched render has
//! that the unpitched render of the same audio doesn't.
//!
//!   cargo test --release -p lumisound-core --test pitch_cloud -- --nocapture --test-threads=1
//!   LUMI_CLOUD_DIR=<dir of .lms copies> (adds real cloud tracks; synthetic part always runs)
//!
//! Users heard "little stutter dips" and glitchy clarity at any pitch other
//! than 0, on the whole track and every track after. A dip is a 10 ms window
//! whose level falls 4 dB+ below where the unpitched render says it should be.

use lumisound_core::engine::{AudioEngine, EngineListener};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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

const CHUNK: usize = 1024;

fn render(path: &str, start: f64, secs: f64, pitch: f64) -> (Vec<f32>, f64, u64) {
    let e = AudioEngine::new(Arc::new(Events(Mutex::new(vec![]))));
    if pitch != 0.0 {
        e.set_speed_pitch(1.0, pitch).unwrap();
    }
    e.load(path.into(), start, 0.0).expect("load");
    std::thread::sleep(Duration::from_millis(300));
    e.play();
    let rate = e.output_rate() as f64;
    let mut out = Vec::new();
    for _ in 0..((secs * rate) as usize / CHUNK) {
        out.extend(e.render_offline(CHUNK));
        std::thread::sleep(Duration::from_millis(3));
    }
    (out, rate, e.health().underrun_events)
}

fn mono(x: &[f32]) -> Vec<f32> {
    x.chunks_exact(2).map(|c| 0.5 * (c[0] + c[1])).collect()
}

fn env_db(x: &[f32], w: usize) -> Vec<f64> {
    x.chunks(w).filter(|c| c.len() == w).map(|c| 10.0 * ((c.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / w as f64).max(1e-14)).log10()).collect()
}

/// Shift (in windows) of `b` against `a` that best lines the envelopes up.
fn align(a: &[f64], b: &[f64], max: i64) -> i64 {
    let n = a.len().min(b.len()) as i64;
    let mut best = (0, f64::MAX);
    for lag in -max..=max {
        let mut s = 0.0;
        let mut k = 0.0;
        for i in max..(n - max) {
            let j = i + lag;
            s += (a[i as usize] - b[j as usize]).abs();
            k += 1.0;
        }
        if s / k < best.1 {
            best = (lag, s / k);
        }
    }
    best.0
}

#[derive(Debug, Clone, Copy)]
struct Clarity {
    /// Dips per minute (10 ms windows 4 dB+ under the expected level).
    dips_per_min: f64,
    /// Spread (p10..p90) of the level difference, dB: wobble.
    wobble_db: f64,
    /// Worst dip, dB under expected.
    worst_db: f64,
}

fn clarity(base: &[f32], pitched: &[f32], rate: f64) -> Clarity {
    // 1 ms envelopes to align, 10 ms to judge.
    let (a, b) = (mono(base), mono(pitched));
    let fine = (rate / 1000.0) as usize;
    let lag = align(&env_db(&a, fine), &env_db(&b, fine), 60);
    let (a, b): (&[f32], &[f32]) = if lag >= 0 { (&a[..], &b[lag as usize * fine..]) } else { (&a[(-lag) as usize * fine..], &b[..]) };
    let w = (rate / 100.0) as usize;
    let (ea, eb) = (env_db(a, w), env_db(b, w));
    let top = ea.iter().cloned().fold(f64::MIN, f64::max);
    let d: Vec<f64> = ea.iter().zip(&eb).filter(|(x, _)| **x > top - 30.0).map(|(x, y)| y - x).collect();
    let mut s = d.clone();
    s.sort_by(|x, y| x.total_cmp(y));
    let med = s[s.len() / 2];
    let dips = d.iter().filter(|v| **v < med - 4.0).count();
    let mins = d.len() as f64 / 100.0 / 60.0;
    Clarity { dips_per_min: dips as f64 / mins.max(1e-9), wobble_db: s[s.len() * 9 / 10] - s[s.len() / 10], worst_db: med - s[0] }
}

fn write_wav(path: &Path, rate: u32, secs: f64, f: impl Fn(f64) -> (f64, f64)) {
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
        let (l, r) = f(i as f64 / rate as f64);
        b.extend_from_slice(&((l.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
        b.extend_from_slice(&((r.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
    }
    std::fs::write(path, b).unwrap();
}

/// Bass + chord held under hi-hat/snare style noise bursts 8x a second: the
/// case where transient phase resets used to cancel the sustained notes.
fn drums_over_chord(path: &Path) {
    let mut seed = 0x1234_5678u32;
    let noise: Vec<f64> = (0..48_000).map(|_| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        seed as f64 / u32::MAX as f64 * 2.0 - 1.0
    }).collect();
    write_wav(path, 48_000, 30.0, |t| {
        let tau = std::f64::consts::TAU;
        let tonal = 0.22 * (tau * 55.0 * t).sin() + 0.12 * (tau * 220.0 * t).sin() + 0.1 * (tau * 277.18 * t).sin() + 0.1 * (tau * 329.63 * t).sin();
        let beat = (t * 8.0).fract() / 8.0;
        let hit = noise[((t * 48_000.0) as usize) % noise.len()] * 0.25 * (-beat * 60.0).exp();
        let width = 0.03 * (tau * 440.0 * t + 0.7).sin();
        (tonal + hit + width, tonal + hit - width)
    });
}

/// Low band (< 400 Hz, one-pole x4) envelope dips: sustained bass/chord
/// level through the drum hits. Measured on output alone (the input's low
/// band is constant).
fn low_band_dips(x: &[f32], rate: f64, bass_hz: f64) -> (f64, f64) {
    let m = mono(x);
    let a = (-std::f64::consts::TAU * 400.0 / rate).exp();
    let mut st = [0f64; 4];
    let lp: Vec<f32> = m.iter().map(|v| {
        let mut y = *v as f64;
        for s in st.iter_mut() {
            *s = (1.0 - a) * y + a * *s;
            y = *s;
        }
        y as f32
    }).collect();
    // Two whole bass cycles per window, or the window itself ripples.
    let w = (2.0 * rate / bass_hz).round() as usize;
    let e = env_db(&lp[lp.len() / 5..], w);
    let mut s = e.clone();
    s.sort_by(|x, y| x.total_cmp(y));
    let med = s[s.len() / 2];
    (med - s[0], s[s.len() * 9 / 10] - s[s.len() / 10])
}

#[test]
fn pitch_keeps_sustained_notes_through_drum_hits() {
    let dir = std::env::temp_dir().join(format!("pitch-clarity-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("drums_chord.wav");
    drums_over_chord(&p);
    let path = p.to_string_lossy().to_string();
    let (base, rate, _) = render(&path, 2.0, 12.0, 0.0);
    let (b_worst, b_wob) = low_band_dips(&base, rate, 55.0);
    eprintln!("pitch   0 st: low-band worst dip {b_worst:.2} dB, wobble {b_wob:.2} dB");
    let mut fails = vec![];
    for st in [-1.5, 2.0, -4.0, 5.0] {
        let (out, rate, under) = render(&path, 2.0, 12.0, st);
        let (worst, wob) = low_band_dips(&out, rate, 55.0 * 2f64.powf(st / 12.0));
        let c = clarity(&base, &out, rate);
        let ok = worst < 2.0 && wob < 1.0 && under == 0;
        eprintln!("pitch {st:+} st: low-band worst dip {worst:.2} dB, wobble {wob:.2} dB | broadband dips {:.1}/min wobble {:.2} dB worst {:.1} dB, underruns {under}  {}", c.dips_per_min, c.wobble_db, c.worst_db, if ok { "PASS" } else { "FAIL" });
        if !ok {
            fails.push(st);
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert!(fails.is_empty(), "sustained notes dip under drum hits at {fails:?} st");
}

#[test]
fn pitch_change_mid_track_is_seamless() {
    // Changing pitch while playing must not leave a gap (it used to reopen the deck).
    let dir = std::env::temp_dir().join(format!("pitch-change-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("tone.wav");
    write_wav(&p, 48_000, 30.0, |t| {
        let v = 0.3 * (std::f64::consts::TAU * 330.0 * t).sin();
        (v, v)
    });
    let e = AudioEngine::new(Arc::new(Events(Mutex::new(vec![]))));
    e.load(p.to_string_lossy().into(), 1.0, 0.0).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    e.play();
    let rate = e.output_rate() as f64;
    let mut out = Vec::new();
    let pump = |out: &mut Vec<f32>, secs: f64| {
        for _ in 0..((secs * rate) as usize / CHUNK) {
            out.extend(e.render_offline(CHUNK));
            std::thread::sleep(Duration::from_millis(3));
        }
    };
    pump(&mut out, 2.0);
    let mark = out.len();
    let pos0 = e.position();
    e.set_speed_pitch(1.0, 3.0).unwrap();
    pump(&mut out, 2.0);
    e.set_speed_pitch(1.0, -2.0).unwrap();
    pump(&mut out, 2.0);
    let m = mono(&out[mark..]);
    let w = (rate / 200.0) as usize; // 5 ms
    let env = env_db(&m, w);
    let worst = env.iter().cloned().fold(f64::MAX, f64::min);
    let body = env[env.len() / 2];
    let played = (out.len() - mark) as f64 / 2.0 / rate;
    let drift = (e.position() - pos0) / played;
    eprintln!("pitch change: quietest 5 ms window {:.1} dB under steady level, track/out time {drift:.3}", body - worst);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(body - worst < 6.0, "gap or dip when changing pitch: {:.1} dB", body - worst);
    assert!((drift - 1.0).abs() < 0.03, "position drifted across pitch changes: {drift:.3}");
}

#[test]
fn cloud_tracks_pitch_clarity() {
    let Ok(dir) = std::env::var("LUMI_CLOUD_DIR") else {
        eprintln!("LUMI_CLOUD_DIR not set; skipping");
        return;
    };
    let dir = PathBuf::from(dir);
    let limit: usize = std::env::var("LUMI_PITCH_TRACKS").ok().and_then(|v| v.parse().ok()).unwrap_or(10);
    let skip: usize = std::env::var("LUMI_PITCH_SKIP").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    let unlocked = dir.join("unlocked");
    std::fs::create_dir_all(&unlocked).unwrap();
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "lms")).collect();
    files.sort();
    // Spread the pick across the library (different artists/genres).
    let step = (files.len() / limit.max(1)).max(1);
    let pick: Vec<PathBuf> = files.iter().skip(skip).step_by(step).take(limit).cloned().collect();
    let mut all = Vec::new();
    let mut refs: Vec<Clarity> = Vec::new();
    let mut fails = Vec::new();
    for f in &pick {
        let out = unlocked.join(f.file_stem().unwrap());
        if !out.exists() {
            assert!(lumisound_core::lock::lms_unlock(f.to_string_lossy().into(), out.to_string_lossy().into()), "unlock {f:?}");
        }
        let path = out.to_string_lossy().to_string();
        let dur = lumisound_core::analysis::probe_duration(path.clone(), unlocked.to_string_lossy().into());
        if dur < 50.0 {
            continue;
        }
        let name: String = f.file_name().unwrap().to_string_lossy().chars().take(40).collect();
        let (base, rate, _) = render(&path, 30.0, 15.0, 0.0);
        for st in [-1.5, 2.0, -4.0] {
            let (out, rate2, under) = render(&path, 30.0, 15.0, st);
            assert_eq!(rate, rate2);
            let c = clarity(&base, &out, rate);
            eprintln!("{name:<40} {st:+5} st: dips {:>5.1}/min  wobble {:.2} dB  worst {:>4.1} dB  underruns {under}", c.dips_per_min, c.wobble_db, c.worst_db);
            if under > 0 {
                fails.push(format!("{name} {st}: underruns"));
            }
            all.push(c);
            if std::env::var("LUMI_PITCH_REF").is_ok() {
                // Reference: the same clip pitched by Rubber Band (ffmpeg), played flat.
                let refp = unlocked.join(format!("ref_{st}.wav"));
                let ok = std::process::Command::new("ffmpeg").args(["-v", "error", "-y", "-ss", "30", "-t", "16", "-i", &path, "-af", &format!("rubberband=pitch={}", 2f64.powf(st / 12.0)), "-ar", &(rate as u32).to_string(), "-ac", "2", refp.to_str().unwrap()]).status().is_ok_and(|s| s.success());
                if ok {
                    let (r, _, _) = render(refp.to_str().unwrap(), 0.0, 15.0, 0.0);
                    let rc = clarity(&base, &r, rate);
                    eprintln!("{:<40} {st:+5} st: rubberband ref dips {:>5.1}/min  wobble {:.2} dB  worst {:>4.1} dB", "", rc.dips_per_min, rc.wobble_db, rc.worst_db);
                    refs.push(rc);
                }
            }
        }
    }
    let n = all.len().max(1) as f64;
    let dips = all.iter().map(|c| c.dips_per_min).sum::<f64>() / n;
    let wob = all.iter().map(|c| c.wobble_db).sum::<f64>() / n;
    let worst = all.iter().map(|c| c.dips_per_min).fold(0.0, f64::max);
    eprintln!("\n{} renders: mean dips {dips:.1}/min, worst track {worst:.1}/min, mean wobble {wob:.2} dB", all.len());
    if !refs.is_empty() {
        let n = refs.len() as f64;
        eprintln!("rubberband reference: mean dips {:.1}/min, mean wobble {:.2} dB", refs.iter().map(|c| c.dips_per_min).sum::<f64>() / n, refs.iter().map(|c| c.wobble_db).sum::<f64>() / n);
    }
    let max_dips: f64 = std::env::var("LUMI_PITCH_MAX_DIPS").ok().and_then(|v| v.parse().ok()).unwrap_or(f64::MAX);
    assert!(dips <= max_dips, "mean dips {dips:.1}/min over limit {max_dips}");
    assert!(fails.is_empty(), "{fails:?}");
}
