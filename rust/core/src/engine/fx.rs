//! LumiFX — the Lumisound engine's effects.
//!
//! An effect is a recipe over the engine's own stages: tempo/pitch (WSOLA),
//! LumiEQ, reverb rooms, modulation (8D pan, tremolo, vibrato) and the
//! `Character` stage defined here — band limiting, tape-style drive, bit and
//! sample-rate reduction and stereo width — which is what gives effects like
//! AM Radio, Lo-Fi Tape, Phone Call or 8-Bit a real sound of their own
//! instead of being EQ curves with a name.
//!
//! The catalogue lives here so every app surface lists the same effects with
//! the same parameters, and changing one changes it everywhere.

use super::dsp::{Biquad, Shape};

/// Character stage settings. Neutral = all zero / width 1 / bits 0.
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq)]
pub struct FxCharacter {
    /// High-pass corner in Hz (0 = off).
    pub highpass_hz: f32,
    /// Low-pass corner in Hz (0 = off).
    pub lowpass_hz: f32,
    /// Tape-style saturation 0…1.
    pub drive: f32,
    /// Bit depth 2…16 (0 = off).
    pub bits: u8,
    /// Sample-and-hold rate in Hz (0 = off).
    pub crush_rate_hz: f32,
    /// Stereo width: 0 mono, 1 as recorded, up to 2 extra wide.
    pub width: f32,
}

impl FxCharacter {
    pub const NEUTRAL: FxCharacter = FxCharacter { highpass_hz: 0.0, lowpass_hz: 0.0, drive: 0.0, bits: 0, crush_rate_hz: 0.0, width: 1.0 };

    pub fn is_neutral(&self) -> bool {
        self.highpass_hz <= 0.0 && self.lowpass_hz <= 0.0 && self.drive <= 0.0 && (self.bits == 0 || self.bits >= 16) && self.crush_rate_hz <= 0.0 && (self.width - 1.0).abs() < 1e-3
    }
}

/// The realtime character processor.
pub struct Character {
    rate: f32,
    cfg: FxCharacter,
    hp: [Biquad; 2],
    lp: [Biquad; 2],
    hold: [f32; 2],
    phase: f32,
    /// Wet mix, glided so switching effects never clicks.
    mix: f32,
    mix_target: f32,
    mix_step: f32,
    pending: Option<FxCharacter>,
}

impl Character {
    pub fn new(rate: f32) -> Self {
        let mut c = Self {
            rate,
            cfg: FxCharacter::NEUTRAL,
            hp: [Biquad::default(); 2],
            lp: [Biquad::default(); 2],
            hold: [0.0; 2],
            phase: 0.0,
            mix: 0.0,
            mix_target: 0.0,
            mix_step: 1.0 / (0.04 * rate),
            pending: None,
        };
        c.configure(FxCharacter::NEUTRAL);
        c
    }

    pub fn settings(&self) -> FxCharacter {
        self.pending.unwrap_or(self.cfg)
    }

    /// Fade the current character out, switch, fade the new one in.
    pub fn set(&mut self, cfg: FxCharacter) {
        if cfg == self.settings() {
            return;
        }
        if self.mix <= 0.0 {
            self.configure(cfg);
            self.mix_target = if cfg.is_neutral() { 0.0 } else { 1.0 };
        } else {
            self.pending = Some(cfg);
            self.mix_target = 0.0;
        }
    }

    fn configure(&mut self, cfg: FxCharacter) {
        self.cfg = cfg;
        let q = std::f32::consts::FRAC_1_SQRT_2;
        for ch in 0..2 {
            self.hp[ch] = Biquad::new(Shape::HighPass, cfg.highpass_hz.max(10.0), 0.0, q, self.rate);
            self.lp[ch] = Biquad::new(Shape::LowPass, if cfg.lowpass_hz > 0.0 { cfg.lowpass_hz } else { self.rate * 0.45 }, 0.0, q, self.rate);
        }
    }

    #[inline]
    fn saturate(x: f32, drive: f32) -> f32 {
        if drive <= 0.0 {
            return x;
        }
        // Asymmetric tape curve: soft, a little even-harmonic warmth, level-matched.
        let k = 1.0 + drive * 6.0;
        let y = (x * k + 0.08 * drive).tanh() - (0.08 * drive).tanh();
        y / k.tanh()
    }

