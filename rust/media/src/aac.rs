//! AAC beyond what symphonia decodes. symphonia's decoder is AAC-LC only,
//! mono/stereo, 1024-sample frames; it refuses HE-AAC v1/v2 (SBR / PS),
//! 5.1 / 7.1 AAC and 960-sample frames, and plays implicitly signalled
//! HE-AAC as its half-rate LC core (muffled, no top octave). Those streams
//! go to `syom` (pure-Rust AAC: LC, HE v1/v2, LD, up to 7.1); plain LC
//! stereo stays on symphonia's decoder. Multichannel is folded to stereo
//! by channel label, since AAC's native order starts with the centre.

use symphonia::core::audio::{AsAudioBufferRef, AudioBuffer, AudioBufferRef, Channels, Signal, SignalSpec};
use symphonia::core::codecs::{CODEC_TYPE_AAC, CodecDescriptor, CodecParameters, Decoder, DecoderOptions, FinalizeResult};
use symphonia::core::errors::{Result, decode_error, unsupported_error};
use symphonia::core::formats::Packet;
use symphonia::core::support_codec;
use symphonia::default::codecs::AacDecoder as Native;

const RATES: [u32; 13] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

/// The parts of an AudioSpecificConfig that pick the decoder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Asc {
    /// Audio object type of the core (2 = LC).
    pub core_type: u8,
    pub core_rate: u32,
    /// channel_configuration (0 = defined by a PCE).
    pub channels: u8,
    /// SBR signalled explicitly (AOT 5 / 29).
    pub sbr: bool,
    /// Parametric stereo signalled explicitly (AOT 29).
    pub ps: bool,
    /// Output rate when SBR is signalled.
    pub sbr_rate: Option<u32>,
    pub frame_960: bool,
}

struct Bits<'a> {
    d: &'a [u8],
    pos: usize,
}

impl Bits<'_> {
    fn read(&mut self, n: usize) -> Option<u32> {
        let mut v = 0u32;
        for _ in 0..n {
            let byte = *self.d.get(self.pos / 8)?;
            v = (v << 1) | ((byte >> (7 - self.pos % 8)) & 1) as u32;
            self.pos += 1;
        }
        Some(v)
    }
    fn aot(&mut self) -> Option<u8> {
        let t = self.read(5)?;
        Some(if t == 31 { 32 + self.read(6)? } else { t } as u8)
    }
    fn rate(&mut self) -> Option<u32> {
        let i = self.read(4)?;
        if i == 15 { self.read(24) } else { RATES.get(i as usize).copied() }
    }
}

pub fn parse_asc(d: &[u8]) -> Option<Asc> {
    let mut b = Bits { d, pos: 0 };
    let mut aot = b.aot()?;
    let core_rate = b.rate()?;
    let channels = b.read(4)? as u8;
    let (mut sbr, mut ps, mut sbr_rate) = (false, false, None);
    if aot == 5 || aot == 29 {
        sbr = true;
        ps = aot == 29;
        sbr_rate = Some(b.rate()?);
        aot = b.aot()?;
    }
    // GASpecificConfig starts with frameLengthFlag for the GA object types.
    let frame_960 = matches!(aot, 1..=4 | 6 | 7 | 17 | 19..=23) && b.read(1)? == 1;
    Some(Asc { core_type: aot, core_rate, channels, sbr, ps, sbr_rate, frame_960 })
}

impl Asc {
    /// Whether symphonia's LC decoder can't play this as intended.
    /// `container_rate` is the track's rate: twice the core rate means
    /// implicitly signalled SBR (HE-AAC whose ASC only describes the core).
    pub fn needs_full_decoder(&self, container_rate: Option<u32>) -> bool {
        self.core_type != 2 || self.sbr || self.channels == 0 || self.channels > 2 || self.frame_960 || container_rate.is_some_and(|r| r == self.core_rate * 2)
    }

    /// The rate the decoder outputs.
    pub fn output_rate(&self, container_rate: Option<u32>) -> u32 {
        if let Some(r) = self.sbr_rate {
            return r;
        }
        match container_rate {
            Some(r) if r == self.core_rate * 2 => r,
            _ => self.core_rate,
        }
    }
}

