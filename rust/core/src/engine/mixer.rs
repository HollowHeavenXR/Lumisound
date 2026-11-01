//! The realtime mixer. Owned by the audio callback; the control side talks
//! to it only through lock-free queues (commands in, events out) and a few
//! atomics, so the callback never blocks.

use super::deck::Deck;
use super::binaural::Binaural;
use super::dsp::{Compressor, Eq10, Ramp, Reverb};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

pub enum Cmd {
    Play,
    Pause { fade_frames: u64 },
    Volume(f32),
    /// Per-track gain (ReplayGain / normalization) for the playing deck, linear.
    TrackGain(f32),
    Eq { gains: [f32; 10], enabled: bool },
    Effects { reverb_wet: f32, reverb_preset: String, mono: bool, night: bool },
    /// 8D auto-pan (Hz, 0 = off) and tremolo (Hz, depth 0…1; 0 = off).
    /// Binaural "spatial audio": on/off and head yaw (degrees).
    Spatial { enabled: bool, yaw_deg: f32 },
    Modulation { pan_hz: f32, tremolo_hz: f32, tremolo_depth: f32, vibrato_hz: f32, vibrato_semitones: f32 },
    /// Replace the playing deck immediately (load / seek).
    Replace(Box<Deck>),
    /// Gapless successor: starts the frame the current deck drains.
    QueueNext(Box<Deck>),
    ClearNext,
    /// Fade the current deck out and `deck` in over `frames`.
    Crossfade { deck: Box<Deck>, frames: u64, equal_power: bool },
    Stop,
}

pub enum Event {
    /// The playing deck drained with nothing queued.
    Ended { id: u64 },
    /// A queued or crossfaded deck became the playing one.
    Started { id: u64 },
    /// The deck decoder failed before producing audio.
    Failed { id: u64 },
    /// Hand finished decks back so they are freed off the audio thread.
    Retire(Box<Deck>),
}

/// Wait-free ring of the most recent output (mono) for visualizers.
pub struct Tap {
    buf: Box<[std::sync::atomic::AtomicU32]>,
    pos: std::sync::atomic::AtomicUsize,
}

impl Default for Tap {
    fn default() -> Self {
        Self { buf: (0..16_384).map(|_| std::sync::atomic::AtomicU32::new(0)).collect(), pos: Default::default() }
    }
}

impl Tap {
    #[inline]
    fn push(&self, v: f32) {
        let p = self.pos.load(Ordering::Relaxed);
        self.buf[p % self.buf.len()].store(v.to_bits(), Ordering::Relaxed);
        self.pos.store(p.wrapping_add(1), Ordering::Release);
    }

    /// The latest `n` samples, oldest first.
    pub fn latest(&self, n: usize) -> Vec<f32> {
        let n = n.min(self.buf.len());
        let end = self.pos.load(Ordering::Acquire);
        (0..n).map(|i| f32::from_bits(self.buf[(end.wrapping_sub(n).wrapping_add(i)) % self.buf.len()].load(Ordering::Relaxed))).collect()
    }
}

/// Published by the callback for the control side.
#[derive(Default)]
pub struct Telemetry {
    pub tap: Tap,
    pub position_bits: AtomicU64,
    pub duration_bits: AtomicU64,
    pub playing: AtomicBool,
    pub deck_id: AtomicU64,
    /// Peak levels (L, R) of the last buffer, f32 bits packed.
    pub levels_bits: AtomicU64,
}

/// Crossfade gain curve: equal power (constant loudness) or linear.
#[inline]
fn shape(x: f32, equal_power: bool) -> f32 {
    if equal_power { (x * std::f32::consts::FRAC_PI_2).sin() } else { x }
}

pub struct Mixer {
    rate: u32,
    cur: Option<Box<Deck>>,
    next: Option<Box<Deck>>,
    fading: Option<(Box<Deck>, Ramp)>,
    fade_in: Ramp,
    equal_power: bool,
    master: Ramp,
    volume: f32,
    playing: bool,
    pausing: bool,
    eq: Eq10,
    reverb: Reverb,
    comp: Compressor,
    mono: bool,
    spatial: Binaural,
    pan_hz: f32,
    pan_phase: f32,
    trem_hz: f32,
    trem_depth: f32,
    trem_phase: f32,
    vib_hz: f32,
    vib_amp: f32,
    vib_phase: f32,
    vib_buf: Vec<[f32; 2]>,
    vib_w: usize,
    cmds: rtrb::Consumer<Cmd>,
    events: rtrb::Producer<Event>,
    pub tele: Arc<Telemetry>,
}

