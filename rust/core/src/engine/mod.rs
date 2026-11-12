//! Lumisound audio engine: symphonia decoding on per-track deck threads,
//! a realtime mixer (gapless hand-over, crossfades, 10-band EQ, volume and
//! de-click ramps, per-track gain) and CoreAudio output via cpal. Swift only
//! configures AVAudioSession and Now Playing; it drives this through
//! `AudioEngine` and gets track events through `EngineListener`.

pub mod boost;
pub mod eq;
pub mod space;
pub mod health;
pub mod deck;
pub mod dsp;
pub mod mixer;
pub mod stretch;

use mixer::{Cmd, Event, Mixer, Telemetry};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum EngineError {
    #[error("{message}")]
    Open { message: String },
    #[error("audio output unavailable: {message}")]
    Output { message: String },
}

#[uniffi::export(with_foreign)]
pub trait EngineListener: Send + Sync {
    /// The playing track finished and nothing was queued.
    fn on_track_ended(&self, id: u64);
    /// A queued (gapless) or crossfaded track became the playing one.
    fn on_track_started(&self, id: u64);
    /// A track could not be decoded.
    fn on_track_failed(&self, id: u64);
}

const CMD_QUEUE: usize = 256;
const EVT_QUEUE: usize = 256;

#[derive(uniffi::Object)]
pub struct AudioEngine {
    cmds: Mutex<rtrb::Producer<Cmd>>,
    mixer: Arc<Mutex<Mixer>>,
    tele: Arc<Telemetry>,
    rate: AtomicU64,
    next_id: AtomicU64,
    current: Mutex<Option<(String, f32)>>,
    /// (speed, pitch semitones) applied to every deck opened.
    tempo: Mutex<(f64, f64)>,
    shutdown: Arc<AtomicBool>,
    output: Mutex<Option<output::Output>>,
}

fn db_to_lin(db: f32) -> f32 {
    10f32.powf(db / 20.0)
}

#[uniffi::export]
impl AudioEngine {
    #[uniffi::constructor]
    pub fn new(listener: Arc<dyn EngineListener>) -> Arc<Self> {
        let (cmd_tx, cmd_rx) = rtrb::RingBuffer::new(CMD_QUEUE);
        let (evt_tx, mut evt_rx) = rtrb::RingBuffer::<Event>::new(EVT_QUEUE);
        let tele = Arc::new(Telemetry::default());
        let rate = output::preferred_rate();
        let mixer = Arc::new(Mutex::new(Mixer::new(rate, cmd_rx, evt_tx, tele.clone())));
        let shutdown = Arc::new(AtomicBool::new(false));
        let sd = shutdown.clone();
        let tele_ev = tele.clone();
        std::thread::Builder::new()
            .name("lumisound-engine-events".into())
            .spawn(move || {
                while !sd.load(Ordering::Relaxed) {
                    while let Ok(e) = evt_rx.pop() {
                        match e {
                            Event::Ended { id } => listener.on_track_ended(id),
                            Event::Started { id } => listener.on_track_started(id),
                            Event::Failed { id } => listener.on_track_failed(id),
                            Event::Retire(d) => drop(d),
                            Event::Incident(i) => tele_ev.health.record(i),
                        }
                    }
                    std::thread::sleep(Duration::from_millis(15));
                }
            })
            .expect("engine event thread");
        Arc::new(Self {
            cmds: Mutex::new(cmd_tx),
            mixer,
            tele,
            rate: AtomicU64::new(rate as u64),
            next_id: AtomicU64::new(1),
            current: Mutex::new(None),
            tempo: Mutex::new((1.0, 0.0)),
            shutdown,
            output: Mutex::new(None),
        })
    }

    /// Open the audio device (call after activating AVAudioSession, and
    /// again after route changes / interruptions).
    pub fn start_output(&self) -> Result<(), EngineError> {
        let mut o = self.output.lock().unwrap();
        *o = None;
        self.adopt_device_rate(output::preferred_rate());
        let out = output::Output::start(self.mixer.clone(), self.tele.clone()).map_err(|m| {
            use std::sync::atomic::Ordering::Relaxed;
            self.tele.health.output_errors.fetch_add(1, Relaxed);
            self.tele.health.record(health::EngineIncident {
                kind: health::IncidentKind::OutputStartFailed,
                phase: health::PlaybackPhase::Starting,
                deck_id: self.current_id(),
                position: self.position(),
                value: 0.0,
                budget_ms: 0.0,
                message: Some(m.clone()),
                at: 0.0,
            });
            EngineError::Output { message: m }
        })?;
        *o = Some(out);
        Ok(())
    }

    pub fn stop_output(&self) {
        *self.output.lock().unwrap() = None;
    }

    pub fn output_rate(&self) -> u32 {
        self.rate.load(Ordering::Relaxed) as u32
    }

    /// Load `path` (an already-unlocked, playable file) at `start_secs` and
    /// make it the playing deck. Returns its id.
    pub fn load(&self, path: String, start_secs: f64, gain_db: f32) -> Result<u64, EngineError> {
        let d = self.open(&path, start_secs, gain_db)?;
        let id = d.id;
        *self.current.lock().unwrap() = Some((path, gain_db));
        // A new track: whatever was queued after the old one (gapless deck,
        // planned blend and its cue) belongs to the old one.
        self.send(Cmd::ClearNext);
        self.send(Cmd::Replace(Box::new(d)));
        Ok(id)
    }