    #[inline]
    pub fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if self.mix != self.mix_target {
            self.mix = if self.mix < self.mix_target { (self.mix + self.mix_step).min(self.mix_target) } else { (self.mix - self.mix_step).max(self.mix_target) };
        } else if let Some(next) = self.pending.take() {
            self.configure(next);
            self.mix_target = if next.is_neutral() { 0.0 } else { 1.0 };
        }
        if self.mix <= 0.0 {
            return (l, r);
        }
        let c = self.cfg;
        let mut s = [l, r];
        // Sample-rate reduction (sample and hold).
        if c.crush_rate_hz > 0.0 {
            self.phase += c.crush_rate_hz / self.rate;
            if self.phase >= 1.0 {
                self.phase -= 1.0;
                self.hold = s;
            }
            s = self.hold;
        }
        for (ch, x) in s.iter_mut().enumerate() {
            let mut y = *x;
            if c.highpass_hz > 0.0 {
                y = self.hp[ch].process(0, y);
            }
            if c.lowpass_hz > 0.0 {
                y = self.lp[ch].process(0, y);
            }
            y = Self::saturate(y, c.drive);
            if c.bits > 0 && c.bits < 16 {
                let steps = (1u32 << (c.bits - 1)) as f32;
                y = (y * steps).round() / steps;
            }
            *x = y;
        }
        // Stereo width (mid/side).
        if (c.width - 1.0).abs() > 1e-3 {
            let mid = (s[0] + s[1]) * 0.5;
            let side = (s[0] - s[1]) * 0.5 * c.width.clamp(0.0, 2.0);
            // Keep loudness steady as width grows.
            let norm = 1.0 / (1.0 + (c.width - 1.0).max(0.0) * 0.25);
            s = [(mid + side) * norm, (mid - side) * norm];
        }
        let m = self.mix;
        (l + (s[0] - l) * m, r + (s[1] - r) * m)
    }
}

// ---- catalogue ------------------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug)]
pub struct FxPreset {
    pub id: String,
    pub name: String,
    /// SF Symbol.
    pub icon: String,
    /// "Character", "Space", "Time" or "Motion".
    pub category: String,
    pub story: String,
    pub speed: f32,
    pub pitch_semitones: f32,
    /// Ten EQ gains, or empty to leave the listener's EQ alone.
    pub eq: Vec<f32>,
    /// Reverb room preset id and wet amount 0…100, or None to leave reverb alone.
    pub reverb_preset: Option<String>,
    pub reverb_wet: Option<f32>,
    pub tremolo_hz: f32,
    pub tremolo_depth: f32,
    pub vibrato_hz: f32,
    pub vibrato_semitones: f32,
    pub character: FxCharacter,
}

fn ch(highpass_hz: f32, lowpass_hz: f32, drive: f32, bits: u8, crush_rate_hz: f32, width: f32) -> FxCharacter {
    FxCharacter { highpass_hz, lowpass_hz, drive, bits, crush_rate_hz, width }
}

#[allow(clippy::too_many_arguments)]
fn fx(id: &str, name: &str, icon: &str, cat: &str, story: &str, speed: f32, pitch: f32, eq: &[f32], reverb: Option<(&str, f32)>, trem: (f32, f32), vib: (f32, f32), character: FxCharacter) -> FxPreset {
    FxPreset {
        id: id.into(),
        name: name.into(),
        icon: icon.into(),
        category: cat.into(),
        story: story.into(),
        speed,
        pitch_semitones: pitch,
        eq: eq.to_vec(),
        reverb_preset: reverb.map(|r| r.0.to_string()),
        reverb_wet: reverb.map(|r| r.1),
        tremolo_hz: trem.0,
        tremolo_depth: trem.1,
        vibrato_hz: vib.0,
        vibrato_semitones: vib.1,
        character,
    }
}

