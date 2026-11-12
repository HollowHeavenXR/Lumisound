//! LumiSpace — the Lumisound engine's spatial audio.
//!
//! The old renderer folded the track to mono and placed it as one source in
//! front of the head: head tracking worked, but the stereo image was gone.
//! LumiSpace keeps the stereo mix and plays it through two *virtual
//! speakers* in front of the listener, the way a mix is meant to be heard:
//! - Each speaker reaches each ear through its own path: Woodworth
//!   interaural delay (fractional, glided) and a Brown–Duda head-shadow
//!   filter for that angle — four paths, recomputed as the head turns, so
//!   the speakers stay put in the room.
//! - A pinna cue (a gentle notch near 8 kHz) helps the image sit in front
//!   rather than inside the head.
//! - Early reflections from a small set of walls (per mode) give the
//!   speakers a room; they are low-passed like real surfaces.
//! - Bass below 120 Hz bypasses the virtual speakers (no comb filtering of
//!   the low end, which is non-directional anyway).
//! - Level is matched to the dry signal, and mode changes cross-fade.
//!
//! Modes: Studio (±30°, small treated room), Wide (±50°, open), Concert
//! (±40°, large hall reflections), Crossfeed (no head tracking: a gentle
//! blend of each channel into the other ear, for long headphone sessions).

use super::dsp::{Biquad, Shape};

const HEAD_RADIUS: f32 = 0.0875;
const SPEED_OF_SOUND: f32 = 343.0;
const ITD_BUF: usize = 128;
const REFL_BUF: usize = 8192;

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpatialMode {
    Off,
    Studio,
    Wide,
    Concert,
    Crossfeed,
}

impl SpatialMode {
    /// (speaker half-angle °, reflections, head-tracked).
    fn params(self) -> (f32, &'static [(f32, f32, usize)], bool) {
        // Reflections: (delay ms, gain, ear 0 = left / 1 = right).
        const STUDIO: &[(f32, f32, usize)] = &[(4.3, 0.20, 0), (5.1, 0.18, 1), (8.9, 0.12, 1), (11.7, 0.11, 0), (16.2, 0.07, 0), (19.4, 0.06, 1)];
        const WIDE: &[(f32, f32, usize)] = &[(6.8, 0.15, 0), (7.9, 0.14, 1), (14.1, 0.09, 1), (17.6, 0.08, 0)];
        const CONCERT: &[(f32, f32, usize)] = &[
            (17.0, 0.24, 0),
            (21.5, 0.23, 1),
            (29.0, 0.19, 1),
            (34.5, 0.18, 0),
            (43.0, 0.14, 0),
            (51.0, 0.13, 1),
            (62.0, 0.10, 1),
            (77.0, 0.08, 0),
            (93.0, 0.06, 1),
            (118.0, 0.04, 0),
        ];
        match self {
            SpatialMode::Off => (0.0, &[], false),
            SpatialMode::Studio => (30.0, STUDIO, true),
            SpatialMode::Wide => (50.0, WIDE, true),
            SpatialMode::Concert => (40.0, CONCERT, true),
            SpatialMode::Crossfeed => (28.0, &[], false),
        }
    }
}

#[derive(Clone, Copy, Default)]
struct Shadow {
    b0: f32,
    b1: f32,
    a1: f32,
    x1: f32,
    y1: f32,
}

impl Shadow {
    /// Brown–Duda: H(s) = (α s + β)/(s + β), β = 2c/a, bilinear-transformed.
    /// `theta` = angle between source and the ear's axis.
    fn design(theta: f32, rate: f32) -> Self {
        let alpha_min = 0.1f32;
        let theta_min = 150f32.to_radians();
        let alpha = (1.0 + alpha_min / 2.0) + (1.0 - alpha_min / 2.0) * (theta / theta_min * std::f32::consts::PI).cos();
        let beta = 2.0 * SPEED_OF_SOUND / HEAD_RADIUS;
        let k = 2.0 * rate;
        let a0 = k + beta;
        Self { b0: (alpha * k + beta) / a0, b1: (beta - alpha * k) / a0, a1: (beta - k) / a0, x1: 0.0, y1: 0.0 }
    }
    fn retune(&mut self, o: &Shadow) {
        (self.b0, self.b1, self.a1) = (o.b0, o.b1, o.a1);
    }
    #[inline]
    fn process(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.b1 * self.x1 - self.a1 * self.y1;
        self.x1 = x;
        self.y1 = y;
        y
    }
}