    /// Gapless successor (decoding starts now, plays when the current drains).
    pub fn queue_next(&self, path: String, gain_db: f32) -> Result<u64, EngineError> {
        self.queue_next_at(path, 0.0, gain_db)
    }

    /// Gapless successor that starts `start_secs` in (Skip Silent Intros).
    pub fn queue_next_at(&self, path: String, start_secs: f64, gain_db: f32) -> Result<u64, EngineError> {
        let d = self.open(&path, start_secs.max(0.0), gain_db)?;
        let id = d.id;
        self.send(Cmd::QueueNext(Box::new(d)));
        Ok(id)
    }

    pub fn clear_next(&self) {
        self.send(Cmd::ClearNext);
    }

    /// Crossfade from the current track into `path` over `secs`.
    /// `tempo_match` (1 = off) beat-matches: the incoming track plays at that
    /// tempo ratio (pitch kept) for the first 60% of the fade, so its beats
    /// run at the outgoing track's tempo, then eases to its own tempo by the
    /// end. Use `beatmatch_ratio` to pick it.
    pub fn crossfade_to(&self, path: String, secs: f64, start_secs: f64, gain_db: f32, equal_power: bool, tempo_match: f64) -> Result<u64, EngineError> {
        let frames = (secs.max(0.0) * self.output_rate() as f64) as u64;
        let nudge = ((tempo_match - 1.0).abs() > 1e-4 && frames > 0).then(|| {
            let hold = frames * 3 / 5;
            deck::Nudge { start: tempo_match.clamp(0.9, 1.1), hold_frames: hold, ramp_frames: frames - hold }
        });
        let d = self.open_with(&path, start_secs, gain_db, nudge)?;
        let id = d.id;
        *self.current.lock().unwrap() = Some((path, gain_db));
        self.send(Cmd::Crossfade { deck: Box::new(d), frames, equal_power });
        Ok(id)
    }

    /// Queue `path` as the next track with a planned blend (Smart
    /// Crossfade, `crate::blend::blend_plan`): the deck opens and buffers
    /// now; the mixer starts the fade the frame the playing track reaches
    /// `plan.out_start`, so a bar-locked fade lands exactly on the downbeat.
    /// `on_track_started` fires when the fade begins.
    pub fn queue_blend(&self, path: String, plan: crate::blend::BlendPlan, gain_db: f32, equal_power: bool) -> Result<u64, EngineError> {
        let speed = self.tempo.lock().unwrap().0.clamp(0.25, 4.0);
        let frames = ((plan.fade_secs.max(0.05) / speed) * self.output_rate() as f64) as u64;
        let nudge = ((plan.tempo_match - 1.0).abs() > 1e-4 && frames > 0).then(|| {
            let hold = frames * 3 / 5;
            deck::Nudge { start: plan.tempo_match.clamp(0.9, 1.1), hold_frames: hold, ramp_frames: frames - hold }
        });
        let d = self.open_with(&path, plan.in_start.max(0.0), gain_db, nudge)?;
        let id = d.id;
        let swap = (plan.style == crate::blend::BlendStyle::BassSwap).then(|| {
            // The basses trade places over one beat-ish (1/8 of the fade, 120-500 ms).
            let len = (frames / 8).clamp(self.output_rate() as u64 / 8, self.output_rate() as u64 / 2);
            ((frames as f64 * plan.swap_at.clamp(0.1, 0.9)) as u64, len)
        });
        let equal_power = equal_power || plan.style != crate::blend::BlendStyle::EqualPower;
        self.send(Cmd::QueueBlend { deck: Box::new(d), cue: mixer::BlendCue { at_pos: plan.out_start, frames, equal_power, swap } });
        Ok(id)
    }

    /// Note which deck is current after a gapless hand-over (Swift tells us
    /// the new path so seeks reopen the right file).
    pub fn adopt_current(&self, path: String, gain_db: f32) {
        *self.current.lock().unwrap() = Some((path, gain_db));
    }

    /// Pitch-preserving speed (0.25–4×) and pitch shift (±24 semitones).
    /// Applies to the playing track at its current position.
    pub fn set_speed_pitch(&self, speed: f64, pitch_semitones: f64) -> Result<Option<u64>, EngineError> {
        {
            let mut t = self.tempo.lock().unwrap();
            if (t.0 - speed).abs() < 1e-6 && (t.1 - pitch_semitones).abs() < 1e-6 {
                return Ok(None);
            }
            *t = (speed, pitch_semitones);
        }
        let Some((path, gain)) = self.current.lock().unwrap().clone() else {
            return Ok(None);
        };
        self.clear_next();
        // Reopen the same track (same deck id: the app's bookkeeping is by
        // id) a short lead ahead of the playing position. The mixer swaps it
        // in with a 30 ms crossfade when playback reaches that spot, so a
        // pitch change has no gap and no jump. (It used to seek: the track
        // went silent until the new deck had buffered.)
        let id = self.tele.deck_id.load(Ordering::Relaxed);
        if !self.is_playing() || id == 0 {
            return self.seek(self.position()).map(Some);
        }
        let lead = 0.25 * speed.clamp(0.25, 4.0);
        let start = self.position() + lead;
        let dur = self.duration();
        if dur > 0.0 && start >= dur - 0.5 {
            return Ok(None);
        }
        let (sp, pi) = *self.tempo.lock().unwrap();
        let d = deck::open(id, &path, start, self.output_rate(), db_to_lin(gain), sp, pi, None, self.tele.clone()).map_err(|m| EngineError::Open { message: m })?;
        self.send(Cmd::Retune(Box::new(d)));
        Ok(Some(id))
    }

