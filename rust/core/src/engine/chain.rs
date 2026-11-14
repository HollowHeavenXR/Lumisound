//! The engine's sound stage for audio the engine doesn't decode itself.
//!
//! On Apple platforms the engine owns playback end to end (decks, mixer,
//! output). The Android app streams and decodes with the platform player, so
//! it runs every decoded buffer through this: the same processors in the same
//! order as the mixer's master section — LumiEQ, LumiFX character, reverb,
//! night-mode compressor, mono fold-down, LumiSpace, 8D rotation, tremolo,
//! volume, LumiBoost, look-ahead limiter. A setting sounds the same on both.
//!
//! `process_*` runs on the player's audio thread: one uncontended lock (the
//! control side holds it only to change a setting), no allocation.

use super::boost::{BoostRoute, LumiBoost};
use super::dsp::{Compressor, Limiter, Ramp, Reverb};
use super::eq::LumiEq;
use super::fx::{Character, FxCharacter};
use super::space::{LumiSpace, SpatialMode};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

struct Stage {
    rate: u32,
    eq: LumiEq,
    character: Character,
    reverb: Reverb,
    reverb_preset: String,
    comp: Compressor,
    mono: bool,
    spatial: LumiSpace,
    yaw: f32,
    pan_hz: f32,
    pan_phase: f32,
    trem_hz: f32,
    trem_depth: f32,
    trem_phase: f32,
    volume: Ramp,
    boost: LumiBoost,
    limiter: Limiter,
}

impl Stage {
    fn new(rate: u32) -> Self {
        let r = rate as f32;
        Self {
            rate,
            eq: LumiEq::new(r),
            character: Character::new(r),
            reverb: Reverb::new(r),
            reverb_preset: String::new(),
            comp: Compressor::new(r),
            mono: false,
            spatial: LumiSpace::new(r),
            yaw: 0.0,
            pan_hz: 0.0,
            pan_phase: 0.0,
            trem_hz: 0.0,
            trem_depth: 0.0,
            trem_phase: 0.0,
            volume: Ramp::new(1.0),
            boost: LumiBoost::new(r),
            limiter: Limiter::new(r),
        }
    }

    /// Rebuild every processor at `rate`, keeping the settings.
    fn set_rate(&mut self, rate: u32) {
        if rate == self.rate || rate == 0 {
            return;
        }
        let mut n = Stage::new(rate);
        n.eq.enabled = self.eq.enabled;
        n.eq.loudness_match = self.eq.loudness_match;
        n.eq.set_gains(&self.eq.gains());
        n.character.set(self.character.settings());
        if !self.reverb_preset.is_empty() {
            n.reverb.set_preset(&self.reverb_preset);
        }
        n.reverb.set_wet(self.reverb.wet_target());
        n.reverb_preset = std::mem::take(&mut self.reverb_preset);
        n.comp.enabled = self.comp.enabled;
        n.mono = self.mono;
        n.spatial.set_mode(self.spatial.mode());
        n.spatial.set_yaw(self.yaw);
        n.yaw = self.yaw;
        (n.pan_hz, n.trem_hz, n.trem_depth) = (self.pan_hz, self.trem_hz, self.trem_depth);
        n.volume = Ramp::new(self.volume.target());
        n.boost.set_route(self.boost.route());
        n.boost.set_amount(self.boost.amount_target());
        *self = n;
    }

