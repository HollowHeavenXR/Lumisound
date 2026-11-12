//! LumiEQ — the Lumisound engine's equalizer and its preset catalogue.
//!
//! Ten bands (32 Hz…16 kHz: low shelf, eight peaks, high shelf), built for
//! this engine rather than copied from a generic graphic EQ:
//! - **Proportional Q**: a band narrows as it is pushed harder, the way an
//!   analog console's does, so big moves stay musical and small ones broad.
//! - **Glide**: band gains move to a new setting over ~60 ms, coefficients
//!   recomputed every 32 frames, so dragging a slider or switching presets
//!   never zippers or clicks.
//! - **True headroom**: the input is lowered by the real peak of the combined
//!   response (measured over 48 points, not "the largest slider"), so
//!   neighbouring boosts that stack are paid for, and a cut-only curve costs
//!   no level.
//! - **Loudness match**: presets are levelled by their loudness-weighted
//!   average change, so switching preset changes the tone, not the volume
//!   (louder always sounds "better", which made the old comparison unfair).
//!
//! Presets are designed against this filter bank (they sound as named here
//! and only here) and exported with names, taglines and categories so every
//! app surface reads the same list.

use super::dsp::{Biquad, Shape};

pub const EQ_BANDS_HZ: [f32; 10] = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
pub const EQ_MAX_DB: f32 = 12.0;
const GLIDE_BLOCK: u32 = 32;
const GLIDE_SECS: f32 = 0.06;

fn band_q(i: usize, gain_db: f32) -> f32 {
    match i {
        0 | 9 => 0.707,
        _ => 0.9 + gain_db.abs() * 0.07,
    }
}

fn design(i: usize, g: f32, rate: f32) -> Biquad {
    let shape = match i {
        0 => Shape::LowShelf,
        9 => Shape::HighShelf,
        _ => Shape::Peak,
    };
    Biquad::new(shape, EQ_BANDS_HZ[i], g, band_q(i, g), rate)
}

/// Combined response (dB) of `gains` at `freqs`.
fn response_db(gains: &[f32; 10], freqs: &[f32], rate: f32) -> Vec<f32> {
    let bank: Vec<Biquad> = (0..10).map(|i| design(i, gains[i], rate)).collect();
    freqs.iter().map(|&f| 20.0 * bank.iter().map(|b| b.magnitude(f, rate)).product::<f32>().max(1e-6).log10()).collect()
}

fn log_freqs(n: usize, lo: f32, hi: f32) -> Vec<f32> {
    let (a, b) = (lo.ln(), hi.ln());
    (0..n).map(|i| (a + (b - a) * i as f32 / (n.max(2) - 1) as f32).exp()).collect()
}

/// Loudness weight (rough equal-loudness at listening level: the ear is
/// least sensitive in the deep bass and above 10 kHz).
fn loudness_weight(f: f32) -> f32 {
    if f < 100.0 {
        0.25 + 0.75 * (f / 100.0)
    } else if f < 1000.0 {
        1.0
    } else if f < 5000.0 {
        1.3
    } else if f < 10_000.0 {
        1.0
    } else {
        0.5
    }
}

/// (headroom gain, loudness make-up gain), both linear.
fn level_plan(gains: &[f32; 10], rate: f32) -> (f32, f32) {
    let freqs = log_freqs(48, 20.0, (rate * 0.45).min(20_000.0));
    let db = response_db(gains, &freqs, rate);
    let peak = db.iter().cloned().fold(f32::MIN, f32::max).max(0.0);
    let (mut sum, mut wsum) = (0f32, 0f32);
    for (f, d) in freqs.iter().zip(&db) {
        let w = loudness_weight(*f);
        sum += d * w;
        wsum += w;
    }
    let avg = if wsum > 0.0 { sum / wsum } else { 0.0 };
    (10f32.powf(-peak / 20.0), 10f32.powf(-avg / 20.0))
}

