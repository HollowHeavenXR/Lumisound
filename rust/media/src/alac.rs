//! ALAC with every magic-cookie layout. symphonia's decoder only takes the
//! bare 24-byte ALACSpecificConfig (optionally + a 24-byte `chan` atom), but
//! CAF files from Apple's tools and ffmpeg wrap it the legacy way:
//! `frma` atom + `alac` atom (size, "alac", version/flags, config). That
//! 48-byte cookie was misread as config + channel layout and refused, so
//! ALAC-in-CAF never played. This unwraps the cookie and hands the rest to
//! symphonia's decoder.

use symphonia::core::audio::AudioBufferRef;
use symphonia::core::codecs::{CODEC_TYPE_ALAC, CodecDescriptor, CodecParameters, Decoder, DecoderOptions, FinalizeResult};
use symphonia::core::errors::Result;
use symphonia::core::formats::Packet;
use symphonia::core::support_codec;
use symphonia::default::codecs::AlacDecoder as Inner;

pub struct AlacDecoder {
    inner: Inner,
}

/// The ALACSpecificConfig (+ `chan` atom when present) out of any cookie.
pub fn normalize_cookie(data: &[u8]) -> Option<Vec<u8>> {
    const CONFIG: usize = 24;
    let at = |i: usize| data.get(i..i + 4);
    // Find an atom whose type is "alac": [size u32][b"alac"][ver/flags u32][config…].
    let mut i = 0;
    while i + 8 <= data.len() {
        let size = u32::from_be_bytes(data[i..i + 4].try_into().ok()?) as usize;
        if at(i + 4) == Some(b"alac") && size >= 12 + CONFIG {
            let mut out = data.get(i + 12..i + 12 + CONFIG)?.to_vec();
            // A following `chan` atom (24 bytes) keeps the channel layout.
            let next = i + size;
            if at(next + 4) == Some(b"chan") && data.len() >= next + 24 {
                out.extend_from_slice(&data[next..next + 24]);
            }
            return Some(out);
        }
        if size < 8 {
            break;
        }
        i += size;
    }
    None
}

impl Decoder for AlacDecoder {
    fn try_new(params: &CodecParameters, opts: &DecoderOptions) -> Result<Self> {
        let unwrapped = params.extra_data.as_deref().and_then(normalize_cookie);
        let inner = match unwrapped {
            Some(cookie) => {
                let mut p = params.clone();
                p.with_extra_data(cookie.into_boxed_slice());
                Inner::try_new(&p, opts)?
            }
            None => Inner::try_new(params, opts)?,
        };
        Ok(AlacDecoder { inner })
    }

    fn supported_codecs() -> &'static [CodecDescriptor] {
        &[support_codec!(CODEC_TYPE_ALAC, "alac", "Apple Lossless Audio Codec")]
    }

    fn reset(&mut self) {
        self.inner.reset()
    }

    fn codec_params(&self) -> &CodecParameters {
        self.inner.codec_params()
    }

    fn decode(&mut self, packet: &Packet) -> Result<AudioBufferRef<'_>> {
        self.inner.decode(packet)
    }

    fn finalize(&mut self) -> FinalizeResult {
        self.inner.finalize()
    }

    fn last_decoded(&self) -> AudioBufferRef<'_> {
        self.inner.last_decoded()
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_cookie;

    #[test]
    fn unwraps_caf_cookie() {
        // ffmpeg's CAF kuki: frma atom + alac atom (36 bytes).
        let hex = "0000000c66726d61616c616300000024616c616300000000000010000010280a0e02000000004004001588800000ac44";
        let raw: Vec<u8> = (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap()).collect();
        let c = normalize_cookie(&raw).unwrap();
        assert_eq!(c.len(), 24);
        assert_eq!(&c[..4], &4096u32.to_be_bytes());
        assert_eq!(c[5], 16); // bit depth
        assert_eq!(c[9], 2); // channels
        // A bare config isn't an atom list: left alone.
        assert!(normalize_cookie(&c).is_none());
    }
}
