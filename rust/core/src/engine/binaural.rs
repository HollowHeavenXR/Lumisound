//! Lightweight binaural renderer for "spatial audio": the track (folded to
//! mono, like the AVAudioEnvironmentNode path) is a single source in front
//! of the listener; head yaw from the headphones turns the head. Spherical
//! head model: Woodworth interaural time difference + Brown–Duda head-shadow
//! shelf per ear, so the image stays anchored as the head turns.

const HEAD_RADIUS: f32 = 0.0875;
const SPEED_OF_SOUND: f32 = 343.0;
const MAX_DELAY: usize = 128;

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
        self.b0 = o.b0;
        self.b1 = o.b1;
        self.a1 = o.a1;
    }

    #[inline]
    fn process(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.b1 * self.x1 - self.a1 * self.y1;
        self.x1 = x;
        self.y1 = y;
        y
    }
}

pub struct Binaural {
    rate: f32,
    pub enabled: bool,
    shadow: [Shadow; 2],
    /// Current / target per-ear delays in samples (smoothed to avoid zipper).
    delay: [f32; 2],
    target: [f32; 2],
    buf: [Vec<f32>; 2],
    w: usize,
}

impl Binaural {
    pub fn new(rate: f32) -> Self {
        let mut b = Self { rate, enabled: false, shadow: [Shadow::default(); 2], delay: [0.0; 2], target: [0.0; 2], buf: [vec![0.0; MAX_DELAY], vec![0.0; MAX_DELAY]], w: 0 };
        b.set_yaw(0.0);
        b.delay = b.target;
        b
    }

    /// Head yaw in degrees (positive = head turned left, as CoreMotion gives
    /// it after the app's sign flip). The source stays fixed in front.
    pub fn set_yaw(&mut self, yaw_deg: f32) {
        // Source azimuth relative to the head (radians, + = to the right).
        let az = yaw_deg.to_radians();
        let az = (az + std::f32::consts::PI).rem_euclid(std::f32::consts::TAU) - std::f32::consts::PI;
        for (ear, sign) in [(0usize, -1f32), (1, 1f32)] {
            // Angle between the source and this ear's axis (ear at ±90°).
            let theta = (az - sign * std::f32::consts::FRAC_PI_2).abs();
            let theta = if theta > std::f32::consts::PI { std::f32::consts::TAU - theta } else { theta };
            let d = Shadow::design(theta, self.rate);
            self.shadow[ear].retune(&d);
            // Woodworth: extra path to the far ear.
            let lat = az.sin() * sign; // > 0 when the source is on this ear's side
            let tau = if lat >= 0.0 { 0.0 } else { HEAD_RADIUS / SPEED_OF_SOUND * (lat.abs().asin() + lat.abs()) };
            self.target[ear] = (tau * self.rate).min((MAX_DELAY - 2) as f32);
        }
    }

    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if !self.enabled {
            return (l, r);
        }
        let m = (l + r) * 0.5;
        let n = MAX_DELAY;
        let mut out = [0f32; 2];
        for ear in 0..2 {
            self.buf[ear][self.w] = m;
            self.delay[ear] += (self.target[ear] - self.delay[ear]) * 0.002;
            let rp = self.w as f32 - self.delay[ear];
            let rp = if rp < 0.0 { rp + n as f32 } else { rp };
            let i0 = rp as usize % n;
            let i1 = (i0 + 1) % n;
            let f = rp.fract();
            let s = self.buf[ear][i0] * (1.0 - f) + self.buf[ear][i1] * f;
            out[ear] = self.shadow[ear].process(s);
        }
        self.w = (self.w + 1) % n;
        (out[0], out[1])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn energy(b: &mut Binaural) -> (f32, f32) {
        let (mut el, mut er) = (0.0, 0.0);
        for i in 0..48_000 {
            let x = (i as f32 * 0.37).sin() * 0.3 + (i as f32 * 1.9).sin() * 0.3;
            let (l, r) = b.process(x, x);
            if i > 4800 {
                el += l * l;
                er += r * r;
            }
        }
        (el, er)
    }
    #[test]
    fn source_follows_head_turn() {
        let mut b = Binaural::new(48_000.0);
        b.enabled = true;
        let (l0, r0) = energy(&mut b);
        assert!((l0 / r0 - 1.0).abs() < 0.05, "centred {l0} {r0}");
        // Head turned left by 90°: the front source is now on the right.
        b.set_yaw(90.0);
        b.delay = b.target;
        let (l, r) = energy(&mut b);
        assert!(r > l * 1.5, "right {r} left {l}");
        b.set_yaw(-90.0);
        b.delay = b.target;
        let (l, r) = energy(&mut b);
        assert!(l > r * 1.5, "left {l} right {r}");
    }
}