/// One speaker → one ear.
#[derive(Clone, Copy, Default)]
struct Path {
    shadow: Shadow,
    delay: f32,
    target: f32,
}

pub struct LumiSpace {
    rate: f32,
    mode: SpatialMode,
    yaw: f32,
    /// paths[speaker][ear]
    paths: [[Path; 2]; 2],
    /// Per-speaker input history for the ITD taps.
    itd: [[f32; ITD_BUF]; 2],
    itd_w: usize,
    /// Mid signal history for reflections.
    refl: Vec<f32>,
    refl_w: usize,
    refl_taps: Vec<(usize, f32, usize)>,
    refl_lp: [Biquad; 2],
    /// Bass split (kept direct).
    split: [Biquad; 2],
    pinna: Biquad,
    /// Crossfeed low-pass.
    xf_lp: Biquad,
    xf_buf: [[f32; 32]; 2],
    xf_w: usize,
    xf_delay: usize,
    norm: f32,
    /// Wet mix 0…1, glided on mode changes.
    mix: f32,
    mix_target: f32,
    mix_step: f32,
    pending: Option<SpatialMode>,
}

impl LumiSpace {
    pub fn new(rate: f32) -> Self {
        let lp = |f: f32| Biquad::new(Shape::LowPass, f, 0.0, std::f32::consts::FRAC_1_SQRT_2, rate);
        let mut s = Self {
            rate,
            mode: SpatialMode::Off,
            yaw: 0.0,
            paths: [[Path::default(); 2]; 2],
            itd: [[0.0; ITD_BUF]; 2],
            itd_w: 0,
            refl: vec![0.0; REFL_BUF],
            refl_w: 0,
            refl_taps: Vec::new(),
            refl_lp: [lp(5000.0), lp(5000.0)],
            split: [lp(120.0), lp(120.0)],
            pinna: Biquad::new(Shape::Peak, 8200.0, -3.5, 2.5, rate),
            xf_lp: lp(700.0),
            xf_buf: [[0.0; 32]; 2],
            xf_w: 0,
            xf_delay: ((0.0003 * rate) as usize).clamp(1, 31),
            norm: 1.0,
            mix: 0.0,
            mix_target: 0.0,
            mix_step: 1.0 / (0.12 * rate),
            pending: None,
        };
        s.configure(SpatialMode::Off);
        s
    }

    pub fn mode(&self) -> SpatialMode {
        self.pending.unwrap_or(self.mode)
    }

    pub fn yaw(&self) -> f32 {
        self.yaw
    }

    /// Change mode: fades the current one out, switches, fades back in.
    pub fn set_mode(&mut self, mode: SpatialMode) {
        if mode == self.mode() {
            return;
        }
        if self.mix <= 0.0 {
            self.configure(mode);
            self.mix_target = if mode == SpatialMode::Off { 0.0 } else { 1.0 };
        } else {
            self.pending = Some(mode);
            self.mix_target = 0.0;
        }
    }

    fn configure(&mut self, mode: SpatialMode) {
        self.mode = mode;
        let (_, taps, _) = mode.params();
        self.refl_taps = taps.iter().map(|&(ms, g, ear)| (((ms * 0.001 * self.rate) as usize).clamp(1, REFL_BUF - 1), g, ear)).collect();
        let damp = if mode == SpatialMode::Concert { 3500.0 } else { 6000.0 };
        for f in self.refl_lp.iter_mut() {
            *f = Biquad::new(Shape::LowPass, damp, 0.0, std::f32::consts::FRAC_1_SQRT_2, self.rate);
        }
        self.set_yaw(self.yaw);
        for s in self.paths.iter_mut() {
            for p in s.iter_mut() {
                p.delay = p.target;
            }
        }
        // Level match: a centred source reaches each ear through two paths
        // (near + far, head-shadowed) plus reflections; measured sum ≈ this.
        let refl: f32 = taps.iter().map(|t| t.1 * t.1).sum::<f32>().sqrt();
        self.norm = match mode {
            SpatialMode::Crossfeed => 1.0,
            _ => 1.0 / (1.35 + refl),
        };
    }

