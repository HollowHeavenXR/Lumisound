//! The Lumisound lock format (`.lms`): a header followed by the audio
//! XOR-masked with a fixed 24-byte key. The mask is position based (offsets
//! count from the first payload byte), so any byte range can be unmasked
//! independently (seekable).
//!
//! * v1: `LMSLOCK1` (8 bytes), payload.
//! * v2: `LMSLOCK2`, flags (u32 LE), reserved (u32), payload — 16 bytes of
//!   header. Flags: `FLAG_ENGINE_EXCLUSIVE` (only the Lumisound Audio Engine
//!   may play it; the app refuses the system engine), `FLAG_LYRICS_SYNCED`
//!   (the track's lyrics were force time-synced). Payload bytes are
//!   identical between versions, so changing the header never re-masks.

use std::io::{Read, Write};
use std::path::Path;

pub const MAGIC: &[u8; 8] = b"LMSLOCK1";
pub const MAGIC2: &[u8; 8] = b"LMSLOCK2";
pub const HEADER2_LEN: usize = 16;
pub const FLAG_ENGINE_EXCLUSIVE: u32 = 1;
pub const FLAG_LYRICS_SYNCED: u32 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    pub version: u8,
    pub flags: u32,
    /// Where the masked payload starts.
    pub payload_offset: usize,
}

/// Parse a header from the file's first bytes (at least 8; 16 for v2).
pub fn parse_header(head: &[u8]) -> Option<Header> {
    if head.len() >= 8 && &head[..8] == MAGIC {
        return Some(Header { version: 1, flags: 0, payload_offset: 8 });
    }
    if head.len() >= HEADER2_LEN && &head[..8] == MAGIC2 {
        let flags = u32::from_le_bytes([head[8], head[9], head[10], head[11]]);
        return Some(Header { version: 2, flags, payload_offset: HEADER2_LEN });
    }
    None
}

pub fn encode_header(flags: u32) -> Vec<u8> {
    if flags == 0 {
        return MAGIC.to_vec();
    }
    let mut h = MAGIC2.to_vec();
    h.extend_from_slice(&flags.to_le_bytes());
    h.extend_from_slice(&0u32.to_le_bytes());
    h
}

/// Header of a file, if it is locked.
pub fn read_header(p: &Path) -> Option<Header> {
    let mut f = std::fs::File::open(p).ok()?;
    let mut h = [0u8; HEADER2_LEN];
    let n = read_full(&mut f, &mut h).ok()?;
    parse_header(&h[..n])
}
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
    read_header(p).is_some()
}

/// Stream-unmask `src` into `dst` (a plain copy when `src` is not locked).
pub fn unmask_into(src: &Path, dst: &mut impl Write) -> std::io::Result<()> {
    let mut f = std::io::BufReader::with_capacity(1 << 20, std::fs::File::open(src)?);
    let mut head = [0u8; HEADER2_LEN];
    let n = read_full(&mut f, &mut head)?;
    let Some(h) = parse_header(&head[..n]) else {
        dst.write_all(&head[..n])?;
        std::io::copy(&mut f, dst)?;
        return Ok(());
    };
    // Header bytes read past a v1 header are already payload.
    let mut off = 0u64;
    if n > h.payload_offset {
        let mut first = head[h.payload_offset..n].to_vec();
        apply_mask(&mut first, 0);
        dst.write_all(&first)?;
        off = (n - h.payload_offset) as u64;
    }
    let mut buf = vec![0u8; 1 << 20];
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
    crate::AUDIO_EXTS.contains(&inner.as_str()).then_some(inner)
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

/// Atomically write `bytes` to `dst` (temp file in the same dir + rename).
fn atomic_write_with(dst: &Path, f: impl FnOnce(&mut std::fs::File) -> std::io::Result<()>) -> std::io::Result<()> {
    let dir = dst.parent().unwrap_or(Path::new("."));
    let tmp = dir.join(format!(".{}.tmp-{}", dst.file_name().and_then(|n| n.to_str()).unwrap_or("lms"), std::process::id() as u64 ^ nanos()));
    let r = (|| {
        let mut out = std::fs::File::create(&tmp)?;
        f(&mut out)?;
        out.sync_all()?;
        std::fs::rename(&tmp, dst)
    })();
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r
}

fn nanos() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(0)
}