impl Mixer {
    pub fn new(rate: u32, cmds: rtrb::Consumer<Cmd>, events: rtrb::Producer<Event>, tele: Arc<Telemetry>) -> Self {
        Self { rate, cur: None, next: None, fading: None, fade_in: Ramp::new(1.0), equal_power: true, master: Ramp::new(0.0), volume: 1.0, playing: false, pausing: false, eq: Eq10::new(rate as f32), reverb: Reverb::new(rate as f32), comp: Compressor::new(rate as f32), mono: false, spatial: Binaural::new(rate as f32), pan_hz: 0.0, pan_phase: 0.0, trem_hz: 0.0, trem_depth: 0.0, trem_phase: 0.0, vib_hz: 0.0, vib_amp: 0.0, vib_phase: 0.0, vib_buf: vec![[0.0; 2]; 4096], vib_w: 0, cmds, events, tele }
    }

    fn retire(&mut self, d: Box<Deck>) {
        let _ = self.events.push(Event::Retire(d));
    }

    fn short_fade(&self) -> u64 {
        (self.rate / 100) as u64 // 10 ms de-click
    }

    fn apply(&mut self, c: Cmd) {
        match c {
            Cmd::Play => {
                self.playing = true;
                self.pausing = false;
                self.master.to(self.volume, self.short_fade());
            }
            Cmd::Pause { fade_frames } => {
                self.pausing = true;
                self.master.to(0.0, fade_frames.max(self.short_fade()));
            }
            Cmd::Volume(v) => {
                self.volume = v.clamp(0.0, 2.0);
                if self.playing && !self.pausing {
                    self.master.to(self.volume, self.short_fade() * 3);
                }
            }
            Cmd::TrackGain(g) => {
                if let Some(d) = self.cur.as_mut() {
                    d.gain = g.clamp(0.0, 4.0);
                }
            }
            Cmd::Eq { gains, enabled } => {
                self.eq.enabled = enabled;
                self.eq.set_gains(&gains);
            }
            Cmd::Effects { reverb_wet, reverb_preset, mono, night } => {
                self.reverb.wet = reverb_wet.clamp(0.0, 1.0);
                self.reverb.set_preset(&reverb_preset);
                self.mono = mono;
                self.comp.enabled = night;
            }
            Cmd::Spatial { enabled, yaw_deg } => {
                self.spatial.enabled = enabled;
                self.spatial.set_yaw(yaw_deg);
            }
            Cmd::Modulation { pan_hz, tremolo_hz, tremolo_depth, vibrato_hz, vibrato_semitones } => {
                // Delay-line vibrato: peak pitch ratio 2^(st/12) ≈ 1 + A·2πf,
                // so the delay swing A (seconds) = (2^(st/12) - 1) / (2πf).
                self.vib_hz = vibrato_hz.clamp(0.0, 20.0);
                self.vib_amp = if self.vib_hz > 0.0 {
                    ((2f32.powf(vibrato_semitones.abs().min(3.0) / 12.0) - 1.0) / (std::f32::consts::TAU * self.vib_hz)).min(0.02)
                } else {
                    0.0
                };
                self.pan_hz = pan_hz.clamp(0.0, 4.0);
                self.trem_hz = tremolo_hz.clamp(0.0, 20.0);
                self.trem_depth = tremolo_depth.clamp(0.0, 1.0);
            }
            Cmd::Replace(d) => {
                if let Some(old) = self.cur.replace(d) {
                    self.retire(old);
                }
                if let Some((f, _)) = self.fading.take() {
                    self.retire(f);
                }
                self.fade_in = Ramp::new(1.0);
                let id = self.cur.as_ref().unwrap().id;
                self.tele.deck_id.store(id, Ordering::Relaxed);
            }
            Cmd::QueueNext(d) => {
                if let Some(old) = self.next.replace(d) {
                    self.retire(old);
                }
            }
            Cmd::ClearNext => {
                if let Some(old) = self.next.take() {
                    self.retire(old);
                }
            }
            Cmd::Crossfade { deck, frames, equal_power } => {
                self.equal_power = equal_power;
                if let Some((f, _)) = self.fading.take() {
                    self.retire(f);
                }
                let id = deck.id;
                match self.cur.replace(deck) {
                    Some(old) => {
                        let mut down = Ramp::new(1.0);
                        down.to(0.0, frames);
                        self.fading = Some((old, down));
                        self.fade_in = Ramp::new(0.0);
                        self.fade_in.to(1.0, frames);
                    }
                    None => self.fade_in = Ramp::new(1.0),
                }
                self.tele.deck_id.store(id, Ordering::Relaxed);
                let _ = self.events.push(Event::Started { id });
            }
            Cmd::Stop => {
                self.playing = false;
                self.pausing = false;
                self.master = Ramp::new(0.0);
                for d in [self.cur.take(), self.next.take(), self.fading.take().map(|f| f.0)].into_iter().flatten() {
                    self.retire(d);
                }
            }
        }
    }

