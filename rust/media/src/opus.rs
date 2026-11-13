//! Opus for symphonia via the pure-Rust `opus-decoder` (RFC 8251
//! conformant): Ogg-Opus (.opus/.ogg) and WebM/Matroska-Opus decode in the
//! same pipeline as every other format. Output is 48 kHz; the stream's
//! pre-skip is dropped here.

use std::sync::LazyLock;
use symphonia::core::audio::{AsAudioBufferRef, AudioBuffer, AudioBufferRef, Channels, Signal, SignalSpec};
use symphonia::core::codecs::{CODEC_TYPE_OPUS, CodecDescriptor, CodecParameters, CodecRegistry, Decoder, DecoderOptions, FinalizeResult};
use symphonia::core::errors::{Error, Result, decode_error, unsupported_error};
use symphonia::core::formats::Packet;
use symphonia::core::support_codec;

/// Registry with symphonia's codecs plus Opus.
pub fn codecs() -> &'static CodecRegistry {
    static R: LazyLock<CodecRegistry> = LazyLock::new(|| {
        let mut r = CodecRegistry::new();
        symphonia::default::register_enabled_codecs(&mut r);
        r.register_all::<OpusDecoder>();
        // After the defaults so it replaces symphonia's ALAC entry.
        r.register_all::<crate::alac::AlacDecoder>();
        r.register_all::<crate::aac::AacDecoder>();
        r
    });
    &R
}

pub struct OpusDecoder {
    inner: opus_decoder::OpusDecoder,
    params: CodecParameters,
    channels: usize,
    buf: AudioBuffer<f32>,
    pcm: Vec<f32>,
    skip: usize,
    pre_skip: usize,
}

fn pre_skip(params: &CodecParameters) -> usize {
    if let Some(d) = params.delay {
        return d as usize;
    }
    match params.extra_data.as_deref() {
        Some(h) if h.len() >= 12 && &h[..8] == b"OpusHead" => u16::from_le_bytes([h[10], h[11]]) as usize,
        _ => 0,
    }
}

impl Decoder for OpusDecoder {
    fn try_new(params: &CodecParameters, _opts: &DecoderOptions) -> Result<Self> {
        let channels = params
            .channels
            .map(|c| c.count())
            .or_else(|| params.extra_data.as_deref().filter(|h| h.len() > 9 && &h[..8] == b"OpusHead").map(|h| h[9] as usize))
            .unwrap_or(2);
        if channels == 0 || channels > 2 {
            return unsupported_error("opus: only mono/stereo streams are supported");
        }
        let inner = opus_decoder::OpusDecoder::new(48_000, channels).map_err(|_| Error::Unsupported("opus decoder init failed"))?;
        let layout = if channels == 1 { Channels::FRONT_LEFT } else { Channels::FRONT_LEFT | Channels::FRONT_RIGHT };
        let skip = pre_skip(params);
        Ok(Self {
            inner,
            params: params.clone(),
            channels,
            buf: AudioBuffer::new(5760, SignalSpec::new(48_000, layout)),
            pcm: vec![0.0; 5760 * channels],
            skip,
            pre_skip: skip,
        })
    }

    fn supported_codecs() -> &'static [CodecDescriptor] {
        &[support_codec!(CODEC_TYPE_OPUS, "opus", "Opus")]
    }

    fn reset(&mut self) {
        self.inner.reset();
        self.skip = self.pre_skip;
    }

    fn codec_params(&self) -> &CodecParameters {
        &self.params
    }

    fn decode(&mut self, packet: &Packet) -> Result<AudioBufferRef<'_>> {
        let n = match self.inner.decode_float(packet.buf(), &mut self.pcm, false) {
            Ok(n) => n,
            Err(_) => return decode_error("opus: invalid packet"),
        };
        let drop = self.skip.min(n);
        self.skip -= drop;
        // End trim from the container (Ogg's final granule position): the
        // encoder pads the last frame, which played as a short silence.
        // (Its start trim is the pre-skip, already dropped above.)
        let keep = (n - drop).saturating_sub(packet.trim_end() as usize);
        self.buf.clear();
        self.buf.render_reserved(Some(keep));
        for ch in 0..self.channels {
            let plane = self.buf.chan_mut(ch);
            for (i, s) in plane.iter_mut().enumerate() {
                *s = self.pcm[(drop + i) * self.channels + ch];
            }
        }
        Ok(self.buf.as_audio_buffer_ref())
    }

    fn finalize(&mut self) -> FinalizeResult {
        FinalizeResult::default()
    }

    fn last_decoded(&self) -> AudioBufferRef<'_> {
        self.buf.as_audio_buffer_ref()
    }
}