/// Lock `plain` into `locked` (`LMSLOCK1` + masked bytes). Streams in 1 MiB
/// blocks; never touches `plain`.
pub fn lock_file(plain: &Path, locked: &Path) -> std::io::Result<()> {
    lock_file_flags(plain, locked, 0)
}

/// Lock with header flags (v2 header when any flag is set).
pub fn lock_file_flags(plain: &Path, locked: &Path, flags: u32) -> std::io::Result<()> {
    let mut src = std::io::BufReader::with_capacity(1 << 20, std::fs::File::open(plain)?);
    atomic_write_with(locked, |out| {
        let mut w = std::io::BufWriter::with_capacity(1 << 20, out);
        w.write_all(&encode_header(flags))?;
        let mut buf = vec![0u8; 1 << 20];
        let mut off = 0u64;
        loop {
            let n = src.read(&mut buf)?;
            if n == 0 {
                break;
            }
            apply_mask(&mut buf[..n], off);
            w.write_all(&buf[..n])?;
            off += n as u64;
        }
        w.flush()
    })
}

/// Rewrite a locked file's header with `flags` into `out` (atomic). The
/// masked payload is copied byte for byte (offsets are payload-relative), so
/// this is a fast stream copy, never a re-mask. `out` may equal `locked`.
pub fn rewrite_header(locked: &Path, out: &Path, flags: u32) -> std::io::Result<()> {
    let h = read_header(locked).ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "not a locked file"))?;
    let mut src = std::io::BufReader::with_capacity(1 << 20, std::fs::File::open(locked)?);
    let mut skip = vec![0u8; h.payload_offset];
    src.read_exact(&mut skip)?;
    atomic_write_with(out, |f| {
        let mut w = std::io::BufWriter::with_capacity(1 << 20, f);
        w.write_all(&encode_header(flags))?;
        std::io::copy(&mut src, &mut w)?;
        w.flush()
    })
}

