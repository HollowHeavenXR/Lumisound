//! Document import: copying picked files into Imported Music (dedupe by
//! size, race-safe), the per-file online-enrichment cache, tag fallbacks
//! shared by the scan and the AVFoundation fallback path, the Ogg/Opus
//! comment reader, and the periodic tag-refresh diff.

use crate::error::{CoreError, CoreResult};
use crate::store;
use std::collections::HashMap;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

// ---- copy into the library --------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportCopy {
    pub path: String,
    /// The same file (same byte size) was already in the library.
    pub reused: bool,
}

fn size(p: &Path) -> Option<u64> {
    std::fs::metadata(p).ok().map(|m| m.len())
}

/// `name 2.ext`, `name 3.ext`… until free.
fn numbered(dest: &Path) -> PathBuf {
    let dir = dest.parent().unwrap_or(Path::new("."));
    let stem = dest.file_stem().and_then(|s| s.to_str()).unwrap_or("track");
    let ext = dest.extension().and_then(|e| e.to_str()).unwrap_or("");
    (2..).map(|n| dir.join(if ext.is_empty() { format!("{stem} {n}") } else { format!("{stem} {n}.{ext}") })).find(|p| !p.exists()).unwrap()
}

/// Copy without overwriting (fails with AlreadyExists if `dest` appeared).
fn copy_new(src: &Path, dest: &Path) -> std::io::Result<()> {
    let mut from = std::fs::File::open(src)?;
    let mut to = std::fs::OpenOptions::new().write(true).create_new(true).open(dest)?;
    if let Err(e) = std::io::copy(&mut from, &mut to) {
        drop(to);
        let _ = std::fs::remove_file(dest);
        return Err(e);
    }
    Ok(())
}

/// Copy `source` into `library_dir` as `<name with / and : replaced>.<ext>`.
/// An existing file of the same size is reused; a different-sized one (a
/// partial or older copy) is replaced. Concurrent imports racing to the same
/// name: the loser adopts the winner if it's the same size, else takes a
/// numbered name.
#[uniffi::export]
pub fn import_copy_file(source: String, library_dir: String) -> CoreResult<ImportCopy> {
    let src = Path::new(&source);
    let dir = Path::new(&library_dir);
    std::fs::create_dir_all(dir)?;
    let stem = src.file_stem().and_then(|s| s.to_str()).unwrap_or("track").replace(['/', ':'], "-");
    let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("");
    let dest = dir.join(if ext.is_empty() { stem } else { format!("{stem}.{ext}") });
    let src_size = size(src).ok_or_else(|| CoreError::invalid("source unreadable"))?;
    let ok = |p: &Path, reused| Ok(ImportCopy { path: p.to_string_lossy().into_owned(), reused });
    if dest.exists() {
        if size(&dest) == Some(src_size) {
            return ok(&dest, true);
        }
        std::fs::remove_file(&dest)?;
    }
    match copy_new(src, &dest) {
        Ok(()) => ok(&dest, false),
        Err(e) if e.kind() == ErrorKind::AlreadyExists => {
            if size(&dest) == Some(src_size) {
                return ok(&dest, true);
            }
            let alt = numbered(&dest);
            copy_new(src, &alt)?;
            ok(&alt, false)
        }
        Err(e) => Err(e.into()),
    }
}

// ---- enrichment cache -------------------------------------------------------------------------

const ENRICH: &str = "doc_import_enrich";

static ENRICH_CACHE: LazyLock<Mutex<(HashMap<String, HashMap<String, String>>, bool)>> = LazyLock::new(|| Mutex::new((store::load(ENRICH), false)));

/// One-time import of the UserDefaults-era cache (JSON object of objects).
#[uniffi::export]
pub fn enrich_cache_import_legacy(json: Vec<u8>) {
    if store::exists(ENRICH) {
        return;
    }
    let m: HashMap<String, HashMap<String, String>> = serde_json::from_slice(&json).unwrap_or_default();
    let mut c = ENRICH_CACHE.lock().unwrap();
    c.0 = m;
    store::save(ENRICH, &c.0);
}

/// Saved artist/album/genre/year for a filename (empty map = looked up, nothing found).
#[uniffi::export]
pub fn enrich_cache_lookup(filename: String) -> Option<HashMap<String, String>> {
    ENRICH_CACHE.lock().unwrap().0.get(&filename).cloned()
}

/// Kept in memory until `enrich_cache_persist` (once per batch, not per song).
#[uniffi::export]
pub fn enrich_cache_store(filename: String, entry: HashMap<String, String>) {
    let mut c = ENRICH_CACHE.lock().unwrap();
    c.0.insert(filename, entry);
    c.1 = true;
}

