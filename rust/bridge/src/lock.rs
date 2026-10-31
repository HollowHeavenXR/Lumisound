//! The Lumisound lock format (`.lms`): an 8-byte `LMSLOCK1` header followed
//! by the audio XOR-masked with a fixed 24-byte key. The mask is position
//! based, so any byte range can be unmasked independently (seekable).

use std::io::{Read, Write};
use std::path::Path;

pub const MAGIC: &[u8; 8] = b"LMSLOCK1";
pub const KEY: [u8; 24] = [
    0x4C, 0x75, 0x6D, 0x69, 0x53, 0x6F, 0x75, 0x6E, 0x64, 0x45, 0x78, 0x63, 0x6C, 0x75, 0x73, 0x69, 0x76, 0x65, 0x4C, 0x6F,
    0x63, 0x6B, 0x21, 0x21,
];
pub const EXT: &str = "lms";

/// XOR `buf` in place as the bytes at payload offset `offset`.
pub fn apply_mask(buf: &mut [u8], offset: u64) {
    let mut k = (offset % KEY.len() as u64) as usize;
    for b in buf.iter_mut() {
        *b ^= KEY[k];
        k += 1;
        if k == KEY.len() {
            k = 0;
        }
    }
}

pub fn is_locked(p: &Path) -> bool {
    let mut h = [0u8; 8];
    std::fs::File::open(p).and_then(|mut f| f.read_exact(&mut h)).is_ok() && &h == MAGIC
}

/// Stream-unmask `src` into `dst` (a plain copy when `src` is not locked).
pub fn unmask_into(src: &Path, dst: &mut impl Write) -> std::io::Result<()> {
    let mut f = std::io::BufReader::with_capacity(1 << 20, std::fs::File::open(src)?);
    let mut head = [0u8; 8];
    let n = read_full(&mut f, &mut head)?;
    let locked = n == 8 && &head == MAGIC;
    if !locked {
        dst.write_all(&head[..n])?;
        std::io::copy(&mut f, dst)?;
        return Ok(());
    }
    let mut buf = vec![0u8; 1 << 20];
    let mut off = 0u64;
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        apply_mask(&mut buf[..n], off);
        dst.write_all(&buf[..n])?;
        off += n as u64;
    }
    Ok(())
}

fn read_full(r: &mut impl Read, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match r.read(&mut buf[n..])? {
            0 => break,
            k => n += k,
        }
    }
    Ok(n)
}

/// Inner audio extension of a `<name>.<ext>.lms` filename when `<ext>` is a
/// supported audio type ("Song.opus.lms" -> "opus").
pub fn inner_ext(filename: &str) -> Option<String> {
    let p = Path::new(filename);
    if p.extension()?.to_str()?.to_lowercase() != EXT {
        return None;
    }
    let stem = p.file_stem()?.to_str()?;
    let inner = stem.rsplit_once('.')?.1.to_lowercase();
    crate::storage::AUDIO_EXTS.contains(&inner.as_str()).then_some(inner)
}

/// Display title for a locked filename: both suffixes removed.
pub fn display_stem(filename: &str) -> String {
    let p = Path::new(filename);
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or(filename).to_string();
    if inner_ext(filename).is_some() {
        return Path::new(&stem).file_stem().and_then(|s| s.to_str()).unwrap_or(&stem).to_string();
    }
    stem
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mask_roundtrip_any_offset() {
        let data: Vec<u8> = (0..100u8).collect();
        let mut whole = data.clone();
        apply_mask(&mut whole, 0);
        let mut tail = data[37..].to_vec();
        apply_mask(&mut tail, 37);
        assert_eq!(&whole[37..], &tail[..]);
        apply_mask(&mut whole, 0);
        assert_eq!(whole, data);
    }
    #[test]
    fn names() {
        assert_eq!(inner_ext("Song.opus.lms").as_deref(), Some("opus"));
        assert_eq!(inner_ext("Song.lms"), None);
        assert_eq!(display_stem("My.Song.m4a.lms"), "My.Song");
    }
}
