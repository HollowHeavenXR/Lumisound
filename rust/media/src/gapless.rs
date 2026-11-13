//! Gapless trimming for formats symphonia hands over untrimmed.
//!
//! AAC in MP4/M4A starts with encoder priming (usually 1024 frames, ~23 ms)
//! and ends with padding up to a whole 1024-frame packet. The container says
//! how much (an `iTunSMPB` tag from Apple encoders, otherwise the track's edit
//! list), but symphonia's MP4 reader ignores both, so every AAC track played
//! ~23 ms of silence first and up to ~23 ms after: a small gap between
//! tracks on a gapless album. `Gapless` reads the valid range from the
//! container; `Trim` cuts decoded buffers to it.

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// The playable part of a track, in source frames from timestamp 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Gapless {
    /// Frames of priming before the music.
    pub delay: u64,
    /// Frames of music after the priming, when known.
    pub frames: Option<u64>,
}

impl Gapless {
    /// A trimmer for decoding that starts at source frame `from` (0, or the
    /// timestamp a seek landed on).
    pub fn trim_from(&self, from: u64) -> Trim {
        let skip = self.delay.saturating_sub(from);
        let left = self.frames.map(|f| (self.delay + f).saturating_sub(from.max(self.delay)));
        Trim { skip, left }
    }

    /// Source frame for a music position in seconds (seek target).
    pub fn source_frame(&self, secs: f64, rate: u32) -> u64 {
        self.delay + (secs.max(0.0) * rate as f64) as u64
    }

    /// Music position in seconds for a source frame.
    pub fn music_secs(&self, frame: u64, rate: u32) -> f64 {
        frame.saturating_sub(self.delay) as f64 / rate.max(1) as f64
    }

    pub fn duration(&self, rate: u32) -> Option<f64> {
        self.frames.map(|f| f as f64 / rate.max(1) as f64)
    }
}

/// Cuts decoded audio to the playable range, buffer by buffer.
#[derive(Debug, Clone, Copy, Default)]
pub struct Trim {
    skip: u64,
    left: Option<u64>,
}

impl Trim {
    /// The frame range of a decoded buffer of `n` frames to keep.
    pub fn keep(&mut self, n: usize) -> std::ops::Range<usize> {
        let s = (self.skip.min(n as u64)) as usize;
        self.skip -= s as u64;
        let mut e = n;
        if let Some(left) = self.left.as_mut() {
            let take = ((e - s) as u64).min(*left) as usize;
            *left -= take as u64;
            e = s + take;
        }
        s..e
    }

    /// Everything playable has been emitted.
    pub fn done(&self) -> bool {
        self.left == Some(0)
    }
}

/// The gapless range for `path` (plain or locked `.lms`) when the codec
/// needs one. MP3 is trimmed by symphonia's own decoder (LAME/Xing header)
/// and Opus pre-skip by ours, so only AAC in an MP4 family container
/// is handled here.
pub fn for_track(path: &Path, codec: symphonia::core::codecs::CodecType) -> Option<Gapless> {
    use symphonia::core::codecs::{CODEC_TYPE_AAC, CODEC_TYPE_ADPCM_IMA_WAV, CODEC_TYPE_ADPCM_MS};
    let read: fn(&mut dyn ReadSeek) -> Option<Gapless> = match codec {
        CODEC_TYPE_AAC => |r| mp4(r),
        // ADPCM pads its last block; the WAV `fact` chunk has the true length.
        CODEC_TYPE_ADPCM_IMA_WAV | CODEC_TYPE_ADPCM_MS => |r| wav_fact(r),
        _ => return None,
    };
    if let Some(mut m) = crate::lock::MaskedFile::open(path) {
        return read(&mut m);
    }
    read(&mut std::fs::File::open(path).ok()?)
}

pub trait ReadSeek: Read + Seek {}
impl<T: Read + Seek> ReadSeek for T {}

