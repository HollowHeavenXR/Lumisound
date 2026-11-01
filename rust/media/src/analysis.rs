//! Pure audio analysis shared by the bridge (ffmpeg-decoded PCM) and the
//! app core (symphonia-decoded PCM): BPM (simple + spectral flux), key /
//! Camelot, waveform peaks, transition and spectral profiles.

const KS_MAJOR: [f64; 12] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const KS_MINOR: [f64; 12] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
const PITCH: [&str; 12] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];

/// Python's round(x, n): correctly rounded from the exact binary value,
/// ties to even. Rust's fixed-precision formatting does the same.
pub fn pyround(x: f64, nd: i32) -> f64 {
    if !x.is_finite() {
        return x;
    }
    format!("{:.*}", nd.max(0) as usize, x).parse().unwrap_or(x)
}

/// `_estimate_bpm` (main.py): energy-onset autocorrelation on 11025 Hz mono.
pub fn bpm_simple(s: &[i16]) -> Option<f64> {
    if s.len() * 2 < 11025 * 2 * 4 {
        return None;
    }
    let sr = 11025usize;
    let w = sr / 50;
    let mut energies = Vec::new();
    let mut i = 0;
    while i + w < s.len() {
        let sum: i64 = s[i..i + w].iter().map(|x| (*x as i64) * (*x as i64)).sum();
        energies.push(sum as f64 / w as f64);
        i += w;
    }
    if energies.len() < 20 {
        return None;
    }
    let onsets: Vec<f64> = (1..energies.len()).map(|i| (energies[i] - energies[i - 1]).max(0.0)).collect();
    let fr = sr as f64 / w as f64;
    let min_lag = ((fr * 60.0 / 200.0) as usize).max(1);
    let max_lag = ((fr * 60.0 / 60.0) as usize).min(onsets.len() - 1);
    if min_lag >= max_lag {
        return None;
    }
    let (mut best_lag, mut best) = (0usize, -1.0f64);
    for lag in min_lag..=max_lag {
        let score: f64 = (lag..onsets.len()).map(|i| onsets[i] * onsets[i - lag]).sum();
        if score > best {
            best = score;
            best_lag = lag;
        }
    }
    if best_lag == 0 {
        return None;
    }
    Some(pyround(60.0 * fr / best_lag as f64, 1))
}

/// `_compute_waveform`: 200 peak values in 0..1.
pub fn waveform(s: &[i16]) -> Option<Vec<f64>> {
    if s.is_empty() {
        return None;
    }
    let bucket = (s.len() / 200).max(1);
    Some(
        s.chunks(bucket)
            .take(200)
            .map(|c| pyround(c.iter().map(|x| (*x as i32).abs()).max().unwrap_or(0) as f64 / 32768.0, 4))
            .collect(),
    )
}

pub fn goertzel(s: &[i16], sr: f64, f: f64) -> f64 {
    let w = 2.0 * std::f64::consts::PI * f / sr;
    let c = 2.0 * w.cos();
    let (mut q1, mut q2) = (0.0f64, 0.0f64);
    for x in s {
        let q0 = c * q1 - q2 + *x as f64;
        q2 = q1;
        q1 = q0;
    }
    q1 * q1 + q2 * q2 - q1 * q2 * c
}

pub fn chroma_vector(s: &[i16], sr: u32) -> [f64; 12] {
    let mut chroma = [0.0; 12];
    let nyq = sr as f64 / 2.0;
    for octave in 2..5 {
        for pitch in 0..12 {
            let f = 440.0 * 2f64.powf(((pitch as f64 - 9.0) + ((octave as f64 - 4.0) * 12.0)) / 12.0);
            if f >= nyq {
                continue;
            }
            chroma[pitch] += goertzel(s, sr as f64, f);
        }
    }
    chroma
}

pub fn corr(a: &[f64], b: &[f64]) -> f64 {
    let ma = a.iter().sum::<f64>() / a.len() as f64;
    let mb = b.iter().sum::<f64>() / b.len() as f64;
    let num: f64 = a.iter().zip(b).map(|(x, y)| (x - ma) * (y - mb)).sum();
    let den = (a.iter().map(|x| (x - ma).powi(2)).sum::<f64>() * b.iter().map(|y| (y - mb).powi(2)).sum::<f64>()).sqrt();
    if den != 0.0 { num / den } else { 0.0 }
}