pub enum AacDecoder {
    Native(Box<Native>),
    Full(Box<Full>),
}

pub struct Full {
    dec: syom::Decoder,
    asc: Box<[u8]>,
    params: CodecParameters,
    buf: AudioBuffer<f32>,
    left: Vec<f32>,
    right: Vec<f32>,
    stereo: bool,
}

/// Stereo fold-down weights (ITU-R BS.775): (left, right) per channel label.
fn weights(c: Option<syom::Channel>) -> (f32, f32) {
    use syom::Channel::*;
    const H: f32 = std::f32::consts::FRAC_1_SQRT_2;
    match c {
        Some(FrontLeft) => (1.0, 0.0),
        Some(FrontRight) => (0.0, 1.0),
        Some(FrontCenter) | Some(BackCenter) => (H, H),
        Some(BackLeft) | Some(SideLeft) => (H, 0.0),
        Some(BackRight) | Some(SideRight) => (0.0, H),
        Some(Lfe) => (0.0, 0.0),
        _ => (H, H),
    }
}

impl Full {
    fn new(params: &CodecParameters, asc_bytes: &[u8], asc: Asc) -> Result<Self> {
        let dec = match syom::Decoder::from_asc(asc_bytes, syom::DecodeOptions::unbounded()) {
            Ok(d) => d,
            Err(e) => return unsupported_error(leak(format!("aac: {e}"))),
        };
        let rate = asc.output_rate(params.sample_rate);
        // Always stereo: parametric stereo is often signalled only inside
        // the stream (a mono-core ASC that decodes to two channels), and a
        // plain mono stream simply plays in both ears.
        let stereo = true;
        let layout = if stereo { Channels::FRONT_LEFT | Channels::FRONT_RIGHT } else { Channels::FRONT_LEFT };
        let mut p = params.clone();
        p.with_sample_rate(rate).with_channels(layout);
        Ok(Full { dec, asc: asc_bytes.into(), params: p, buf: AudioBuffer::new(4096, SignalSpec::new(rate, layout)), left: Vec::with_capacity(4096), right: Vec::with_capacity(4096), stereo })
    }

    fn decode(&mut self, packet: &Packet) -> Result<AudioBufferRef<'_>> {
        self.left.clear();
        self.right.clear();
        let (left, right) = (&mut self.left, &mut self.right);
        let r = self.dec.decode_au(packet.buf(), |f| {
            let planes = f.planar;
            if planes.len() <= 2 {
                left.extend_from_slice(&planes[0][..f.samples]);
                right.extend_from_slice(&planes.get(1).unwrap_or(&planes[0])[..f.samples]);
            } else {
                // Fold surround to stereo, normalised so a full-scale mix can't clip.
                let w: Vec<(f32, f32)> = (0..planes.len()).map(|i| weights(f.meta.channels.get(i).copied().flatten())).collect();
                let (nl, nr) = w.iter().fold((0.0, 0.0), |a, x| (a.0 + x.0, a.1 + x.1));
                let (gl, gr) = (1.0 / nl.max(1.0), 1.0 / nr.max(1.0));
                for s in 0..f.samples {
                    let (mut l, mut r) = (0.0f32, 0.0f32);
                    for (p, (wl, wr)) in planes.iter().zip(&w) {
                        l += p[s] * wl;
                        r += p[s] * wr;
                    }
                    left.push(l * gl);
                    right.push(r * gr);
                }
            }
            Ok(())
        });
        if let Err(e) = r {
            if self.dec.is_failed() {
                self.reset();
            }
            return decode_error(leak(format!("aac: {e}")));
        }
        let n = self.left.len();
        if self.buf.capacity() < n {
            self.buf = AudioBuffer::new(n as u64, *self.buf.spec());
        }
        self.buf.clear();
        self.buf.render_reserved(Some(n));
        if self.stereo {
            self.buf.chan_mut(0).copy_from_slice(&self.left);
            self.buf.chan_mut(1).copy_from_slice(&self.right);
        } else {
            for (o, (l, r)) in self.buf.chan_mut(0).iter_mut().zip(self.left.iter().zip(&self.right)) {
                *o = (l + r) * 0.5;
            }
        }
        Ok(self.buf.as_audio_buffer_ref())
    }

    fn reset(&mut self) {
        self.dec.reset();
        let _ = self.dec.set_asc(&self.asc);
    }
}