/// Stereo ten-band equalizer with glide, headroom and loudness match.
pub struct LumiEq {
    bands: [Biquad; 10],
    /// Gains being played now (gliding toward `target`).
    now: [f32; 10],
    target: [f32; 10],
    step: [f32; 10],
    glide_left: u32,
    block: u32,
    pub enabled: bool,
    pub loudness_match: bool,
    rate: f32,
    pre: f32,
    pre_target: f32,
    pre_coef: f32,
    /// Bypass mix (0 = dry, 1 = EQ) so enabling/disabling glides too.
    mix: f32,
    mix_step: f32,
}

impl LumiEq {
    pub fn new(rate: f32) -> Self {
        let mut e = Self {
            bands: [Biquad::default(); 10],
            now: [0.0; 10],
            target: [0.0; 10],
            step: [0.0; 10],
            glide_left: 0,
            block: 0,
            enabled: false,
            loudness_match: true,
            rate,
            pre: 1.0,
            pre_target: 1.0,
            pre_coef: 1.0 - (-1.0 / (0.05 * rate)).exp(),
            mix: 0.0,
            mix_step: 1.0 / (0.03 * rate),
        };
        for i in 0..10 {
            e.bands[i] = design(i, 0.0, rate);
        }
        e
    }

    pub fn set_gains(&mut self, gains: &[f32]) {
        for i in 0..10 {
            self.target[i] = gains.get(i).copied().unwrap_or(0.0).clamp(-EQ_MAX_DB, EQ_MAX_DB);
        }
        let blocks = ((GLIDE_SECS * self.rate) as u32 / GLIDE_BLOCK).max(1);
        for i in 0..10 {
            self.step[i] = (self.target[i] - self.now[i]) / blocks as f32;
        }
        self.glide_left = blocks;
        let (head, loud) = level_plan(&self.target, self.rate);
        self.pre_target = if self.loudness_match { head.min(loud) } else { head };
    }

    pub fn gains(&self) -> [f32; 10] {
        self.target
    }

    /// Current input gain (headroom × loudness match).
    pub fn pre_gain(&self) -> f32 {
        self.pre_target
    }

    fn flat(&self) -> bool {
        self.glide_left == 0 && self.target.iter().all(|g| g.abs() < 0.01)
    }

    #[inline]
    fn advance_glide(&mut self) {
        if self.glide_left == 0 {
            return;
        }
        self.glide_left -= 1;
        for i in 0..10 {
            self.now[i] = if self.glide_left == 0 { self.target[i] } else { self.now[i] + self.step[i] };
            let d = design(i, self.now[i], self.rate);
            self.bands[i].retune(&d);
        }
    }

    /// One stereo frame.
    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        let want = if self.enabled && !self.flat() { 1.0 } else { 0.0 };
        if want == 0.0 && self.mix <= 0.0 {
            return (l, r);
        }
        self.mix = if want > self.mix { (self.mix + self.mix_step).min(1.0) } else { (self.mix - self.mix_step).max(0.0) };
        self.block += 1;
        if self.block >= GLIDE_BLOCK {
            self.block = 0;
            self.advance_glide();
        }
        self.pre += (self.pre_target - self.pre) * self.pre_coef;
        let (mut wl, mut wr) = (l * self.pre, r * self.pre);
        for b in self.bands.iter_mut() {
            wl = b.process(0, wl);
            wr = b.process(1, wr);
        }
        let m = self.mix;
        (l + (wl - l) * m, r + (wr - r) * m)
    }
}

// ---- presets -------------------------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug)]
pub struct EqPresetInfo {
    pub id: String,
    pub name: String,
    pub tagline: String,
    /// "Signature", "Genre", "Device" or "Utility".
    pub category: String,
    pub gains: Vec<f32>,
}

