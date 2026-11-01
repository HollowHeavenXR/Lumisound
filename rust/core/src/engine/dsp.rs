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
}

impl Eq10 {
    pub fn new(rate: f32) -> Self {
        let mut e = Self { bands: [Biquad::default(); 10], gains: [0.0; 10], enabled: false, rate };
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
    }

    pub fn is_flat(&self) -> bool {
        self.gains.iter().all(|g| g.abs() < 0.01)
    }

    #[inline]
    pub fn process(&mut self, ch: usize, mut x: f32) -> f32 {
        if !self.enabled || self.is_flat() {
            return x;
        }
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
        assert!((db - 6.0).abs() < 0.6, "got {db} dB");
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