pub fn key_from_chroma(c: &[f64; 12]) -> Option<String> {
    if c.iter().all(|x| *x == 0.0) {
        return None;
    }
    let (mut best, mut score) = (None, -2.0);
    for root in 0..12 {
        let rot: Vec<f64> = c[root..].iter().chain(c[..root].iter()).copied().collect();
        let ma = corr(&rot, &KS_MAJOR);
        let mi = corr(&rot, &KS_MINOR);
        if ma > score {
            score = ma;
            best = Some(format!("{} major", PITCH[root]));
        }
        if mi > score {
            score = mi;
            best = Some(format!("{} minor", PITCH[root]));
        }
    }
    best
}

pub fn camelot(key: Option<&str>) -> Option<&'static str> {
    let parts: Vec<&str> = key?.split_whitespace().collect();
    if parts.len() != 2 {
        return None;
    }
    let major = [("C", "8B"), ("G", "9B"), ("D", "10B"), ("A", "11B"), ("E", "12B"), ("B", "1B"), ("F#", "2B"), ("C#", "3B"), ("G#", "4B"), ("D#", "5B"), ("A#", "6B"), ("F", "7B")];
    let minor = [("A", "8A"), ("E", "9A"), ("B", "10A"), ("F#", "11A"), ("C#", "12A"), ("G#", "1A"), ("D#", "2A"), ("A#", "3A"), ("F", "4A"), ("C", "5A"), ("G", "6A"), ("D", "7A")];
    let table: &[(&str, &str)] = match parts[1].to_lowercase().as_str() {
        "major" => &major,
        "minor" => &minor,
        _ => return None,
    };
    table.iter().find(|(p, _)| *p == parts[0]).map(|(_, c)| *c)
}

pub fn camelot_compatible(a: Option<&str>, b: Option<&str>) -> bool {
    let (Some(a), Some(b)) = (a, b) else { return false };
    if a == b {
        return true;
    }
    let split = |s: &str| -> Option<(i32, char)> { Some((s[..s.len() - 1].parse().ok()?, s.chars().last()?)) };
    let (Some((na, la)), Some((nb, lb))) = (split(a), split(b)) else { return false };
    if la == lb {
        let d = (na - nb).abs() % 12;
        return d == 1 || d == 11;
    }
    na == nb
}

// ---- locked_media.py ports --------------------------------------------------------------------

pub fn bpm_flux(s: &[i16]) -> Option<f64> {
    if s.len() * 2 < 4 * 11025 * 2 {
        return None;
    }
    let hop = 128;
    let frames = s.len() / hop;
    if frames < 64 {
        return None;
    }
    let energy: Vec<f32> = (0..frames)
        .map(|f| {
            let sum: f32 = s[f * hop..(f + 1) * hop].iter().map(|x| { let v = *x as f32 / 32768.0; v * v }).sum();
            (sum / hop as f32).sqrt()
        })
        .collect();
    let mut flux: Vec<f64> = (0..frames).map(|i| if i == 0 { 0.0 } else { (energy[i] - energy[i - 1]).max(0.0) as f64 }).collect();
    if flux.iter().cloned().fold(f64::MIN, f64::max) <= 0.0 {
        return None;
    }
    let mean = flux.iter().sum::<f64>() / flux.len() as f64;
    flux.iter_mut().for_each(|x| *x -= mean);
    let fr = 11025.0 / hop as f64;
    let min_lag = (fr * 60.0 / 200.0) as usize;
    let mut max_lag = (fr * 60.0 / 60.0) as usize;
    if max_lag >= flux.len() {
        max_lag = flux.len() - 1;
    }
    if min_lag < 1 || max_lag <= min_lag {
        return None;
    }
    let ac = |lag: usize| -> f64 { (lag..flux.len()).map(|i| flux[i] * flux[i - lag]).sum() };
    let c0 = ac(0);
    if c0 <= 0.0 {
        return None;
    }
    let (mut best, mut peak) = (0usize, f64::MIN);
    for lag in min_lag..=max_lag {
        let v = ac(lag);
        if v > peak {
            peak = v;
            best = lag;
        }
    }
    if peak / c0 < 0.10 {
        return None;
    }
    let mut bpm = 60.0 * fr / best as f64;
    while bpm > 140.0 && bpm / 2.0 >= 60.0 {
        bpm /= 2.0;
    }
    while bpm < 70.0 && bpm * 2.0 <= 200.0 {
        bpm *= 2.0;
    }
    if !(60.0..=200.0).contains(&bpm) {
        return None;
    }
    Some(pyround(bpm, 1))
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TransitionProfile {
    pub trailing_silence_s: f64,
    pub outro_slope_db_per_s: f64,
    pub outro_cold_stop: bool,
    pub outro_tail_db: f64,
    pub intro_lead_in_s: f64,
    pub intro_onset_hardness: f64,
}

pub fn envelope(s: &[i16]) -> Option<Vec<f64>> {
    let w = (8000.0 * 0.05) as usize;
    let frames = s.len() / w;
    if frames < 3 {
        return None;
    }
    Some(
        (0..frames)
            .map(|f| {
                let sum: f32 = s[f * w..(f + 1) * w].iter().map(|x| { let v = *x as f32 / 32768.0; v * v }).sum();
                (sum / w as f32).sqrt() as f64
            })
            .collect(),
    )
}

pub fn median(v: &[f64]) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = s.len();
    if n == 0 {
        return f64::NAN;
    }
    if n % 2 == 1 { s[n / 2] } else { (s[n / 2 - 1] + s[n / 2]) / 2.0 }
}