const PRESETS: &[(&str, &str, &str, &str, [f32; 10])] = &[
    ("flat", "Reference", "The engine's neutral voice — nothing added.", "Signature", [0.0; 10]),
    ("lumi_signature", "Lumi Signature", "A touch of weight and air; the house sound.", "Signature", [2.0, 1.5, 0.5, 0.0, -0.5, -0.5, 0.0, 1.0, 1.5, 2.0]),
    ("deep_current", "Deep Current", "Sub-bass that rolls under the mix, not over it.", "Signature", [7.0, 5.5, 3.0, 0.5, -1.0, -1.0, 0.0, 0.5, 1.0, 1.0]),
    ("crystal_air", "Crystal Air", "Opens the top end; cymbals and breath shimmer.", "Signature", [-1.5, -1.0, -0.5, 0.0, 0.0, 0.5, 1.5, 3.0, 4.5, 5.5]),
    ("vocal_spotlight", "Vocal Spotlight", "Pulls the voice forward and clears the low mud.", "Signature", [-3.0, -2.0, -1.0, 0.5, 1.5, 3.0, 3.5, 2.0, 0.5, -0.5]),
    ("warm_tape", "Warm Tape", "Soft highs and a round low-mid, like a cassette.", "Signature", [2.5, 2.0, 1.5, 1.0, 0.0, -0.5, -1.0, -1.5, -2.0, -3.0]),
    ("neon_pop", "Neon Pop", "Bright, punchy and vocal-forward.", "Genre", [1.5, 2.0, 1.0, -0.5, -1.5, -0.5, 1.0, 2.5, 3.5, 3.0]),
    ("pulse_club", "Pulse Club", "Kick and sub up front, sparkling hats.", "Genre", [5.0, 4.5, 1.5, -1.0, -2.0, -1.0, 0.5, 2.0, 3.5, 3.0]),
    ("808_engine", "808 Engine", "Long 808 tails and crisp, clear bars.", "Genre", [6.5, 5.0, 1.5, -1.5, -1.5, 0.0, 1.0, 1.5, 2.5, 2.0]),
    ("arena_rock", "Arena Rock", "Guitars bite, drums hit, room-filling.", "Genre", [3.5, 2.5, 0.0, -1.5, -1.0, 0.5, 2.0, 3.0, 2.5, 1.5]),
    ("concert_hall", "Concert Hall", "Natural strings and air for orchestral work.", "Genre", [1.5, 1.0, 0.0, -0.5, -0.5, 0.0, 0.5, 1.5, 2.5, 3.0]),
    ("late_lounge", "Late Lounge", "Warm upright bass and smooth horns.", "Genre", [2.0, 1.5, 1.0, 0.5, -0.5, -1.0, 0.0, 1.0, 1.5, 1.0]),
    ("woodgrain", "Woodgrain", "Acoustic body and finger detail.", "Genre", [1.0, 1.5, 2.0, 1.0, 0.0, 0.5, 1.5, 1.5, 1.0, 1.5]),
    ("night_shift", "Night Shift", "Full sound at low volume (bass and treble the ear loses quietly).", "Utility", [5.0, 3.5, 1.5, 0.0, -0.5, 0.0, 0.5, 1.5, 2.5, 3.0]),
    ("podcast_clarity", "Spoken Word", "Podcasts and audiobooks: clear voices, no boom.", "Utility", [-6.0, -4.5, -2.0, 0.0, 2.0, 3.0, 3.0, 1.5, -0.5, -2.0]),
    ("phone_speaker", "Phone Speaker", "Skips bass a phone can't play; lifts what it can.", "Device", [-6.0, -3.0, 2.0, 2.0, 1.0, 0.0, 1.0, 2.0, 1.5, 0.0]),
    ("earbud_lift", "Earbud Lift", "Fills in the low end small earbuds lose to a loose fit.", "Device", [4.0, 3.5, 2.0, 0.5, 0.0, 0.0, -0.5, 0.0, 1.0, 1.5]),
    ("car_cabin", "Car Cabin", "Cuts the cabin boom, lifts detail over road noise.", "Device", [-2.0, -1.0, -1.5, -1.0, 0.0, 1.0, 2.0, 2.5, 2.0, 1.0]),
];