#[uniffi::export]
pub fn enrich_cache_persist() {
    let mut c = ENRICH_CACHE.lock().unwrap();
    if c.1 {
        store::save(ENRICH, &c.0);
        c.1 = false;
    }
}

// ---- tag helpers ------------------------------------------------------------------------------

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TagIdKind {
    Genre,
    Year,
    TrackNumber,
    SourceId,
    Other,
}

/// Classify an AVFoundation metadata identifier/key (any case): ID3 frames
/// (TCON/TYER/TDRC/TORY/TRCK), iTunes atoms (©gen/©day/trkn), QuickTime and
/// Vorbis-style names, and Lumisound's own LUMISOUND_ID.
#[uniffi::export]
pub fn tag_identifier_kind(identifier: String) -> TagIdKind {
    let id = identifier.to_lowercase();
    if id.contains("lumisound_id") {
        TagIdKind::SourceId
    } else if id.contains("genre") || id.ends_with("/tcon") || id.ends_with("%a9gen") || id.ends_with("\u{a9}gen") {
        TagIdKind::Genre
    } else if id.contains("tracknumber") || id.ends_with("/track") || id.ends_with("/trck") || id.ends_with("/trkn") {
        TagIdKind::TrackNumber
    } else if id.contains("year") || id.contains("date") || id.ends_with("/tyer") || id.ends_with("/tdrc") || id.ends_with("/tory") || id.ends_with("%a9day") || id.ends_with("\u{a9}day") {
        TagIdKind::Year
    } else {
        TagIdKind::Other
    }
}

/// ID3 numeric genre references "(17)" / "(17)Rock": keep the text if any.
#[uniffi::export]
pub fn tag_clean_genre(raw: String) -> String {
    let t = raw.trim();
    if let (true, Some(close)) = (t.starts_with('('), t.find(')')) {
        let rest = t[close + 1..].trim();
        if !rest.is_empty() {
            return rest.to_string();
        }
    }
    t.to_string()
}

/// "5/12" -> 5.
#[uniffi::export]
pub fn tag_parse_track_number(raw: String) -> i64 {
    raw.split('/').next().unwrap_or("").trim().parse().unwrap_or(0)
}

/// First four characters ("2003-11-06" -> "2003").
#[uniffi::export]
pub fn tag_parse_year(raw: String) -> String {
    raw.trim().chars().take(4).collect()
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct NameFallback {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_inferred_from_folder: bool,
}

/// Filename without the container extension (and the `.lms` marker).
#[uniffi::export]
pub fn tag_fallback_title(path: String) -> String {
    let p = Path::new(&path);
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let mut stem = Path::new(name).file_stem().and_then(|s| s.to_str()).unwrap_or(name).to_string();
    if crate::lock::lms_is_converted(path.clone()) {
        stem = Path::new(&stem).file_stem().and_then(|s| s.to_str()).unwrap_or(&stem).to_string();
    }
    stem
}

/// The app's fallbacks over read tags: title still the filename and shaped
/// "Artist - Title" -> split; no album -> the parent folder (not the import
/// roots), flagged as inferred so the Albums tab can leave it out.
#[uniffi::export]
pub fn tag_apply_fallbacks(path: String, title: String, artist: String, album: String) -> NameFallback {
    let fallback = tag_fallback_title(path.clone());
    let (mut title, mut artist, mut album) = (title, artist, album);
    if title.is_empty() {
        title = fallback.clone();
    }
    if title == fallback && title.contains(" - ") {
        let mut parts = title.split(" - ");
        let first = parts.next().unwrap_or("").trim().to_string();
        let rest: Vec<&str> = parts.collect();
        if !rest.is_empty() {
            if artist.is_empty() {
                artist = first;
            }
            title = rest.join(" - ").trim().to_string();
        }
    }
    let mut inferred = false;
    if album.is_empty() {
        let parent = Path::new(&path).parent().and_then(|d| d.file_name()).and_then(|n| n.to_str()).unwrap_or("");
        if !matches!(parent, "Imported Music" | "Documents" | "") {
            album = parent.to_string();
            inferred = true;
        }
    }
    NameFallback { title, artist, album, album_inferred_from_folder: inferred }
}

// ---- Ogg/Opus comments ------------------------------------------------------------------------

fn le32(b: &[u8], o: usize) -> Option<usize> {
    b.get(o..o + 4).map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]) as usize)
}