/// Every effect, in display order.
#[uniffi::export]
pub fn fx_catalogue() -> Vec<FxPreset> {
    let n = FxCharacter::NEUTRAL;
    vec![
        fx("none", "Clean", "waveform", "Character", "The engine, nothing added.", 1.0, 0.0, &[], None, (0.0, 0.0), (0.0, 0.0), n),
        // Character
        fx("lofi", "Lo-Fi Tape", "cassette", "Character", "Worn cassette: soft top, tape drive, a gentle wobble.", 1.0, 0.0,
           &[2.0, 2.5, 1.5, 0.5, 0.0, -0.5, -1.5, -3.0, -5.0, -7.0], None, (0.0, 0.0), (0.55, 0.12), ch(70.0, 6800.0, 0.35, 12, 0.0, 0.8)),
        fx("radio", "AM Radio", "radio", "Character", "A narrow, hot little broadcast in mono.", 1.0, 0.0, &[], None, (0.0, 0.0), (0.0, 0.0), ch(420.0, 3600.0, 0.45, 0, 0.0, 0.0)),
        fx("phone", "Phone Call", "phone.fill", "Character", "Squeezed down a phone line.", 1.0, 0.0, &[], None, (0.0, 0.0), (0.0, 0.0), ch(320.0, 3400.0, 0.3, 8, 8000.0, 0.0)),
        fx("vinyl", "Vinyl Night", "record.circle", "Character", "Warm and round, like a late-night record.", 1.0, 0.0,
           &[1.5, 2.0, 1.5, 0.5, 0.0, 0.0, -0.5, -1.0, -2.0, -3.5], Some(("smallRoom", 10.0)), (0.0, 0.0), (0.0, 0.0), ch(35.0, 12500.0, 0.2, 13, 0.0, 0.9)),
        fx("chiptune", "8-Bit", "gamecontroller.fill", "Character", "Crunched to an old console's bits and rate.", 1.0, 0.0, &[], None, (0.0, 0.0), (0.0, 0.0), ch(120.0, 0.0, 0.1, 5, 11025.0, 1.0)),
        fx("soft", "Soft Focus", "camera.filter", "Character", "Edges rounded off for easy, quiet listening.", 1.0, 0.0,
           &[0.5, 1.0, 1.0, 0.5, 0.0, -0.5, -1.0, -2.0, -3.0, -4.0], None, (0.0, 0.0), (0.0, 0.0), ch(0.0, 9500.0, 0.1, 0, 0.0, 1.0)),
        // Space
        fx("wide", "Wide Open", "arrow.left.and.right", "Space", "The stereo picture pushed out past the speakers.", 1.0, 0.0, &[], None, (0.0, 0.0), (0.0, 0.0), ch(0.0, 0.0, 0.0, 0, 0.0, 1.7)),
        fx("cinema", "Cinema", "film", "Space", "Big low end and a theatre around you.", 1.0, 0.0,
           &[4.0, 3.0, 1.0, 0.0, -0.5, 0.0, 1.0, 1.5, 1.5, 1.0], Some(("mediumHall", 24.0)), (0.0, 0.0), (0.0, 0.0), ch(0.0, 0.0, 0.0, 0, 0.0, 1.4)),
        fx("stadium", "Stadium", "sportscourt.fill", "Space", "Live from the middle of the arena.", 1.0, 0.0,
           &[1.0, 1.0, 0.0, -0.5, 0.0, 1.0, 1.5, 1.0, 0.5, 0.0], Some(("cathedral", 36.0)), (0.0, 0.0), (0.0, 0.0), ch(45.0, 0.0, 0.0, 0, 0.0, 1.3)),
        fx("nextroom", "Next Room", "door.left.hand.closed", "Space", "The party is through the wall.", 1.0, 0.0, &[3.0, 2.0, 1.0, 0.0, -2.0, -4.0, -6.0, -8.0, -9.0, -10.0],
           Some(("mediumRoom", 30.0)), (0.0, 0.0), (0.0, 0.0), ch(0.0, 900.0, 0.0, 0, 0.0, 0.6)),
        fx("underwater", "Underwater", "drop.fill", "Space", "Sunk and swaying, light from far above.", 1.0, 0.0, &[], Some(("largeHall", 40.0)), (0.0, 0.0), (0.35, 0.25), ch(0.0, 620.0, 0.0, 0, 0.0, 1.2)),
        fx("deep", "Deep Space", "sparkles", "Space", "Huge, dark and slow-blooming.", 1.0, 0.0, &[3.0, 2.5, 1.0, 0.0, -1.0, -1.0, 0.0, 1.0, 1.0, 0.5],
           Some(("cathedral", 48.0)), (0.0, 0.0), (0.0, 0.0), ch(30.0, 11000.0, 0.0, 0, 0.0, 1.5)),
        // Time
        fx("nightcore", "Nightcore", "moon.stars.fill", "Time", "Faster, higher and bright.", 1.22, 4.0, &[-1.0, -0.5, 0.0, 0.0, 0.5, 1.5, 3.0, 3.5, 3.0, 2.0], None, (0.0, 0.0), (0.0, 0.0), ch(0.0, 0.0, 0.0, 0, 0.0, 1.15)),
        fx("vaporwave", "Vaporwave", "sun.haze.fill", "Time", "Slowed, lowered and drifting in a hall.", 0.82, -3.5, &[2.0, 2.5, 1.5, 0.5, 0.0, -1.0, -2.0, -3.0, -4.0, -5.0],
           Some(("largeHall", 32.0)), (0.0, 0.0), (0.0, 0.0), ch(0.0, 10000.0, 0.15, 0, 0.0, 1.2)),
        fx("slowmo", "Slowed + Reverb", "tortoise.fill", "Time", "The late-night slowed edit.", 0.85, -1.5, &[], Some(("largeHall", 34.0)), (0.0, 0.0), (0.0, 0.0), n),
        fx("doubletime", "Sped Up", "hare.fill", "Time", "Quicker, same key.", 1.25, 0.0, &[], None, (0.0, 0.0), (0.0, 0.0), n),
        fx("pitchUp", "Key Up", "arrow.up.circle", "Time", "Three semitones higher, same tempo.", 1.0, 3.0, &[], None, (0.0, 0.0), (0.0, 0.0), n),
        fx("pitchDown", "Key Down", "arrow.down.circle", "Time", "Three semitones lower, same tempo.", 1.0, -3.0, &[], None, (0.0, 0.0), (0.0, 0.0), n),
        // Motion
        fx("tremolo", "Pulse", "waveform.path", "Motion", "The volume throbs like an amp tremolo.", 1.0, 0.0, &[], None, (5.5, 0.55), (0.0, 0.0), n),
        fx("vibrato", "Warble", "water.waves", "Motion", "A gentle pitch wobble.", 1.0, 0.0, &[], None, (0.0, 0.0), (4.5, 0.35), n),
        fx("rotary", "Rotary", "fanblades.fill", "Motion", "A spinning speaker: pitch and volume swirl together.", 1.0, 0.0, &[], Some(("smallRoom", 12.0)), (6.2, 0.25), (6.2, 0.12), ch(0.0, 0.0, 0.15, 0, 0.0, 1.3)),
    ]
}

