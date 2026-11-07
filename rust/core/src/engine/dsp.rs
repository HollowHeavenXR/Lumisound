//! Realtime-safe DSP blocks: RBJ biquads, the 10-band graphic EQ, and
//! click-free gain ramps.

use std::f32::consts::PI;

pub const EQ_BANDS_HZ: [f32; 10] = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

#[derive(Clone, Copy, Default)]
pub struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    z1: [f32; 2],
    z2: [f32; 2],
}

#[derive(Clone, Copy, PartialEq)]
pub enum Shape {
    LowShelf,
    Peak,
    HighShelf,
}

impl Biquad {
    /// RBJ cookbook filter at `freq` Hz with `gain_db`, Q≈1.0 (shelves S=1).
    pub fn new(shape: Shape, freq: f32, gain_db: f32, q: f32, rate: f32) -> Self {
        let f = freq.min(rate * 0.45);
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = 2.0 * PI * f / rate;
        let (cw, sw) = (w0.cos(), w0.sin());
        let alpha = sw / (2.0 * q);
        let (b0, b1, b2, a0, a1, a2) = match shape {
            Shape::Peak => (1.0 + alpha * a, -2.0 * cw, 1.0 - alpha * a, 1.0 + alpha / a, -2.0 * cw, 1.0 - alpha / a),
            Shape::LowShelf => {
                let s = 2.0 * a.sqrt() * alpha;
                (
                    a * ((a + 1.0) - (a - 1.0) * cw + s),
                    2.0 * a * ((a - 1.0) - (a + 1.0) * cw),
                    a * ((a + 1.0) - (a - 1.0) * cw - s),
                    (a + 1.0) + (a - 1.0) * cw + s,
                    -2.0 * ((a - 1.0) + (a + 1.0) * cw),
                    (a + 1.0) + (a - 1.0) * cw - s,
                )
            }
            Shape::HighShelf => {
                let s = 2.0 * a.sqrt() * alpha;
                (
                    a * ((a + 1.0) + (a - 1.0) * cw + s),
                    -2.0 * a * ((a - 1.0) + (a + 1.0) * cw),
                    a * ((a + 1.0) + (a - 1.0) * cw - s),
                    (a + 1.0) - (a - 1.0) * cw + s,
                    2.0 * ((a - 1.0) - (a + 1.0) * cw),
                    (a + 1.0) - (a - 1.0) * cw - s,
                )
            }
        };
        Self { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0, z1: [0.0; 2], z2: [0.0; 2] }
    }

    /// Keep state, swap coefficients (no click on EQ moves).
    pub fn retune(&mut self, other: &Biquad) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (other.b0, other.b1, other.b2, other.a1, other.a2);
    }

    #[inline]
    pub fn process(&mut self, ch: usize, x: f32) -> f32 {
        // Transposed direct form II.
        let y = self.b0 * x + self.z1[ch];
        self.z1[ch] = self.b1 * x - self.a1 * y + self.z2[ch];
        self.z2[ch] = self.b2 * x - self.a2 * y;
        y
    }
}

/// Ten-band graphic EQ (low shelf, 8 peaks, high shelf), stereo.
pub struct Eq10 {
    bands: [Biquad; 10],
    gains: [f32; 10],
    pub enabled: bool,
    rate: f32,
    /// Auto-headroom: boosts are paid for by lowering the input first (half
    /// the largest boost), so a hot master isn't driven into the limiter and
    /// the tone change stays audible instead of being squashed. Smoothed.
    pre: f32,
    pre_target: f32,
    pre_coef: f32,
}

impl Eq10 {
    pub fn new(rate: f32) -> Self {
        let pre_coef = 1.0 - (-1.0 / (0.05 * rate)).exp(); // ~50 ms glide
        let mut e = Self { bands: [Biquad::default(); 10], gains: [0.0; 10], enabled: false, rate, pre: 1.0, pre_target: 1.0, pre_coef };
        e.set_gains(&[0.0; 10]);
        e
    }