    /// Head yaw in degrees (positive = head turned left). Ignored by
    /// Crossfeed, which isn't head-tracked.
    pub fn set_yaw(&mut self, yaw_deg: f32) {
        self.yaw = yaw_deg;
        let (half, _, tracked) = self.mode.params();
        let yaw = if tracked { yaw_deg } else { 0.0 };
        for (spk, side) in [(0usize, -1f32), (1, 1f32)] {
            // Speaker azimuth relative to the head (+ = right).
            let az = (side * half + yaw).to_radians();
            let az = (az + std::f32::consts::PI).rem_euclid(std::f32::consts::TAU) - std::f32::consts::PI;
            for (ear, esign) in [(0usize, -1f32), (1, 1f32)] {
                let theta = (az - esign * std::f32::consts::FRAC_PI_2).abs();
                let theta = if theta > std::f32::consts::PI { std::f32::consts::TAU - theta } else { theta };
                let d = Shadow::design(theta, self.rate);
                self.paths[spk][ear].shadow.retune(&d);
                let lat = az.sin() * esign;
                let tau = if lat >= 0.0 { 0.0 } else { HEAD_RADIUS / SPEED_OF_SOUND * (lat.abs().asin() + lat.abs()) };
                self.paths[spk][ear].target = (tau * self.rate).min((ITD_BUF - 2) as f32);
            }
        }
    }

    #[inline]
    fn read_itd(&self, spk: usize, delay: f32) -> f32 {
        let rp = self.itd_w as f32 - delay;
        let rp = if rp < 0.0 { rp + ITD_BUF as f32 } else { rp };
        let i0 = rp as usize % ITD_BUF;
        let f = rp.fract();
        self.itd[spk][i0] * (1.0 - f) + self.itd[spk][(i0 + 1) % ITD_BUF] * f
    }

