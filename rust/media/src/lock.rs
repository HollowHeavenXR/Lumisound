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
    let mut src = std::io::BufReader::with_capacity(1 << 20, std::fs::File::open(plain)?);
    atomic_write_with(locked, |out| {
        let mut w = std::io::BufWriter::with_capacity(1 << 20, out);
        w.write_all(MAGIC)?;
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