#[uniffi::export]
pub fn fx_preset(id: String) -> Option<FxPreset> {
    fx_catalogue().into_iter().find(|p| p.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn neutral_is_bit_exact_and_presets_are_sane() {
        let mut c = Character::new(48_000.0);
        assert_eq!(c.process(0.3, -0.4), (0.3, -0.4));
        let cat = fx_catalogue();
        let mut ids = std::collections::HashSet::new();
        for p in &cat {
            assert!(ids.insert(p.id.clone()), "duplicate {}", p.id);
            assert!(p.eq.is_empty() || p.eq.len() == 10);
            assert!(p.speed > 0.5 && p.speed < 1.6);
        }
    }

    #[test]
    fn radio_band_limits_and_mono() {
        let mut c = Character::new(48_000.0);
        c.set(fx_preset("radio".into()).unwrap().character);
        let (mut low, mut mid, mut side) = (0f32, 0f32, 0f32);
        for i in 0..48_000 {
            let t = i as f32 / 48_000.0;
            let lo = (std::f32::consts::TAU * 60.0 * t).sin() * 0.3;
            let md = (std::f32::consts::TAU * 1000.0 * t).sin() * 0.3;
            let (l, r) = c.process(lo + md, lo - md * 0.5);
            if i > 24_000 {
                side += (l - r).abs();
                let _ = (low, mid);
                low += l.abs();
                mid += r.abs();
            }
        }
        assert!(side < 1.0, "mono expected, side {side}");
        let mut b = Character::new(48_000.0);
        b.set(fx_preset("radio".into()).unwrap().character);
        let mut e_low = 0f32;
        for i in 0..48_000 {
            let x = (std::f32::consts::TAU * 60.0 * i as f32 / 48_000.0).sin() * 0.5;
            let (l, _) = b.process(x, x);
            if i > 24_000 {
                e_low += l * l;
            }
        }
        assert!(e_low < 50.0, "60 Hz should be cut, energy {e_low}");
    }

    #[test]
    fn switching_glides_and_never_blows_up() {
        let mut c = Character::new(44_100.0);
        for id in ["lofi", "chiptune", "wide", "underwater", "none", "phone"] {
            c.set(fx_preset(id.into()).unwrap().character);
            for i in 0..4410 {
                let (l, r) = c.process((i as f32 * 0.05).sin(), (i as f32 * 0.07).cos());
                assert!(l.is_finite() && r.is_finite() && l.abs() <= 2.0 && r.abs() <= 2.0);
            }
        }
    }
}
