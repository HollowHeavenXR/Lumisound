//! Time-stretching (pitch-preserving speed) for interleaved stereo: a phase
//! vocoder with identity phase locking, stereo-coherent phases and
//! transient phase resets. Runs on the deck decode thread, never in the
//! audio callback.
//!
//! Why not WSOLA (the previous stretcher): splicing time-domain segments
//! only works when one alignment fits the whole signal. On chords and
//! polyphonic music no single offset does, so every splice broke phase and
//! the result warbled (measured THD+N ≈ -2 dB on a three-note chord at
//! 1.25x). Working per frequency bin keeps every partial continuous.
//!
//! * Identity phase locking (Laroche & Dolson): bins near a spectral peak
//!   keep their phase relation to the peak, so each partial stays one
//!   coherent sinusoid instead of a smear of independent bins.
//! * Stereo coherence: synthesis phases come from the mid (L+R) spectrum and
//!   the same rotation is applied to both channels, preserving the
//!   inter-channel phase (stereo image) instead of letting it drift.
//! * Transients: a frame whose spectrum suddenly gains energy across many
//!   bins (a drum hit) resets synthesis phase to the analysis phase, so
//!   attacks stay sharp instead of being smeared ("phasiness").
//! * At ratio 1 every frame is a phase reset: the overlap-add reconstructs
//!   the input exactly, so a stretch that returns to 1 (beat-matched
//!   crossfades) never jumps.

use rustfft::num_complex::Complex32;
use rustfft::{Fft, FftPlanner};
use std::f32::consts::PI;
use std::sync::Arc;

/// Frame size (≈85 ms at 48 kHz) and synthesis hop (87.5% overlap).
/// Measured (tests/engine_quality.rs) against the old 2048 / 75%: chords
/// at 1.25x -51.6 → -76.2 dB THD+N, chords pitched +3 st -39.7 → -74.6 dB,
/// and less pre-echo on drum hits (-17.9 → -25.2 dB), since the finer hop
/// lets transient phase resets land closer to the attack.
const N: usize = 4096;
const HS: usize = N / 8;
const BINS: usize = N / 2 + 1;
/// Hann² overlap-add at 87.5% overlap sums to 3.0.
const OLA_GAIN: f32 = 3.0;
/// Fraction of rising bins that marks a transient.
const TRANSIENT_FRACTION: f32 = 0.38;

pub struct Wsola {
    /// Input frames per output frame (> 1 = faster).
    ratio: f64,
    input: Vec<[f32; 2]>,
    /// Fractional analysis position (frames into `input`).
    pos: f64,
    fwd: Arc<dyn Fft<f32>>,
    inv: Arc<dyn Fft<f32>>,
    window: Vec<f32>,
    /// Overlap-add accumulator (N frames), output read from the front.
    acc: Vec<[f32; 2]>,
    prev_phase: Vec<f32>,
    synth_phase: Vec<f32>,
    prev_mag: Vec<f32>,
    /// Start (in `input`) of the previous analysis frame; the phase advance
    /// must use the hop actually taken (whole frames), not the fractional
    /// target, or every non-integer ratio accumulates phase error.
    prev_start: Option<u64>,
    /// Input frames dropped from the front so far (absolute positions).
    dropped: u64,
    started: bool,
    used: bool,
    /// Output frames still to drop: the stretched silence that primes the
    /// first frame (so a stream starts at full level, not on a window ramp).
    skip: u64,
    /// Output frames the real input calls for (Σ input / ratio) and the
    /// frames emitted, so `finish` ends the stream at exactly that length.
    expected: f64,
    emitted: u64,
    buf: [Vec<Complex32>; 2],
    mid: Vec<Complex32>,
    scratch: Vec<Complex32>,
    // Per-frame work buffers, reused (no allocation on the decode thread).
    mags: Vec<f32>,
    phase: Vec<f32>,
    peaks: Vec<usize>,
    new_synth: Vec<f32>,
}

fn wrap(x: f32) -> f32 {
    let y = (x + PI).rem_euclid(2.0 * PI) - PI;
    if y <= -PI { y + 2.0 * PI } else { y }
}

