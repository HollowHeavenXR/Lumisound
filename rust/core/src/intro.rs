//! Skip Silent Intros: where the music really starts.
//!
//! Reads the first 40 s (mono, 11.025 kHz) in 10 ms steps and compares
//! each step against the track's own level (90th percentile), not a fixed
//! number:
//!
//! - Silence is under -66 dBFS (30 ms average, about -60 dBFS peak).
//! - Sound only counts once it holds for 80 ms, so vinyl crackle or a
//!   click doesn't end the silence.
//! - Silence before the first sound is skipped.
//! - Steady background noise before the music (tape hiss, amp hum, room
//!   tone: 35 dB under the track and barely changing) is skipped up to
//!   where the music begins.
//! - Anything else quiet before the music proper (soft notes, wind, a
//!   spoken line, a fade-in) is kept.
//! - Playback starts 60 ms before the first sound so its attack is intact.
//!
//! The result is cached per file, applied by the engine when it opens the
//! track (no audible jump), and computed ahead for the next track in the
//! queue. Checked on every cloud track against ffmpeg's silencedetect
//! (tests/intro_cloud.rs).

use crate::analysis::{cached_f64, put_f64};
use lumisound_media::decode;
use std::path::Path;

pub const RATE: u32 = 11_025;
const ANALYZE_SECS: f64 = 40.0;
const STEP: f64 = 0.01;
const MIN_SKIP: f64 = 0.35;
const PRE_ROLL: f64 = 0.06;
/// Sound must last this long (steps) to end the lead-in.
const HOLD_STEPS: usize = 8;
/// Under this (30 ms average) a step is silence: about -60 dBFS peak, the
/// level ffmpeg's silencedetect and most editors call silent.
const ABS_SILENCE_DB: f32 = -66.0;
/// Below this a step is digital silence (not even hiss).
const DIGITAL_SILENCE_DB: f32 = -85.0;
const CACHE_NS: &str = "intro_skip_v1";

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntroKind {
    /// Starts straight away (or lead-in under MIN_SKIP).
    None,
    /// Digital silence before the music.
    Silence,
    /// Steady background noise (hiss, hum) before the music.
    Noise,
    /// Quiet but musical lead-in: kept (only silence before it skipped).
    QuietMusic,
    /// No clear start inside the analysed stretch: left alone.
    Unclear,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct IntroAnalysis {
    /// Where playback should start (seconds); 0 = from the top.
    pub skip_secs: f64,
    /// Where the first held sound begins.
    pub onset_secs: f64,
    pub kind: IntroKind,
    /// Track level (90th percentile, dBFS).
    pub content_db: f32,
    /// Mean level of the lead-in (dBFS).
    pub lead_in_db: f32,
    /// Variation of the lead-in level (dB, std).
    pub lead_in_std_db: f32,
}

/// Start offset for a track (cached). `pcm` = mono i16 at RATE when the
/// core can't decode the file itself.
#[uniffi::export]
pub fn intro_skip(path: String, pcm: Option<Vec<i16>>) -> f64 {
    if let Some(v) = cached_f64(CACHE_NS, &path) {
        return v;
    }
    let Some(s) = pcm.or_else(|| decode::mono_pcm(Path::new(&path), RATE, None, Some(ANALYZE_SECS))) else { return 0.0 };
    let v = analyze(&s, RATE as f64).skip_secs;
    put_f64(CACHE_NS, &path, v);
    v
}

/// Cached start offset only (never decodes); None = not analysed yet.
#[uniffi::export]
pub fn intro_skip_cached(path: String) -> Option<f64> {
    cached_f64(CACHE_NS, &path)
}

/// Full analysis (diagnostics / tests). Not cached.
#[uniffi::export]
pub fn intro_analyze(path: String, pcm: Option<Vec<i16>>) -> Option<IntroAnalysis> {
    let s = pcm.or_else(|| decode::mono_pcm(Path::new(&path), RATE, None, Some(ANALYZE_SECS)))?;
    Some(analyze(&s, RATE as f64))
}

/// Level per 10 ms step (30 ms window, DC/rumble removed), dBFS.
fn levels(s: &[i16], sr: f64) -> Vec<f32> {
    let step = (sr * STEP).round() as usize;
    if step == 0 {
        return vec![];
    }
    // One-pole high-pass at ~40 Hz.
    let a = (-std::f64::consts::TAU * 40.0 / sr).exp();
    let (mut px, mut py) = (0.0f64, 0.0f64);
    let mut pow: Vec<f64> = Vec::with_capacity(s.len() / step + 1);
    let mut acc = 0.0;
    for (i, v) in s.iter().enumerate() {
        let x = *v as f64 / 32768.0;
        let y = a * (py + x - px);
        px = x;
        py = y;
        acc += y * y;
        if (i + 1) % step == 0 {
            pow.push(acc / step as f64);
            acc = 0.0;
        }
    }
    (0..pow.len())
        .map(|i| {
            let a = i.saturating_sub(1);
            let b = (i + 2).min(pow.len());
            let m = pow[a..b].iter().sum::<f64>() / (b - a) as f64;
            (10.0 * (m + 1e-13).log10()) as f32
        })
        .collect()
}

fn percentile(v: &[f32], p: f64) -> f32 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.total_cmp(b));
    s[((s.len() - 1) as f64 * p).round() as usize]
}

