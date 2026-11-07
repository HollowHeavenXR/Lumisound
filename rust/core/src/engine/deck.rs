//! A deck: one track being decoded on its own thread into a lock-free ring
//! buffer of interleaved stereo f32 at the output rate. The mixer (audio
//! callback) only ever pops from the ring.

use rubato::{FftFixedIn, Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error;
use symphonia::core::formats::{FormatOptions, SeekMode, SeekTo};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::Time;

/// ~1.5 s of stereo audio at 48 kHz.
const RING_SAMPLES: usize = 48_000 * 2 * 3 / 2;
const CHUNK: usize = 1024;

pub struct DeckShared {
    pub stop: AtomicBool,
    /// Decoder reached the end (or failed) and wrote everything it will.
    pub eof: AtomicBool,
    pub failed: AtomicBool,
    pub duration_bits: AtomicU64,
}

pub struct Deck {
    pub id: u64,
    pub path: String,
    /// Track position (seconds) of the first frame this deck produces.
    pub start_offset: f64,
    pub frames_played: u64,
    pub out_rate: u32,
    pub ring: rtrb::Consumer<f32>,
    pub shared: Arc<DeckShared>,
    /// Per-track gain (ReplayGain / normalization), linear.
    pub gain: f32,
    /// Playback speed (track seconds per output second) the deck opened with.
    pub speed: f64,
    /// (output frames, track seconds per output frame) runs from the decode
    /// thread, so position stays exact while the rate changes.
    segs: rtrb::Consumer<(u64, f64)>,
    seg_left: u64,
    seg_step: f64,
    track_secs: f64,
    /// When the deck was opened (first-audio latency).
    pub opened_at: std::time::Instant,
    /// Became current by gapless hand-over (phase for incidents).
    pub handed_over: bool,
}

/// Tempo match for a beat-matched crossfade: play at `start` × speed, hold for
/// `hold_frames` output frames, then ease linearly to 1 over `ramp_frames`.
#[derive(Clone, Copy, Debug)]
pub struct Nudge {
    pub start: f64,
    pub hold_frames: u64,
    pub ramp_frames: u64,
}

impl Nudge {
    fn at(&self, frame: u64) -> f64 {
        if frame <= self.hold_frames {
            return self.start;
        }
        let t = (frame - self.hold_frames) as f64 / self.ramp_frames.max(1) as f64;
        if t >= 1.0 { 1.0 } else { self.start + (1.0 - self.start) * t }
    }
}

impl Deck {
    pub fn position(&self) -> f64 {
        self.start_offset + self.track_secs
    }

    /// One output frame was played.
    #[inline]
    pub fn advance(&mut self) {
        self.frames_played += 1;
        if self.seg_left == 0 {
            if let Ok((n, step)) = self.segs.pop() {
                self.seg_left = n;
                self.seg_step = step;
            }
        }
        self.seg_left = self.seg_left.saturating_sub(1);
        self.track_secs += self.seg_step;
    }

    pub fn duration(&self) -> f64 {
        f64::from_bits(self.shared.duration_bits.load(Ordering::Relaxed))
    }

    /// Everything decoded has been played.
    pub fn drained(&self) -> bool {
        self.shared.eof.load(Ordering::Acquire) && self.ring.slots() == 0
    }

    pub fn buffered_frames(&self) -> usize {
        self.ring.slots() / 2
    }
}

impl Drop for Deck {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
    }
}

