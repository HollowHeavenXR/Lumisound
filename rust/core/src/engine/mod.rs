//! Lumisound audio engine: symphonia decoding on per-track deck threads,
//! a realtime mixer (gapless hand-over, crossfades, 10-band EQ, volume and
//! de-click ramps, per-track gain) and CoreAudio output via cpal. Swift only
//! configures AVAudioSession and Now Playing; it drives this through
//! `AudioEngine` and gets track events through `EngineListener`.

pub mod deck;
pub mod dsp;
pub mod mixer;

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
            shutdown,
            output: Mutex::new(None),
        })
    }

    /// Open the audio device (call after activating AVAudioSession, and
    /// again after route changes / interruptions).
    pub fn start_output(&self) -> Result<(), EngineError> {
        let mut o = self.output.lock().unwrap();
        *o = None;
        let out = output::Output::start(self.mixer.clone()).map_err(|m| EngineError::Output { message: m })?;
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
        self.send(Cmd::Replace(Box::new(d)));
        Ok(id)
    }

    /// Gapless successor (decoding starts now, plays when the current drains).
    pub fn queue_next(&self, path: String, gain_db: f32) -> Result<u64, EngineError> {
        let d = self.open(&path, 0.0, gain_db)?;
        let id = d.id;
        self.send(Cmd::QueueNext(Box::new(d)));
        Ok(id)
    }

    pub fn clear_next(&self) {
        self.send(Cmd::ClearNext);
    }

    /// Crossfade from the current track into `path` over `secs`.
    pub fn crossfade_to(&self, path: String, secs: f64, start_secs: f64, gain_db: f32, equal_power: bool) -> Result<u64, EngineError> {
        let d = self.open(&path, start_secs, gain_db)?;
        let id = d.id;
        *self.current.lock().unwrap() = Some((path, gain_db));
        let frames = (secs.max(0.0) * self.output_rate() as f64) as u64;
        self.send(Cmd::Crossfade { deck: Box::new(d), frames, equal_power });
        Ok(id)
    }

    /// Note which deck is current after a gapless hand-over (Swift tells us
    /// the new path so seeks reopen the right file).
    pub fn adopt_current(&self, path: String, gain_db: f32) {
        *self.current.lock().unwrap() = Some((path, gain_db));
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

    /// Ten gains in dB for 32 Hz…16 kHz.
    pub fn set_eq(&self, gains_db: Vec<f32>, enabled: bool) {
        let mut g = [0f32; 10];
        for (i, v) in gains_db.iter().take(10).enumerate() {
            g[i] = *v;
        }
        self.send(Cmd::Eq { gains: g, enabled });
    }

    /// Reverb wet amount 0…1 with a room preset name, mono fold-down and
    /// night-mode compression.
    pub fn set_effects(&self, reverb_wet: f32, reverb_preset: String, mono: bool, night_mode: bool) {
        self.send(Cmd::Effects { reverb_wet, reverb_preset, mono, night: night_mode });
    }

    /// 8D rotation speed (Hz, 0 = off) and tremolo rate/depth (0 = off).
    pub fn set_modulation(&self, pan_hz: f32, tremolo_hz: f32, tremolo_depth: f32) {
        self.send(Cmd::Modulation { pan_hz, tremolo_hz, tremolo_depth });
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
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        deck::open(id, path, start, self.output_rate(), db_to_lin(gain_db)).map_err(|m| EngineError::Open { message: m })
    }

    fn send(&self, c: Cmd) {
        let mut q = self.cmds.lock().unwrap();
        let mut c = c;
        // The callback drains every buffer; if it is stalled (no output yet),
        // render inline so commands still take effect.
        loop {
            match q.push(c) {
                Ok(()) => return,
                Err(rtrb::PushError::Full(back)) => {
                    c = back;
                    std::thread::sleep(Duration::from_millis(2));
                }
            }
        }
    }

    /// Offline render (tests / export): pull `frames` stereo frames.
    pub fn render_offline(&self, frames: usize) -> Vec<f32> {
        let mut buf = vec![0f32; frames * 2];
        self.mixer.lock().unwrap().render(&mut buf);
        buf
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
        pub fn start(mixer: Arc<Mutex<Mixer>>) -> Result<Self, String> {
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
                                        Err(_) => scratch.iter_mut().for_each(|s| *s = 0.0),
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
                                |e| eprintln!("lumisound output error: {e}"),
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
        pub fn start(_mixer: Arc<Mutex<Mixer>>) -> Result<Self, String> {
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
            all.extend(e.render_offline(chunk));
            std::thread::sleep(Duration::from_millis(1));
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
        let ib = e.crossfade_to(b.to_string_lossy().into(), 0.3, 0.0, 0.0, true).unwrap();
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
}