/// Index of the first step that starts a run of at least HOLD_STEPS steps
/// for which `loud` holds; None when there's none.
fn first_held(l: &[f32], loud: impl Fn(f32) -> bool) -> Option<usize> {
    let mut run = 0;
    for (i, v) in l.iter().enumerate() {
        if loud(*v) {
            run += 1;
            if run >= HOLD_STEPS {
                return Some(i + 1 - run);
            }
        } else {
            run = 0;
        }
    }
    None
}

pub fn analyze(s: &[i16], sr: f64) -> IntroAnalysis {
    let l = levels(s, sr);
    let none = |content: f32| IntroAnalysis { skip_secs: 0.0, onset_secs: 0.0, kind: IntroKind::None, content_db: content, lead_in_db: content, lead_in_std_db: 0.0 };
    if l.len() < 50 {
        return none(-120.0);
    }
    let content = percentile(&l, 0.9);
    if content < -55.0 {
        // The whole stretch is (near) silent: nothing to anchor a decision on.
        return IntroAnalysis { kind: IntroKind::Unclear, ..none(content) };
    }
    let quiet_below = (content - 30.0).min(-20.0);
    let Some(onset) = first_held(&l, |v| v >= quiet_below || v >= ABS_SILENCE_DB) else {
        return IntroAnalysis { kind: IntroKind::Unclear, ..none(content) };
    };
    // An onset at the very start: nothing to skip. The sound must also be
    // part of the track (within 30 dB of it), not a -58 dB hum that merely
    // crosses -60.
    let onset = if l[onset..(onset + HOLD_STEPS).min(l.len())].iter().all(|v| *v < quiet_below) {
        // Above -60 but still far under the track: steady noise. The music
        // starts where it rises to within 30 dB of the track.
        first_held(&l[onset..], |v| v >= quiet_below).map_or(onset, |o| onset + o)
    } else {
        onset
    };
    let onset_secs = onset as f64 * STEP;
    if onset_secs < MIN_SKIP + PRE_ROLL {
        return none(content);
    }
    if onset_secs >= ANALYZE_SECS - 1.0 || onset + HOLD_STEPS >= l.len() {
        return IntroAnalysis { onset_secs, kind: IntroKind::Unclear, ..none(content) };
    }
    // Lead-in statistics over its sounding part (digital silence aside),
    // ignoring the loudest 5 % (crackle, clicks).
    let lead = &l[..onset];
    let silent_share = lead.iter().filter(|v| **v < ABS_SILENCE_DB).count() as f64 / lead.len() as f64;
    let mut sorted: Vec<f32> = lead.iter().cloned().filter(|v| *v >= DIGITAL_SILENCE_DB).collect();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let core = &sorted[..((sorted.len() as f64 * 0.95).ceil() as usize).min(sorted.len())];
    let (mean, std) = if core.is_empty() {
        (-120.0, 0.0)
    } else {
        let m = core.iter().sum::<f32>() / core.len() as f32;
        (m, (core.iter().map(|v| (v - m).powi(2)).sum::<f32>() / core.len() as f32).sqrt())
    };

    let skip_to = |at: f64| (at - PRE_ROLL).max(0.0);
    // First sound of any kind (held 80 ms above ABS_SILENCE_DB).
    let first_sound = first_held(lead, |v| v >= ABS_SILENCE_DB).unwrap_or(onset);
    let (kind, start) = if silent_share < 0.85 && mean < content - 35.0 && std < 3.0 {
        // Mostly steady background noise: skip it up to the music.
        (IntroKind::Noise, skip_to(onset_secs))
    } else if first_sound == onset {
        (IntroKind::Silence, skip_to(onset_secs))
    } else {
        // Quiet sounds before the music proper (soft notes, wind, a spoken
        // line, a fade): keep them, skip only the silence before them.
        (IntroKind::QuietMusic, skip_to(first_sound as f64 * STEP))
    };
    let skip_secs = if start >= MIN_SKIP { start } else { 0.0 };
    let kind = if skip_secs == 0.0 && kind != IntroKind::QuietMusic { IntroKind::None } else { kind };
    IntroAnalysis { skip_secs, onset_secs, kind, content_db: content, lead_in_db: mean, lead_in_std_db: std }
}

