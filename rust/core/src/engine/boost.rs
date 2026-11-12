//! LumiBoost — the Lumisound engine's volume booster.
//!
//! Boosting by turning up one gain stage just drives the limiter: the
//! loudest band (usually the bass) hits the ceiling first and the whole mix
//! pumps and flattens. LumiBoost raises *loudness* instead:
//! 1. **Three bands** (Linkwitz–Riley 4th order at 160 Hz and 3.2 kHz; the
//!    low band gets an all-pass match so the bands sum back flat).
//! 2. **Per-band upward gain with its own ceiling**: each band is boosted by
//!    its share of the amount, but a fast envelope follower holds it under a
//!    band ceiling, so quiet passages gain the full boost and loud ones only
//!    what fits. One band hitting its ceiling never ducks the others.
//! 3. **Route profile**: on headphones the bass shares the boost; on the
//!    phone's speaker the bass barely moves (the speaker can't move air
//!    below ~200 Hz and only distorts) and a harmonic bass enhancer adds the
//!    2nd/3rd harmonics of the bass instead, which the ear hears as the
//!    fundamental. Bluetooth/AirPlay sits in between.
//! 4. **Soft saturation** above −2 dBFS before the master look-ahead limiter,
//!    so the limiter only catches the rare true peak.
//!
//! Zero boost is a bit-exact bypass. Amount changes glide over ~80 ms.

use super::dsp::{Biquad, Shape};

pub const MAX_BOOST_DB: f32 = 12.0;

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum BoostRoute {
    Headphones,
    Speaker,
    Wireless,
    External,
}

struct Lr4 {
    a: Biquad,
    b: Biquad,
}

impl Lr4 {
    fn new(shape: Shape, f: f32, rate: f32) -> Self {
        let q = std::f32::consts::FRAC_1_SQRT_2;
        Self { a: Biquad::new(shape, f, 0.0, q, rate), b: Biquad::new(shape, f, 0.0, q, rate) }
    }
    #[inline]
    fn process(&mut self, ch: usize, x: f32) -> f32 {
        self.b.process(ch, self.a.process(ch, x))
    }
}

struct Band {
    /// Gain share of the boost amount (0…1).
    share: f32,
    /// Peak ceiling for this band after gain (linear).
    ceiling: f32,
    env: f32,
    gain: f32,
}

pub struct LumiBoost {
    rate: f32,
    lo_lp: Lr4,
    lo_hp: Lr4,
    hi_lp: Lr4,
    hi_hp: Lr4,
    /// All-pass match for the low band (LP + HP at 3.2 kHz).
    ap_lp: Lr4,
    ap_hp: Lr4,
    /// Harmonic bass: shaped low band, band-passed to 180–700 Hz.
    harm_hp: Biquad,
    harm_lp: Biquad,
    bands: [Band; 3],
    amount: f32,
    target: f32,
    step: f32,
    route: BoostRoute,
    harmonics: f32,
    attack: f32,
    release: f32,
    /// Smallest band gain reduction this buffer, dB (for the meter).
    pub reduction_db: f32,
}

fn db(x: f32) -> f32 {
    10f32.powf(x / 20.0)
}

impl LumiBoost {
    pub fn new(rate: f32) -> Self {
        let mut b = Self {
            rate,
            lo_lp: Lr4::new(Shape::LowPass, 160.0, rate),
            lo_hp: Lr4::new(Shape::HighPass, 160.0, rate),
            hi_lp: Lr4::new(Shape::LowPass, 3200.0, rate),
            hi_hp: Lr4::new(Shape::HighPass, 3200.0, rate),
            ap_lp: Lr4::new(Shape::LowPass, 3200.0, rate),
            ap_hp: Lr4::new(Shape::HighPass, 3200.0, rate),
            harm_hp: Biquad::new(Shape::HighPass, 180.0, 0.0, 0.707, rate),
            harm_lp: Biquad::new(Shape::LowPass, 700.0, 0.0, 0.707, rate),
            bands: [
                Band { share: 0.7, ceiling: db(-4.0), env: 0.0, gain: 1.0 },
                Band { share: 1.0, ceiling: db(-3.0), env: 0.0, gain: 1.0 },
                Band { share: 0.8, ceiling: db(-6.0), env: 0.0, gain: 1.0 },
            ],
            amount: 0.0,
            target: 0.0,
            step: 0.0,
            route: BoostRoute::Headphones,
            harmonics: 0.0,
            attack: 1.0 - (-1.0 / (0.004 * rate)).exp(),
            release: 1.0 - (-1.0 / (0.18 * rate)).exp(),
            reduction_db: 0.0,
        };
        b.set_route(BoostRoute::Headphones);
        b
    }

    pub fn route(&self) -> BoostRoute {
        self.route
    }

    pub fn amount_target(&self) -> f32 {
        self.target
    }

    /// Boost amount in dB (0…12).
    pub fn set_amount(&mut self, db_amount: f32) {
        self.target = db_amount.clamp(0.0, MAX_BOOST_DB);
        self.step = (self.target - self.amount).abs() / (0.08 * self.rate);
    }

    pub fn set_route(&mut self, route: BoostRoute) {
        self.route = route;
        let (low_share, low_ceiling, harm) = match route {
            BoostRoute::Headphones => (0.7, -4.0, 0.0),
            BoostRoute::External => (0.6, -5.0, 0.0),
            BoostRoute::Wireless => (0.5, -5.0, 0.15),
            BoostRoute::Speaker => (0.15, -9.0, 0.45),
        };
        self.bands[0].share = low_share;
        self.bands[0].ceiling = db(low_ceiling);
        self.harmonics = harm;
    }