    /// One stereo frame.
    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if self.mix != self.mix_target {
            self.mix = if self.mix < self.mix_target { (self.mix + self.mix_step).min(self.mix_target) } else { (self.mix - self.mix_step).max(self.mix_target) };
        } else if let Some(next) = self.pending.take() {
            self.configure(next);
            self.mix_target = if next == SpatialMode::Off { 0.0 } else { 1.0 };
        }
        if self.mix <= 0.0 && self.mode == SpatialMode::Off {
            return (l, r);
        }
        let (wl, wr) = match self.mode {
            SpatialMode::Off => (l, r),
            SpatialMode::Crossfeed => self.crossfeed(l, r),
            _ => self.speakers(l, r),
        };
        let m = self.mix;
        (l + (wl - l) * m, r + (wr - r) * m)
    }

    #[inline]
    fn crossfeed(&mut self, l: f32, r: f32) -> (f32, f32) {
        let n = self.xf_buf[0].len();
        self.xf_buf[0][self.xf_w] = l;
        self.xf_buf[1][self.xf_w] = r;
        let rd = (self.xf_w + n - self.xf_delay) % n;
        let (dl, dr) = (self.xf_buf[0][rd], self.xf_buf[1][rd]);
        self.xf_w = (self.xf_w + 1) % n;
        let fl = self.xf_lp.process(0, dr);
        let fr = self.xf_lp.process(1, dl);
        const AMT: f32 = 0.32;
        let k = 1.0 / (1.0 + AMT * 0.6);
        ((l + fl * AMT) * k, (r + fr * AMT) * k)
    }

    #[inline]
    fn speakers(&mut self, l: f32, r: f32) -> (f32, f32) {
        let lo_l = self.split[0].process(0, l);
        let lo_r = self.split[1].process(0, r);
        let (hl, hr) = (l - lo_l, r - lo_r);
        self.itd[0][self.itd_w] = hl;
        self.itd[1][self.itd_w] = hr;
        let mut ear = [0f32; 2];
        for spk in 0..2 {
            for e in 0..2 {
                let d = {
                    let p = &mut self.paths[spk][e];
                    p.delay += (p.target - p.delay) * 0.002;
                    p.delay
                };
                let s = self.read_itd(spk, d);
                ear[e] += self.paths[spk][e].shadow.process(s);
            }
        }
        self.itd_w = (self.itd_w + 1) % ITD_BUF;
        // Reflections of the (high) mid signal.
        let mid = (hl + hr) * 0.5;
        self.refl[self.refl_w] = mid;
        let mut rf = [0f32; 2];
        for &(d, g, e) in &self.refl_taps {
            rf[e] += self.refl[(self.refl_w + REFL_BUF - d) % REFL_BUF] * g;
        }
        self.refl_w = (self.refl_w + 1) % REFL_BUF;
        let rl = self.refl_lp[0].process(0, rf[0]);
        let rr = self.refl_lp[1].process(0, rf[1]);
        let (mut ol, mut or) = ((ear[0] + rl) * self.norm, (ear[1] + rr) * self.norm);
        ol = self.pinna.process(0, ol);
        or = self.pinna.process(1, or);
        (ol + lo_l, or + lo_r)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn energy(s: &mut LumiSpace, left_only: bool) -> (f32, f32) {
        let (mut el, mut er) = (0.0, 0.0);
        let mut seed = 0x2545F491u32;
        for i in 0..48_000 {
            // White noise: broadband, like music (pure tones comb against reflections).
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            let x = (seed as f32 / u32::MAX as f32 - 0.5) * 0.6;
            let (l, r) = if left_only { s.process(x, 0.0) } else { s.process(x, x) };
            assert!(l.is_finite() && r.is_finite());
            if i > 12_000 {
                el += l * l;
                er += r * r;
            }
        }
        (el, er)
    }

    #[test]
    fn off_is_bit_exact() {
        let mut s = LumiSpace::new(48_000.0);
        assert_eq!(s.process(0.4, -0.1), (0.4, -0.1));
    }

    #[test]
    fn keeps_stereo_and_follows_head() {
        let mut s = LumiSpace::new(48_000.0);
        s.set_mode(SpatialMode::Studio);
        // Left channel only: still clearly on the left (stereo kept, unlike the mono renderer).
        let (l, r) = energy(&mut s, true);
        assert!(l > r * 1.5, "left-only l {l} r {r}");
        // Centred source, head straight: balanced.
        let (l0, r0) = energy(&mut s, false);
        assert!((l0 / r0 - 1.0).abs() < 0.1, "centre {l0} {r0}");
        // Head turned left 90°: the front stage moves to the right ear.
        s.set_yaw(90.0);
        let (l, r) = energy(&mut s, false);
        assert!(r > l * 1.3, "turned right {r} left {l}");
    }

    #[test]
    fn level_is_close_to_dry_and_modes_switch_cleanly() {
        for mode in [SpatialMode::Studio, SpatialMode::Wide, SpatialMode::Concert, SpatialMode::Crossfeed] {
            let mut dry = LumiSpace::new(48_000.0);
            let (dl, dr) = energy(&mut dry, false);
            let mut s = LumiSpace::new(48_000.0);
            s.set_mode(mode);
            let (wl, wr) = energy(&mut s, false);
            let db = 10.0 * ((wl + wr) / (dl + dr)).log10();
            assert!(db.abs() < 4.0, "{mode:?} level {db} dB");
        }
        let mut s = LumiSpace::new(48_000.0);
        s.set_mode(SpatialMode::Concert);
        energy(&mut s, false);
        s.set_mode(SpatialMode::Wide);
        energy(&mut s, false);
        assert_eq!(s.mode(), SpatialMode::Wide);
        s.set_mode(SpatialMode::Off);
        energy(&mut s, false);
        assert_eq!(s.process(0.2, 0.1), (0.2, 0.1));
    }
}