/// Open `path` and start decoding from `start` seconds. Returns once the
/// container is probed (fails fast on unreadable files).
pub fn open(id: u64, path: &str, start: f64, out_rate: u32, gain: f32, speed: f64, pitch_semitones: f64, nudge: Option<Nudge>, tele: Arc<super::mixer::Telemetry>) -> Result<Deck, String> {
    let opened_at = std::time::Instant::now();
    let speed = speed.clamp(0.25, 4.0);
    let pitch = 2f64.powf(pitch_semitones.clamp(-24.0, 24.0) / 12.0);
    // Pitch: resample to out_rate/p and play at out_rate (p times faster and
    // higher), then time-stretch by s/p so the tempo comes out at s. Exact
    // ratio (no rounding): pitch shifts use a band-limited sinc resampler,
    // which handles any ratio cleanly (the FFT resampler only suits ratios
    // of "nice" rates and measured -37 dB THD+N on pitch shifts).
    let target = out_rate as f64 / pitch;
    let stretch_ratio = speed / pitch;
    // Locked `.lms` tracks decode in place (unmasked on the fly): no unlocked
    // copy, so a cold start never waits on decrypting the whole file.
    let (mss, hint) = lumisound_media::decode::media_source(Path::new(path)).map_err(|e| e.to_string())?;
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions { enable_gapless: true, ..Default::default() }, &MetadataOptions::default())
        .map_err(|e| format!("unsupported file: {e}"))?;
    let mut fmt = probed.format;
    let track = fmt.default_track().ok_or("no audio track")?.clone();
    let p = &track.codec_params;
    let src_rate = p.sample_rate.ok_or("unknown sample rate")?;
    let duration = match (p.n_frames, p.time_base) {
        (Some(n), Some(tb)) => {
            let t = tb.calc_time(n);
            t.seconds as f64 + t.frac
        }
        (Some(n), None) => n as f64 / src_rate as f64,
        _ => 0.0,
    };
    let mut dec = lumisound_media::opus::codecs().make(p, &DecoderOptions::default()).map_err(|e| e.to_string())?;
    let mut actual_start = 0.0;
    if start > 0.0 {
        if let Ok(s) = fmt.seek(SeekMode::Accurate, SeekTo::Time { time: Time::new(start.trunc() as u64, start.fract()), track_id: Some(track.id) }) {
            actual_start = s.actual_ts as f64 / src_rate as f64;
            if let Some(tb) = p.time_base {
                let t = tb.calc_time(s.actual_ts);
                actual_start = t.seconds as f64 + t.frac;
            }
        }
    }
    let (prod, cons) = rtrb::RingBuffer::<f32>::new(RING_SAMPLES * (out_rate as usize).div_ceil(48_000).max(1));
    let shared = Arc::new(DeckShared { stop: AtomicBool::new(false), eof: AtomicBool::new(false), failed: AtomicBool::new(false), duration_bits: AtomicU64::new(duration.to_bits()) });
    let (seg_prod, segs) = rtrb::RingBuffer::<(u64, f64)>::new(8192);
    let sh = shared.clone();
    let tid = track.id;
    let tempo = Tempo { stretch_ratio, speed, out_rate, nudge };
    std::thread::Builder::new()
        .name("lumisound-deck".into())
        .spawn(move || {
            let mut stats = DecodeStats::default();
            let r = decode_loop(&mut *fmt, &mut *dec, tid, src_rate, target, out_rate, tempo, prod, seg_prod, &sh, &mut stats);
            report_decode(&tele, id, actual_start, duration, src_rate, &stats, r.as_ref().err());
            if r.is_err() {
                sh.failed.store(true, Ordering::Release);
            }
            sh.eof.store(true, Ordering::Release);
        })
        .map_err(|e| e.to_string())?;
    Ok(Deck { id, path: path.to_string(), start_offset: actual_start.max(0.0), frames_played: 0, out_rate, ring: cons, shared, gain, speed, segs, seg_left: 0, seg_step: speed / out_rate as f64, track_secs: 0.0, opened_at, handed_over: false })
}

/// What the decode thread saw, reported when it finishes.
#[derive(Default)]
struct DecodeStats {
    frames: u64,
    /// Time spent in the codec only (not waiting on the ring).
    decode_secs: f64,
    decode_errors: u64,
    read_error: Option<String>,
}

fn report_decode(tele: &super::mixer::Telemetry, deck: u64, start: f64, duration: f64, src_rate: u32, st: &DecodeStats, err: Option<&String>) {
    use super::health::{EngineIncident, IncidentKind, PlaybackPhase, SLOW_DECODE_X, atomic_min_nonzero};
    use std::sync::atomic::Ordering::Relaxed;
    let h = &tele.health;
    let decoded_secs = st.frames as f64 / src_rate.max(1) as f64;
    let reached = start + decoded_secs;
    let inc = |kind, value: f64, message: Option<String>| EngineIncident { kind, phase: PlaybackPhase::Playing, deck_id: deck, position: reached, value, budget_ms: 0.0, message, at: 0.0 };
    if st.decode_errors > 0 {
        h.decode_errors.fetch_add(st.decode_errors, Relaxed);
        h.record(inc(IncidentKind::DecodeErrors, st.decode_errors as f64, None));
    }
    // Speed over a meaningful stretch only (codec time, excluding ring waits).
    if decoded_secs >= 5.0 && st.decode_secs > 0.0 {
        let x = decoded_secs / st.decode_secs;
        atomic_min_nonzero(&h.decode_speed_min_milli, (x * 1000.0) as u64);
        if x < SLOW_DECODE_X {
            h.slow_decodes.fetch_add(1, Relaxed);
            h.record(inc(IncidentKind::SlowDecode, x, None));
        }
    }
    if let Some(e) = err {
        if st.frames == 0 {
            h.deck_failures.fetch_add(1, Relaxed);
            h.record(inc(IncidentKind::DeckFailed, 0.0, Some(e.clone())));
        } else {
            h.decode_stopped_early.fetch_add(1, Relaxed);
            h.record(inc(IncidentKind::DecodeStoppedEarly, (duration - reached).max(0.0), Some(e.clone())));
        }
    } else if duration > 0.0 && reached < duration - 2.0 && st.frames > 0 {
        // Ended (stopped decks report nothing: they exit before EOF) well short of the end.
        if let Some(e) = &st.read_error {
            h.decode_stopped_early.fetch_add(1, Relaxed);
            h.record(inc(IncidentKind::DecodeStoppedEarly, duration - reached, Some(e.clone())));
        }
    }
}