    fn design(i: usize, g: f32, rate: f32) -> Biquad {
        let shape = match i {
            0 => Shape::LowShelf,
            9 => Shape::HighShelf,
            _ => Shape::Peak,
        };
        Biquad::new(shape, EQ_BANDS_HZ[i], g, if shape == Shape::Peak { 1.1 } else { 0.707 }, rate)
    }

    pub fn set_gains(&mut self, gains: &[f32]) {
        for i in 0..10 {
            let g = gains.get(i).copied().unwrap_or(0.0).clamp(-24.0, 24.0);
            self.gains[i] = g;
            let d = Self::design(i, g, self.rate);
            self.bands[i].retune(&d);
        }
        let boost = self.gains.iter().fold(0f32, |m, g| m.max(*g));
        self.pre_target = 10f32.powf(-0.5 * boost / 20.0);
    }

    /// Current headroom gain (1 = none).
    pub fn pre_gain(&self) -> f32 {
        self.pre_target
    }

    pub fn gains(&self) -> [f32; 10] {
        self.gains
    }

    pub fn is_flat(&self) -> bool {
        self.gains.iter().all(|g| g.abs() < 0.01)
    }

    #[inline]
    pub fn process(&mut self, ch: usize, mut x: f32) -> f32 {
        if !self.enabled || self.is_flat() {
            return x;
        }
        if ch == 0 {
            self.pre += (self.pre_target - self.pre) * self.pre_coef;
        }
        x *= self.pre;
        for b in self.bands.iter_mut() {
            x = b.process(ch, x);
        }
        x
    }
}

/// Linear gain ramp over a number of frames (fades, volume moves, crossfade).
#[derive(Clone, Copy)]
pub struct Ramp {
    pub value: f32,
    target: f32,
    step: f32,
    left: u64,
}

impl Ramp {
    pub fn new(v: f32) -> Self {
        Self { value: v, target: v, step: 0.0, left: 0 }
    }

    pub fn to(&mut self, target: f32, frames: u64) {
        if frames == 0 {
            self.value = target;
            self.target = target;
            self.left = 0;
            return;
        }
        self.target = target;
        self.step = (target - self.value) / frames as f32;
        self.left = frames;
    }

    #[inline]
    pub fn next(&mut self) -> f32 {
        if self.left > 0 {
            self.value += self.step;
            self.left -= 1;
            if self.left == 0 {
                self.value = self.target;
            }
        }
        self.value
    }