impl Wsola {
    pub fn new(ratio: f64) -> Self {
        let mut planner = FftPlanner::new();
        let fwd = planner.plan_fft_forward(N);
        let inv = planner.plan_fft_inverse(N);
        let scratch_len = fwd.get_inplace_scratch_len().max(inv.get_inplace_scratch_len());
        let window = (0..N).map(|i| 0.5 - 0.5 * (2.0 * PI * i as f32 / N as f32).cos()).collect();
        Self {
            ratio: ratio.clamp(0.25, 4.0),
            input: Vec::new(),
            pos: 0.0,
            fwd,
            inv,
            window,
            acc: vec![[0.0; 2]; N],
            prev_phase: vec![0.0; BINS],
            synth_phase: vec![0.0; BINS],
            prev_mag: vec![0.0; BINS],
            prev_start: None,
            dropped: 0,
            started: false,
            used: false,
            skip: 0,
            expected: 0.0,
            emitted: 0,
            buf: [vec![Complex32::new(0.0, 0.0); N], vec![Complex32::new(0.0, 0.0); N]],
            mid: vec![Complex32::new(0.0, 0.0); N],
            scratch: vec![Complex32::new(0.0, 0.0); scratch_len],
            mags: vec![0.0; BINS],
            phase: vec![0.0; BINS],
            peaks: Vec::with_capacity(BINS / 2),
            new_synth: vec![0.0; BINS],
        }
    }

    pub fn is_identity(&self) -> bool {
        (self.ratio - 1.0).abs() < 1e-6
    }

    /// Change the ratio mid-stream (beat-matched crossfades ramp it).
    pub fn set_ratio(&mut self, ratio: f64) {
        self.ratio = ratio.clamp(0.25, 4.0);
    }

    /// At ratio 1 with nothing ever processed the input passes straight through.
    pub fn can_bypass(&self) -> bool {
        self.is_identity() && !self.used
    }

    /// Kept for the deck's API. Once used, the vocoder keeps running: at
    /// ratio 1 it reconstructs the input exactly (phase reset every frame),
    /// so there is no seam to manage and nothing to drain.
    pub fn drain_identity(&mut self, _out: &mut Vec<f32>) {}

    /// Feed interleaved stereo, append stretched interleaved stereo to `out`.
    pub fn process(&mut self, interleaved: &[f32], out: &mut Vec<f32>) {
        if self.can_bypass() {
            out.extend_from_slice(interleaved);
            return;
        }
        if !self.used {
            // Prime with N - HS frames of silence: the first real sample then
            // sits where the overlap-add is already complete. The silence's
            // own stretched output is dropped below.
            self.used = true;
            // The silence is walked at ratio 1 (exact reconstruction), so the
            // first real sample comes out at full level, exactly `N - HS`
            // frames in; stretching starts from there.
            self.input.resize(N - HS, [0.0; 2]);
            self.skip = (N - HS) as u64;
        }
        self.expected += (interleaved.len() / 2) as f64 / self.ratio;
        self.input.extend(interleaved.chunks_exact(2).map(|c| [c[0], c[1]]));
        self.run(out);
    }

    /// End of stream: flush the tail still inside the analysis window, then
    /// cut the output to exactly the length the input calls for.
    pub fn finish(&mut self, out: &mut Vec<f32>) {
        if !self.used {
            return;
        }
        let start = out.len();
        let before = self.emitted;
        self.input.extend(std::iter::repeat_n([0.0f32; 2], N + HS));
        self.run(out);
        let allowed = (self.expected.round() as u64).saturating_sub(before) as usize;
        out.truncate(start + (allowed * 2).min(out.len() - start));
        self.emitted = before + ((out.len() - start) / 2) as u64;
    }

    fn run(&mut self, out: &mut Vec<f32>) {
        while (self.pos as usize) + N <= self.input.len() {
            let start = self.pos as usize;
            let abs = self.dropped + start as u64;
            let hop = self.prev_start.map_or(HS as u64, |p| abs - p).max(1) as usize;
            let priming = abs < (N - HS) as u64;
            let ratio = if priming { 1.0 } else { self.ratio };
            self.frame(start, hop, (ratio - 1.0).abs() < 1e-6);
            self.prev_start = Some(abs);
            // Emit the finished front hop, shift the accumulator.
            for f in &self.acc[..HS] {
                if self.skip > 0 {
                    self.skip -= 1;
                    continue;
                }
                out.push(f[0] / OLA_GAIN);
                out.push(f[1] / OLA_GAIN);
                self.emitted += 1;
            }
            self.acc.copy_within(HS.., 0);
            for f in &mut self.acc[N - HS..] {
                *f = [0.0; 2];
            }
            self.pos += HS as f64 * ratio;
            // Drop consumed input to bound memory.
            let drop = self.pos as usize;
            if drop > 16_384 {
                self.input.drain(..drop);
                self.pos -= drop as f64;
                self.dropped += drop as u64;
            }
        }
    }

