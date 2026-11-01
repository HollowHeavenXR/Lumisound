//! WSOLA time-stretching (pitch-preserving speed) for interleaved stereo.
//! Runs on the deck decode thread, not in the audio callback.

/// Output-side hop and analysis window (samples per channel).
const HOP: usize = 512;
const WIN: usize = HOP * 2;
/// ± search range for the best-matching input segment.
const SEEK: usize = 160;
/// Samples used for the correlation (mono mix), keeps the search cheap.
const CORR: usize = 256;

pub struct Wsola {
    /// Input frames per output frame (> 1 = faster).
    ratio: f64,
    input: Vec<[f32; 2]>,
    /// Fractional read position of the next analysis frame in `input`.
    pos: f64,
    /// Tail of the previous output window, overlapped with the next.
    prev: Vec<[f32; 2]>,
    window: Vec<f32>,
    first: bool,
    /// Start (in `input`) of the last segment used, for `drain_identity`.
    last_best: usize,
}

impl Wsola {
    pub fn new(ratio: f64) -> Self {
        let window = (0..WIN).map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / WIN as f32).cos()).collect();
        Self { ratio: ratio.clamp(0.25, 4.0), input: Vec::new(), pos: 0.0, prev: vec![[0.0; 2]; HOP], window, first: true, last_best: 0 }
    }

    pub fn is_identity(&self) -> bool {
        (self.ratio - 1.0).abs() < 1e-6
    }

    /// Change the ratio mid-stream (beat-matched crossfades ramp it).
    pub fn set_ratio(&mut self, ratio: f64) {
        self.ratio = ratio.clamp(0.25, 4.0);
    }

    /// At ratio 1 with nothing buffered the input passes straight through.
    pub fn can_bypass(&self) -> bool {
        self.is_identity() && self.input.is_empty()
    }

    /// Leave stretching without a seam: the pending tail plus the raw
    /// continuation equals the source (Hann halves at 50% overlap sum to 1),
    /// so emit `input[last_best + HOP..]` verbatim and reset.
    pub fn drain_identity(&mut self, out: &mut Vec<f32>) {
        let from = if self.first { self.pos as usize } else { self.last_best + HOP };
        for f in self.input.iter().skip(from) {
            out.push(f[0]);
            out.push(f[1]);
        }
        self.input.clear();
        self.pos = 0.0;
        self.first = true;
        self.last_best = 0;
        for p in self.prev.iter_mut() {
            *p = [0.0; 2];
        }
    }

    /// Feed interleaved stereo, append stretched interleaved stereo to `out`.
    pub fn process(&mut self, interleaved: &[f32], out: &mut Vec<f32>) {
        if self.can_bypass() {
            out.extend_from_slice(interleaved);
            return;
        }
        self.input.extend(interleaved.chunks_exact(2).map(|c| [c[0], c[1]]));
        loop {
            let base = self.pos as usize;
            let lo = base.saturating_sub(SEEK);
            if base + SEEK + WIN > self.input.len() {
                break;
            }
            // Find the segment near `base` that best continues the previous output.
            let best = if self.first {
                base
            } else {
                let mut best = base;
                let mut best_score = f32::MIN;
                let mut cand = lo;
                while cand <= base + SEEK {
                    let mut score = 0.0f32;
                    for i in 0..CORR {
                        let a = self.prev[i][0] + self.prev[i][1];
                        let b = self.input[cand + i][0] + self.input[cand + i][1];
                        score += a * b;
                    }
                    if score > best_score {
                        best_score = score;
                        best = cand;
                    }
                    cand += 4;
                }
                best
            };
            self.first = false;
            self.last_best = best;
            // Overlap-add: first half with the previous tail, keep the second half.
            for i in 0..HOP {
                let w_in = self.window[i];
                let s = self.input[best + i];
                out.push(self.prev[i][0] + s[0] * w_in);
                out.push(self.prev[i][1] + s[1] * w_in);
            }
            for i in 0..HOP {
                let w = self.window[HOP + i];
                let s = self.input[best + HOP + i];
                self.prev[i] = [s[0] * w, s[1] * w];
            }
            // The natural continuation of the chosen segment is `best + HOP`;
            // advance the analysis position by the stretched hop.
            self.pos += HOP as f64 * self.ratio;
            // Drop consumed input to bound memory.
            let drop = (self.pos as usize).saturating_sub(SEEK + WIN);
            if drop > 8192 {
                self.input.drain(..drop);
                self.pos -= drop as f64;
                self.last_best -= drop;
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
}