/// symphonia's error constructors take `&'static str`; decode errors are
/// rare and the set of messages small, so leak them once each.
fn leak(s: String) -> &'static str {
    use std::collections::HashMap;
    use std::sync::{LazyLock, Mutex};
    static SEEN: LazyLock<Mutex<HashMap<String, &'static str>>> = LazyLock::new(Default::default);
    let mut m = SEEN.lock().unwrap_or_else(|e| e.into_inner());
    if m.len() > 64 {
        return "aac: decode error";
    }
    m.entry(s.clone()).or_insert_with(|| Box::leak(s.into_boxed_str()))
}

impl Decoder for AacDecoder {
    fn try_new(params: &CodecParameters, opts: &DecoderOptions) -> Result<Self> {
        let asc_bytes = params.extra_data.as_deref();
        let asc = asc_bytes.and_then(parse_asc);
        if let (Some(bytes), Some(asc)) = (asc_bytes, asc) {
            if asc.needs_full_decoder(params.sample_rate) {
                return Full::new(params, bytes, asc).map(|f| AacDecoder::Full(Box::new(f)));
            }
        }
        match Native::try_new(params, opts) {
            Ok(n) => Ok(AacDecoder::Native(Box::new(n))),
            Err(e) => match (asc_bytes, asc) {
                (Some(bytes), Some(asc)) => Full::new(params, bytes, asc).map(|f| AacDecoder::Full(Box::new(f))),
                _ => Err(e),
            },
        }
    }

    fn supported_codecs() -> &'static [CodecDescriptor] {
        &[support_codec!(CODEC_TYPE_AAC, "aac", "Advanced Audio Coding (LC, HE v1/v2, multichannel)")]
    }

    fn reset(&mut self) {
        match self {
            AacDecoder::Native(n) => n.reset(),
            AacDecoder::Full(f) => f.reset(),
        }
    }

    fn codec_params(&self) -> &CodecParameters {
        match self {
            AacDecoder::Native(n) => n.codec_params(),
            AacDecoder::Full(f) => &f.params,
        }
    }

    fn decode(&mut self, packet: &Packet) -> Result<AudioBufferRef<'_>> {
        match self {
            AacDecoder::Native(n) => n.decode(packet),
            AacDecoder::Full(f) => f.decode(packet),
        }
    }

    fn finalize(&mut self) -> FinalizeResult {
        FinalizeResult::default()
    }

    fn last_decoded(&self) -> AudioBufferRef<'_> {
        match self {
            AacDecoder::Native(n) => n.last_decoded(),
            AacDecoder::Full(f) => f.buf.as_audio_buffer_ref(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_audio_specific_configs() {
        // LC 44.1 kHz stereo.
        let lc = parse_asc(&[0x12, 0x10]).unwrap();
        assert_eq!((lc.core_type, lc.core_rate, lc.channels, lc.sbr), (2, 44100, 2, false));
        assert!(!lc.needs_full_decoder(Some(44100)));
        // Same ASC in a 44.1 kHz track whose core is 22.05: implicit SBR.
        let core = parse_asc(&[0x13, 0x90]).unwrap();
        assert_eq!(core.core_rate, 22050);
        assert!(core.needs_full_decoder(Some(44100)));
        assert_eq!(core.output_rate(Some(44100)), 44100);
        // Explicit HE-AAC v1: AOT 5, 22.05 core, stereo, ext 44.1, then LC.
        let he = parse_asc(&[0x2B, 0x92, 0x08, 0x00]).unwrap();
        assert!(he.sbr && !he.ps);
        assert_eq!((he.core_type, he.core_rate, he.sbr_rate), (2, 22050, Some(44100)));
        // 5.1 LC.
        let six = parse_asc(&[0x11, 0xB0]).unwrap();
        assert_eq!(six.channels, 6);
        assert!(six.needs_full_decoder(Some(48000)));
    }
}