    pub fn seek(&self, secs: f64) -> Result<u64, EngineError> {
        let Some((path, gain)) = self.current.lock().unwrap().clone() else {
            return Err(EngineError::Open { message: "nothing loaded".into() });
        };
        let d = self.open(&path, secs.max(0.0), gain)?;
        let id = d.id;
        self.send(Cmd::Replace(Box::new(d)));
        Ok(id)
    }

    pub fn play(&self) {
        self.send(Cmd::Play);
    }

    pub fn pause(&self, fade_secs: f64) {
        let frames = (fade_secs.max(0.0) * self.output_rate() as f64) as u64;
        self.send(Cmd::Pause { fade_frames: frames });
    }

    pub fn stop(&self) {
        *self.current.lock().unwrap() = None;
        self.send(Cmd::Stop);
    }

    pub fn set_volume(&self, volume: f32) {
        self.send(Cmd::Volume(volume));
    }

    /// ReplayGain / normalization for the playing track, in dB.
    pub fn set_track_gain(&self, gain_db: f32) {
        self.send(Cmd::TrackGain(db_to_lin(gain_db)));
    }

    /// Ten gains in dB for 32 Hz…16 kHz (LumiEQ; levelled by loudness).
    pub fn set_eq(&self, gains_db: Vec<f32>, enabled: bool) {
        self.set_eq_with(gains_db, enabled, true);
    }

    /// `set_eq` with loudness matching chosen (off = headroom only).
    pub fn set_eq_with(&self, gains_db: Vec<f32>, enabled: bool, loudness_match: bool) {
        let mut g = [0f32; 10];
        for (i, v) in gains_db.iter().take(10).enumerate() {
            g[i] = *v;
        }
        self.send(Cmd::Eq { gains: g, enabled, loudness_match });
    }

    /// LumiBoost: extra loudness in dB (0 = off, up to 12) for this output route.
    pub fn set_boost(&self, db: f32, route: boost::BoostRoute) {
        self.send(Cmd::Boost { db, route });
    }

    /// Deepest LumiBoost gain reduction in the last buffer, dB (≤ 0): how hard
    /// the booster is holding loud passages back.
    pub fn boost_reduction(&self) -> f32 {
        f32::from_bits(self.tele.boost_reduction_bits.load(Ordering::Relaxed))
    }

    /// Reverb wet amount 0…1 with a room preset name, mono fold-down and
    /// night-mode compression.
    pub fn set_effects(&self, reverb_wet: f32, reverb_preset: String, mono: bool, night_mode: bool) {
        self.send(Cmd::Effects { reverb_wet, reverb_preset, mono, night: night_mode });
    }

    /// Spatial audio on (Studio) or off, with head yaw in degrees.
    pub fn set_spatial(&self, enabled: bool, yaw_degrees: f32) {
        let mode = if enabled { space::SpatialMode::Studio } else { space::SpatialMode::Off };
        self.send(Cmd::Spatial { mode, yaw_deg: yaw_degrees });
    }

    /// LumiSpace mode and the head yaw from the headphones' motion sensor (degrees).
    pub fn set_spatial_mode(&self, mode: space::SpatialMode, yaw_degrees: f32) {
        self.send(Cmd::Spatial { mode, yaw_deg: yaw_degrees });
    }

    /// 8D rotation speed (Hz, 0 = off), tremolo rate/depth and vibrato
    /// rate/depth in semitones (0 = off).
    pub fn set_modulation(&self, pan_hz: f32, tremolo_hz: f32, tremolo_depth: f32, vibrato_hz: f32, vibrato_semitones: f32) {
        self.send(Cmd::Modulation { pan_hz, tremolo_hz, tremolo_depth, vibrato_hz, vibrato_semitones });
    }

    /// Cumulative health counters (underruns, callback load, decode speed…).
    pub fn health(&self) -> health::EngineHealth {
        self.tele.health.snapshot()
    }

    /// Counter deltas and grouped incidents since the previous call (drains
    /// the incident log). The app uploads this when `has_problems`.
    pub fn health_report(&self) -> health::EngineReport {
        self.tele.health.report()
    }

    /// The incident log (most recent 256), oldest first.
    pub fn incidents(&self) -> Vec<health::EngineIncident> {
        self.tele.health.incidents()
    }

    pub fn reset_health(&self) {
        self.tele.health.reset();
    }

    pub fn position(&self) -> f64 {
        f64::from_bits(self.tele.position_bits.load(Ordering::Relaxed))
    }

    pub fn duration(&self) -> f64 {
        f64::from_bits(self.tele.duration_bits.load(Ordering::Relaxed))
    }