    pub fn done(&self) -> bool {
        self.left == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn rms_after(eq: &mut Eq10, freq: f32, rate: f32) -> f32 {
        let n = (rate as usize) / 2;
        let mut acc = 0.0;
        for i in 0..n {
            let x = (2.0 * PI * freq * i as f32 / rate).sin() * 0.5;
            let y = eq.process(0, x);
            if i > n / 2 {
                acc += y * y;
            }
        }
        (acc / (n / 2) as f32).sqrt()
    }
    #[test]
    fn eq_boosts_band() {
        let rate = 48000.0;
        let mut flat = Eq10::new(rate);
        flat.enabled = true;
        let base = rms_after(&mut flat, 1000.0, rate);
        let mut eq = Eq10::new(rate);
        eq.enabled = true;
        let mut g = [0.0; 10];
        g[5] = 6.0;
        eq.set_gains(&g);
        let boosted = rms_after(&mut eq, 1000.0, rate);
        let db = 20.0 * (boosted / base).log10();
        // +6 dB band, minus the 3 dB auto-headroom.
        assert!((db - 3.0).abs() < 0.6, "got {db} dB");
        let off = 20.0 * (rms_after(&mut eq, 8000.0, rate) / rms_after(&mut flat, 8000.0, rate)).log10();
        assert!((db - off - 6.0).abs() < 0.8, "tone change {}", db - off);
    }
    #[test]
    fn ramp_reaches_target() {
        let mut r = Ramp::new(0.0);
        r.to(1.0, 4);
        let v: Vec<f32> = (0..5).map(|_| r.next()).collect();
        assert_eq!(v[3], 1.0);
        assert!(r.done());
    }
}

// ---- Freeverb (Jezar's public-domain design) --------------------------------------------------

const COMB_TUNING: [usize; 8] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
const ALLPASS_TUNING: [usize; 4] = [556, 441, 341, 225];
const STEREO_SPREAD: usize = 23;

struct Comb {
    buf: Vec<f32>,
    idx: usize,
    store: f32,
}

impl Comb {
    fn new(n: usize) -> Self {
        Self { buf: vec![0.0; n.max(1)], idx: 0, store: 0.0 }
    }
    #[inline]
    fn process(&mut self, x: f32, feedback: f32, damp: f32) -> f32 {
        let out = self.buf[self.idx];
        self.store = out * (1.0 - damp) + self.store * damp;
        self.buf[self.idx] = x + self.store * feedback;
        self.idx = (self.idx + 1) % self.buf.len();
        out
    }
}

struct Allpass {
    buf: Vec<f32>,
    idx: usize,
}

impl Allpass {
    fn new(n: usize) -> Self {
        Self { buf: vec![0.0; n.max(1)], idx: 0 }
    }
    #[inline]
    fn process(&mut self, x: f32) -> f32 {
        let b = self.buf[self.idx];
        let out = b - x;
        self.buf[self.idx] = x + b * 0.5;
        self.idx = (self.idx + 1) % self.buf.len();
        out
    }
}

pub struct Reverb {
    combs: [Vec<Comb>; 2],
    allpasses: [Vec<Allpass>; 2],
    /// Mix, gliding to `wet_target` (~40 ms): slider moves don't zipper and
    /// switching off fades the tail instead of cutting it (a click + a jump
    /// in the dry level).
    wet: f32,
    wet_target: f32,
    wet_coef: f32,
    /// Fully off and cleared: turning it back on never replays old echoes.
    idle: bool,
    pub room: f32,
    pub damp: f32,
    pub width: f32,
    /// Pre-delay (per room size) so the dry sound lands before the room,
    /// like a real space; and a ~120 Hz low cut on what feeds the tank, so
    /// bass doesn't turn the tail to mud.
    pre: Vec<f32>,
    pre_w: usize,
    pre_len: usize,
    /// Previous pre-delay during a preset change (crossfaded out over 30 ms).
    pre_old: usize,
    pre_xf: f32,
    /// Tank input level, ramped 0 → 1 over 150 ms when the reverb starts:
    /// the music was already playing, so the room must fade in, not be
    /// "struck" by an abrupt onset (which rang broadband for ~1 s).
    feed: f32,
    rate: f32,
    hp_a: f32,
    hp_x1: f32,
    hp_y1: f32,
}

impl Reverb {
    pub fn new(rate: f32) -> Self {
        let scale = rate / 44_100.0;
        let mk = |spread: usize| -> (Vec<Comb>, Vec<Allpass>) {
            (
                COMB_TUNING.iter().map(|t| Comb::new(((t + spread) as f32 * scale) as usize)).collect(),
                ALLPASS_TUNING.iter().map(|t| Allpass::new(((t + spread) as f32 * scale) as usize)).collect(),
            )
        };
        let (cl, al) = mk(0);
        let (cr, ar) = mk(STEREO_SPREAD);
        let hp_rc = 1.0 / (std::f32::consts::TAU * 120.0);
        Self {
            combs: [cl, cr],
            allpasses: [al, ar],
            wet: 0.0,
            wet_target: 0.0,
            wet_coef: 1.0 - (-1.0 / (0.04 * rate)).exp(),
            idle: true,
            room: 0.5,
            damp: 0.5,
            width: 1.0,
            pre: vec![0.0; (rate * 0.06) as usize + 1],
            pre_w: 0,
            pre_len: (rate * 0.01) as usize,
            pre_old: 0,
            pre_xf: 1.0,
            feed: 0.0,
            rate,
            hp_a: hp_rc / (hp_rc + 1.0 / rate),
            hp_x1: 0.0,
            hp_y1: 0.0,
        }
    }