/// Every built-in preset, in display order ("custom" isn't listed: it is the
/// listener's own curve).
#[uniffi::export]
pub fn eq_presets() -> Vec<EqPresetInfo> {
    PRESETS
        .iter()
        .map(|(id, name, tag, cat, g)| EqPresetInfo { id: id.to_string(), name: name.to_string(), tagline: tag.to_string(), category: cat.to_string(), gains: g.to_vec() })
        .collect()
}

/// Gains for a preset id (zeros for "custom" or unknown ids).
#[uniffi::export]
pub fn eq_preset_gains(id: String) -> Vec<f32> {
    PRESETS.iter().find(|p| p.0 == id).map(|p| p.4.to_vec()).unwrap_or_else(|| vec![0.0; 10])
}

/// Current preset id for a stored value: ids pass through, names of the
/// presets before LumiEQ ("Bass Boost", "Hip-Hop"…) map to their successor.
#[uniffi::export]
pub fn eq_preset_resolve(stored: String) -> String {
    let id = match stored.as_str() {
        "Flat" => "flat",
        "Bass Boost" => "deep_current",
        "Treble Boost" => "crystal_air",
        "Vocal" => "vocal_spotlight",
        "Pop" => "neon_pop",
        "Electronic" => "pulse_club",
        "Rock" => "arena_rock",
        "Classical" => "concert_hall",
        "Jazz" => "late_lounge",
        "Hip-Hop" => "808_engine",
        "Acoustic" => "woodgrain",
        "Custom" => "custom",
        other => other,
    };
    if id == "custom" || PRESETS.iter().any(|p| p.0 == id) { id.to_string() } else { "flat".to_string() }
}

/// Auto EQ: the preset for a track from its genre tag, else its tempo.
#[uniffi::export]
pub fn eq_auto_preset(bpm: Option<f64>, genre: Option<String>) -> Option<String> {
    if let Some(g) = genre.map(|g| g.to_lowercase()).filter(|g| !g.trim().is_empty()) {
        let rules: &[(&[&str], &str)] = &[
            (&["podcast", "audiobook", "spoken", "talk", "comedy"], "podcast_clarity"),
            (&["hip hop", "hip-hop", "hiphop", "rap", "trap", "drill", "grime"], "808_engine"),
            (&["classical", "orchestra", "symphony", "baroque", "opera", "soundtrack", "score"], "concert_hall"),
            (&["acoustic", "folk", "singer-songwriter", "unplugged", "country"], "woodgrain"),
            (&["jazz", "blues", "swing", "bebop", "soul", "r&b", "rnb", "lounge"], "late_lounge"),
            (&["lo-fi", "lofi", "chill", "ambient", "vaporwave"], "warm_tape"),
            (&["edm", "electronic", "house", "techno", "trance", "dubstep", "dance", "drum and bass", "dnb", "phonk"], "pulse_club"),
            (&["metal", "rock", "punk", "grunge", "alternative"], "arena_rock"),
            (&["pop", "k-pop", "j-pop", "synthpop", "indie pop"], "neon_pop"),
            (&["vocal", "a cappella", "acappella", "choir"], "vocal_spotlight"),
        ];
        for (needles, id) in rules {
            if needles.iter().any(|n| g.contains(n)) {
                return Some(id.to_string());
            }
        }
    }
    let bpm = bpm.filter(|b| *b > 0.0)?;
    Some(
        match bpm {
            b if b < 70.0 => "concert_hall",
            b if b < 100.0 => "woodgrain",
            b if b < 128.0 => "neon_pop",
            _ => "pulse_club",
        }
        .to_string(),
    )
}