#[cfg(test)]
mod tests {
    use super::*;
    const SR: f64 = RATE as f64;

    struct Rng(u64);
    impl Rng {
        fn noise(&mut self) -> f64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0 as f64 / u64::MAX as f64 * 2.0 - 1.0
        }
    }

    fn secs(n: f64) -> usize {
        (n * SR) as usize
    }

    /// Music-like signal: a chord with a 4 Hz amplitude pulse (it varies).
    fn music(len: f64, amp: f64) -> Vec<f64> {
        (0..secs(len))
            .map(|i| {
                let t = i as f64 / SR;
                let pulse = 0.55 + 0.45 * (std::f64::consts::TAU * 2.0 * t).sin().abs();
                amp * pulse * ((std::f64::consts::TAU * 220.0 * t).sin() + 0.6 * (std::f64::consts::TAU * 330.0 * t).sin() + 0.4 * (std::f64::consts::TAU * 440.0 * t).sin()) / 2.0
            })
            .collect()
    }

    fn pcm(x: &[f64]) -> Vec<i16> {
        x.iter().map(|v| (v.clamp(-1.0, 1.0) * 32767.0) as i16).collect()
    }

    fn with_intro(intro: Vec<f64>) -> Vec<i16> {
        let mut x = intro;
        x.extend(music(20.0, 0.5));
        pcm(&x)
    }

    #[test]
    fn digital_silence_is_skipped_with_pre_roll() {
        let a = analyze(&with_intro(vec![0.0; secs(3.0)]), SR);
        assert_eq!(a.kind, IntroKind::Silence);
        assert!((a.onset_secs - 3.0).abs() < 0.03, "{a:?}");
        assert!((a.skip_secs - 2.94).abs() < 0.03, "{a:?}");
    }

    #[test]
    fn steady_hiss_is_skipped() {
        let mut r = Rng(42);
        let hiss: Vec<f64> = (0..secs(4.0)).map(|_| 0.004 * r.noise()).collect(); // ~ -52 dBFS
        let a = analyze(&with_intro(hiss), SR);
        assert_eq!(a.kind, IntroKind::Noise, "{a:?}");
        assert!((a.onset_secs - 4.0).abs() < 0.05, "{a:?}");
    }

    #[test]
    fn silence_then_hiss_is_skipped() {
        let mut r = Rng(9);
        let mut x = vec![0.0; secs(1.0)];
        x.extend((0..secs(2.0)).map(|_| 0.003 * r.noise()));
        let a = analyze(&with_intro(x), SR);
        assert_eq!(a.kind, IntroKind::Noise, "{a:?}");
        assert!(a.skip_secs > 2.8, "{a:?}");
    }

    #[test]
    fn crackle_does_not_end_the_lead_in() {
        let mut x = vec![0.0; secs(2.5)];
        for k in 1..8 {
            let at = secs(k as f64 * 0.3);
            for v in x.iter_mut().skip(at).take(secs(0.02)) {
                *v = 0.5;
            }
        }
        let a = analyze(&with_intro(x), SR);
        assert!((a.onset_secs - 2.5).abs() < 0.05, "{a:?}");
        assert!(a.skip_secs > 2.3, "{a:?}");
    }

    #[test]
    fn quiet_musical_intro_is_kept() {
        // 0.8 s silence, then 6 s of soft (-34 dB) but clearly musical intro.
        let mut x = vec![0.0; secs(0.8)];
        x.extend(music(6.0, 0.02));
        let a = analyze(&with_intro(x), SR);
        assert!(a.skip_secs < 0.8, "{a:?}");
        assert!(a.skip_secs >= 0.7, "silence before it still skipped: {a:?}");
    }

    #[test]
    fn fade_in_is_kept() {
        let fade: Vec<f64> = music(4.0, 0.5).iter().enumerate().map(|(i, v)| v * (i as f64 / secs(4.0) as f64).powi(3)).collect();
        let a = analyze(&with_intro(fade), SR);
        // Only the inaudible start (under -60 dBFS, ~0.65 s) may go.
        assert_eq!(a.kind, IntroKind::QuietMusic, "{a:?}");
        assert!(a.skip_secs < 0.8, "{a:?}");
    }

    #[test]
    fn immediate_start_and_short_gaps_are_left_alone() {
        assert_eq!(analyze(&with_intro(vec![]), SR).skip_secs, 0.0);
        assert_eq!(analyze(&with_intro(vec![0.0; secs(0.3)]), SR).skip_secs, 0.0);
    }

    #[test]
    fn all_silent_is_unclear() {
        let a = analyze(&pcm(&vec![0.0; secs(40.0)]), SR);
        assert_eq!(a.kind, IntroKind::Unclear);
        assert_eq!(a.skip_secs, 0.0);
    }
}