pub fn transition_from(tail_pcm: &[i16], head_pcm: &[i16]) -> Option<TransitionProfile> {
    let tail = envelope(tail_pcm)?;
    let head = envelope(head_pcm)?;
    let db = |x: f64| 20.0 * x.max(1e-5).log10();
    let win = 0.05;
    let tail_peak = tail.iter().cloned().fold(f64::MIN, f64::max);
    if tail_peak <= 0.0 {
        return None;
    }
    let threshold = (tail_peak * 0.01).max(0.0015);
    let last_music = tail.iter().rposition(|v| *v > threshold)?;
    let trailing = (tail.len() - 1 - last_music) as f64 * win;
    let music = &tail[..=last_music];
    let wf = (10.0 / win) as usize;
    let outro = if music.len() > wf { &music[music.len() - wf..] } else { music };
    let frames = outro.len();
    if frames < 4 {
        return None;
    }
    // Least-squares slope of dB over time (np.polyfit deg 1).
    let ys: Vec<f64> = outro.iter().map(|v| db(*v)).collect();
    let n = frames as f64;
    let ts: Vec<f64> = (0..frames).map(|i| i as f64 * win).collect();
    let (mt, my) = (ts.iter().sum::<f64>() / n, ys.iter().sum::<f64>() / n);
    let sxy: f64 = ts.iter().zip(&ys).map(|(t, y)| (t - mt) * (y - my)).sum();
    let sxx: f64 = ts.iter().map(|t| (t - mt).powi(2)).sum();
    let slope = if sxx > 0.0 { sxy / sxx } else { 0.0 };
    let tail_frames = 3usize.max((frames - 1).min((1.0 / win) as usize));
    let last = median(&outro[frames - tail_frames..]);
    let body = median(&outro[..(frames - tail_frames).max(1)]);
    let cold = db(body) - db(last) > 12.0 && slope > -2.0;
    let head_peak = head.iter().cloned().fold(f64::MIN, f64::max);
    let head_db: Vec<f64> = head.iter().map(|v| db(*v)).collect();
    let lead_th = db(head_peak) - 12.0;
    let first = head_db.iter().position(|d| *d >= lead_th);
    let lead_in = first.map(|i| i as f64 * win).unwrap_or(0.0);
    let onset = first.unwrap_or(0);
    let target = db(head_peak) - 3.0;
    let hardness = match head_db[onset..].iter().position(|d| *d >= target) {
        Some(r) => (1.0 - (r as f64 * win) / 2.0).clamp(0.0, 1.0),
        None => 0.0,
    };
    Some(TransitionProfile {
        trailing_silence_s: pyround(trailing, 2),
        outro_slope_db_per_s: pyround(slope, 2),
        outro_cold_stop: cold,
        outro_tail_db: pyround(db(last), 1),
        intro_lead_in_s: pyround(lead_in, 2),
        intro_onset_hardness: pyround(hardness, 3),
    })
}

pub const EQ_BANDS_HZ: [f64; 10] = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