    pub fn wet_target(&self) -> f32 {
        self.wet_target
    }

    pub fn set_wet(&mut self, wet: f32) {
        self.wet_target = wet.clamp(0.0, 1.0);
    }

    fn clear(&mut self) {
        for ch in 0..2 {
            for c in self.combs[ch].iter_mut() {
                c.buf.fill(0.0);
                c.store = 0.0;
            }
            for a in self.allpasses[ch].iter_mut() {
                a.buf.fill(0.0);
            }
        }
        self.pre.fill(0.0);
        self.hp_x1 = 0.0;
        self.hp_y1 = 0.0;
    }

    /// Room presets matching the app's ReverbRoomPreset names.
    pub fn set_preset(&mut self, name: &str) {
        // (room, damping, pre-delay ms)
        let (room, damp, pre_ms) = match name {
            "smallRoom" => (0.35, 0.6, 4.0),
            "mediumRoom" => (0.55, 0.5, 9.0),
            "largeRoom" | "largeRoom2" => (0.75, 0.4, 14.0),
            "mediumHall" | "mediumHall2" | "mediumHall3" => (0.8, 0.35, 22.0),
            "largeHall" | "largeHall2" => (0.88, 0.3, 30.0),
            "plate" => (0.7, 0.15, 1.0),
            "cathedral" => (0.95, 0.25, 45.0),
            "mediumChamber" | "largeChamber" => (0.65, 0.45, 12.0),
            _ => (0.55, 0.5, 9.0),
        };
        self.room = room;
        self.damp = damp;
        let len = ((pre_ms / 1000.0 * self.rate) as usize).min(self.pre.len() - 1);
        if len != self.pre_len {
            self.pre_old = self.pre_len;
            self.pre_len = len;
            self.pre_xf = 0.0;
        }
    }

    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if self.wet_target <= 1e-4 && self.wet <= 1e-5 {
            if !self.idle {
                self.clear();
                self.idle = true;
                self.wet = 0.0;
                self.feed = 0.0;
            }
            return (l, r);
        }
        self.idle = false;
        self.wet += (self.wet_target - self.wet) * self.wet_coef;
        let x = (l + r) * 0.5;
        let y = self.hp_a * (self.hp_y1 + x - self.hp_x1);
        self.hp_x1 = x;
        self.hp_y1 = y;
        let n = self.pre.len();
        self.pre[self.pre_w] = y;
        let mut delayed = self.pre[(self.pre_w + n - self.pre_len) % n];
        if self.pre_xf < 1.0 {
            let old = self.pre[(self.pre_w + n - self.pre_old) % n];
            delayed = old + (delayed - old) * self.pre_xf;
            self.pre_xf = (self.pre_xf + 1.0 / (0.03 * self.rate)).min(1.0);
        }
        self.pre_w = (self.pre_w + 1) % n;
        if self.feed < 1.0 {
            self.feed = (self.feed + 1.0 / (0.15 * self.rate)).min(1.0);
        }
        // Raised-cosine shape: smooth at both ends of the ramp.
        let fg = 0.5 - 0.5 * (std::f32::consts::PI * self.feed).cos();
        let input = delayed * 0.03 * fg;
        let fb = self.room * 0.28 + 0.7;
        let damp = self.damp * 0.4;
        let mut out = [0f32; 2];
        for ch in 0..2 {
            let mut acc = 0.0;
            for c in self.combs[ch].iter_mut() {
                acc += c.process(input, fb, damp);
            }
            for a in self.allpasses[ch].iter_mut() {
                acc = a.process(acc);
            }
            out[ch] = acc;
        }
        let w1 = self.wet * (self.width / 2.0 + 0.5) * 3.0;
        let w2 = self.wet * ((1.0 - self.width) / 2.0) * 3.0;
        let dry = 1.0 - self.wet * 0.5;
        (l * dry + out[0] * w1 + out[1] * w2, r * dry + out[1] * w1 + out[0] * w2)
    }
}