/// Vorbis comments (KEY uppercased) from an Opus/Ogg file's second page
/// (OpusTags). Empty when absent or malformed.
#[uniffi::export]
pub fn vorbis_comments_read(path: String) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let Ok(f) = std::fs::File::open(&path) else { return out };
    let mut head = Vec::with_capacity(256 * 1024);
    use std::io::Read;
    let _ = f.take(4 * 1024 * 1024).read_to_end(&mut head);
    let b = &head;
    let (mut off, mut page) = (0usize, 0);
    while off + 27 < b.len() {
        if &b[off..off + 4] != b"OggS" {
            break;
        }
        let segs = b[off + 26] as usize;
        let hdr = 27 + segs;
        if off + hdr > b.len() {
            break;
        }
        let len: usize = b[off + 27..off + hdr].iter().map(|&x| x as usize).sum();
        let start = off + hdr;
        if start + len > b.len() {
            break;
        }
        page += 1;
        if page == 2 {
            let d = &b[start..start + len];
            if d.len() < 8 || &d[..8] != b"OpusTags" {
                break;
            }
            let mut pos = 8;
            let Some(vendor) = le32(d, pos) else { break };
            pos += 4 + vendor;
            let Some(count) = le32(d, pos) else { break };
            pos += 4;
            for _ in 0..count.min(200) {
                let Some(n) = le32(d, pos) else { break };
                pos += 4;
                let Some(raw) = d.get(pos..pos + n) else { break };
                if let Ok(s) = std::str::from_utf8(raw) {
                    if let Some((k, v)) = s.split_once('=') {
                        out.insert(k.to_uppercase(), v.to_string());
                    }
                }
                pos += n;
            }
            break;
        }
        off = start + len;
    }
    out
}

// ---- periodic refresh -------------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SongTags {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_inferred_from_folder: bool,
    pub genre: String,
    pub year: String,
    pub track_number: i64,
    pub source_track_id: Option<String>,
}

/// Raw embedded tags (empty strings when absent, no filename/folder
/// fallbacks), for the refresh merge. Nil when the core can't parse the file.
#[uniffi::export]
pub fn scan_read_raw_tags(path: String, cache_dir: String) -> Option<SongTags> {
    let readable = crate::lock::lms_playable_path(path, cache_dir);
    let i = lumisound_media::tags::read_info(Path::new(&readable))?;
    Some(SongTags {
        title: i.title.unwrap_or_default(),
        artist: i.artist.unwrap_or_default(),
        album: i.album.unwrap_or_default(),
        album_inferred_from_folder: false,
        genre: i.genre.map(tag_clean_genre).unwrap_or_default(),
        year: i.year.map(tag_parse_year).unwrap_or_default(),
        track_number: i.track.unwrap_or(0) as i64,
        source_track_id: i.source_id,
    })
}

