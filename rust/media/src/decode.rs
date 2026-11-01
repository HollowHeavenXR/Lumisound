//! On-device decoding with symphonia (MP3, AAC/ALAC in MP4, FLAC, WAV/AIFF/
//! CAF, Ogg Vorbis). Produces mono PCM at an analysis rate, like the
//! bridge's `ffmpeg -ac 1 -ar <rate> -f s16le`.

use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error;
use symphonia::core::formats::{FormatOptions, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use symphonia::core::units::Time;

pub struct Probe {
    pub duration: f64,
    pub sample_rate: u32,
    pub channels: u16,
}

fn open(path: &Path) -> Option<(Box<dyn symphonia::core::formats::FormatReader>, u32)> {
    let file = std::fs::File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    // `.lms` callers pass the unlocked copy; use the real extension when present.
    if let Some(e) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(e);
    }
    let probed = symphonia::default::get_probe().format(&hint, mss, &FormatOptions { enable_gapless: true, ..Default::default() }, &MetadataOptions::default()).ok()?;
    let fmt = probed.format;
    let track = fmt.default_track()?;
    let id = track.id;
    Some((fmt, id))
}

/// Duration / rate / channels without decoding.
pub fn probe(path: &Path) -> Option<Probe> {
    let (fmt, id) = open(path)?;
    let t = fmt.tracks().iter().find(|t| t.id == id)?;
    let p = &t.codec_params;
    let sr = p.sample_rate?;
    let dur = match (p.n_frames, p.time_base) {
        (Some(n), Some(tb)) => {
            let t = tb.calc_time(n);
            t.seconds as f64 + t.frac
        }
        (Some(n), None) => n as f64 / sr as f64,
        _ => 0.0,
    };
    Some(Probe { duration: dur, sample_rate: sr, channels: p.channels.map(|c| c.count() as u16).unwrap_or(2) })
}

/// Mono i16 PCM at `rate` Hz from `start` seconds for at most `max_len`
/// seconds (whole file when None). Linear-interpolating resampler.
pub fn mono_pcm(path: &Path, rate: u32, start: Option<f64>, max_len: Option<f64>) -> Option<Vec<i16>> {
    let (mut fmt, id) = open(path)?;
    let params = fmt.tracks().iter().find(|t| t.id == id)?.codec_params.clone();
    let src_rate = params.sample_rate? as f64;
    let mut dec = crate::opus::codecs().make(&params, &DecoderOptions::default()).ok()?;
    if let Some(s) = start.filter(|s| *s > 0.0) {
        let _ = fmt.seek(SeekMode::Accurate, SeekTo::Time { time: Time::new(s.trunc() as u64, s.fract()), track_id: Some(id) });
    }
    let want = max_len.map(|l| (l * rate as f64) as usize);
    let step = src_rate / rate as f64;
    let mut out: Vec<i16> = Vec::with_capacity(want.unwrap_or(rate as usize * 60));
    let mut mono: Vec<f32> = Vec::new();
    let mut pos = 0.0f64; // fractional read position into `mono`
    let mut buf: Option<SampleBuffer<f32>> = None;
    loop {
        if want.is_some_and(|w| out.len() >= w) {
            break;
        }
        let packet = match fmt.next_packet() {
            Ok(p) => p,
            Err(Error::IoError(_)) | Err(Error::ResetRequired) => break,
            Err(_) => break,
        };
        if packet.track_id() != id {
            continue;
        }
        let decoded = match dec.decode(&packet) {
            Ok(d) => d,
            Err(Error::DecodeError(_)) => continue,
            Err(_) => break,
        };
        let spec = *decoded.spec();
        let ch = spec.channels.count().max(1);
        let b = buf.get_or_insert_with(|| SampleBuffer::new(decoded.capacity() as u64, spec));
        if b.capacity() < decoded.capacity() * ch {
            *b = SampleBuffer::new(decoded.capacity() as u64, spec);
        }
        b.copy_interleaved_ref(decoded);
        for frame in b.samples().chunks(ch) {
            mono.push(frame.iter().sum::<f32>() / ch as f32);
        }
        // Resample everything we can from `mono`, keep the remainder.
        while pos + 1.0 < mono.len() as f64 {
            let i = pos as usize;
            let f = (pos - i as f64) as f32;
            let v = mono[i] * (1.0 - f) + mono[i + 1] * f;
            out.push((v.clamp(-1.0, 1.0) * 32767.0) as i16);
            pos += step;
            if want.is_some_and(|w| out.len() >= w) {
                break;
            }
        }
        let used = (pos as usize).min(mono.len());
        mono.drain(..used);
        pos -= used as f64;
    }
    if let Some(w) = want {
        out.truncate(w);
    }
    (!out.is_empty()).then_some(out)
}

/// Native-rate float PCM, de-interleaved per channel (max 2 used), from
/// `start` for up to `max_len` seconds. Returns (rate, channels).
pub fn planar(path: &Path, start: Option<f64>, max_len: Option<f64>) -> Option<(u32, Vec<Vec<f32>>)> {
    let (mut fmt, id) = open(path)?;
    let params = fmt.tracks().iter().find(|t| t.id == id)?.codec_params.clone();
    let rate = params.sample_rate?;
    let mut dec = crate::opus::codecs().make(&params, &DecoderOptions::default()).ok()?;
    if let Some(s) = start.filter(|s| *s > 0.0) {
        let _ = fmt.seek(SeekMode::Accurate, SeekTo::Time { time: Time::new(s.trunc() as u64, s.fract()), track_id: Some(id) });
    }
    let want = max_len.map(|l| (l * rate as f64) as usize);
    let mut chans: Vec<Vec<f32>> = Vec::new();
    let mut buf: Option<SampleBuffer<f32>> = None;
    loop {
        if want.is_some_and(|w| chans.first().is_some_and(|c| c.len() >= w)) {
            break;
        }
        let packet = match fmt.next_packet() {
            Ok(p) => p,
            Err(_) => break,
        };
        if packet.track_id() != id {
            continue;
        }
        let decoded = match dec.decode(&packet) {
            Ok(d) => d,
            Err(Error::DecodeError(_)) => continue,
            Err(_) => break,
        };
        let spec = *decoded.spec();
        let ch = spec.channels.count().max(1);
        if chans.is_empty() {
            chans = vec![Vec::new(); ch.min(2)];
        }
        let b = buf.get_or_insert_with(|| SampleBuffer::new(decoded.capacity() as u64, spec));
        if b.capacity() < decoded.capacity() * ch {
            *b = SampleBuffer::new(decoded.capacity() as u64, spec);
        }
        b.copy_interleaved_ref(decoded);
        for f in b.samples().chunks(ch) {
            for (c, v) in chans.iter_mut().zip(f) {
                c.push(*v);
            }
        }
    }
    if let Some(w) = want {
        chans.iter_mut().for_each(|c| c.truncate(w));
    }
    (!chans.is_empty() && !chans[0].is_empty()).then_some((rate, chans))
}