    #[inline]
    fn frame(&mut self, mut l: f32, mut r: f32) -> (f32, f32) {
        (l, r) = self.eq.process(l, r);
        (l, r) = self.character.process(l, r);
        (l, r) = self.reverb.process(l, r);
        (l, r) = self.comp.process(l, r);
        if self.mono {
            let m = (l + r) * 0.5;
            (l, r) = (m, m);
        }
        (l, r) = self.spatial.process(l, r);
        let tau = std::f32::consts::TAU;
        if self.pan_hz > 0.0 {
            self.pan_phase = (self.pan_phase + tau * self.pan_hz / self.rate as f32) % tau;
            let x = self.pan_phase.sin() * 0.6;
            l *= (1.0 - x).sqrt();
            r *= (1.0 + x).sqrt();
        }
        if self.trem_hz > 0.0 && self.trem_depth > 0.0 {
            self.trem_phase = (self.trem_phase + tau * self.trem_hz / self.rate as f32) % tau;
            let lfo = 1.0 - self.trem_depth / 2.0 + self.trem_depth / 2.0 * self.trem_phase.sin();
            l *= lfo;
            r *= lfo;
        }
        let g = self.volume.next();
        l *= g;
        r *= g;
        (l, r) = self.boost.process(l, r);
        if !l.is_finite() || !r.is_finite() {
            l = if l.is_finite() { l } else { 0.0 };
            r = if r.is_finite() { r } else { 0.0 };
        }
        (l, r) = self.limiter.process(l, r);
        (l.clamp(-1.0, 1.0), r.clamp(-1.0, 1.0))
    }
}

/// See the module docs. One per player.
#[derive(uniffi::Object)]
pub struct SoundChain {
    stage: Mutex<Stage>,
    boost_reduction_bits: AtomicU32,
    levels_bits: AtomicU64,
}

impl SoundChain {
    fn with<R>(&self, f: impl FnOnce(&mut Stage) -> R) -> R {
        f(&mut self.stage.lock().unwrap_or_else(|e| e.into_inner()))
    }

    fn meter(&self, s: &mut Stage, pk_l: f32, pk_r: f32) {
        self.boost_reduction_bits.store(s.boost.take_reduction().to_bits(), Ordering::Relaxed);
        self.levels_bits.store(((pk_l.to_bits() as u64) << 32) | pk_r.to_bits() as u64, Ordering::Relaxed);
    }

    /// Interleaved float frames, in place. Mono is processed as dual mono and
    /// folded back; channels past the second are left untouched.
    pub fn process_f32_slice(&self, buf: &mut [f32], channels: usize) {
        if channels == 0 {
            return;
        }
        let mut s = self.stage.lock().unwrap_or_else(|e| e.into_inner());
        let (mut pk_l, mut pk_r) = (0f32, 0f32);
        for f in buf.chunks_exact_mut(channels) {
            let (l, r) = if channels == 1 { (f[0], f[0]) } else { (f[0], f[1]) };
            let (l, r) = s.frame(l, r);
            if channels == 1 {
                f[0] = (l + r) * 0.5;
            } else {
                f[0] = l;
                f[1] = r;
            }
            pk_l = pk_l.max(l.abs());
            pk_r = pk_r.max(r.abs());
        }
        self.meter(&mut s, pk_l, pk_r);
    }

    /// Interleaved 16-bit frames, in place.
    pub fn process_i16_slice(&self, buf: &mut [i16], channels: usize) {
        if channels == 0 {
            return;
        }
        let mut s = self.stage.lock().unwrap_or_else(|e| e.into_inner());
        let (mut pk_l, mut pk_r) = (0f32, 0f32);
        let to = |x: f32| (x * 32767.0).round().clamp(-32768.0, 32767.0) as i16;
        for f in buf.chunks_exact_mut(channels) {
            let a = f[0] as f32 / 32768.0;
            let b = if channels == 1 { a } else { f[1] as f32 / 32768.0 };
            let (l, r) = s.frame(a, b);
            if channels == 1 {
                f[0] = to((l + r) * 0.5);
            } else {
                f[0] = to(l);
                f[1] = to(r);
            }
            pk_l = pk_l.max(l.abs());
            pk_r = pk_r.max(r.abs());
        }
        self.meter(&mut s, pk_l, pk_r);
    }
}

#[uniffi::export]
impl SoundChain {
    #[uniffi::constructor]
    pub fn new(sample_rate: u32) -> std::sync::Arc<Self> {
        let rate = if sample_rate == 0 { 48_000 } else { sample_rate };
        std::sync::Arc::new(Self { stage: Mutex::new(Stage::new(rate)), boost_reduction_bits: AtomicU32::new(0), levels_bits: AtomicU64::new(0) })
    }