/// Merge a fresh raw tag read (`scan_read_raw_tags` or the AVFoundation
/// fallback) into the stored tags. Title/artist/album: the tag when present,
/// else the stored value (which may come from the online lookup), then the
/// filename/folder fallbacks. Genre/year: the file's own win, else carried
/// over. A missing track number or source id never erases a known one.
/// Nil when nothing changed (the common case).
#[uniffi::export]
pub fn tag_refresh_merge(path: String, current: SongTags, raw: SongTags) -> Option<SongTags> {
    let pick = |r: &str, c: &str| if r.is_empty() { c.to_string() } else { r.to_string() };
    let f = tag_apply_fallbacks(path, pick(&raw.title, &current.title), pick(&raw.artist, &current.artist), pick(&raw.album, &current.album));
    let album_changed = f.album != current.album;
    let m = SongTags {
        title: f.title,
        artist: f.artist,
        album: f.album,
        album_inferred_from_folder: if album_changed { f.album_inferred_from_folder } else { current.album_inferred_from_folder },
        genre: pick(&raw.genre, &current.genre),
        year: pick(&raw.year, &current.year),
        track_number: if current.track_number != 0 { current.track_number } else { raw.track_number },
        source_track_id: current.source_track_id.clone().or(raw.source_track_id),
    };
    let changed = m.title != current.title || m.artist != current.artist || m.album != current.album || m.genre != current.genre || m.year != current.year || m.track_number != current.track_number || m.source_track_id != current.source_track_id;
    changed.then_some(m)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_dedupes_and_handles_collisions() {
        let d = std::env::temp_dir().join(format!("imp-{}", uuid::Uuid::new_v4()));
        let lib = d.join("Imported Music");
        std::fs::create_dir_all(&d).unwrap();
        let src = d.join("A: B.mp3");
        std::fs::write(&src, b"12345").unwrap();
        let a = import_copy_file(src.to_string_lossy().into(), lib.to_string_lossy().into()).unwrap();
        assert!(!a.reused && a.path.ends_with("A- B.mp3"));
        let b = import_copy_file(src.to_string_lossy().into(), lib.to_string_lossy().into()).unwrap();
        assert!(b.reused && b.path == a.path);
        std::fs::write(&src, b"1234567").unwrap();
        let c = import_copy_file(src.to_string_lossy().into(), lib.to_string_lossy().into()).unwrap();
        assert!(!c.reused && c.path == a.path && std::fs::metadata(&c.path).unwrap().len() == 7);
        assert!(numbered(Path::new(&c.path)).to_string_lossy().ends_with("A- B 2.mp3"));
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn tag_rules() {
        assert_eq!(tag_identifier_kind("id3/TCON".into()), TagIdKind::Genre);
        assert_eq!(tag_identifier_kind("itsk/%A9day".into()), TagIdKind::Year);
        assert_eq!(tag_identifier_kind("id3/TRCK".into()), TagIdKind::TrackNumber);
        assert_eq!(tag_identifier_kind("mdta/LUMISOUND_ID".into()), TagIdKind::SourceId);
        assert_eq!(tag_identifier_kind("id3/TIT2".into()), TagIdKind::Other);
        assert_eq!(tag_clean_genre("(17)Rock".into()), "Rock");
        assert_eq!(tag_clean_genre("(17)".into()), "(17)");
        assert_eq!(tag_parse_track_number("5/12".into()), 5);
        let f = tag_apply_fallbacks("/x/Imported Music/Band - Song.m4a.lms".into(), "".into(), "".into(), "".into());
        assert_eq!((f.title.as_str(), f.artist.as_str(), f.album.as_str(), f.album_inferred_from_folder), ("Song", "Band", "", false));
        let g = tag_apply_fallbacks("/x/Albums/Kid A/t.mp3".into(), "T".into(), "R".into(), "".into());
        assert!(g.album == "Kid A" && g.album_inferred_from_folder);
    }

    #[test]
    fn refresh_merge() {
        let path = "/x/Imported Music/file.m4a".to_string();
        let cur = SongTags { title: "T".into(), artist: "Enriched".into(), album: "Al".into(), album_inferred_from_folder: false, genre: "Pop".into(), year: "1999".into(), track_number: 3, source_track_id: Some("youtube:x".into()) };
        let empty = SongTags { title: String::new(), artist: String::new(), album: String::new(), album_inferred_from_folder: false, genre: String::new(), year: String::new(), track_number: 0, source_track_id: None };
        // No tags in the file: nothing (incl. the online-enriched artist) is lost.
        assert_eq!(tag_refresh_merge(path.clone(), cur.clone(), empty.clone()), None);
        let mut raw = empty;
        raw.genre = "Rock".into();
        raw.title = "New".into();
        let m = tag_refresh_merge(path, cur, raw).unwrap();
        assert_eq!((m.genre.as_str(), m.title.as_str(), m.artist.as_str()), ("Rock", "New", "Enriched"));
    }

    #[test]
    fn reads_opus_tags_page() {
        let mut page1 = b"OggS".to_vec();
        page1.extend_from_slice(&[0u8; 22]);
        page1.push(1);
        page1.push(19);
        page1.extend_from_slice(b"OpusHead\x01\x02\x00\x00\x80\xbb\x00\x00\x00\x00\x00");
        let mut tags = b"OpusTags".to_vec();
        tags.extend_from_slice(&3u32.to_le_bytes());
        tags.extend_from_slice(b"lib");
        tags.extend_from_slice(&2u32.to_le_bytes());
        for c in ["title=Hello", "LUMISOUND_ID=youtube:abc"] {
            tags.extend_from_slice(&(c.len() as u32).to_le_bytes());
            tags.extend_from_slice(c.as_bytes());
        }
        let mut page2 = b"OggS".to_vec();
        page2.extend_from_slice(&[0u8; 22]);
        page2.push(1);
        page2.push(tags.len() as u8);
        page2.extend_from_slice(&tags);
        let p = std::env::temp_dir().join(format!("t-{}.opus", uuid::Uuid::new_v4()));
        std::fs::write(&p, [page1, page2].concat()).unwrap();
        let m = vorbis_comments_read(p.to_string_lossy().into());
        assert_eq!(m.get("TITLE").map(String::as_str), Some("Hello"));
        assert_eq!(m.get("LUMISOUND_ID").map(String::as_str), Some("youtube:abc"));
        let _ = std::fs::remove_file(p);
    }
}