    #[inline]
    fn band_gain(&mut self, i: usize, peak: f32) -> f32 {
        let a = self.amount;
        let b = &mut self.bands[i];
        let c = if peak > b.env { self.attack } else { self.release };
        b.env += (peak - b.env) * c;
        let want = db(a * b.share);
        let fit = if b.env > 1e-6 { b.ceiling / b.env } else { want };
        let g = want.min(fit.max(1.0));
        // Smooth the gain itself (no zipper on the envelope's ripple).
        b.gain += (g - b.gain) * if g < b.gain { self.attack } else { self.release };
        b.gain
    }

    #[inline]
    fn soft_clip(x: f32) -> f32 {
        const KNEE: f32 = 0.79; // −2 dBFS
        let ax = x.abs();
        if ax <= KNEE {
            return x;
        }
        let over = (ax - KNEE) / (1.0 - KNEE);
        x.signum() * (KNEE + (1.0 - KNEE) * over.tanh())
    }

    /// One stereo frame.
    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if self.amount != self.target {
            self.amount = if self.amount < self.target { (self.amount + self.step).min(self.target) } else { (self.amount - self.step).max(self.target) };
        }
        if self.amount <= 0.0 {
            return (l, r);
        }
        let mut lows = [0f32; 2];
        let mut mids = [0f32; 2];
        let mut highs = [0f32; 2];
        for (ch, x) in [l, r].into_iter().enumerate() {
            let low = self.lo_lp.process(ch, x);
            let rest = self.lo_hp.process(ch, x);
            lows[ch] = self.ap_lp.process(ch, low) + self.ap_hp.process(ch, low);
            mids[ch] = self.hi_lp.process(ch, rest);
            highs[ch] = self.hi_hp.process(ch, rest);
        }
        let gl = self.band_gain(0, lows[0].abs().max(lows[1].abs()));
        let gm = self.band_gain(1, mids[0].abs().max(mids[1].abs()));
        let gh = self.band_gain(2, highs[0].abs().max(highs[1].abs()));
        let reduction = [(0, gl), (1, gm), (2, gh)].iter().map(|&(i, g)| 20.0 * (g.max(1e-6)).log10() - self.amount * self.bands[i].share).fold(0f32, f32::min);
        self.reduction_db = self.reduction_db.min(reduction);
        // Harmonic bass (speaker / wireless): asymmetric saturation of the
        // low band makes 2nd and 3rd harmonics, band-passed into the range
        // the speaker can play, scaled with the boost.
        let harm_amt = self.harmonics * (self.amount / MAX_BOOST_DB);
        let mut out = [0f32; 2];
        for ch in 0..2 {
            let mut y = lows[ch] * gl + mids[ch] * gm + highs[ch] * gh;
            if harm_amt > 0.0 {
                let d = lows[ch] * 4.0;
                let shaped = d.tanh() + 0.3 * d * d.abs().min(1.0);
                let h = self.harm_lp.process(ch, self.harm_hp.process(ch, shaped));
                y += h * harm_amt;
            }
            out[ch] = Self::soft_clip(y);
        }
        (out[0], out[1])
    }

    /// Read and reset the meter.
    pub fn take_reduction(&mut self) -> f32 {
        let r = self.reduction_db;
        self.reduction_db = 0.0;
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(b: &mut LumiBoost, freq: f32, amp: f32) -> (f32, f32) {
        let (mut acc, mut peak, mut n) = (0f32, 0f32, 0);
        for i in 0..48_000 {
            let x = (std::f32::consts::TAU * freq * i as f32 / 48_000.0).sin() * amp;
            let (l, _) = b.process(x, x);
            assert!(l.is_finite());
            if i > 24_000 {
                acc += l * l;
                peak = peak.max(l.abs());
                n += 1;
            }
        }
        ((acc / n as f32).sqrt(), peak)
    }

    #[test]
    fn zero_boost_is_bit_exact() {
        let mut b = LumiBoost::new(48_000.0);
        assert_eq!(b.process(0.25, -0.5), (0.25, -0.5));
    }

    #[test]
    fn quiet_material_gets_the_boost_loud_material_stays_under_full_scale() {
        let mut b = LumiBoost::new(48_000.0);
        b.set_amount(9.0);
        let quiet = 0.05;
        let (rms_q, _) = run(&mut b, 1000.0, quiet);
        let gain = 20.0 * (rms_q / (quiet / 2f32.sqrt())).log10();
        assert!(gain > 8.0 && gain < 9.5, "quiet gain {gain}");
        let (_, peak_l) = run(&mut b, 1000.0, 0.9);
        assert!(peak_l <= 1.0, "peak {peak_l}");
    }

    #[test]
    fn speaker_route_spares_the_bass() {
        let mut hp = LumiBoost::new(48_000.0);
        hp.set_amount(12.0);
        let (bass_hp, _) = run(&mut hp, 60.0, 0.05);
        let mut sp = LumiBoost::new(48_000.0);
        sp.set_route(BoostRoute::Speaker);
        sp.set_amount(12.0);
        let (bass_sp, _) = run(&mut sp, 60.0, 0.05);
        assert!(bass_hp > bass_sp * 1.8, "headphones {bass_hp} speaker {bass_sp}");
    }

    #[test]
    fn bands_sum_flat_at_tiny_boost() {
        // With a minimal boost, the three-band split must not colour the sound.
        let mut b = LumiBoost::new(48_000.0);
        b.set_amount(0.01);
        for f in [50.0, 160.0, 1000.0, 3200.0, 9000.0] {
            let (rms, _) = run(&mut b, f, 0.1);
            let dbv = 20.0 * (rms / (0.1 / 2f32.sqrt())).log10();
            assert!(dbv.abs() < 0.5, "{f} Hz: {dbv} dB");
        }
    }
}