    /// Fill `out` (interleaved stereo f32).
    pub fn render(&mut self, out: &mut [f32]) {
        while let Ok(c) = self.cmds.pop() {
            self.apply(c);
        }
        let (mut pk_l, mut pk_r) = (0f32, 0f32);
        for frame in out.chunks_exact_mut(2) {
            let g = self.master.next();
            if self.pausing && self.master.done() {
                self.playing = false;
                self.pausing = false;
            }
            if !self.playing {
                frame[0] = 0.0;
                frame[1] = 0.0;
                continue;
            }
            let (mut l, mut r) = (0.0f32, 0.0f32);
            // Gapless hand-over the moment the current deck drains.
            if self.cur.as_ref().is_some_and(|d| d.drained()) {
                let old = self.cur.take().unwrap();
                let failed = old.frames_played == 0 && old.shared.failed.load(Ordering::Acquire);
                let id = old.id;
                self.retire(old);
                if let Some(n) = self.next.take() {
                    let nid = n.id;
                    self.cur = Some(n);
                    self.tele.deck_id.store(nid, Ordering::Relaxed);
                    let _ = self.events.push(if failed { Event::Failed { id } } else { Event::Started { id: nid } });
                } else {
                    let _ = self.events.push(if failed { Event::Failed { id } } else { Event::Ended { id } });
                }
            }
            if let Some(d) = self.cur.as_mut() {
                if d.ring.slots() >= 2 {
                    let a = d.ring.pop().unwrap_or(0.0);
                    let b = d.ring.pop().unwrap_or(0.0);
                    let fi = shape(self.fade_in.next(), self.equal_power) * d.gain;
                    l += a * fi;
                    r += b * fi;
                    d.frames_played += 1;
                }
            }
            let mut fade_done = false;
            if let Some((d, ramp)) = self.fading.as_mut() {
                let fg = shape(ramp.next(), self.equal_power) * d.gain;
                if d.ring.slots() >= 2 {
                    l += d.ring.pop().unwrap_or(0.0) * fg;
                    r += d.ring.pop().unwrap_or(0.0) * fg;
                    d.frames_played += 1;
                }
                fade_done = ramp.done() || d.drained();
            }
            if fade_done {
                let (d, _) = self.fading.take().unwrap();
                self.retire(d);
            }
            l = self.eq.process(0, l);
            r = self.eq.process(1, r);
            (l, r) = self.reverb.process(l, r);
            (l, r) = self.comp.process(l, r);
            if self.mono {
                let m = (l + r) * 0.5;
                (l, r) = (m, m);
            }
            (l, r) = self.spatial.process(l, r);
            let tau = std::f32::consts::TAU;
            if self.pan_hz > 0.0 {
                // Balance swing like AVAudioMixerNode.pan = sin(phase) * 0.5.
                self.pan_phase = (self.pan_phase + tau * self.pan_hz / self.rate as f32) % tau;
                let p = self.pan_phase.sin() * 0.5;
                if p > 0.0 { l *= 1.0 - p } else { r *= 1.0 + p }
            }
            if self.vib_amp > 0.0 {
                let n = self.vib_buf.len();
                self.vib_buf[self.vib_w] = [l, r];
                self.vib_phase = (self.vib_phase + tau * self.vib_hz / self.rate as f32) % tau;
                // Centre delay = swing + 1 ms so the read point never passes the write point.
                let delay = (self.vib_amp * (1.0 + self.vib_phase.sin()) + 0.001) * self.rate as f32;
                let rp = self.vib_w as f32 - delay;
                let rp = if rp < 0.0 { rp + n as f32 } else { rp };
                let i0 = rp as usize % n;
                let i1 = (i0 + 1) % n;
                let f = rp.fract();
                l = self.vib_buf[i0][0] * (1.0 - f) + self.vib_buf[i1][0] * f;
                r = self.vib_buf[i0][1] * (1.0 - f) + self.vib_buf[i1][1] * f;
                self.vib_w = (self.vib_w + 1) % n;
            }
            if self.trem_hz > 0.0 && self.trem_depth > 0.0 {
                self.trem_phase = (self.trem_phase + tau * self.trem_hz / self.rate as f32) % tau;
                let lfo = 1.0 - self.trem_depth / 2.0 + self.trem_depth / 2.0 * self.trem_phase.sin();
                l *= lfo;
                r *= lfo;
            }
            l *= g;
            r *= g;
            // Soft safety clip (EQ boosts + crossfade overlap can exceed 0 dBFS).
            frame[0] = l.clamp(-1.0, 1.0);
            frame[1] = r.clamp(-1.0, 1.0);
            self.tele.tap.push((frame[0] + frame[1]) * 0.5);
            pk_l = pk_l.max(frame[0].abs());
            pk_r = pk_r.max(frame[1].abs());
        }
        if let Some(d) = self.cur.as_ref() {
            self.tele.position_bits.store(d.position().to_bits(), Ordering::Relaxed);
            self.tele.duration_bits.store(d.duration().to_bits(), Ordering::Relaxed);
        }
        self.tele.playing.store(self.playing, Ordering::Relaxed);
        self.tele.levels_bits.store(((pk_l.to_bits() as u64) << 32) | pk_r.to_bits() as u64, Ordering::Relaxed);
    }
}
