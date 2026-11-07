//! The realtime mixer. Owned by the audio callback; the control side talks
//! to it only through lock-free queues (commands in, events out) and a few
//! atomics, so the callback never blocks.

use super::deck::Deck;
use super::binaural::Binaural;
use super::dsp::{Compressor, Eq10, Limiter, Ramp, Reverb};
use super::health::{EngineIncident, Health, IncidentKind, PlaybackPhase, SLOW_START_MS, atomic_max};
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
    /// Health incident (timestamped and logged off the audio thread).
    Incident(EngineIncident),
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
    pub health: Health,
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
    limiter: Limiter,
    mono: bool,
    spatial: Binaural,
    pan_hz: f32,
    pan_phase: f32,
    trem_hz: f32,
    trem_depth: f32,
    trem_phase: f32,
    vib_hz: f32,
    /// Delay swing (s): `vib_amp` glides to `vib_target` (~30 ms) so depth
    /// changes never jump; `vib_wet` crossfades the effect in/out (10 ms).
    vib_amp: f32,
    vib_coef: f32,
    vib_target: f32,
    vib_wet: f32,
    vib_phase: f32,
    vib_buf: Vec<[f32; 2]>,
    vib_w: usize,
    cmds: rtrb::Consumer<Cmd>,
    events: rtrb::Producer<Event>,
    pub tele: Arc<Telemetry>,
    mon: Monitor,
}

/// Per-episode state for health incidents (audio thread only).
#[derive(Default)]
struct Monitor {
    /// Frames of silence in the current underrun episode of the playing deck…
    cur_starve: u64,
    cur_starve_phase: Option<PlaybackPhase>,
    /// …and of the fading-out deck during a crossfade.
    fade_starve: u64,
    last_render: Option<std::time::Instant>,
    last_playing: bool,
    clip_run: u64,
    last_clip_incident: u64,
    frames: u64,
}

impl Mixer {
    pub fn new(rate: u32, cmds: rtrb::Consumer<Cmd>, events: rtrb::Producer<Event>, tele: Arc<Telemetry>) -> Self {
        Self { rate, cur: None, next: None, fading: None, fade_in: Ramp::new(1.0), equal_power: true, master: Ramp::new(0.0), volume: 1.0, playing: false, pausing: false, eq: Eq10::new(rate as f32), reverb: Reverb::new(rate as f32), comp: Compressor::new(rate as f32), limiter: Limiter::new(rate as f32), mono: false, spatial: Binaural::new(rate as f32), pan_hz: 0.0, pan_phase: 0.0, trem_hz: 0.0, trem_depth: 0.0, trem_phase: 0.0, vib_hz: 0.0, vib_amp: 0.0, vib_coef: 1.0 - (-1.0 / (0.03 * rate as f32)).exp(), vib_target: 0.0, vib_wet: 0.0, vib_phase: 0.0, vib_buf: vec![[0.0; 2]; 4096], vib_w: 0, cmds, events, tele, mon: Monitor::default() }
    }

    fn retire(&mut self, d: Box<Deck>) {
        let _ = self.events.push(Event::Retire(d));
    }

    fn incident(&mut self, kind: IncidentKind, phase: PlaybackPhase, deck_id: u64, position: f64, value: f64, budget_ms: f64) {
        if self.events.push(Event::Incident(EngineIncident { kind, phase, deck_id, position, value, budget_ms, message: None, at: 0.0 })).is_err() {
            self.tele.health.incidents_dropped.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }
    }

    fn frames_ms(&self, frames: u64) -> f64 {
        frames as f64 * 1000.0 / self.rate as f64
    }