/// Unlock `locked` into `out` (legacy unmasked `.lms` files pass through).
pub fn unlock_file(locked: &Path, out: &Path) -> std::io::Result<()> {
    atomic_write_with(out, |f| {
        let mut w = std::io::BufWriter::with_capacity(1 << 20, f);
        unmask_into(locked, &mut w)?;
        w.flush()
    })
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
    fn v2_header_roundtrip_and_rewrite() {
        let d = std::env::temp_dir().join(format!("lmsv2-{}", nanos()));
        std::fs::create_dir_all(&d).unwrap();
        let (p, l, o) = (d.join("a.opus"), d.join("a.opus.lms"), d.join("out.opus"));
        let data: Vec<u8> = (0..2_500_000u32).map(|i| (i * 13) as u8).collect();
        std::fs::write(&p, &data).unwrap();
        lock_file(&p, &l).unwrap();
        assert_eq!(read_header(&l).unwrap(), Header { version: 1, flags: 0, payload_offset: 8 });
        // v1 -> v2 exclusive, payload untouched, still unlocks to the original.
        rewrite_header(&l, &l, FLAG_ENGINE_EXCLUSIVE).unwrap();
        assert_eq!(read_header(&l).unwrap(), Header { version: 2, flags: FLAG_ENGINE_EXCLUSIVE, payload_offset: 16 });
        assert_eq!(std::fs::metadata(&l).unwrap().len(), data.len() as u64 + 16);
        unlock_file(&l, &o).unwrap();
        assert_eq!(std::fs::read(&o).unwrap(), data);
        // Both flags, then lock_file_flags directly.
        rewrite_header(&l, &l, FLAG_ENGINE_EXCLUSIVE | FLAG_LYRICS_SYNCED).unwrap();
        assert_eq!(read_header(&l).unwrap().flags, 3);
        let l2 = d.join("b.opus.lms");
        lock_file_flags(&p, &l2, FLAG_LYRICS_SYNCED).unwrap();
        unlock_file(&l2, &o).unwrap();
        assert_eq!(std::fs::read(&o).unwrap(), data);
        assert!(is_locked(&l2) && is_locked(&l));
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn file_roundtrip() {
        let d = std::env::temp_dir().join(format!("lmstest-{}", nanos()));
        std::fs::create_dir_all(&d).unwrap();
        let (p, l, o) = (d.join("a.m4a"), d.join("a.m4a.lms"), d.join("out.m4a"));
        let data: Vec<u8> = (0..3_000_000u32).map(|i| (i * 7) as u8).collect();
        std::fs::write(&p, &data).unwrap();
        lock_file(&p, &l).unwrap();
        assert!(is_locked(&l));
        unlock_file(&l, &o).unwrap();
        assert_eq!(std::fs::read(&o).unwrap(), data);
        std::fs::remove_dir_all(&d).unwrap();
    }
    #[test]
    fn names() {
        assert_eq!(inner_ext("Song.opus.lms").as_deref(), Some("opus"));
        assert_eq!(inner_ext("Song.lms"), None);
        assert_eq!(display_stem("My.Song.m4a.lms"), "My.Song");
    }
}

/// A locked file read as its plain audio, unmasking on the fly: `Read +
/// Seek` over the payload. Tag/artwork readers use this instead of
/// unlocking the whole file to a temp copy first (tens of MB for a lossless
/// track, repeated whenever iOS purged the temp folder).
pub struct MaskedFile {
    file: std::fs::File,
    payload_offset: u64,
    /// Current position in the plain stream.
    pos: u64,
}

impl MaskedFile {
    /// None when `p` isn't a locked file.
    pub fn open(p: &Path) -> Option<Self> {
        let h = read_header(p)?;
        let mut file = std::fs::File::open(p).ok()?;
        use std::io::Seek;
        file.seek(std::io::SeekFrom::Start(h.payload_offset as u64)).ok()?;
        Some(Self { file, payload_offset: h.payload_offset as u64, pos: 0 })
    }

    pub fn len(&self) -> u64 {
        self.file.metadata().map(|m| m.len().saturating_sub(self.payload_offset)).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl Read for MaskedFile {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.file.read(buf)?;
        apply_mask(&mut buf[..n], self.pos);
        self.pos += n as u64;
        Ok(n)
    }
}

impl std::io::Seek for MaskedFile {
    fn seek(&mut self, to: std::io::SeekFrom) -> std::io::Result<u64> {
        let target: i64 = match to {
            std::io::SeekFrom::Start(o) => o as i64,
            std::io::SeekFrom::Current(d) => self.pos as i64 + d,
            std::io::SeekFrom::End(d) => self.len() as i64 + d,
        };
        if target < 0 {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "seek before start"));
        }
        self.file.seek(std::io::SeekFrom::Start(self.payload_offset + target as u64))?;
        self.pos = target as u64;
        Ok(self.pos)
    }
}

#[cfg(test)]
mod masked_tests {
    use super::*;
    use std::io::Seek;
    #[test]
    fn masked_file_reads_and_seeks_plain_bytes() {
        let d = std::env::temp_dir().join(format!("masked-{}", nanos()));
        std::fs::create_dir_all(&d).unwrap();
        let data: Vec<u8> = (0..500_000u32).map(|i| (i * 31 + 7) as u8).collect();
        let (p, l1, l2) = (d.join("a.flac"), d.join("a.flac.lms"), d.join("b.flac.lms"));
        std::fs::write(&p, &data).unwrap();
        lock_file(&p, &l1).unwrap();
        lock_file_flags(&p, &l2, FLAG_ENGINE_EXCLUSIVE).unwrap();
        for l in [&l1, &l2] {
            let mut m = MaskedFile::open(l).unwrap();
            assert_eq!(m.len(), data.len() as u64);
            let mut all = Vec::new();
            m.read_to_end(&mut all).unwrap();
            assert_eq!(all, data);
            m.seek(std::io::SeekFrom::Start(123_457)).unwrap();
            let mut b = [0u8; 1000];
            m.read_exact(&mut b).unwrap();
            assert_eq!(&b[..], &data[123_457..124_457]);
            m.seek(std::io::SeekFrom::End(-10)).unwrap();
            let mut t = Vec::new();
            m.read_to_end(&mut t).unwrap();
            assert_eq!(t, &data[data.len() - 10..]);
        }
        assert!(MaskedFile::open(&p).is_none());
        let _ = std::fs::remove_dir_all(d);
    }
}
