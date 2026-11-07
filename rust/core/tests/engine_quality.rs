//! Objective sound-quality measurements for the Lumisound Audio Engine, on
//! synthetic signals where the right answer is known exactly. Each
//! improvement pass is judged by these numbers (printed as a table), and the
//! asserts hold the quality bar so regressions fail the build.
//!
//!   cargo test --release -p lumisound-core --test engine_quality -- --nocapture --test-threads=1

use lumisound_core::engine::{AudioEngine, EngineListener};
use std::f64::consts::TAU;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Quiet(Mutex<Vec<String>>);
impl EngineListener for Quiet {
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

const CHUNK: usize = 512;

fn dir() -> PathBuf {
    let d = std::env::temp_dir().join(format!("lumi-quality-{}", std::process::id()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// 16-bit stereo WAV of a sum of sines (freq, amplitude).
fn wav(path: &Path, rate: u32, secs: f64, tones: &[(f64, f64)]) {
    wav_fn(path, rate, secs, |t| tones.iter().map(|(f, a)| a * (TAU * f * t).sin()).sum());
}

/// 16-bit stereo WAV of `f(t)`.
fn wav_fn(path: &Path, rate: u32, secs: f64, f: impl Fn(f64) -> f64) {
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
        let t = i as f64 / rate as f64;
        let v = f(t);
        let s = (v * 32767.0).round().clamp(-32768.0, 32767.0) as i16;
        b.extend_from_slice(&s.to_le_bytes());
        b.extend_from_slice(&s.to_le_bytes());
    }
    std::fs::write(path, b).unwrap();
}

fn engine() -> (Arc<AudioEngine>, Arc<Quiet>) {
    let q = Arc::new(Quiet(Mutex::new(vec![])));
    (AudioEngine::new(q.clone()), q)
}

/// Paced render (decks keep their buffers full).
fn pump(e: &AudioEngine, secs: f64) -> Vec<f32> {
    let n = (secs * e.output_rate() as f64) as usize / CHUNK;
    let mut out = Vec::with_capacity(n * CHUNK * 2);
    for _ in 0..n {
        out.extend(e.render_offline(CHUNK));
        std::thread::sleep(Duration::from_micros(1500));
    }
    out
}

fn left(x: &[f32]) -> Vec<f64> {
    x.iter().step_by(2).map(|v| *v as f64).collect()
}

/// THD+N averaged over 100 ms windows: what you'd hear as distortion,
/// smearing or warble, without penalising slow phase drift that a
/// time-stretcher may legitimately introduce over a whole second.
fn thdn_windowed_db(x: &[f64], rate: f64, freqs: &[f64]) -> f64 {
    let w = (rate * 0.1) as usize;
    let (mut res, mut tot) = (0.0, 0.0);
    for c in x.chunks(w).filter(|c| c.len() == w) {
        let fitted = refine(c, rate, freqs);
        res += residual(c, rate, &fitted);
        tot += c.iter().map(|v| v * v).sum::<f64>() / c.len() as f64;
    }
    10.0 * (res / tot.max(1e-20)).max(1e-20).log10()
}

fn refine(x: &[f64], rate: f64, freqs: &[f64]) -> Vec<f64> {
    let mut cur = freqs.to_vec();
    for i in 0..cur.len() {
        let f0 = freqs[i];
        let mut best = (f0, f64::MAX);
        let mut f = f0 * 0.995;
        while f <= f0 * 1.005 {
            cur[i] = f;
            let r = residual(x, rate, &cur);
            if r < best.1 {
                best = (f, r);
            }
            f += f0 * 0.0005;
        }
        cur[i] = best.0;
    }
    cur
}

/// THD+N in dB for `x` (mono) known to contain `freqs` (Hz): least-squares
/// fit of a sine+cosine at each (refined) frequency plus DC; the residual is
/// distortion + noise. Lower is better.
fn thdn_db(x: &[f64], rate: f64, freqs: &[f64]) -> f64 {
    let fitted = refine(x, rate, freqs);
    let res = residual(x, rate, &fitted);
    let total: f64 = x.iter().map(|v| v * v).sum::<f64>() / x.len() as f64;
    10.0 * (res / total.max(1e-20)).max(1e-20).log10()
}

/// Mean squared residual after a joint least-squares fit of DC plus a sine
/// and cosine at every frequency (normal equations, Gaussian elimination).
fn residual(x: &[f64], rate: f64, freqs: &[f64]) -> f64 {
    let k = 1 + 2 * freqs.len();
    let basis = |i: usize, j: usize| -> f64 {
        if j == 0 {
            1.0
        } else {
            let f = freqs[(j - 1) / 2];
            let a = TAU * f * i as f64 / rate;
            if j % 2 == 1 { a.sin() } else { a.cos() }
        }
    };
    let mut m = vec![vec![0.0; k + 1]; k];
    let mut row = vec![0.0; k];
    for (i, v) in x.iter().enumerate() {
        for (j, r) in row.iter_mut().enumerate() {
            *r = basis(i, j);
        }
        for a in 0..k {
            for b in 0..k {
                m[a][b] += row[a] * row[b];
            }
            m[a][k] += row[a] * v;
        }
    }
    for c in 0..k {
        let p = (c..k).max_by(|&a, &b| m[a][c].abs().total_cmp(&m[b][c].abs())).unwrap();
        m.swap(c, p);
        let d = m[c][c];
        if d.abs() < 1e-12 {
            continue;
        }
        for r in 0..k {
            if r != c {
                let f = m[r][c] / d;
                for cc in c..=k {
                    m[r][cc] -= f * m[c][cc];
                }
            }
        }
    }
    let coef: Vec<f64> = (0..k).map(|c| if m[c][c].abs() < 1e-12 { 0.0 } else { m[c][k] / m[c][c] }).collect();
    x.iter()
        .enumerate()
        .map(|(i, v)| {
            let fit: f64 = (0..k).map(|j| coef[j] * basis(i, j)).sum();
            (v - fit).powi(2)
        })
        .sum::<f64>()
        / x.len() as f64
}

/// Click score: the worst second difference relative to what the signal's
/// own content predicts (a 200 Hz sine has |x''| <= A·(2πf/fs)²). 1.0 =
/// smooth; a discontinuity shows as tens or hundreds.
fn click_score(x: &[f64], rate: f64, f: f64, amp: f64) -> f64 {
    let expect = amp * (TAU * f / rate).powi(2);
    let worst = x.windows(3).map(|w| (w[2] - 2.0 * w[1] + w[0]).abs()).fold(0.0, f64::max);
    worst / expect.max(1e-12)
}

struct Row(String, String, f64, String);

#[test]
fn engine_quality_report() {
    let d = dir();
    let rate = 48_000.0;
    let mut rows: Vec<Row> = Vec::new();
    let mut fails: Vec<String> = Vec::new();
    let mut check = |rows: &mut Vec<Row>, name: &str, metric: &str, v: f64, limit: f64, lower_better: bool| {
        let ok = if lower_better { v <= limit } else { v >= limit };
        rows.push(Row(name.into(), metric.into(), v, format!("{}{limit}", if lower_better { "<=" } else { ">=" })));
        if !ok {
            fails.push(format!("{name}: {metric} {v:.2} (limit {limit})"));
        }
    };

    // --- THD+N: pure tone and a 3-note chord through each processing path ---
    let tone48 = d.join("tone48.wav");
    wav(&tone48, 48_000, 6.0, &[(1000.0, 0.5)]);
    let tone44 = d.join("tone44.wav");
    wav(&tone44, 44_100, 6.0, &[(1000.0, 0.5)]);
    let chord = d.join("chord.wav");
    wav(&chord, 48_000, 6.0, &[(261.63, 0.2), (329.63, 0.2), (392.0, 0.2)]);
    let paths: &[(&str, &Path, f64, f64, &[f64], f64)] = &[
        // name, file, speed, pitch st, freqs (before pitch), THD+N limit dB
        ("plain 48k", &tone48, 1.0, 0.0, &[1000.0], -80.0),
        ("resample 44.1k", &tone44, 1.0, 0.0, &[1000.0], -70.0),
        ("speed 1.25x", &tone48, 1.25, 0.0, &[1000.0], -55.0),
        ("speed 0.8x", &tone48, 0.8, 0.0, &[1000.0], -55.0),
        ("pitch +4", &tone48, 1.0, 4.0, &[1000.0], -50.0),
        ("pitch -5", &tone48, 1.0, -5.0, &[1000.0], -50.0),
        ("speed 1.3 pitch +2", &tone48, 1.3, 2.0, &[1000.0], -50.0),
        ("chord plain", &chord, 1.0, 0.0, &[261.63, 329.63, 392.0], -80.0),
        ("chord speed 1.25x", &chord, 1.25, 0.0, &[261.63, 329.63, 392.0], -65.0),
        ("chord pitch +3", &chord, 1.0, 3.0, &[261.63, 329.63, 392.0], -65.0),
    ];
    for (name, file, speed, st, freqs, limit) in paths {
        let (e, _) = engine();
        e.set_speed_pitch(*speed, *st).unwrap();
        e.load(file.to_string_lossy().into(), 0.0, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        e.play();
        let out = left(&pump(&e, 2.5));
        let seg = &out[(rate * 1.0) as usize..(rate * 2.0) as usize];
        let ratio = 2f64.powf(st / 12.0);
        let shifted: Vec<f64> = freqs.iter().map(|f| f * ratio).collect();
        let v = thdn_windowed_db(seg, rate, &shifted);
        check(&mut rows, name, "THD+N dB (100ms)", v, *limit, true);
    }

    // --- Decode speed of the heaviest path (sinc resample + vocoder):
    // render flat out and see how fast the deck keeps up. ---
    {
        let long = d.join("long.wav");
        wav(&long, 44_100, 40.0, &[(1000.0, 0.3), (2500.0, 0.2)]);
        for (name, speed, st) in [("decode speed: pitch +4", 1.0, 4.0), ("decode speed: speed 1.3 pitch -3", 1.3, -3.0)] {
            let (e, _) = engine();
            e.set_speed_pitch(speed, st).unwrap();
            e.load(long.to_string_lossy().into(), 0.0, 0.0).unwrap();
            std::thread::sleep(Duration::from_millis(200));
            e.play();
            let t = std::time::Instant::now();
            let target = 20.0;
            let mut played = 0.0;
            while played < target && t.elapsed().as_secs_f64() < 20.0 {
                e.render_offline(CHUNK);
                // Only count frames that carried audio: an empty ring renders silence.
                played = e.health().playing_seconds - e.health().underrun_ms / 1000.0;
                if e.health().underrun_ms > 0.0 {
                    std::thread::sleep(Duration::from_micros(200));
                }
            }
            let x = played / t.elapsed().as_secs_f64();
            check(&mut rows, name, "x real time", x, 20.0, false);
        }
    }

    // --- Overload: a hot tone pushed over full scale by EQ ---
    let hot = d.join("hot.wav");
    wav(&hot, 48_000, 4.0, &[(1000.0, 0.8)]);
    {
        let (e, _) = engine();
        e.set_eq(vec![0.0, 0.0, 0.0, 0.0, 0.0, 9.0, 0.0, 0.0, 0.0, 0.0], true); // +9 dB at 1 kHz
        e.load(hot.to_string_lossy().into(), 0.0, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        e.play();
        let raw = pump(&e, 2.5);
        let out = left(&raw);
        let seg = &out[(rate * 1.0) as usize..(rate * 2.0) as usize];
        let peak = raw.iter().fold(0f32, |m, v| m.max(v.abs())) as f64;
        check(&mut rows, "EQ +9 dB on hot tone", "THD+N dB", thdn_db(seg, rate, &[1000.0]), -30.0, true);
        check(&mut rows, "EQ +9 dB on hot tone", "peak", peak, 0.97, true);
    }

    // --- Clicks at every transition (200 Hz sine: smooth, known curvature) ---
    let low = d.join("low.wav");
    wav(&low, 48_000, 8.0, &[(200.0, 0.5)]);
    let low2 = d.join("low2.wav");
    wav(&low2, 48_000, 8.0, &[(200.0, 0.5)]);
    {
        let (e, _) = engine();
        e.load(low.to_string_lossy().into(), 0.0, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        e.play();
        let start = left(&pump(&e, 0.5));
        e.pause(0.0);
        let pause = left(&pump(&e, 0.2));
        e.play();
        let resume = left(&pump(&e, 0.3));
        e.seek(3.7).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let seek = left(&pump(&e, 0.4));
        e.crossfade_to(low2.to_string_lossy().into(), 1.0, 1.234, 0.0, true, 1.0).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let xfade = left(&pump(&e, 1.5));
        for (name, x) in [("start", &start), ("pause", &pause), ("resume", &resume), ("seek", &seek), ("crossfade", &xfade)] {
            check(&mut rows, &format!("click at {name}"), "click score", click_score(x, rate, 200.0, 0.5), 8.0, true);
        }
    }
    {
        // Gapless hand-over between two tones of different phase.
        let a = d.join("ga.wav");
        // Whole cycles, so the content itself is continuous across the join:
        // any click is the engine's (a gap or a repeated block).
        wav(&a, 48_000, 1.0, &[(200.0, 0.5)]);
        let b = d.join("gb.wav");
        wav(&b, 48_000, 2.0, &[(200.0, 0.5)]);
        let (e, _) = engine();
        e.load(a.to_string_lossy().into(), 0.0, 0.0).unwrap();
        e.queue_next(b.to_string_lossy().into(), 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        e.play();
        let x = left(&pump(&e, 1.8));
        check(&mut rows, "click at gapless handover", "click score", click_score(&x[(rate * 0.2) as usize..], rate, 200.0, 0.5), 8.0, true);
    }

    // --- Transients under time-stretch: drum-like hits must stay sharp ---
    // (a longer analysis window resolves chords better but can smear an
    // attack backwards in time: "pre-echo"). Hits every 0.4 s over a quiet
    // pad; after stretching, the energy in the 25 ms before each detected
    // hit, relative to the 25 ms after it, must stay low.
    {
        let hits = d.join("hits.wav");
        wav_fn(&hits, 48_000, 8.0, |t| {
            let k = (t / 0.4).floor();
            let dt = t - k * 0.4 - 0.2;
            let pad = 0.03 * (TAU * 220.0 * t).sin();
            if dt < 0.0 { return pad; }
            // Deterministic "noise" burst decaying over ~15 ms.
            let n = ((t * 48_000.0).round() * 12.9898).sin() * 43758.5453;
            pad + 0.6 * (-dt / 0.015).exp() * (n - n.floor() - 0.5) * 2.0
        });
        for (name, speed) in [("hits speed 1.25x", 1.25), ("hits speed 0.8x", 0.8)] {
            let (e, _) = engine();
            e.set_speed_pitch(speed, 0.0).unwrap();
            e.load(hits.to_string_lossy().into(), 0.0, 0.0).unwrap();
            std::thread::sleep(Duration::from_millis(300));
            e.play();
            let x = left(&pump(&e, 6.0 / speed));
            let w = (rate * 0.025) as usize;
            let env: Vec<f64> = x.chunks(w / 5).map(|c| c.iter().map(|v| v * v).sum::<f64>()).collect();
            // Onsets: frames whose energy jumps 10x over the previous frame.
            let mut worst = f64::MIN;
            let mut count = 0;
            let mut i = 10;
            while i + 10 < env.len() {
                if env[i] > 10.0 * env[i - 1] && env[i] > 1e-3 {
                    let before: f64 = env[i - 5..i].iter().sum();
                    let after: f64 = env[i..i + 5].iter().sum();
                    worst = worst.max(10.0 * (before / after.max(1e-12)).log10());
                    count += 1;
                    i += 20;
                } else {
                    i += 1;
                }
            }
            assert!(count >= 8, "{name}: only {count} hits found");
            check(&mut rows, name, "pre-echo dB", worst, -18.0, true);
        }
    }

    // --- Vibrato: no click switching it on/off; the swing it was asked for ---
    {
        let tone = d.join("vib.wav");
        wav(&tone, 48_000, 6.0, &[(200.0, 0.5)]);
        let (e, _) = engine();
        e.load(tone.to_string_lossy().into(), 0.0, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        e.play();
        let mut x = left(&pump(&e, 0.4));
        e.set_modulation(0.0, 0.0, 0.0, 5.0, 0.5);
        let on = left(&pump(&e, 1.6));
        e.set_modulation(0.0, 0.0, 0.0, 0.0, 0.0);
        let off = left(&pump(&e, 0.5));
        // Pitch swing from zero crossings in the settled part (0.4-1.6 s in).
        let settled = on[(rate * 0.4) as usize..].to_vec();
        let settled = &settled[..];
        let zc: Vec<f64> = settled.windows(2).enumerate().filter(|(_, w)| w[0] < 0.0 && w[1] >= 0.0).map(|(i, w)| i as f64 + w[0] / (w[0] - w[1])).collect();
        let freqs: Vec<f64> = zc.windows(2).map(|w| rate / (w[1] - w[0])).collect();
        let (fmin, fmax) = freqs.iter().fold((f64::MAX, 0f64), |(a, b), v| (a.min(*v), b.max(*v)));
        let swing_st = 12.0 * (fmax / fmin).log2();
        x.extend(on);
        x.extend(off);
        // A ±0.5 st swing raises a 200 Hz sine's curvature by up to ~6%.
        check(&mut rows, "vibrato on/off", "click score", click_score(&x, rate, 200.0 * 1.06, 0.5), 8.0, true);
        check(&mut rows, "vibrato 5 Hz ±0.5 st", "swing st (p-p)", (swing_st - 1.0).abs(), 0.35, true);
        // Ultrasonic junk check: a clean ~200 Hz tone's second difference has
        // power x²·ω⁴; anything above that is high-frequency content the
        // effect added (0 dB = clean).
        let w4 = (TAU * 200.0 / rate).powi(4);
        let d2: f64 = settled.windows(3).map(|w| (w[2] - 2.0 * w[1] + w[0]).powi(2)).sum::<f64>() / settled.len() as f64;
        let p2: f64 = settled.iter().map(|v| v * v).sum::<f64>() / settled.len() as f64;
        check(&mut rows, "vibrato 5 Hz ±0.5 st", "HF excess dB", 10.0 * (d2 / (p2 * w4)).log10(), 1.0, true);
    }

    // --- 8D: loudness should stay steady while the sound rotates ---
    {
        let pink = d.join("pinkish.wav");
        wav(&pink, 48_000, 12.0, &[(220.0, 0.15), (550.0, 0.12), (1300.0, 0.1), (3100.0, 0.08)]);
        let (e, _) = engine();
        e.set_modulation(0.25, 0.0, 0.0, 0.0, 0.0);
        e.load(pink.to_string_lossy().into(), 0.0, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        e.play();
        let raw = pump(&e, 8.0);
        let w = (rate * 0.05) as usize;
        let pw: Vec<f64> = raw.chunks(w * 2).filter(|c| c.len() == w * 2).map(|c| c.iter().map(|v| (*v as f64).powi(2)).sum::<f64>()).collect();
        let (mn, mx) = pw.iter().fold((f64::MAX, 0f64), |(a, b), v| (a.min(*v), b.max(*v)));
        let swing = 10.0 * (mx / mn.max(1e-20)).log10();
        check(&mut rows, "8D rotation", "loudness swing dB", swing, 1.5, true);
    }

    eprintln!("\n{:<28} {:<20} {:>10}  {}", "case", "metric", "value", "limit");
    for Row(n, m, v, l) in &rows {
        eprintln!("{n:<28} {m:<20} {v:>10.2}  {l}");
    }
    let _ = std::fs::remove_dir_all(&d);
    if std::env::var("LUMI_QUALITY_BASELINE").is_err() {
        assert!(fails.is_empty(), "quality limits not met:\n{}", fails.join("\n"));
    }
}