    pub fn is_playing(&self) -> bool {
        self.tele.playing.load(Ordering::Relaxed)
    }

    pub fn current_id(&self) -> u64 {
        self.tele.deck_id.load(Ordering::Relaxed)
    }

    /// The most recent `count` output samples (mono, oldest first) for the
    /// visualizer / music haptics.
    pub fn tap_samples(&self, count: u32) -> Vec<f32> {
        self.tele.tap.latest(count as usize)
    }

    /// Peak levels of the most recent output buffer (visualizer / meters).
    pub fn levels(&self) -> Vec<f32> {
        let b = self.tele.levels_bits.load(Ordering::Relaxed);
        vec![f32::from_bits((b >> 32) as u32), f32::from_bits(b as u32)]
    }
}

/// Tempo ratio for a beat-matched crossfade into a track at `incoming_bpm`
/// from one at `outgoing_bpm`: the incoming track runs at the outgoing tempo.
/// Half/double-time pairs (e.g. 70 → 140) match on the nearer multiple.
/// Returns 1 (plain crossfade) when either BPM is unknown or the needed
/// change is over 8%.
#[uniffi::export]
pub fn beatmatch_ratio(outgoing_bpm: f64, incoming_bpm: f64) -> f64 {
    if !(outgoing_bpm > 0.0 && incoming_bpm > 0.0) {
        return 1.0;
    }
    let best = [0.5, 1.0, 2.0]
        .iter()
        .map(|m| outgoing_bpm * m / incoming_bpm)
        .min_by(|a, b| (a - 1.0).abs().total_cmp(&(b - 1.0).abs()))
        .unwrap_or(1.0);
    if (best - 1.0).abs() <= 0.08 { best } else { 1.0 }
}

/// Effective EQ gains: the user's bands (when enabled) plus bass boost on
/// the 32/64 Hz bands, clamped to the engine's range.
#[uniffi::export]
pub fn effective_eq_gains(bands: Vec<f32>, eq_enabled: bool, bass_boost_enabled: bool, bass_boost_gain: f32) -> Vec<f32> {
    let boost = bass_boost_gain.clamp(0.0, 15.0);
    (0..10)
        .map(|i| {
            let mut g = if eq_enabled { bands.get(i).copied().unwrap_or(0.0) } else { 0.0 };
            if bass_boost_enabled && i < 2 {
                g += boost;
            }
            g.clamp(-24.0, 24.0)
        })
        .collect()
}

impl AudioEngine {
    fn open(&self, path: &str, start: f64, gain_db: f32) -> Result<deck::Deck, EngineError> {
        self.open_with(path, start, gain_db, None)
    }

    fn open_with(&self, path: &str, start: f64, gain_db: f32, nudge: Option<deck::Nudge>) -> Result<deck::Deck, EngineError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (speed, pitch) = *self.tempo.lock().unwrap();
        deck::open(id, path, start, self.output_rate(), db_to_lin(gain_db), speed, pitch, nudge, self.tele.clone()).map_err(|m| EngineError::Open { message: m })
    }

    /// The device now runs at `dev_rate` (Bluetooth A2DP at 44.1 kHz, a
    /// hi-res session at 96 kHz...). Opening the stream at the device rate
    /// while the mixer kept rendering at the old one played everything
    /// ~9% fast or slow (pitch shifted with it) after a route change. Rebuild
    /// the mixer's processors at the new rate and reopen the playing and
    /// queued decks under their same ids (the app's bookkeeping is by id),
    /// the playing one at its current position. Applied before the stream
    /// starts, so the first callback already renders at the right rate.
    fn adopt_device_rate(&self, dev_rate: u32) {
        let old = self.output_rate();
        if dev_rate == old || dev_rate == 0 {
            return;
        }
        self.rate.store(dev_rate as u64, Ordering::Relaxed);
        let (cur, next) = {
            let mut m = self.mixer.lock().unwrap();
            m.set_rate(dev_rate);
            m.reopen_targets()
        };
        let (speed, pitch) = *self.tempo.lock().unwrap();
        if let Some((id, path, gain, pos)) = cur {
            if let Ok(d) = deck::open(id, &path, pos.max(0.0), dev_rate, gain, speed, pitch, None, self.tele.clone()) {
                self.send(Cmd::Replace(Box::new(d)));
            }
        }
        if let Some((id, path, gain, start)) = next {
            if let Ok(d) = deck::open(id, &path, start.max(0.0), dev_rate, gain, speed, pitch, None, self.tele.clone()) {
                self.send(Cmd::QueueNext(Box::new(d)));
            }
        }
        self.tele.health.rate_switches.fetch_add(1, Ordering::Relaxed);
    }

    /// Queue a command for the audio callback. Never blocks the caller (the
    /// main thread): if the queue is full because the callback isn't running
    /// — another app took the audio session, the route died — the commands
    /// are applied to the mixer directly. (This used to wait forever, which
    /// froze play/pause/seek after an interruption.)
    fn send(&self, c: Cmd) {
        let mut q = self.cmds.lock().unwrap();
        let mut c = c;
        for attempt in 0..5 {
            match q.push(c) {
                Ok(()) => return,
                Err(rtrb::PushError::Full(back)) => {
                    c = back;
                    if attempt < 4 {
                        std::thread::sleep(Duration::from_millis(2));
                    }
                }
            }
        }
        // Callback stalled: apply what's queued ourselves, then enqueue.
        if let Ok(mut m) = self.mixer.lock() {
            m.drain_commands();
        }
        let _ = q.push(c);
    }


    /// Offline render (tests / export): pull `frames` stereo frames.
    pub fn render_offline(&self, frames: usize) -> Vec<f32> {
        let mut buf = vec![0f32; frames * 2];
        self.mixer.lock().unwrap().render(&mut buf);
        buf
    }
}