    fn frame(&mut self, at: usize, hop: usize, exact: bool) {
        // Analysis: windowed FFT of both channels and their mid.
        for ch in 0..2 {
            for i in 0..N {
                self.buf[ch][i] = Complex32::new(self.input[at + i][ch] * self.window[i], 0.0);
            }
            self.fwd.process_with_scratch(&mut self.buf[ch], &mut self.scratch);
        }
        for k in 0..BINS {
            self.mid[k] = self.buf[0][k] + self.buf[1][k];
        }
        // Transient: many bins jumping up in level at once.
        let mut rising = 0usize;
        let mut considered = 0usize;
        let mut mags = std::mem::take(&mut self.mags);
        for k in 0..BINS {
            mags[k] = self.mid[k].norm();
        }
        let floor = mags.iter().cloned().fold(0.0f32, f32::max) * 1e-3;
        for k in 4..BINS {
            if mags[k] > floor {
                considered += 1;
                if mags[k] > self.prev_mag[k] * 1.41 + 1e-9 {
                    rising += 1;
                }
            }
        }
        let transient = considered > 16 && rising as f32 / considered as f32 > TRANSIENT_FRACTION;
        let reset = !self.started || exact || transient;

        let mut phase = std::mem::take(&mut self.phase);
        for k in 0..BINS {
            phase[k] = self.mid[k].arg();
        }
        if reset {
            self.synth_phase.copy_from_slice(&phase);
        } else {
            let ha = hop as f32;
            let hs = HS as f32;
            // Peaks (local maxima over ±2 bins) get true-frequency phase advance.
            let mut peaks = std::mem::take(&mut self.peaks);
            peaks.clear();
            for k in 2..BINS - 2 {
                let m = mags[k];
                if m > floor && m >= mags[k - 1] && m >= mags[k - 2] && m > mags[k + 1] && m > mags[k + 2] {
                    peaks.push(k);
                }
            }
            let mut new_synth = std::mem::take(&mut self.new_synth);
            for &p in &peaks {
                let omega = 2.0 * PI * p as f32 / N as f32;
                let dev = wrap(phase[p] - self.prev_phase[p] - omega * ha);
                let inst = omega + dev / ha;
                new_synth[p] = self.synth_phase[p] + inst * hs;
            }
            // Identity locking: every bin follows its nearest peak's rotation.
            if peaks.is_empty() {
                for k in 0..BINS {
                    let omega = 2.0 * PI * k as f32 / N as f32;
                    new_synth[k] = self.synth_phase[k] + omega * hs;
                }
            } else {
                let mut pi = 0;
                for k in 0..BINS {
                    while pi + 1 < peaks.len() && (peaks[pi + 1] as isize - k as isize).abs() <= (peaks[pi] as isize - k as isize).abs() {
                        pi += 1;
                    }
                    let p = peaks[pi];
                    if k != p {
                        new_synth[k] = new_synth[p] + (phase[k] - phase[p]);
                    }
                }
            }
            std::mem::swap(&mut self.synth_phase, &mut new_synth);
            self.new_synth = new_synth;
            self.peaks = peaks;
        }
        self.prev_phase.copy_from_slice(&phase);
        std::mem::swap(&mut self.prev_mag, &mut mags);
        self.mags = mags;
        self.started = true;

        // Same rotation (synthesis - analysis phase of the mid) on both
        // channels keeps their phase difference: the stereo image.
        // (`mid` is done with: it holds the per-bin rotation, computed once.)
        for k in 0..BINS {
            self.mid[k] = Complex32::from_polar(1.0, self.synth_phase[k] - phase[k]);
        }
        self.phase = phase;
        for ch in 0..2 {
            for k in 0..BINS {
                let v = self.buf[ch][k] * self.mid[k];
                self.buf[ch][k] = v;
                if k > 0 && k < N / 2 {
                    self.buf[ch][N - k] = v.conj();
                }
            }
            self.inv.process_with_scratch(&mut self.buf[ch], &mut self.scratch);
            let scale = 1.0 / N as f32;
            for i in 0..N {
                self.acc[i][ch] += self.buf[ch][i].re * scale * self.window[i];
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stretches_length_and_keeps_pitch() {
        let sr = 48_000usize;
        let tone: Vec<f32> = (0..sr * 2).flat_map(|i| {
            let v = (2.0 * std::f32::consts::PI * 440.0 * i as f32 / sr as f32).sin() * 0.5;
            [v, v]
        }).collect();
        for ratio in [0.5, 1.5] {
            let mut w = Wsola::new(ratio);
            let mut out = Vec::new();
            for c in tone.chunks(4096) {
                w.process(c, &mut out);
            }
            let frames = out.len() / 2;
            let expect = (sr as f64 * 2.0 / ratio) as usize;
            assert!((frames as f64 - expect as f64).abs() / (expect as f64) < 0.05, "ratio {ratio}: {frames} vs {expect}");
            // Zero crossings per second ≈ 2·440 regardless of speed.
            let mid = &out[out.len() / 4..out.len() / 4 * 3];
            let zc = mid.chunks_exact(2).collect::<Vec<_>>().windows(2).filter(|p| (p[0][0] >= 0.0) != (p[1][0] >= 0.0)).count();
            let secs = mid.len() as f64 / 2.0 / sr as f64;
            let hz = zc as f64 / secs / 2.0;
            assert!((hz - 440.0).abs() < 15.0, "ratio {ratio}: {hz} Hz");
        }
    }

    #[test]
    fn ratio_one_after_use_reconstructs_exactly() {
        let sr = 48_000usize;
        let sig: Vec<f32> = (0..sr).flat_map(|i| {
            let t = i as f32 / sr as f32;
            let v = (2.0 * PI * 300.0 * t).sin() * 0.3 + (2.0 * PI * 1234.0 * t).sin() * 0.2;
            [v, -v * 0.5]
        }).collect();
        let mut w = Wsola::new(1.2);
        let mut out = Vec::new();
        w.process(&sig[..8192], &mut out);
        w.set_ratio(1.0);
        let before = out.len();
        w.process(&sig[8192..], &mut out);
        // After a frame of settling, output equals the input delayed by the
        // vocoder's latency (N - HS) relative to where the analysis was.
        let tail = &out[before + N * 2..];
        let mut best = f32::MAX;
        for lag in 0..(N * 4) {
            let off = lag * 2;
            if off + 4000 > sig.len() { break; }
            let err: f32 = tail.iter().take(4000).zip(&sig[off..off + 4000]).map(|(a, b)| (a - b).abs()).fold(0.0, f32::max);
            best = best.min(err);
        }
        assert!(best < 1e-3, "ratio-1 reconstruction error {best}");
    }

    #[test]
    fn exact_length_and_full_level_from_the_start() {
        let sr = 48_000usize;
        let input: Vec<f32> = (0..sr).flat_map(|i| {
            let v = (2.0 * std::f32::consts::PI * 440.0 * i as f32 / sr as f32).sin() * 0.5;
            [v, v]
        }).collect();
        for ratio in [1.25, 0.8, 2.0] {
            let mut w = Wsola::new(ratio);
            let mut out = Vec::new();
            for c in input.chunks(1024) {
                w.process(c, &mut out);
            }
            w.finish(&mut out);
            let frames = out.len() / 2;
            let want = (sr as f64 / ratio).round() as usize;
            assert!(frames.abs_diff(want) <= 1, "ratio {ratio}: {frames} frames, want {want}");
            let rms = |a: usize, b: usize| (out[a * 2..b * 2].iter().step_by(2).map(|v| v * v).sum::<f32>() / (b - a) as f32).sqrt();
            let head = rms(0, 480);
            let body = rms(frames / 2, frames / 2 + 4800);
            assert!((head / body - 1.0).abs() < 0.1, "ratio {ratio}: first 10 ms at {:.2} of full level", head / body);
        }
    }
}
