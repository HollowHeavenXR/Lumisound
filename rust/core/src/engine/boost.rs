//! LumiBoost — the Lumisound engine's volume booster.
//!
//! Boosting by turning up one gain stage just drives the limiter: the
//! loudest band (usually the bass) hits the ceiling first and the whole mix
//! pumps and flattens. LumiBoost raises *loudness* instead:
//! 1. **Three bands** (Linkwitz–Riley 4th order at 160 Hz and 3.2 kHz; the
//!    low band gets an all-pass match so the bands sum back flat).
//! 2. **Per-band gain against a loudness ceiling**: each band is boosted by
//!    its share of the amount. A slow RMS follower (not a peak follower)
//!    holds the band's *loudness* under a ceiling, and the band's own soft
//!    clipper rounds off the peaks that the gain pushes past full scale.
//!    Mastered music already peaks at 0 dBFS, so a peak ceiling left nothing
//!    to add (the old design gave a loud master ~1 dB whatever the slider
//!    said); loudness comes from giving up crest factor, band by band, so
//!    one band saturating never ducks or distorts the others.
//! 3. **Route profile**: on headphones the bass shares the boost; on the
//!    phone's speaker the bass barely moves (the speaker can't move air
//!    below ~200 Hz and only distorts) and a harmonic bass enhancer adds the
//!    2nd/3rd harmonics of the bass instead, which the ear hears as the
//!    fundamental. Bluetooth/AirPlay sits in between.
//! 4. **Soft saturation** of the sum above −2.5 dBFS before the master
//!    look-ahead limiter, so the limiter only catches the rare true peak.
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
    /// Loudness ceiling for this band after gain (RMS, linear).
    ceiling: f32,
    /// Peak ceiling of the band's soft clipper (linear).
    peak: f32,
    /// Mean square of the band (slow follower).
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
                Band { share: 0.7, ceiling: db(-5.0), peak: db(-0.5), env: 0.0, gain: 1.0 },
                Band { share: 1.0, ceiling: db(-5.0), peak: db(-0.5), env: 0.0, gain: 1.0 },
                Band { share: 0.85, ceiling: db(-11.0), peak: db(-4.0), env: 0.0, gain: 1.0 },
            ],
            amount: 0.0,
            target: 0.0,
            step: 0.0,
            route: BoostRoute::Headphones,
            harmonics: 0.0,
            attack: 1.0 - (-1.0 / (0.012 * rate)).exp(),
            release: 1.0 - (-1.0 / (0.30 * rate)).exp(),
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
        // (bass share, bass loudness ceiling, bass peak ceiling, harmonics)
        let (low_share, low_ceiling, low_peak, harm) = match route {
            BoostRoute::Headphones => (0.7, -5.0, -0.5, 0.0),
            BoostRoute::External => (0.6, -6.0, -1.0, 0.0),
            BoostRoute::Wireless => (0.6, -6.0, -1.0, 0.15),
            BoostRoute::Speaker => (0.15, -13.0, -6.0, 0.45),
        };
        self.bands[0].share = low_share;
        self.bands[0].ceiling = db(low_ceiling);
        self.bands[0].peak = db(low_peak);
        self.harmonics = harm;
    }

    /// Gain for band `i` given this frame's mean square across channels.
    #[inline]
    fn band_gain(&mut self, i: usize, ms: f32) -> f32 {
        let a = self.amount;
        let b = &mut self.bands[i];
        let c = if ms > b.env { self.attack } else { self.release };
        b.env += (ms - b.env) * c;
        let want = db(a * b.share);
        let rms = b.env.sqrt();
        // Loud passages get what fits under the loudness ceiling (never
        // less than unity: the booster doesn't turn anything down).
        let fit = if rms > 1e-6 { b.ceiling / rms } else { want };
        let g = want.min(fit.max(1.0));
        b.gain += (g - b.gain) * if g < b.gain { self.attack } else { self.release };
        b.gain
    }

    /// `boosted` rounded off towards `ceiling`: linear up to `knee` (a share
    /// of the ceiling), then a tanh shoulder that never passes the ceiling.
    /// Never quieter than `dry`, the same sample before the boost — a peak
    /// that was already past the shoulder goes through as it came in.
    #[inline]
    fn shoulder(boosted: f32, dry: f32, ceiling: f32, knee: f32) -> f32 {
        let knee = ceiling * knee;
        let ax = boosted.abs();
        if ax <= knee {
            return boosted;
        }
        let room = ceiling - knee;
        let shaped = knee + room * ((ax - knee) / room).tanh();
        boosted.signum() * shaped.max(dry.abs().min(ax))
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
        let gl = self.band_gain(0, (lows[0] * lows[0] + lows[1] * lows[1]) * 0.5);
        let gm = self.band_gain(1, (mids[0] * mids[0] + mids[1] * mids[1]) * 0.5);
        let gh = self.band_gain(2, (highs[0] * highs[0] + highs[1] * highs[1]) * 0.5);
        let (pl, pm, ph) = (self.bands[0].peak, self.bands[1].peak, self.bands[2].peak);
        let reduction = [(0, gl), (1, gm), (2, gh)].iter().map(|&(i, g)| 20.0 * (g.max(1e-6)).log10() - self.amount * self.bands[i].share).fold(0f32, f32::min);
        self.reduction_db = self.reduction_db.min(reduction);
        // Harmonic bass (speaker / wireless): asymmetric saturation of the
        // low band makes 2nd and 3rd harmonics, band-passed into the range
        // the speaker can play, scaled with the boost.
        let harm_amt = self.harmonics * (self.amount / MAX_BOOST_DB);
        let mut out = [0f32; 2];
        for ch in 0..2 {
            let dry = lows[ch] + mids[ch] + highs[ch];
            let mut y = Self::shoulder(lows[ch] * gl, lows[ch], pl, 0.8) + Self::shoulder(mids[ch] * gm, mids[ch], pm, 0.8) + Self::shoulder(highs[ch] * gh, highs[ch], ph, 0.8);
            if harm_amt > 0.0 {
                let d = lows[ch] * 4.0;
                let shaped = d.tanh() + 0.3 * d * d.abs().min(1.0);
                let h = self.harm_lp.process(ch, self.harm_hp.process(ch, shaped));
                y += h * harm_amt;
            }
            out[ch] = Self::shoulder(y, if y * dry > 0.0 { dry } else { 0.0 }, 0.96, 0.85);
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

    /// A dense, already-loud "master": bass, mids, hats and drum hits that
    /// peak at full scale (about −10 dBFS RMS), like most released music.
    fn master(n: usize) -> Vec<f32> {
        let mut seed = 0x2545_F491u32;
        let mut v: Vec<f32> = (0..n)
            .map(|i| {
                let t = i as f32 / 48_000.0;
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                let noise = (seed as f32 / u32::MAX as f32) * 2.0 - 1.0;
                let beat = (t * 2.0).fract();
                let kick = (-beat * 18.0).exp() * (std::f32::consts::TAU * 55.0 * t).sin();
                let snare = (-((t * 2.0 + 0.5).fract()) * 30.0).exp() * noise;
                let bass = (std::f32::consts::TAU * 82.0 * t).sin() * 0.5;
                let mids = (std::f32::consts::TAU * 440.0 * t).sin() * 0.3 + (std::f32::consts::TAU * 1320.0 * t).sin() * 0.22 + (std::f32::consts::TAU * 2100.0 * t).sin() * 0.15;
                bass + mids + kick * 0.9 + snare * 0.6 + noise * 0.08
            })
            .collect();
        let peak = v.iter().fold(0f32, |a, b| a.max(b.abs()));
        v.iter_mut().for_each(|x| *x /= peak);
        v
    }

    fn rms_db(v: &[f32]) -> f32 {
        10.0 * (v.iter().map(|x| x * x).sum::<f32>() / v.len() as f32).log10()
    }

    /// Loudness gained on the loud master at `amount` dB, and the output peak.
    fn master_gain(amount: f32, route: BoostRoute) -> (f32, f32) {
        let src = master(48_000 * 4);
        let mut b = LumiBoost::new(48_000.0);
        b.set_route(route);
        b.set_amount(amount);
        let out: Vec<f32> = src.iter().map(|&x| b.process(x, x).0).collect();
        let half = src.len() / 2;
        let peak = out.iter().fold(0f32, |a, x| a.max(x.abs()));
        (rms_db(&out[half..]) - rms_db(&src[half..]), peak)
    }

    #[test]
    fn a_loud_master_gets_audibly_louder_at_every_step() {
        // The old peak-ceiling design gave this signal about 1 dB at any setting.
        let mut last = 0.0;
        for (amount, at_least) in [(1.0, 0.7), (2.0, 1.4), (3.5, 2.4), (6.0, 3.4), (9.0, 3.6), (12.0, 3.6)] {
            let (gain, _) = master_gain(amount, BoostRoute::Headphones);
            assert!(gain >= at_least, "+{amount} dB setting gave only {gain:.2} dB");
            assert!(gain <= amount + 0.3, "+{amount} dB setting gave {gain:.2} dB");
            assert!(gain >= last, "+{amount} dB ({gain:.2}) is quieter than the step before ({last:.2})");
            last = gain;
        }
    }

    #[test]
    fn boosted_peaks_stay_under_the_shoulder_unless_the_input_was_already_over() {
        // Peaks at 0.8: the input never reaches the shoulder, so the output mustn't pass it.
        let src: Vec<f32> = master(48_000 * 2).iter().map(|x| x * 0.6).collect();
        for amount in [3.0, 6.0, 12.0] {
            let mut b = LumiBoost::new(48_000.0);
            b.set_amount(amount);
            let peak = src.iter().map(|&x| b.process(x, -x)).fold(0f32, |a, (l, r)| a.max(l.abs()).max(r.abs()));
            assert!(peak <= 0.96 + 1e-4, "+{amount}: peak {peak}");
        }
    }

    #[test]
    fn quiet_tracks_get_the_whole_boost() {
        let src: Vec<f32> = master(48_000 * 3).iter().map(|x| x * 0.12).collect();
        let mut b = LumiBoost::new(48_000.0);
        b.set_amount(12.0);
        let out: Vec<f32> = src.iter().map(|&x| b.process(x, x).0).collect();
        let half = src.len() / 2;
        let gain = rms_db(&out[half..]) - rms_db(&src[half..]);
        // Headphone shares: bass 0.7, mids 1.0, highs 0.85 of the 12 dB.
        assert!(gain > 9.0 && gain < 12.2, "quiet track gain {gain}");
    }

    #[test]
    fn boost_never_turns_anything_down() {
        for route in [BoostRoute::Headphones, BoostRoute::Speaker, BoostRoute::Wireless, BoostRoute::External] {
            let (gain, _) = master_gain(0.5, route);
            assert!(gain > -0.1, "{route:?}: {gain}");
        }
    }

    #[test]
    fn hold_back_meter_reports_the_missing_gain() {
        let src = master(48_000 * 2);
        let mut b = LumiBoost::new(48_000.0);
        b.set_amount(12.0);
        for &x in &src {
            b.process(x, x);
        }
        let held = b.take_reduction();
        assert!(held < -2.0 && held >= -12.0, "held {held}");
        assert_eq!(b.take_reduction(), 0.0);
    }

    #[test]
    #[ignore]
    fn print_curve() {
        let src = master(48_000 * 4);
        println!("source rms {:.1} dBFS", rms_db(&src));
        for route in [BoostRoute::Headphones, BoostRoute::Speaker] {
            for a in [0.5, 1.0, 2.0, 3.0, 4.5, 6.0, 9.0, 12.0] {
                let (g, p) = master_gain(a, route);
                println!("{route:?} +{a}: {g:.2} dB peak {p:.3}");
            }
        }
    }

    /// Real tracks: `LUMI_BOOST_DIR=<dir> cargo test --release -p lumisound-core --lib boost::tests::real_tracks -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn real_tracks() {
        let Ok(dir) = std::env::var("LUMI_BOOST_DIR") else { return };
        for e in std::fs::read_dir(dir).unwrap().flatten() {
            let Some((rate, ch)) = lumisound_media::decode::planar(&e.path(), Some(45.0), Some(30.0)) else { continue };
            if ch.len() < 2 {
                continue;
            }
            let n = ch[0].len();
            let src: Vec<f32> = (0..n).map(|i| (ch[0][i] + ch[1][i]) * 0.5).collect();
            let peak = ch[0].iter().chain(&ch[1]).fold(0f32, |a, x| a.max(x.abs()));
            let mut line = format!("{:>5.1} dBFS rms, peak {:.2} |", rms_db(&src), peak);
            for route in [BoostRoute::Headphones, BoostRoute::Speaker] {
                for a in [1.0, 2.0, 3.5, 6.0, 9.0, 12.0] {
                    let mut b = LumiBoost::new(rate as f32);
                    b.set_route(route);
                    b.set_amount(a);
                    let out: Vec<f32> = (0..n).map(|i| { let (l, r) = b.process(ch[0][i], ch[1][i]); (l + r) * 0.5 }).collect();
                    line += &format!(" {:.1}", rms_db(&out[n / 3..]) - rms_db(&src[n / 3..]));
                }
                line += " |";
            }
            println!("{line} {}", e.file_name().to_string_lossy().chars().take(40).collect::<String>());
        }
    }
}