    /// The player's output format changed (a track at another rate).
    pub fn set_sample_rate(&self, sample_rate: u32) {
        self.with(|s| s.set_rate(sample_rate));
    }

    /// Process `frames` interleaved float frames of `channels` channels in
    /// place at address `ptr` (a direct buffer). Scalar arguments only, so
    /// the call allocates nothing on the audio thread.
    ///
    /// The caller guarantees `ptr` addresses `frames * channels` writable floats.
    pub fn process_f32(&self, ptr: u64, frames: u32, channels: u32) {
        if ptr == 0 || frames == 0 || channels == 0 {
            return;
        }
        let buf = unsafe { std::slice::from_raw_parts_mut(ptr as usize as *mut f32, frames as usize * channels as usize) };
        self.process_f32_slice(buf, channels as usize);
    }

    /// `process_f32` for 16-bit PCM (native byte order).
    pub fn process_i16(&self, ptr: u64, frames: u32, channels: u32) {
        if ptr == 0 || frames == 0 || channels == 0 {
            return;
        }
        let buf = unsafe { std::slice::from_raw_parts_mut(ptr as usize as *mut i16, frames as usize * channels as usize) };
        self.process_i16_slice(buf, channels as usize);
    }

    /// Ten gains in dB for 32 Hz…16 kHz (LumiEQ).
    pub fn set_eq(&self, gains_db: Vec<f32>, enabled: bool, loudness_match: bool) {
        let mut g = [0f32; 10];
        for (i, v) in gains_db.iter().take(10).enumerate() {
            g[i] = *v;
        }
        self.with(|s| {
            s.eq.enabled = enabled;
            s.eq.loudness_match = loudness_match;
            s.eq.set_gains(&g);
        });
    }

    /// LumiFX character stage (neutral = off).
    pub fn set_character(&self, character: FxCharacter) {
        self.with(|s| s.character.set(character));
    }

    /// Volume 0…1 (glides over ~20 ms).
    pub fn set_volume(&self, volume: f32) {
        self.with(|s| {
            let frames = (s.rate / 50) as u64;
            s.volume.to(volume.clamp(0.0, 1.0), frames);
        });
    }

    /// LumiBoost: extra loudness in dB (0 = off, up to 12) for this output route.
    pub fn set_boost(&self, db: f32, route: BoostRoute) {
        self.with(|s| {
            s.boost.set_route(route);
            s.boost.set_amount(db);
        });
    }

    /// Reverb wet 0…1 with a room preset name, mono fold-down, night mode.
    pub fn set_effects(&self, reverb_wet: f32, reverb_preset: String, mono: bool, night_mode: bool) {
        self.with(|s| {
            s.reverb.set_wet(reverb_wet);
            s.reverb.set_preset(&reverb_preset);
            s.reverb_preset = reverb_preset;
            s.mono = mono;
            s.comp.enabled = night_mode;
        });
    }

    /// LumiSpace room and head yaw in degrees.
    pub fn set_spatial_mode(&self, mode: SpatialMode, yaw_degrees: f32) {
        self.with(|s| {
            s.spatial.set_mode(mode);
            s.spatial.set_yaw(yaw_degrees);
            s.yaw = yaw_degrees;
        });
    }

    /// 8D rotation speed (Hz, 0 = off) and tremolo rate / depth.
    pub fn set_modulation(&self, pan_hz: f32, tremolo_hz: f32, tremolo_depth: f32) {
        self.with(|s| {
            s.pan_hz = pan_hz.clamp(0.0, 4.0);
            s.trem_hz = tremolo_hz.clamp(0.0, 20.0);
            s.trem_depth = tremolo_depth.clamp(0.0, 1.0);
        });
    }