fn push_all(prod: &mut rtrb::Producer<f32>, data: &[f32], sh: &DeckShared) -> bool {
    let mut off = 0;
    while off < data.len() {
        if sh.stop.load(Ordering::Acquire) {
            return false;
        }
        let n = prod.slots().min(data.len() - off);
        if n == 0 {
            std::thread::sleep(std::time::Duration::from_millis(5));
            continue;
        }
        if let Ok(mut chunk) = prod.write_chunk_uninit(n) {
            let (a, b) = chunk.as_mut_slices();
            for (d, s) in a.iter_mut().chain(b.iter_mut()).zip(&data[off..off + n]) {
                d.write(*s);
            }
            unsafe { chunk.commit_all() };
        }
        off += n;
    }
    true
}

struct Tempo {
    stretch_ratio: f64,
    speed: f64,
    out_rate: u32,
    nudge: Option<Nudge>,
}

fn push_seg(segs: &mut rtrb::Producer<(u64, f64)>, frames: usize, step: f64, sh: &DeckShared) -> bool {
    if frames == 0 {
        return true;
    }
    let mut v = (frames as u64, step);
    loop {
        match segs.push(v) {
            Ok(()) => return true,
            Err(rtrb::PushError::Full(back)) => {
                if sh.stop.load(Ordering::Acquire) {
                    return false;
                }
                v = back;
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        }
    }
}

/// The deck's resampler (rubato's trait isn't object-safe).
enum Rs {
    Fft(FftFixedIn<f32>),
    Sinc(SincFixedIn<f32>),
}

impl Rs {
    fn process(&mut self, input: &[&[f32]; 2], active: Option<&[bool]>) -> rubato::ResampleResult<Vec<Vec<f32>>> {
        match self {
            Rs::Fft(r) => r.process(input, active),
            Rs::Sinc(r) => r.process(input, active),
        }
    }
}

/// No resampling when the source already matches; the FFT resampler for a
/// plain rate change (e.g. 44.1 -> 48 kHz: exact, efficient); a 256-tap
/// windowed-sinc resampler for pitch shifts (arbitrary ratio, no rounding).
fn make_resampler(src_rate: u32, target: f64, out_rate: u32) -> Result<Option<Rs>, String> {
    let pitched = (target - out_rate as f64).abs() > 1e-6;
    if !pitched {
        if src_rate == out_rate {
            return Ok(None);
        }
        return FftFixedIn::<f32>::new(src_rate as usize, out_rate as usize, CHUNK, 2, 2).map(|r| Some(Rs::Fft(r))).map_err(|e| e.to_string());
    }
    let params = SincInterpolationParameters { sinc_len: 256, f_cutoff: 0.95, interpolation: SincInterpolationType::Cubic, oversampling_factor: 256, window: WindowFunction::BlackmanHarris2 };
    SincFixedIn::<f32>::new(target / src_rate as f64, 1.0, params, CHUNK, 2).map(|r| Some(Rs::Sinc(r))).map_err(|e| e.to_string())
}

fn decode_loop(
    fmt: &mut dyn symphonia::core::formats::FormatReader,
    dec: &mut dyn symphonia::core::codecs::Decoder,
    track_id: u32,
    src_rate: u32,
    target: f64,
    out_rate: u32,
    tempo: Tempo,
    mut prod: rtrb::Producer<f32>,
    mut segs: rtrb::Producer<(u64, f64)>,
    sh: &DeckShared,
    stats: &mut DecodeStats,
) -> Result<(), String> {
    let mut wsola = super::stretch::Wsola::new(tempo.stretch_ratio * tempo.nudge.map_or(1.0, |n| n.start));
    let mut out_frames: u64 = 0;
    let mut stretched: Vec<f32> = Vec::with_capacity(CHUNK * 8);
    let mut resampler = make_resampler(src_rate, target, out_rate)?;
    let mut pending: [Vec<f32>; 2] = [Vec::with_capacity(CHUNK * 2), Vec::with_capacity(CHUNK * 2)];
    let mut sbuf: Option<SampleBuffer<f32>> = None;
    let mut inter = Vec::with_capacity(CHUNK * 4);
    let mut emit = |data: &[f32], prod: &mut rtrb::Producer<f32>| -> bool {
        let n = tempo.nudge.map_or(1.0, |n| n.at(out_frames));
        wsola.set_ratio(tempo.stretch_ratio * n);
        let step = tempo.speed * n / tempo.out_rate as f64;
        let out: &[f32] = if wsola.can_bypass() {
            data
        } else {
            stretched.clear();
            wsola.process(data, &mut stretched);
            if wsola.is_identity() {
                wsola.drain_identity(&mut stretched);
            }
            &stretched
        };
        out_frames += (out.len() / 2) as u64;
        push_seg(&mut segs, out.len() / 2, step, sh) && push_all(prod, out, sh)
    };
    let mut flush = |pending: &mut [Vec<f32>; 2], rs: &mut Option<Rs>, prod: &mut rtrb::Producer<f32>, inter: &mut Vec<f32>, last: bool| -> bool {
        match rs {
            None => {
                let n = pending[0].len();
                inter.clear();
                for i in 0..n {
                    inter.push(pending[0][i]);
                    inter.push(pending[1][i]);
                }
                pending[0].clear();
                pending[1].clear();
                emit(inter, prod)
            }
            Some(r) => {
                while pending[0].len() >= CHUNK || (last && !pending[0].is_empty()) {
                    if pending[0].len() < CHUNK {
                        pending[0].resize(CHUNK, 0.0);
                        pending[1].resize(CHUNK, 0.0);
                    }
                    let input = [&pending[0][..CHUNK], &pending[1][..CHUNK]];
                    let Ok(out) = r.process(&input, None) else { return false };
                    inter.clear();
                    for i in 0..out[0].len() {
                        inter.push(out[0][i]);
                        inter.push(out[1][i]);
                    }
                    pending[0].drain(..CHUNK);
                    pending[1].drain(..CHUNK);
                    if !emit(inter, prod) {
                        return false;
                    }
                }
                true
            }
        }
    };
    loop {
        if sh.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        let packet = match fmt.next_packet() {
            Ok(p) => p,
            Err(Error::IoError(e)) => {
                // UnexpectedEof is the normal end; anything else is a read error.
                if e.kind() != std::io::ErrorKind::UnexpectedEof {
                    stats.read_error = Some(e.to_string());
                }
                break;
            }
            Err(Error::ResetRequired) => break,
            Err(e) => return Err(e.to_string()),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let t0 = std::time::Instant::now();
        let decoded = match dec.decode(&packet) {
            Ok(d) => d,
            Err(Error::DecodeError(_)) => {
                stats.decode_errors += 1;
                continue;
            }
            Err(e) => return Err(e.to_string()),
        };
        stats.decode_secs += t0.elapsed().as_secs_f64();
        stats.frames += decoded.frames() as u64;
        let spec = *decoded.spec();
        let ch = spec.channels.count().max(1);
        let need = decoded.capacity() * ch;
        if sbuf.as_ref().is_none_or(|b| b.capacity() < need) {
            sbuf = Some(SampleBuffer::new(decoded.capacity() as u64, spec));
        }
        let b = sbuf.as_mut().unwrap();
        b.copy_interleaved_ref(decoded);
        for f in b.samples().chunks(ch) {
            let (l, r) = if ch == 1 { (f[0], f[0]) } else { (f[0], f[1]) };
            pending[0].push(l);
            pending[1].push(r);
        }
        if !flush(&mut pending, &mut resampler, &mut prod, &mut inter, false) {
            return Ok(());
        }
    }
    flush(&mut pending, &mut resampler, &mut prod, &mut inter, true);
    Ok(())
}