/// RIFF/WAVE `fact` chunk: the real sample-frame count of a compressed WAV.
pub fn wav_fact<R: Read + Seek + ?Sized>(r: &mut R) -> Option<Gapless> {
    r.seek(SeekFrom::Start(0)).ok()?;
    let mut h = [0u8; 12];
    r.read_exact(&mut h).ok()?;
    if &h[..4] != b"RIFF" || &h[8..12] != b"WAVE" {
        return None;
    }
    let mut pos = 12u64;
    for _ in 0..64 {
        let mut c = [0u8; 8];
        r.read_exact(&mut c).ok()?;
        let size = u32::from_le_bytes(c[4..8].try_into().ok()?) as u64;
        if &c[..4] == b"fact" && size >= 4 {
            let mut n = [0u8; 4];
            r.read_exact(&mut n).ok()?;
            let frames = u32::from_le_bytes(n) as u64;
            return (frames > 0).then_some(Gapless { delay: 0, frames: Some(frames) });
        }
        if &c[..4] == b"data" {
            return None; // `fact` comes before the audio when present
        }
        pos += 8 + size + (size & 1);
        r.seek(SeekFrom::Start(pos)).ok()?;
    }
    None
}

/// Reads `moov` and returns the audio track's gapless range: `iTunSMPB`
/// first (exact, what Apple's players use), else the edit list.
pub fn mp4<R: Read + Seek + ?Sized>(r: &mut R) -> Option<Gapless> {
    let moov = find_top(r, b"moov")?;
    if let Some(g) = itunsmpb(&moov) {
        return Some(g);
    }
    edit_list(&moov)
}

/// The body of the first top-level atom of `kind` (capped at 64 MB).
fn find_top<R: Read + Seek + ?Sized>(r: &mut R, kind: &[u8; 4]) -> Option<Vec<u8>> {
    r.seek(SeekFrom::Start(0)).ok()?;
    let mut pos = 0u64;
    loop {
        let mut h = [0u8; 8];
        r.read_exact(&mut h).ok()?;
        let mut size = u32::from_be_bytes(h[..4].try_into().ok()?) as u64;
        let mut header = 8u64;
        if size == 1 {
            let mut big = [0u8; 8];
            r.read_exact(&mut big).ok()?;
            size = u64::from_be_bytes(big);
            header = 16;
        }
        if &h[4..8] == kind {
            let body = size.checked_sub(header)?;
            if body > 64 << 20 {
                return None;
            }
            let mut buf = vec![0u8; body as usize];
            r.read_exact(&mut buf).ok()?;
            return Some(buf);
        }
        if size < header {
            return None; // size 0 (to end of file) or corrupt
        }
        pos += size;
        r.seek(SeekFrom::Start(pos)).ok()?;
    }
}

/// Child atoms of `body`: (type, body).
fn children(body: &[u8]) -> impl Iterator<Item = (&[u8], &[u8])> {
    let mut i = 0usize;
    std::iter::from_fn(move || {
        if i + 8 > body.len() {
            return None;
        }
        let size = u32::from_be_bytes(body[i..i + 4].try_into().ok()?) as usize;
        let (header, size) = if size == 1 {
            let big = u64::from_be_bytes(body.get(i + 8..i + 16)?.try_into().ok()?) as usize;
            (16, big)
        } else {
            (8, size)
        };
        if size < header || i + size > body.len() {
            return None;
        }
        let item = (&body[i + 4..i + 8], &body[i + header..i + size]);
        i += size;
        Some(item)
    })
}

fn child<'a>(body: &'a [u8], kind: &[u8]) -> Option<&'a [u8]> {
    children(body).find(|(k, _)| *k == kind).map(|(_, b)| b)
}

fn be32(b: &[u8], at: usize) -> Option<u64> {
    Some(u32::from_be_bytes(b.get(at..at + 4)?.try_into().ok()?) as u64)
}

fn be64(b: &[u8], at: usize) -> Option<u64> {
    Some(u64::from_be_bytes(b.get(at..at + 8)?.try_into().ok()?))
}