    /// Deepest LumiBoost hold-back in the last buffer, dB (≤ 0).
    pub fn boost_reduction(&self) -> f32 {
        f32::from_bits(self.boost_reduction_bits.load(Ordering::Relaxed))
    }

    /// Peak levels (left, right) of the last buffer.
    pub fn levels(&self) -> Vec<f32> {
        let b = self.levels_bits.load(Ordering::Relaxed);
        vec![f32::from_bits((b >> 32) as u32), f32::from_bits(b as u32)]
    }

    /// Samples the limiter delays the signal by (for A/V or lyric timing).
    pub fn latency_frames(&self) -> u32 {
        self.with(|s| s.limiter.latency() as u32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(n: usize, amp: f32) -> Vec<f32> {
        (0..n).flat_map(|i| { let x = (std::f32::consts::TAU * 440.0 * i as f32 / 48_000.0).sin() * amp; [x, x] }).collect()
    }

    fn rms(v: &[f32]) -> f32 {
        (v.iter().map(|x| x * x).sum::<f32>() / v.len() as f32).sqrt()
    }

    #[test]
    fn neutral_chain_only_delays() {
        let c = SoundChain::new(48_000);
        let src = tone(9600, 0.5);
        let mut out = src.clone();
        c.process_f32_slice(&mut out, 2);
        let d = c.latency_frames() as usize * 2;
        for i in (d + 200)..out.len() {
            assert!((out[i] - src[i - d]).abs() < 1e-4, "frame {i}: {} vs {}", out[i], src[i - d]);
        }
    }

    #[test]
    fn boost_and_eq_change_the_level_and_stay_in_range() {
        let c = SoundChain::new(48_000);
        let src = tone(48_000, 0.1);
        let mut flat = src.clone();
        c.process_f32_slice(&mut flat, 2);
        c.set_boost(9.0, BoostRoute::Headphones);
        let mut loud = src.clone();
        c.process_f32_slice(&mut loud, 2);
        let gain = 20.0 * (rms(&loud[48_000..]) / rms(&flat[48_000..])).log10();
        assert!(gain > 7.5 && gain < 9.5, "boost gain {gain}");
        assert!(c.levels().iter().all(|p| *p <= 1.0));
    }

    #[test]
    fn i16_and_mono_paths_match_the_float_path() {
        let a = SoundChain::new(44_100);
        let b = SoundChain::new(44_100);
        for c in [&a, &b] {
            c.set_eq(vec![6.0, 4.0, 2.0, 0.0, 0.0, 0.0, 0.0, 2.0, 3.0, 4.0], true, true);
        }
        let src = tone(8000, 0.3);
        let mut f = src.clone();
        a.process_f32_slice(&mut f, 2);
        let mut i: Vec<i16> = src.iter().map(|x| (x * 32767.0) as i16).collect();
        b.process_i16_slice(&mut i, 2);
        for k in 2000..f.len() {
            assert!((f[k] - i[k] as f32 / 32767.0).abs() < 2e-3, "sample {k}");
        }
        let m = SoundChain::new(48_000);
        let mut mono: Vec<f32> = src.iter().step_by(2).copied().collect();
        m.process_f32_slice(&mut mono, 1);
        assert!(mono.iter().all(|x| x.is_finite()));
    }

    #[test]
    fn a_rate_change_keeps_the_settings() {
        let c = SoundChain::new(48_000);
        c.set_boost(6.0, BoostRoute::Speaker);
        c.set_effects(0.3, "largeRoom".into(), true, true);
        c.set_spatial_mode(SpatialMode::Wide, 10.0);
        c.set_sample_rate(44_100);
        c.with(|s| {
            assert_eq!(s.rate, 44_100);
            assert_eq!(s.boost.amount_target(), 6.0);
            assert_eq!(s.boost.route(), BoostRoute::Speaker);
            assert!(s.mono && s.comp.enabled);
            assert_eq!(s.spatial.mode(), SpatialMode::Wide);
            assert_eq!(s.reverb_preset, "largeRoom");
        });
    }
}