pub fn spectral_from(s: &[i16]) -> Option<Vec<f64>> {
    const N: usize = 4096;
    const SR: f64 = 32000.0;
    if s.len() * 2 < N * 4 {
        return None;
    }
    let x: Vec<f64> = s.iter().map(|v| *v as f64 / 32768.0).collect();
    let hop = N / 2;
    if x.len() < N {
        return None;
    }
    let frames = (x.len() - N) / hop;
    if frames < 4 {
        return None;
    }
    let window: Vec<f64> = (0..N).map(|n| 0.5 - 0.5 * (2.0 * std::f64::consts::PI * n as f64 / (N - 1) as f64).cos()).collect();
    let mut planner = rustfft::FftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(N);
    let bins = N / 2 + 1;
    let mut power = vec![0.0f64; bins];
    let mut buf = vec![rustfft::num_complex::Complex::new(0.0, 0.0); N];
    for f in 0..frames {
        for (i, b) in buf.iter_mut().enumerate() {
            *b = rustfft::num_complex::Complex::new(x[f * hop + i] * window[i], 0.0);
        }
        fft.process(&mut buf);
        for (k, p) in power.iter_mut().enumerate() {
            *p += buf[k].norm_sqr();
        }
    }
    power.iter_mut().for_each(|p| *p /= frames as f64);
    let total: f64 = power.iter().sum();
    if total <= 0.0 {
        return None;
    }
    let freqs: Vec<f64> = (0..bins).map(|k| k as f64 * SR / N as f64).collect();
    let r2 = std::f64::consts::SQRT_2;
    let refd = total / (bins as f64).max(1.0);
    Some(
        EQ_BANDS_HZ
            .iter()
            .map(|c| {
                let (lo, hi) = (c / r2, c * r2);
                let (mut band, mut width) = (0.0, 0usize);
                for (k, f) in freqs.iter().enumerate() {
                    if *f >= lo && *f < hi {
                        band += power[k];
                        width += 1;
                    }
                }
                if width == 0 {
                    return 0.0;
                }
                let density = band / (width as f64).max(1.0);
                pyround(10.0 * (density.max(1e-12) / refd.max(1e-12)).log10(), 2)
            })
            .collect(),
    )
}

// ---- artwork ----------------------------------------------------------------------------------

// ---- loudness (ITU-R BS.1770 K-weighting, gated integrated loudness) -------------------------

struct Bq {
    b: [f64; 3],
    a: [f64; 2],
    x: [f64; 2],
    y: [f64; 2],
}

impl Bq {
    fn process(&mut self, x: f64) -> f64 {
        let y = self.b[0] * x + self.b[1] * self.x[0] + self.b[2] * self.x[1] - self.a[0] * self.y[0] - self.a[1] * self.y[1];
        self.x = [x, self.x[0]];
        self.y = [y, self.y[0]];
        y
    }
}

fn k_weighting(sr: f64) -> (Bq, Bq) {
    let (f0, g, q) = (1681.9744509555319, 3.99984385397, 0.7071752369554193);
    let k = (std::f64::consts::PI * f0 / sr).tan();
    let vh = 10f64.powf(g / 20.0);
    let vb = vh.powf(0.4996667741545416);
    let a0 = 1.0 + k / q + k * k;
    let shelf = Bq { b: [(vh + vb * k / q + k * k) / a0, 2.0 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0], a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0], x: [0.0; 2], y: [0.0; 2] };
    let (f1, q1) = (38.13547087602444, 0.5003270373238773);
    let k1 = (std::f64::consts::PI * f1 / sr).tan();
    let a01 = 1.0 + k1 / q1 + k1 * k1;
    let hp = Bq { b: [1.0, -2.0, 1.0], a: [2.0 * (k1 * k1 - 1.0) / a01, (1.0 - k1 / q1 + k1 * k1) / a01], x: [0.0; 2], y: [0.0; 2] };
    (shelf, hp)
}

/// Integrated loudness (LUFS) of planar float audio: 400 ms blocks, 75%
/// overlap, absolute (-70) and relative (-10 LU) gates.
pub fn integrated_lufs(rate: u32, chans: &[Vec<f32>]) -> Option<f64> {
    let sr = rate as f64;
    let frames = chans.first()?.len();
    let weighted: Vec<Vec<f64>> = chans
        .iter()
        .map(|c| {
            let (mut s, mut h) = k_weighting(sr);
            c.iter().map(|x| h.process(s.process(*x as f64))).collect()
        })
        .collect();
    let block = (sr * 0.4) as usize;
    let step = ((sr * 0.1) as usize).max(1);
    if block == 0 || frames < block {
        return None;
    }
    let mut blocks: Vec<(f64, f64)> = Vec::new();
    let mut start = 0;
    while start + block <= frames {
        let p: f64 = weighted.iter().map(|w| w[start..start + block].iter().map(|s| s * s).sum::<f64>() / block as f64).sum();
        if p > 0.0 {
            blocks.push((p, -0.691 + 10.0 * p.log10()));
        }
        start += step;
    }
    let abs: Vec<(f64, f64)> = blocks.into_iter().filter(|b| b.1 > -70.0).collect();
    if abs.is_empty() {
        return None;
    }
    let mean = abs.iter().map(|b| b.0).sum::<f64>() / abs.len() as f64;
    let rel = -0.691 + 10.0 * mean.log10() - 10.0;
    let gated: Vec<f64> = abs.iter().filter(|b| b.1 > rel).map(|b| b.0).collect();
    if gated.is_empty() {
        return None;
    }
    let p = gated.iter().sum::<f64>() / gated.len() as f64;
    (p > 0.0).then(|| -0.691 + 10.0 * p.log10())
}
