//! A deck: one track being decoded on its own thread into a lock-free ring
//! buffer of interleaved stereo f32 at the output rate. The mixer (audio
//! callback) only ever pops from the ring.

use rubato::{FftFixedIn, Resampler};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error;
use symphonia::core::formats::{FormatOptions, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
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
    /// Playback speed (track seconds per output second).
    pub speed: f64,
}

impl Deck {
    pub fn position(&self) -> f64 {
        self.start_offset + self.frames_played as f64 / self.out_rate as f64 * self.speed
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
pub fn open(id: u64, path: &str, start: f64, out_rate: u32, gain: f32, speed: f64, pitch_semitones: f64) -> Result<Deck, String> {
    let speed = speed.clamp(0.25, 4.0);
    let pitch = 2f64.powf(pitch_semitones.clamp(-24.0, 24.0) / 12.0);
    // Pitch: resample to out_rate·p and play at out_rate. Tempo: WSOLA by s/p.
    let target_rate = ((out_rate as f64) * pitch).round() as u32;
    let stretch_ratio = speed / pitch;
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(e) = Path::new(path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(e);
    }
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
    let mut dec = symphonia::default::get_codecs().make(p, &DecoderOptions::default()).map_err(|e| e.to_string())?;
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
    let sh = shared.clone();
    let tid = track.id;
    std::thread::Builder::new()
        .name("lumisound-deck".into())
        .spawn(move || {
            let r = decode_loop(&mut *fmt, &mut *dec, tid, src_rate, target_rate, stretch_ratio, prod, &sh);
            if r.is_err() {
                sh.failed.store(true, Ordering::Release);
            }
            sh.eof.store(true, Ordering::Release);
        })
        .map_err(|e| e.to_string())?;
    Ok(Deck { id, path: path.to_string(), start_offset: actual_start.max(0.0), frames_played: 0, out_rate, ring: cons, shared, gain, speed })
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

fn decode_loop(
    fmt: &mut dyn symphonia::core::formats::FormatReader,
    dec: &mut dyn symphonia::core::codecs::Decoder,
    track_id: u32,
    src_rate: u32,
    out_rate: u32,
    stretch_ratio: f64,
    mut prod: rtrb::Producer<f32>,
    sh: &DeckShared,
) -> Result<(), String> {
    let mut wsola = super::stretch::Wsola::new(stretch_ratio);
    let mut stretched: Vec<f32> = Vec::with_capacity(CHUNK * 8);
    let mut resampler = if src_rate != out_rate { Some(FftFixedIn::<f32>::new(src_rate as usize, out_rate as usize, CHUNK, 2, 2).map_err(|e| e.to_string())?) } else { None };
    let mut pending: [Vec<f32>; 2] = [Vec::with_capacity(CHUNK * 2), Vec::with_capacity(CHUNK * 2)];
    let mut sbuf: Option<SampleBuffer<f32>> = None;
    let mut inter = Vec::with_capacity(CHUNK * 4);
    let mut emit = |data: &[f32], prod: &mut rtrb::Producer<f32>| -> bool {
        if wsola.is_identity() {
            return push_all(prod, data, sh);
        }
        stretched.clear();
        wsola.process(data, &mut stretched);
        push_all(prod, &stretched, sh)
    };
    let mut flush = |pending: &mut [Vec<f32>; 2], rs: &mut Option<FftFixedIn<f32>>, prod: &mut rtrb::Producer<f32>, inter: &mut Vec<f32>, last: bool| -> bool {
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
            Err(Error::IoError(_)) => break,
            Err(Error::ResetRequired) => break,
            Err(e) => return Err(e.to_string()),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match dec.decode(&packet) {
            Ok(d) => d,
            Err(Error::DecodeError(_)) => continue,
            Err(e) => return Err(e.to_string()),
        };
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