#[uniffi::export]
impl AudioEngine {
    /// True when the output callback ran within the last `max_age_ms`.
    /// (False before output starts or while iOS has it stopped.)
    pub fn output_alive(&self, max_age_ms: u32) -> bool {
        let last = self.tele.health.last_callback_ns.load(Ordering::Relaxed);
        last != 0 && health::mono_ns().saturating_sub(last) <= max_age_ms as u64 * 1_000_000
    }

    /// Tear down and reopen the output stream on the current route (after an
    /// interruption, a Bluetooth reconnect, or a stalled callback). The
    /// mixer, decks and position are untouched; queued commands are applied.
    pub fn restart_output(&self) -> Result<(), EngineError> {
        *self.output.lock().unwrap() = None;
        if let Ok(mut m) = self.mixer.lock() {
            m.drain_commands();
        }
        self.tele.health.output_restarts.fetch_add(1, Ordering::Relaxed);
        self.start_output()
    }
}

impl Drop for AudioEngine {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Relaxed);
    }
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
mod output {
    use super::Mixer;
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    use std::sync::mpsc;
    use std::sync::{Arc, Mutex};

    pub fn preferred_rate() -> u32 {
        cpal::default_host().default_output_device().and_then(|d| d.default_output_config().ok()).map(|c| c.sample_rate().0).unwrap_or(48_000)
    }

    /// The cpal stream lives on its own thread (it is !Send on Apple).
    pub struct Output {
        stop: mpsc::Sender<()>,
    }

    impl Output {
        pub fn start(mixer: Arc<Mutex<Mixer>>, tele: Arc<super::mixer::Telemetry>) -> Result<Self, String> {
            let tele_err = tele.clone();
            let (stop_tx, stop_rx) = mpsc::channel::<()>();
            let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
            std::thread::Builder::new()
                .name("lumisound-output".into())
                .spawn(move || {
                    let r = (|| {
                        let dev = cpal::default_host().default_output_device().ok_or("no output device")?;
                        let cfg = dev.default_output_config().map_err(|e| e.to_string())?;
                        let channels = cfg.channels() as usize;
                        let mut config: cpal::StreamConfig = cfg.into();
                        config.buffer_size = cpal::BufferSize::Default;
                        let mut scratch: Vec<f32> = Vec::new();
                        let stream = dev
                            .build_output_stream(
                                &config,
                                move |data: &mut [f32], _| {
                                    let frames = data.len() / channels.max(1);
                                    scratch.resize(frames * 2, 0.0);
                                    match mixer.try_lock() {
                                        Ok(mut m) => m.render(&mut scratch),
                                        Err(_) => {
                                            // Silence this buffer rather than block the audio thread.
                                            tele.health.lock_misses.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                            scratch.iter_mut().for_each(|s| *s = 0.0)
                                        }
                                    }
                                    for (i, f) in data.chunks_mut(channels.max(1)).enumerate() {
                                        let (l, r) = (scratch[i * 2], scratch[i * 2 + 1]);
                                        match f.len() {
                                            1 => f[0] = (l + r) * 0.5,
                                            _ => {
                                                f[0] = l;
                                                f[1] = r;
                                                for x in f.iter_mut().skip(2) {
                                                    *x = 0.0;
                                                }
                                            }
                                        }
                                    }
                                },
                                move |e| {
                                    // Device lost / route change / reset: the app restarts output.
                                    tele_err.health.output_errors.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                    tele_err.health.record(super::health::EngineIncident {
                                        kind: super::health::IncidentKind::OutputError,
                                        phase: super::health::PlaybackPhase::Playing,
                                        deck_id: tele_err.deck_id.load(std::sync::atomic::Ordering::Relaxed),
                                        position: f64::from_bits(tele_err.position_bits.load(std::sync::atomic::Ordering::Relaxed)),
                                        value: 0.0,
                                        budget_ms: 0.0,
                                        message: Some(e.to_string()),
                                        at: 0.0,
                                    });
                                },
                                None,
                            )
                            .map_err(|e| e.to_string())?;
                        stream.play().map_err(|e| e.to_string())?;
                        Ok::<_, String>(stream)
                    })();
                    match r {
                        Ok(stream) => {
                            let _ = ready_tx.send(Ok(()));
                            let _ = stop_rx.recv();
                            drop(stream);
                        }
                        Err(e) => {
                            let _ = ready_tx.send(Err(e));
                        }
                    }
                })
                .map_err(|e| e.to_string())?;
            ready_rx.recv().map_err(|e| e.to_string())??;
            Ok(Self { stop: stop_tx })
        }
    }

    impl Drop for Output {
        fn drop(&mut self) {
            let _ = self.stop.send(());
        }
    }
}