    /// Ends an underrun episode of the playing deck (audio came back or the deck changed).
    fn end_cur_starve(&mut self, deck_id: u64, position: f64) {
        if self.mon.cur_starve > 0 {
            let (frames, phase) = (self.mon.cur_starve, self.mon.cur_starve_phase.unwrap_or(PlaybackPhase::Playing));
            self.mon.cur_starve = 0;
            self.mon.cur_starve_phase = None;
            let ms = self.frames_ms(frames);
            self.tele.health.underrun_events.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            self.incident(IncidentKind::Underrun, phase, deck_id, position, ms, 0.0);
        }
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
                self.vib_target = if self.vib_hz > 0.0 {
                    ((2f32.powf(vibrato_semitones.abs().min(3.0) / 12.0) - 1.0) / (std::f32::consts::TAU * self.vib_hz)).min(0.02)
                } else {
                    0.0
                };
                self.pan_hz = pan_hz.clamp(0.0, 4.0);
                self.trem_hz = tremolo_hz.clamp(0.0, 20.0);
                self.trem_depth = tremolo_depth.clamp(0.0, 1.0);
            }
            Cmd::Replace(d) => {
                if let Some(o) = self.cur.as_ref().map(|o| (o.id, o.position())) {
                    self.end_cur_starve(o.0, o.1);
                }
                self.mon.fade_starve = 0;
                if let Some((f, _)) = self.fading.take() {
                    self.retire(f);
                }
                // Seek / load: a 10 ms micro-crossfade from the old position to
                // the new one instead of a hard cut (which clicks on any
                // waveform that isn't at a zero crossing).
                let xf = self.short_fade();
                match self.cur.replace(d) {
                    Some(old) if self.playing && old.frames_played > 0 => {
                        let mut down = Ramp::new(1.0);
                        down.to(0.0, xf);
                        self.fading = Some((old, down));
                        self.equal_power = true;
                        self.fade_in = Ramp::new(0.0);
                        self.fade_in.to(1.0, xf);
                    }
                    Some(old) => {
                        self.retire(old);
                        self.fade_in = Ramp::new(1.0);
                    }
                    None => self.fade_in = Ramp::new(1.0),
                }
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
                if let Some(o) = self.cur.as_ref().map(|o| (o.id, o.position())) {
                    self.end_cur_starve(o.0, o.1);
                }
                self.mon.fade_starve = 0;
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
                if let Some(o) = self.cur.as_ref().map(|o| (o.id, o.position())) {
                    self.end_cur_starve(o.0, o.1);
                }
                self.mon.fade_starve = 0;
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
    /// Apply queued commands without rendering: used by the control side
    /// when the output callback isn't running (interrupted session, dead
    /// route), so play/pause/seek still take effect instead of piling up.
    pub fn drain_commands(&mut self) {
        while let Ok(c) = self.cmds.pop() {
            self.apply(c);
        }
    }

    pub fn render(&mut self, out: &mut [f32]) {
        let t_start = std::time::Instant::now();
        self.tele.health.last_callback_ns.store(super::health::mono_ns(), Ordering::Relaxed);
        while let Ok(c) = self.cmds.pop() {
            self.apply(c);
        }
        let (mut pk_l, mut pk_r) = (0f32, 0f32);
        let (mut nonfinite, mut clipped, mut playing_frames) = (0u64, 0u64, 0u64);
        for frame in out.chunks_exact_mut(2) {
            let g = self.master.next();
            if self.pausing && self.master.done() {
                self.playing = false;
                self.pausing = false;
            }
            if !self.playing {
                // Keep the limiter's look-ahead line draining (silence in),
                // or its last 1.5 ms would be cut off: a click on pause.
                let (l, r) = self.limiter.process(0.0, 0.0);
                frame[0] = l;
                frame[1] = r;
                continue;
            }
            playing_frames += 1;
            let (mut l, mut r) = (0.0f32, 0.0f32);
            // Gapless hand-over the moment the current deck drains.
            if self.cur.as_ref().is_some_and(|d| d.drained()) {
                let old = self.cur.take().unwrap();
                let failed = old.frames_played == 0 && old.shared.failed.load(Ordering::Acquire);
                let id = old.id;
                self.retire(old);
                self.end_cur_starve(id, 0.0);
                if let Some(mut n) = self.next.take() {
                    let nid = n.id;
                    n.handed_over = true;
                    self.cur = Some(n);
                    self.tele.deck_id.store(nid, Ordering::Relaxed);
                    let _ = self.events.push(if failed { Event::Failed { id } } else { Event::Started { id: nid } });
                } else {
                    let _ = self.events.push(if failed { Event::Failed { id } } else { Event::Ended { id } });
                }
            }
            let fading_now = self.fading.is_some();
            let mut starve: Option<(u64, f64, PlaybackPhase)> = None;
            let mut resumed: Option<(u64, f64)> = None;
            let mut first_audio: Option<(u64, f64, f64)> = None;
            if let Some(d) = self.cur.as_mut() {
                if d.ring.slots() >= 2 {
                    if d.frames_played == 0 {
                        first_audio = Some((d.id, d.position(), d.opened_at.elapsed().as_secs_f64() * 1000.0));
                    }
                    let a = d.ring.pop().unwrap_or(0.0);
                    let b = d.ring.pop().unwrap_or(0.0);
                    let fi = shape(self.fade_in.next(), self.equal_power) * d.gain;
                    l += a * fi;
                    r += b * fi;
                    d.advance();
                    resumed = Some((d.id, d.position()));
                } else if d.frames_played > 0 && !d.drained() {
                    // Buffer empty mid-track: audible silence. (Before the first
                    // frame it's start latency, measured separately.)
                    let phase = if fading_now {
                        PlaybackPhase::Crossfade
                    } else if d.handed_over && (d.frames_played as f64) < self.rate as f64 * 2.0 {
                        PlaybackPhase::Handover
                    } else if (d.frames_played as f64) < self.rate as f64 * 0.5 {
                        PlaybackPhase::Starting
                    } else {
                        PlaybackPhase::Playing
                    };
                    starve = Some((d.id, d.position(), phase));
                }
            }
            if let Some((id, pos, ms)) = first_audio {
                let h = &self.tele.health;
                atomic_max(&h.start_latency_max_us, (ms * 1000.0) as u64);
                if ms > SLOW_START_MS {
                    h.slow_starts.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    let phase = if fading_now { PlaybackPhase::Crossfade } else { PlaybackPhase::Starting };
                    self.incident(IncidentKind::SlowStart, phase, id, pos, ms, 0.0);
                }
            }
            if let Some((_, _, phase)) = starve {
                self.mon.cur_starve += 1;
                self.mon.cur_starve_phase.get_or_insert(phase);
                self.tele.health.underrun_frames.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            } else if let Some((id, pos)) = resumed {
                self.end_cur_starve(id, pos);
            }
            let mut fade_done = false;
            if let Some((d, ramp)) = self.fading.as_mut() {
                let fg = shape(ramp.next(), self.equal_power) * d.gain;
                if d.ring.slots() >= 2 {
                    l += d.ring.pop().unwrap_or(0.0) * fg;
                    r += d.ring.pop().unwrap_or(0.0) * fg;
                    d.advance();
                    if self.mon.fade_starve > 0 {
                        let (frames, id, pos) = (self.mon.fade_starve, d.id, d.position());
                        self.mon.fade_starve = 0;
                        let ms = frames as f64 * 1000.0 / self.rate as f64;
                        self.tele.health.underrun_events.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        let _ = self.events.push(Event::Incident(EngineIncident { kind: IncidentKind::Underrun, phase: PlaybackPhase::Crossfade, deck_id: id, position: pos, value: ms, budget_ms: 0.0, message: None, at: 0.0 }));
                    }
                } else if !d.drained() {
                    self.mon.fade_starve += 1;
                    self.tele.health.underrun_frames.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                fade_done = ramp.done() || d.drained();
            }
            if fade_done {
                let (d, _) = self.fading.take().unwrap();
                self.mon.fade_starve = 0;
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
                // Constant-power balance swing: gains sqrt(1±x) keep L²+R²
                // steady as the sound circles (the old linear attenuation
                // dipped ~2 dB at each side). x = 0.6 gives the same 2:1
                // (6 dB) side-to-side ratio as before.
                self.pan_phase = (self.pan_phase + tau * self.pan_hz / self.rate as f32) % tau;
                let x = self.pan_phase.sin() * 0.6;
                l *= (1.0 - x).sqrt();
                r *= (1.0 + x).sqrt();
            }
            // The delay line always records (one store per frame), so turning
            // vibrato on never reads stale audio from the last time it ran.
            let n = self.vib_buf.len();
            self.vib_buf[self.vib_w] = [l, r];
            if self.vib_target > 0.0 || self.vib_wet > 0.0 {
                let rate = self.rate as f32;
                self.vib_amp += (self.vib_target - self.vib_amp) * self.vib_coef;
                let wet_to = if self.vib_target > 0.0 || self.vib_amp > 1e-6 { 1.0 } else { 0.0 };
                let step = 1.0 / (0.01 * rate);
                // Ramp toward the target and stay there (no flip-flopping around it).
                self.vib_wet = if wet_to > self.vib_wet { (self.vib_wet + step).min(wet_to) } else { (self.vib_wet - step).max(wet_to) };
                self.vib_phase = (self.vib_phase + tau * self.vib_hz / rate) % tau;
                // Centre delay = swing + 1 ms so the read point never passes the write point.
                let delay = (self.vib_amp * (1.0 + self.vib_phase.sin()) + 0.001) * rate;
                let rp = self.vib_w as f32 - delay;
                let rp = if rp < 0.0 { rp + n as f32 } else { rp };
                let i0 = rp as usize % n;
                let f = rp.fract();
                // 4-point cubic Hermite: linear interpolation dulls the highs
                // by a varying amount as the delay moves (a faint flutter).
                let at = |k: usize| self.vib_buf[(i0 + n + k - 1) % n];
                let (xm1, x0, x1, x2) = (at(0), at(1), at(2), at(3));
                let mut y = [0.0f32; 2];
                for c in 0..2 {
                    let c1 = 0.5 * (x1[c] - xm1[c]);
                    let c2 = xm1[c] - 2.5 * x0[c] + 2.0 * x1[c] - 0.5 * x2[c];
                    let c3 = 0.5 * (x2[c] - xm1[c]) + 1.5 * (x0[c] - x1[c]);
                    y[c] = ((c3 * f + c2) * f + c1) * f + x0[c];
                }
                let w = self.vib_wet;
                l = y[0] * w + l * (1.0 - w);
                r = y[1] * w + r * (1.0 - w);
            }
            self.vib_w = (self.vib_w + 1) % n;
            if self.trem_hz > 0.0 && self.trem_depth > 0.0 {
                self.trem_phase = (self.trem_phase + tau * self.trem_hz / self.rate as f32) % tau;
                let lfo = 1.0 - self.trem_depth / 2.0 + self.trem_depth / 2.0 * self.trem_phase.sin();
                l *= lfo;
                r *= lfo;
            }
            l *= g;
            r *= g;
            // NaN/Inf (a DSP state blow-up) must never reach the speaker.
            if !l.is_finite() || !r.is_finite() {
                nonfinite += 1;
                l = if l.is_finite() { l } else { 0.0 };
                r = if r.is_finite() { r } else { 0.0 };
            }
            if l.abs() > 1.0 || r.abs() > 1.0 {
                clipped += 1;
            }
            // Look-ahead limiter instead of a hard clip: EQ boosts, crossfade
            // overlap or reverb pushing past full scale are turned down
            // smoothly rather than squared off (harsh distortion).
            (l, r) = self.limiter.process(l, r);
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
        self.account(out.len() / 2, t_start, playing_frames, nonfinite, clipped);
    }

    /// Callback-level health: render time vs budget, late callbacks,
    /// invalid samples and clipping episodes.
    fn account(&mut self, frames: usize, t_start: std::time::Instant, playing_frames: u64, nonfinite: u64, clipped: u64) {
        use std::sync::atomic::Ordering::Relaxed;
        let budget = frames as f64 / self.rate as f64;
        let took = t_start.elapsed().as_secs_f64();
        let load = if budget > 0.0 { took / budget } else { 0.0 };
        let deck = self.cur.as_ref().map(|d| (d.id, d.position())).unwrap_or((0, 0.0));
        let phase = if self.fading.is_some() { PlaybackPhase::Crossfade } else { PlaybackPhase::Playing };
        {
            let h = &self.tele.health;
            h.sample_rate.store(self.rate as u64, Relaxed);
            h.buffer_frames.store(frames as u64, Relaxed);
            h.callbacks.fetch_add(1, Relaxed);
            h.playing_frames.fetch_add(playing_frames, Relaxed);
            h.load_sum_micro.fetch_add((load * 1e6) as u64, Relaxed);
            atomic_max(&h.load_max_micro, (load * 1e6) as u64);
        }
        if playing_frames > 0 && load > 1.0 {
            self.tele.health.callback_overruns.fetch_add(1, Relaxed);
            self.incident(IncidentKind::CallbackOverrun, phase, deck.0, deck.1, took * 1000.0, budget * 1000.0);
        }
        // The OS should call back every ~budget; a gap well beyond it while
        // playing means the device or process was stalled (audible).
        if let Some(prev) = self.mon.last_render {
            let gap = t_start.duration_since(prev).as_secs_f64();
            if self.mon.last_playing && playing_frames > 0 && gap > budget * 2.5 + 0.005 && gap < 5.0 {
                self.tele.health.late_callbacks.fetch_add(1, Relaxed);
                self.incident(IncidentKind::LateCallback, phase, deck.0, deck.1, gap * 1000.0, budget * 1000.0);
            }
        }
        self.mon.last_render = Some(t_start);
        self.mon.last_playing = playing_frames > 0;
        if nonfinite > 0 {
            self.tele.health.nonfinite_samples.fetch_add(nonfinite, Relaxed);
            self.incident(IncidentKind::NonFinite, phase, deck.0, deck.1, nonfinite as f64, 0.0);
        }
        // Clipping: one incident per episode (rate-limited to every 5 s).
        self.mon.frames += frames as u64;
        if clipped > 0 {
            self.tele.health.clipped_samples.fetch_add(clipped, Relaxed);
            self.mon.clip_run += clipped;
        }
        if self.mon.clip_run > 0 && (clipped == 0 || self.mon.frames - self.mon.last_clip_incident > self.rate as u64 * 5) {
            if self.mon.clip_run as f64 > self.rate as f64 * 0.01 {
                let run = self.mon.clip_run as f64;
                self.incident(IncidentKind::Clipping, phase, deck.0, deck.1, run, 0.0);
                self.mon.last_clip_incident = self.mon.frames;
            }
            if clipped == 0 {
                self.mon.clip_run = 0;
            }
        }
    }
}
