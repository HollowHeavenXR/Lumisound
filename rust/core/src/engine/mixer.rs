//! The realtime mixer. Owned by the audio callback; the control side talks
//! to it only through lock-free queues (commands in, events out) and a few
//! atomics, so the callback never blocks.

use super::deck::Deck;
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

/// Published by the callback for the control side.
#[derive(Default)]
pub struct Telemetry {
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
    cmds: rtrb::Consumer<Cmd>,
    events: rtrb::Producer<Event>,
    pub tele: Arc<Telemetry>,
}

impl Mixer {
    pub fn new(rate: u32, cmds: rtrb::Consumer<Cmd>, events: rtrb::Producer<Event>, tele: Arc<Telemetry>) -> Self {
        Self { rate, cur: None, next: None, fading: None, fade_in: Ramp::new(1.0), equal_power: true, master: Ramp::new(0.0), volume: 1.0, playing: false, pausing: false, eq: Eq10::new(rate as f32), reverb: Reverb::new(rate as f32), comp: Compressor::new(rate as f32), mono: false, cmds, events, tele }
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
            l *= g;
            r *= g;
            // Soft safety clip (EQ boosts + crossfade overlap can exceed 0 dBFS).
            frame[0] = l.clamp(-1.0, 1.0);
            frame[1] = r.clamp(-1.0, 1.0);
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