#[cfg(not(any(target_os = "ios", target_os = "macos")))]
mod output {
    use super::Mixer;
    use std::sync::{Arc, Mutex};

    pub fn preferred_rate() -> u32 {
        48_000
    }

    /// No audio device on this platform (tests, tvOS/watchOS until wired).
    pub struct Output;

    impl Output {
        pub fn start(_mixer: Arc<Mutex<Mixer>>, _tele: Arc<super::mixer::Telemetry>) -> Result<Self, String> {
            Err("no audio output on this platform".into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct L(Mutex<Vec<String>>);
    impl EngineListener for L {
        fn on_track_ended(&self, id: u64) {
            self.0.lock().unwrap().push(format!("end{id}"));
        }
        fn on_track_started(&self, id: u64) {
            self.0.lock().unwrap().push(format!("start{id}"));
        }
        fn on_track_failed(&self, id: u64) {
            self.0.lock().unwrap().push(format!("fail{id}"));
        }
    }

    fn wav(path: &std::path::Path, secs: f32, freq: f32, rate: u32) {
        let n = (secs * rate as f32) as u32;
        let mut b = Vec::new();
        let data_len = n * 4;
        b.extend_from_slice(b"RIFF");
        b.extend_from_slice(&(36 + data_len).to_le_bytes());
        b.extend_from_slice(b"WAVEfmt ");
        b.extend_from_slice(&16u32.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&2u16.to_le_bytes());
        b.extend_from_slice(&rate.to_le_bytes());
        b.extend_from_slice(&(rate * 4).to_le_bytes());
        b.extend_from_slice(&4u16.to_le_bytes());
        b.extend_from_slice(&16u16.to_le_bytes());
        b.extend_from_slice(b"data");
        b.extend_from_slice(&data_len.to_le_bytes());
        for i in 0..n {
            let v = ((2.0 * std::f32::consts::PI * freq * i as f32 / rate as f32).sin() * 0.5 * 32767.0) as i16;
            b.extend_from_slice(&v.to_le_bytes());
            b.extend_from_slice(&v.to_le_bytes());
        }
        std::fs::write(path, b).unwrap();
    }

    fn pump(e: &AudioEngine, secs: f64) -> Vec<f32> {
        let mut all = Vec::new();
        let chunk = 1024;
        let n = (secs * e.output_rate() as f64) as usize / chunk;
        for _ in 0..n {
            // Paced by the decoders, not the clock: wait (bounded) until the
            // decks have this chunk buffered, so slow debug builds and a busy
            // machine can't starve them and skew timing-based asserts.
            let t = std::time::Instant::now();
            while !e.mixer.lock().unwrap().decks_ready(chunk) && t.elapsed() < Duration::from_secs(2) {
                std::thread::sleep(Duration::from_millis(1));
            }
            all.extend(e.render_offline(chunk));
        }
        all
    }

    #[test]
    fn plays_resamples_and_hands_over_gaplessly() {
        let d = std::env::temp_dir().join(format!("engine-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&d).unwrap();
        let (a, b) = (d.join("a.wav"), d.join("b.wav"));
        wav(&a, 0.5, 440.0, 44_100); // resampled 44.1k -> 48k
        wav(&b, 0.5, 880.0, 48_000);
        let l = Arc::new(L(Mutex::new(vec![])));
        let e = AudioEngine::new(l.clone());
        let ia = e.load(a.to_string_lossy().into(), 0.0, 0.0).unwrap();
        let ib = e.queue_next(b.to_string_lossy().into(), 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(200)); // let decks buffer
        e.play();
        let out = pump(&e, 1.3);
        std::thread::sleep(Duration::from_millis(100));
        let ev = l.0.lock().unwrap().clone();
        assert_eq!(ev, vec![format!("start{ib}"), format!("end{ib}")], "events {ev:?} (a={ia})");
        let loud = out.iter().filter(|s| s.abs() > 0.1).count() / 2;
        // 1.0 s of 0.5-amplitude tone across both tracks: |sin| > 0.2 for
        // 87.2% of samples -> ~41.9k frames at 48 kHz. A gap at the seam or
        // dropped buffers would show up as a shortfall.
        assert!((40_500..=43_500).contains(&loud), "loud frames {loud}");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn beatmatch_ratio_picks_nearest_multiple() {
        assert_eq!(beatmatch_ratio(120.0, 0.0), 1.0);
        assert!((beatmatch_ratio(124.0, 120.0) - 124.0 / 120.0).abs() < 1e-9);
        assert!((beatmatch_ratio(70.0, 136.0) - 140.0 / 136.0).abs() < 1e-9);
        assert_eq!(beatmatch_ratio(100.0, 128.0), 1.0);
    }

    #[test]
    fn beatmatched_crossfade_tracks_position_and_returns_to_native_tempo() {
        let d = std::env::temp_dir().join(format!("engine-bm-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&d).unwrap();
        let (a, b) = (d.join("a.wav"), d.join("b.wav"));
        wav(&a, 1.0, 440.0, 48_000);
        wav(&b, 6.0, 440.0, 48_000);
        let l = Arc::new(L(Mutex::new(vec![])));
        let e = AudioEngine::new(l.clone());
        e.load(a.to_string_lossy().into(), 0.0, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        e.play();
        pump(&e, 0.3);
        // 1 s fade at 1.08x: 0.6 s held + 0.4 s easing back = 0.6*1.08 + 0.4*1.04.
        e.crossfade_to(b.to_string_lossy().into(), 1.0, 0.0, 0.0, true, 1.08).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut out = pump(&e, 1.0);
        // pump renders whole 1024-frame chunks; integrate the planned tempo.
        let played = |secs: f64| ((secs * 48_000.0) as usize / 1024 * 1024) as f64 / 48_000.0;
        let t = played(1.0);
        let r = t - 0.6;
        let expect = 0.6 * 1.08 + r + 0.08 * (r - r * r / 0.8);
        assert!((e.position() - expect).abs() < 0.01, "pos {} vs {expect}", e.position());
        // Afterwards it runs at 1x: output time = track time.
        out.extend(pump(&e, 2.0));
        let after = expect + played(2.0);
        assert!((e.position() - after).abs() < 0.01, "pos {} vs {after}", e.position());
        // Steady tone after the fade, no seam where stretching stops.
        let tail = &out[out.len() - 48_000 * 2..];
        let loud = tail.iter().filter(|s| s.abs() > 0.1).count() / 2;
        assert!(loud > 40_000, "tail loud frames {loud}");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn crossfades_without_a_gap() {
        let d = std::env::temp_dir().join(format!("engine-xf-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&d).unwrap();
        let (a, b) = (d.join("a.wav"), d.join("b.wav"));
        wav(&a, 1.0, 440.0, 48_000);
        wav(&b, 1.0, 660.0, 48_000);
        let l = Arc::new(L(Mutex::new(vec![])));
        let e = AudioEngine::new(l.clone());
        e.load(a.to_string_lossy().into(), 0.0, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        e.play();
        let mut out = pump(&e, 0.4);
        let ib = e.crossfade_to(b.to_string_lossy().into(), 0.3, 0.0, 0.0, true, 1.0).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        out.extend(pump(&e, 0.6));
        std::thread::sleep(Duration::from_millis(60));
        assert!(l.0.lock().unwrap().contains(&format!("start{ib}")));
        // No silent stretch longer than a sine zero-crossing during the fade.
        let mut run = 0usize;
        let mut worst = 0usize;
        for f in out.chunks(2).skip(2048) {
            if f[0].abs() < 1e-4 { run += 1; worst = worst.max(run) } else { run = 0 }
        }
        assert!(worst < 8, "silent run of {worst} frames");
        assert_eq!(e.current_id(), ib);
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn follows_device_rate_change_without_pitch_shift() {
        let d = std::env::temp_dir().join(format!("engine-rate-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&d).unwrap();
        let a = d.join("a.wav");
        wav(&a, 6.0, 440.0, 48_000);
        let l = Arc::new(L(Mutex::new(vec![])));
        let e = AudioEngine::new(l.clone());
        assert_eq!(e.output_rate(), 48_000);
        let id = e.load(a.to_string_lossy().into(), 0.0, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        e.play();
        let _ = pump(&e, 1.0);
        let before = e.position();
        // The route moves to a 44.1 kHz device (Bluetooth A2DP).
        e.adopt_device_rate(44_100);
        assert_eq!(e.output_rate(), 44_100);
        std::thread::sleep(Duration::from_millis(200));
        let out = pump(&e, 1.5);
        assert_eq!(e.current_id(), id, "same deck id after the switch");
        // Measure the tone from zero crossings after the 10 ms hand-over.
        let left: Vec<f32> = out.chunks(2).map(|c| c[0]).skip(4410).collect();
        let zc: Vec<f64> = left.windows(2).enumerate().filter(|(_, w)| w[0] < 0.0 && w[1] >= 0.0).map(|(i, w)| i as f64 + (w[0] / (w[0] - w[1])) as f64).collect();
        let hz = 44_100.0 * (zc.len() - 1) as f64 / (zc[zc.len() - 1] - zc[0]);
        assert!((hz - 440.0).abs() < 1.0, "tone at {hz:.1} Hz after the rate switch");
        let moved = e.position() - before;
        assert!((moved - 1.5).abs() < 0.15, "position advanced {moved:.2}s over 1.5 s");
        assert_eq!(e.health().rate_switches, 1);
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn double_speed_halves_duration() {
        let d = std::env::temp_dir().join(format!("engine-sp-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&d).unwrap();
        let a = d.join("a.wav");
        wav(&a, 1.0, 440.0, 48_000);
        let l = Arc::new(L(Mutex::new(vec![])));
        let e = AudioEngine::new(l.clone());
        e.set_speed_pitch(2.0, 0.0).unwrap();
        let id = e.load(a.to_string_lossy().into(), 0.0, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        e.play();
        let out = pump(&e, 0.9);
        std::thread::sleep(Duration::from_millis(60));
        assert!(l.0.lock().unwrap().contains(&format!("end{id}")), "{:?}", l.0.lock().unwrap());
        let loud = out.iter().filter(|s| s.abs() > 0.1).count() / 2;
        // 1 s of audio at 2x ≈ 0.5 s ≈ 24k frames, ~87% above the threshold.
        assert!((18_000..=23_500).contains(&loud), "loud {loud}");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    // The 256-tap sinc resampler is far too slow unoptimised to keep a deck
    // fed in real time; tests/engine_quality.rs measures pitch (and decode
    // speed) in release builds.
    #[cfg_attr(debug_assertions, ignore)]
    fn pitch_shift_raises_pitch_and_keeps_length() {
        let d = std::env::temp_dir().join(format!("engine-pitch-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&d).unwrap();
        let a = d.join("a.wav");
        wav(&a, 2.0, 440.0, 48_000);
        for (st, speed) in [(4.0, 1.0), (-5.0, 1.0), (3.0, 1.5), (1.0, 1.0), (-1.0, 0.8), (7.0, 1.25), (12.0, 1.0), (-12.0, 1.0)] {
            let l = Arc::new(L(Mutex::new(vec![])));
            let e = AudioEngine::new(l.clone());
            e.set_speed_pitch(speed, st).unwrap();
            e.load(a.to_string_lossy().into(), 0.0, 0.0).unwrap();
            std::thread::sleep(Duration::from_millis(200));
            e.play();
            // Paced like real playback (time-stretch is slow in debug builds;
            // pumping flat out would starve the deck and skew the count).
            let mut out = Vec::new();
            for _ in 0..(48_000 / 1024) {
                out.extend(e.render_offline(1024));
                std::thread::sleep(Duration::from_millis(8));
            }
            assert_eq!(e.health().underrun_events, 0, "{st:+} st: deck starved: {:?}", e.incidents());
            let left: Vec<f32> = out.iter().step_by(2).copied().collect();
            let mid = &left[4_800..40_000];
            let zc = mid.windows(2).filter(|p| (p[0] >= 0.0) != (p[1] >= 0.0)).count();
            let hz = zc as f64 / (mid.len() as f64 / 48_000.0) / 2.0;
            let expect = 440.0 * 2f64.powf(st / 12.0);
            assert!((hz / expect - 1.0).abs() < 0.01, "{st:+} st: {hz:.1} Hz, expected {expect:.1}");
            // Track time advances at `speed` regardless of pitch.
            let played = out.len() as f64 / 2.0 / 48_000.0;
            assert!((e.position() / (played * speed) - 1.0).abs() < 0.08, "{st:+} st position {}", e.position());
        }
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn health_counts_callbacks_without_false_alarms_and_groups_incidents() {
        let d = std::env::temp_dir().join(format!("engine-health-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&d).unwrap();
        let a = d.join("a.wav");
        wav(&a, 2.0, 440.0, 48_000);
        let l = Arc::new(L(Mutex::new(vec![])));
        let e = AudioEngine::new(l.clone());
        e.load(a.to_string_lossy().into(), 0.0, 0.0).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        e.play();
        pump(&e, 1.0);
        std::thread::sleep(Duration::from_millis(60));
        let h = e.health();
        assert!(h.callbacks >= 40, "{h:?}");
        assert!(h.playing_seconds > 0.9, "{h:?}");
        assert_eq!(h.underrun_events, 0, "{h:?} {:?}", e.incidents());
        assert_eq!(h.nonfinite_samples, 0);
        assert!(h.start_latency_max_ms > 0.0 && h.start_latency_max_ms < 400.0, "{h:?}");
        assert!(h.callback_load_avg < 1.0, "{h:?}");
        let r = e.health_report();
        assert!(!r.severe && r.delta.callbacks == h.callbacks);
        // A second report only covers what happened since.
        assert_eq!(e.health_report().delta.callbacks, 0);

        // Grouping/severity from recorded incidents.
        use health::*;
        let mk = |kind, value| EngineIncident { kind, phase: PlaybackPhase::Playing, deck_id: 7, position: 12.0, value, budget_ms: 0.0, message: None, at: 0.0 };
        e.tele.health.record(mk(IncidentKind::Underrun, 40.0));
        e.tele.health.record(mk(IncidentKind::Underrun, 300.0));
        e.tele.health.record(mk(IncidentKind::LateCallback, 90.0));
        let r = e.health_report();
        assert!(r.severe, "300 ms dropout is severe");
        let g = r.groups.iter().find(|g| g.kind == IncidentKind::Underrun).unwrap();
        assert_eq!((g.count, g.worst, g.total), (2, 300.0, 340.0));
        let j: serde_json::Value = serde_json::from_str(&engine_report_json(r)).unwrap();
        assert_eq!(j["groups"][0]["kind"], "underrun");
        assert!(e.incidents().is_empty(), "report drains the log");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn commands_never_block_when_output_is_stalled() {
        // No output callback at all (as after another app takes the session):
        // 2,000 commands must not hang the caller, and they must take effect.
        let l = Arc::new(L(Mutex::new(vec![])));
        let e = AudioEngine::new(l);
        assert!(!e.output_alive(1000), "no callback yet");
        let t = std::time::Instant::now();
        for i in 0..2000 {
            e.set_volume((i % 10) as f32 / 10.0);
            e.play();
            e.pause(0.0);
        }
        assert!(t.elapsed() < Duration::from_secs(2), "send blocked: {:?}", t.elapsed());
        e.play();
        e.render_offline(256);
        assert!(e.output_alive(1000), "a render counts as a callback");
        assert!(e.is_playing(), "the last command won");
    }
}