/// The curve `gains` produces, in dB at `points` log-spaced frequencies from
/// 20 Hz to 20 kHz (for drawing). Includes the level the engine applies.
#[uniffi::export]
pub fn eq_response_curve(gains: Vec<f32>, points: u32, loudness_match: bool) -> Vec<f32> {
    let rate = 48_000.0;
    let mut g = [0f32; 10];
    for (i, v) in gains.iter().take(10).enumerate() {
        g[i] = v.clamp(-EQ_MAX_DB, EQ_MAX_DB);
    }
    let freqs = log_freqs(points.clamp(2, 512) as usize, 20.0, 20_000.0);
    let (head, loud) = level_plan(&g, rate);
    let pre = 20.0 * (if loudness_match { head.min(loud) } else { head }).log10();
    response_db(&g, &freqs, rate).into_iter().map(|d| d + pre).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rms(eq: &mut LumiEq, freq: f32) -> f32 {
        let (mut acc, mut n) = (0f32, 0);
        for i in 0..48_000 {
            let x = (std::f32::consts::TAU * freq * i as f32 / 48_000.0).sin() * 0.5;
            let (l, _) = eq.process(x, x);
            if i > 24_000 {
                acc += l * l;
                n += 1;
            }
        }
        (acc / n as f32).sqrt()
    }

    #[test]
    fn flat_is_bit_exact_and_boost_lands_after_glide() {
        let mut eq = LumiEq::new(48_000.0);
        eq.enabled = true;
        assert_eq!(eq.process(0.3, -0.2), (0.3, -0.2));
        eq.loudness_match = false;
        let mut g = [0f32; 10];
        g[5] = 6.0;
        eq.set_gains(&g);
        let at = rms(&mut eq, 1000.0) / (0.5 / 2f32.sqrt());
        // +6 dB band, minus the 6 dB headroom = unity at the centre.
        assert!((20.0 * at.log10()).abs() < 0.5, "{}", 20.0 * at.log10());
        let side = rms(&mut eq, 100.0) / (0.5 / 2f32.sqrt());
        assert!(20.0 * side.log10() < -4.0);
    }

    #[test]
    fn presets_are_loudness_matched_and_resolve_legacy_names() {
        for p in eq_presets() {
            assert_eq!(p.gains.len(), 10);
            assert!(p.gains.iter().all(|g| g.abs() <= EQ_MAX_DB));
            let curve = eq_response_curve(p.gains.clone(), 64, true);
            assert!(curve.iter().all(|d| *d <= 0.3), "{} clips: {:?}", p.id, curve.iter().cloned().fold(f32::MIN, f32::max));
        }
        assert_eq!(eq_preset_resolve("Hip-Hop".into()), "808_engine");
        assert_eq!(eq_preset_resolve("neon_pop".into()), "neon_pop");
        assert_eq!(eq_preset_resolve("nonsense".into()), "flat");
        assert_eq!(eq_preset_resolve("Custom".into()), "custom");
        assert_eq!(eq_auto_preset(None, Some("UK Drill".into())).as_deref(), Some("808_engine"));
        assert_eq!(eq_auto_preset(Some(140.0), None).as_deref(), Some("pulse_club"));
        assert_eq!(eq_auto_preset(None, None), None);
    }

    #[test]
    fn no_nonfinite_under_extreme_moves() {
        let mut eq = LumiEq::new(44_100.0);
        eq.enabled = true;
        for k in 0..20 {
            let g: Vec<f32> = (0..10).map(|i| if (i + k) % 2 == 0 { 12.0 } else { -12.0 }).collect();
            eq.set_gains(&g);
            for i in 0..2000 {
                let (l, r) = eq.process((i as f32 * 0.3).sin(), (i as f32 * 0.7).cos());
                assert!(l.is_finite() && r.is_finite() && l.abs() < 4.0);
            }
        }
    }
}