/// `----` freeform atom named iTunSMPB in moov/udta/meta/ilst:
/// " 00000000 00000840 0000037C 00000000000F6C76 …" (hex: _, delay, padding, frames).
fn itunsmpb(moov: &[u8]) -> Option<Gapless> {
    let udta = child(moov, b"udta")?;
    let meta = child(udta, b"meta")?;
    // `meta` is a full box (4 bytes version/flags) in MP4; QuickTime omits it.
    let ilst = child(meta.get(4..)?, b"ilst").or_else(|| child(meta, b"ilst"))?;
    for (k, item) in children(ilst) {
        if k != b"----" {
            continue;
        }
        let name = child(item, b"name").and_then(|n| n.get(4..));
        if name != Some(b"iTunSMPB".as_slice()) {
            continue;
        }
        let text = std::str::from_utf8(child(item, b"data")?.get(8..)?).ok()?;
        let f: Vec<u64> = text.split_whitespace().filter_map(|h| u64::from_str_radix(h, 16).ok()).collect();
        let (delay, frames) = (*f.get(1)?, *f.get(3)?);
        if frames == 0 {
            return None;
        }
        return Some(Gapless { delay, frames: Some(frames) });
    }
    None
}

/// The sound track's edit list: its first non-empty edit gives the priming
/// (media_time, media timescale) and the length (segment duration, movie
/// timescale).
fn edit_list(moov: &[u8]) -> Option<Gapless> {
    let mvhd = child(moov, b"mvhd")?;
    let movie_ts = if mvhd[0] == 1 { be32(mvhd, 20)? } else { be32(mvhd, 12)? };
    for (k, trak) in children(moov) {
        if k != b"trak" {
            continue;
        }
        let Some(mdia) = child(trak, b"mdia") else { continue };
        let is_sound = child(mdia, b"hdlr").and_then(|h| h.get(8..12)) == Some(b"soun".as_slice());
        if !is_sound {
            continue;
        }
        let mdhd = child(mdia, b"mdhd")?;
        let media_ts = if mdhd[0] == 1 { be32(mdhd, 20)? } else { be32(mdhd, 12)? };
        let elst = child(child(trak, b"edts")?, b"elst")?;
        let v1 = elst[0] == 1;
        let count = be32(elst, 4)? as usize;
        let entry = if v1 { 20 } else { 12 };
        for e in 0..count {
            let at = 8 + e * entry;
            let (dur, media_time) = if v1 {
                (be64(elst, at)?, be64(elst, at + 8)? as i64)
            } else {
                (be32(elst, at)?, be32(elst, at + 4)? as u32 as i32 as i64)
            };
            if media_time < 0 {
                continue; // empty edit (a gap before the media): not priming
            }
            let frames = (dur > 0 && movie_ts > 0).then(|| ((dur as u128 * media_ts as u128 + movie_ts as u128 / 2) / movie_ts as u128) as u64);
            if media_time == 0 && frames.is_none() {
                return None;
            }
            return Some(Gapless { delay: media_time as u64, frames });
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trim_cuts_priming_and_padding() {
        let g = Gapless { delay: 1024, frames: Some(3000) };
        let mut t = g.trim_from(0);
        assert_eq!(t.keep(1024), 1024..1024);
        assert_eq!(t.keep(1024), 0..1024);
        assert_eq!(t.keep(1024), 0..1024);
        assert_eq!(t.keep(1024), 0..952);
        assert!(t.done());
        assert_eq!(t.keep(1024), 0..0);
    }

    #[test]
    fn trim_after_seek() {
        let g = Gapless { delay: 1024, frames: Some(10_000) };
        // Landed mid-priming.
        let mut t = g.trim_from(512);
        assert_eq!(t.keep(1024), 512..1024);
        // Landed past it: nothing to skip, the end still applies.
        let mut t = g.trim_from(9_216);
        assert_eq!(t.keep(1024), 0..1024);
        assert_eq!(t.keep(1024), 0..784);
        assert_eq!(g.source_frame(1.0, 44_100), 45_124);
        assert!((g.music_secs(45_124, 44_100) - 1.0).abs() < 1e-9);
    }
}