/// Gentle feed-forward compressor for night mode (evens out loud/quiet).
pub struct Compressor {
    env: f32,
    attack: f32,
    release: f32,
    pub enabled: bool,
}

impl Compressor {
    pub fn new(rate: f32) -> Self {
        let coef = |ms: f32| (-1.0 / (ms * 0.001 * rate)).exp();
        Self { env: 0.0, attack: coef(10.0), release: coef(200.0), enabled: false }
    }

    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if !self.enabled {
            return (l, r);
        }
        let x = l.abs().max(r.abs());
        let c = if x > self.env { self.attack } else { self.release };
        self.env = c * self.env + (1.0 - c) * x;
        let db = 20.0 * self.env.max(1e-6).log10();
        // Threshold -24 dBFS, ratio 3:1, +6 dB make-up.
        let over = (db + 24.0).max(0.0);
        let gain_db = -over * (1.0 - 1.0 / 3.0) + 6.0;
        let g = 10f32.powf(gain_db / 20.0);
        (l * g, r * g)
    }
}

/// Transparent look-ahead peak limiter for the master output (replaces a
/// hard clip, which turned overloads from EQ boosts / crossfade overlap /
/// reverb into harsh distortion). Delays the signal by `LOOKAHEAD` samples
/// so gain reduction is fully in place before a peak arrives; the gain
/// follows a sliding-window minimum, ramps down over the look-ahead (no
/// instant steps) and releases smoothly. Below the threshold it's a pure
/// delay: bit-exact, no coloration.
pub struct Limiter {
    threshold: f32,
    delay: Vec<[f32; 2]>,
    pos: usize,
    /// Monotonic deque over the look-ahead window: (index, required gain).
    window: std::collections::VecDeque<(u64, f32)>,
    index: u64,
    gain: f32,
    attack_step: f32,
    release: f32,
}

pub const LOOKAHEAD_MS: f32 = 1.5;

impl Limiter {
    pub fn new(rate: f32) -> Self {
        let la = ((rate * LOOKAHEAD_MS / 1000.0) as usize).max(8);
        Self {
            threshold: 0.966, // -0.3 dBFS: headroom for inter-sample peaks
            delay: vec![[0.0; 2]; la],
            pos: 0,
            window: std::collections::VecDeque::with_capacity(la + 1),
            index: 0,
            gain: 1.0,
            attack_step: 1.0 / la as f32,
            release: 1.0 - (-1.0 / (rate * 0.08)).exp(), // ~80 ms
        }
    }

    pub fn latency(&self) -> usize {
        self.delay.len()
    }

    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        let la = self.delay.len() as u64;
        let peak = l.abs().max(r.abs());
        let need = if peak > self.threshold { self.threshold / peak } else { 1.0 };
        // Sliding minimum of the required gain over the look-ahead window.
        while self.window.back().is_some_and(|&(_, g)| g >= need) {
            self.window.pop_back();
        }
        self.window.push_back((self.index, need));
        while self.window.front().is_some_and(|&(i, _)| i + la <= self.index) {
            self.window.pop_front();
        }
        let target = self.window.front().map_or(1.0, |&(_, g)| g);
        if target < self.gain {
            // Reach the target by the time the peak leaves the delay line.
            self.gain = (self.gain - self.attack_step).max(target);
        } else {
            self.gain += (target - self.gain) * self.release;
        }
        let out = self.delay[self.pos];
        self.delay[self.pos] = [l, r];
        self.pos = (self.pos + 1) % self.delay.len();
        self.index += 1;
        let g = self.gain.min(1.0);
        (out[0] * g, out[1] * g)
    }
}
