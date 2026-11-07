//! Library snapshot persistence and indexing: the cached `library_snapshot`
//! JSON (Swift `Song` records) is read, re-anchored to the current app
//! container and grouped here; Swift decodes the songs as view models.

use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

#[derive(uniffi::Record, Clone, Debug)]
pub struct SongGroup {
    pub key: String,
    pub song_ids: Vec<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct LibraryLoad {
    /// The snapshot JSON with file URLs moved into the current Documents dir.
    pub snapshot_json: Vec<u8>,
    pub by_artist: Vec<SongGroup>,
    pub by_album: Vec<SongGroup>,
    pub by_genre: Vec<SongGroup>,
    pub song_count: u32,
}

fn trimmed_or(v: &Value, fallback: &str) -> String {
    let s = v.as_str().unwrap_or("").trim();
    if s.is_empty() { fallback.to_string() } else { v.as_str().unwrap_or("").to_string() }
}

/// `Song.artistName`.
pub fn artist_name(song: &Value) -> String {
    trimmed_or(&song["artist"], "Unknown Artist")
}

/// `Song.groupableAlbumName`.
pub fn groupable_album(song: &Value) -> String {
    if song["albumInferredFromFolder"].as_bool() == Some(true) {
        return "Unknown Album".into();
    }
    trimmed_or(&song["album"], "Unknown Album")
}

/// `file://` URL for `path`, percent-encoded exactly like Foundation's
/// `URL(fileURLWithPath:).absoluteString` (`.urlPathAllowed`): unreserved
/// characters, sub-delims, ':' '@' and '/' stay literal; everything else
/// (space, '|', '[', ']', '^', '%', '?', '#', non-ASCII…) is encoded. The url
/// crate leaves '|' '[' ']' '^' raw, which Swift can't parse back to the same
/// path, so songs with those characters in their file names fell out of the
/// library and were re-added as "new" on the next scan.
pub fn file_url(path: &str) -> String {
    let mut out = String::with_capacity(path.len() + 16);
    out.push_str("file://");
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Canonical URL for a stored file URL: moved into `docs` when it points into
/// an older container's Documents dir (containers change UUID on every
/// reinstall/update), and re-encoded the way Swift reads it (heals URLs an
/// earlier build wrote with raw '|' '[' ']'). None = already canonical.
fn reanchor_url(u: &str, docs: &str) -> Option<String> {
    let rest = u.strip_prefix("file://")?;
    // Raw '|', '[' … are not valid URL characters, so decode by hand rather
    // than through a strict parser.
    let path = urlencoding::decode(rest.split(['?', '#']).next().unwrap_or(rest)).ok()?.into_owned();
    let path = if path.starts_with(docs) {
        path
    } else if let Some(i) = path.find("/Documents/") {
        Path::new(docs).join(&path[i + "/Documents/".len()..]).to_string_lossy().into_owned()
    } else {
        path
    };
    let canonical = file_url(&path);
    (canonical != u).then_some(canonical)
}

fn reanchor(songs: &mut Value, docs: &str) -> usize {
    let mut moved = 0;
    if let Some(a) = songs.as_array_mut() {
        for s in a {
            if let Some(n) = s["url"].as_str().and_then(|u| reanchor_url(u, docs)) {
                s["url"] = Value::String(n);
                moved += 1;
            }
        }
    }
    moved
}

fn group(songs: &[Value], key: impl Fn(&Value) -> Option<String>) -> Vec<SongGroup> {
    let mut m: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for s in songs {
        if let (Some(k), Some(id)) = (key(s), s["id"].as_str()) {
            m.entry(k).or_default().push(id.to_string());
        }
    }
    m.into_iter().map(|(key, song_ids)| SongGroup { key, song_ids }).collect()
}

/// Read and index the snapshot at `path`; None when missing/empty/corrupt.
#[uniffi::export]
pub fn library_snapshot_load(path: String, documents_dir: String) -> Option<LibraryLoad> {
    let raw = std::fs::read(&path).ok()?;
    let mut snap: Value = serde_json::from_slice(&raw).ok()?;
    let docs = documents_dir.trim_end_matches('/').to_string();
    reanchor(&mut snap["songs"], &docs);
    if snap.get("importedSongs").is_some_and(Value::is_array) {
        reanchor(&mut snap["importedSongs"], &docs);
    }
    let songs = snap["songs"].as_array()?.clone();
    if songs.is_empty() {
        return None;
    }
    Some(LibraryLoad {
        by_artist: group(&songs, |s| Some(artist_name(s))),
        by_album: group(&songs, |s| Some(groupable_album(s))),
        by_genre: group(&songs, |s| s["genre"].as_str().filter(|g| !g.is_empty()).map(str::to_string)),
        song_count: songs.len() as u32,
        snapshot_json: serde_json::to_vec(&snap).ok()?,
    })
}

/// Atomically write the snapshot JSON (encoded by Swift) to `path`.
#[uniffi::export]
pub fn library_snapshot_save(path: String, json: Vec<u8>) -> bool {
    let p = Path::new(&path);
    let tmp = p.with_extension("json.tmp");
    std::fs::write(&tmp, &json).and_then(|_| std::fs::rename(&tmp, p)).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reanchors_and_groups() {
        let d = std::env::temp_dir().join(format!("lib-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&d).unwrap();
        let snap = serde_json::json!({"songs": [
            {"id": "1", "title": "A", "artist": "X", "album": "", "url": "file:///var/mobile/Containers/Data/Application/OLD/Documents/Music/a%20b.mp3"},
            {"id": "2", "title": "B", "artist": " ", "album": "Al", "genre": "Pop", "albumInferredFromFolder": true}
        ], "artists": [], "albums": [], "genres": []});
        let p = d.join("snap.json");
        std::fs::write(&p, serde_json::to_vec(&snap).unwrap()).unwrap();
        let l = library_snapshot_load(p.to_string_lossy().into(), "/var/mobile/Containers/Data/Application/NEW/Documents".into()).unwrap();
        let v: Value = serde_json::from_slice(&l.snapshot_json).unwrap();
        assert_eq!(v["songs"][0]["url"], "file:///var/mobile/Containers/Data/Application/NEW/Documents/Music/a%20b.mp3");
        assert_eq!(l.by_artist.iter().map(|g| g.key.as_str()).collect::<Vec<_>>(), vec!["Unknown Artist", "X"]);
        assert_eq!(l.by_album.len(), 1);
        assert_eq!(l.by_genre[0].key, "Pop");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn file_urls_match_foundation_encoding() {
        let docs = "/var/mobile/Containers/Data/Application/NEW/Documents";
        let p = format!("{docs}/Imported Music/Dragon Ball/21. Kakarot Vs Broly | DBS- Broly [OST] ^ブロリー 100%.opus.lms");
        let u = file_url(&p);
        assert_eq!(u, "file:///var/mobile/Containers/Data/Application/NEW/Documents/Imported%20Music/Dragon%20Ball/21.%20Kakarot%20Vs%20Broly%20%7C%20DBS-%20Broly%20%5BOST%5D%20%5E%E3%83%96%E3%83%AD%E3%83%AA%E3%83%BC%20100%25.opus.lms");
        // A URL an earlier build wrote with raw '|' / '[' is healed in place…
        let broken = format!("file://{}", p.replace(' ', "%20"));
        assert_eq!(reanchor_url(&broken, docs).as_deref(), Some(u.as_str()));
        // …a canonical one is left alone, and an old container is moved.
        assert_eq!(reanchor_url(&u, docs), None);
        let old = u.replace("/NEW/", "/OLD/");
        assert_eq!(reanchor_url(&old, docs).as_deref(), Some(u.as_str()));
        // Swift-written URLs (same encoding) round-trip unchanged.
        let swift = "file:///var/mobile/Containers/Data/Application/NEW/Documents/a%20b%7Cc.mp3";
        assert_eq!(reanchor_url(swift, docs), None);
        if let Ok(out) = std::env::var("LUMI_URL_OUT") {
            std::fs::write(out, format!("{p}\n{u}\n")).unwrap();
        }
    }
}

// ---- scan cache: path -> (mtime, size, Song) so unchanged files skip tag reads ------------------

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

#[derive(serde::Serialize, serde::Deserialize, Clone)]
struct ScanEntry {
    mtime: f64,
    #[serde(rename = "fileSize")]
    file_size: i64,
    song: Value,
}

#[derive(Default)]
struct ScanCache {
    path: Option<String>,
    entries: HashMap<String, ScanEntry>,
    dirty: bool,
}

static SCAN: LazyLock<Mutex<ScanCache>> = LazyLock::new(|| Mutex::new(ScanCache::default()));

fn stamp(p: &str) -> Option<(f64, i64)> {
    let m = std::fs::metadata(p).ok()?;
    let t = m.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64();
    Some((t, m.len() as i64))
}

/// Key: path relative to Documents when inside it, else the absolute path.
fn scan_key(path: &str, docs: &str) -> String {
    match path.strip_prefix(docs) {
        Some(rest) => rest.trim_matches('/').to_string(),
        None => path.to_string(),
    }
}

/// Load the cache file once (same JSON layout the Swift cache used).
#[uniffi::export]
pub fn scan_cache_open(cache_path: String) {
    let mut c = SCAN.lock().unwrap();
    if c.path.as_deref() == Some(&cache_path) {
        return;
    }
    c.entries = std::fs::read(&cache_path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    c.path = Some(cache_path);
    c.dirty = false;
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ScanPartition {
    /// JSON array of cached Songs with `url` set to the file's current URL.
    pub cached_songs_json: Vec<u8>,
    /// Files that are new or changed since they were cached.
    pub uncached_paths: Vec<String>,
}

/// Stat every file and split it into cache hits (unchanged mtime + size)
/// and files that need a fresh tag read.
#[uniffi::export]
pub fn scan_cache_partition(paths: Vec<String>, documents_dir: String) -> ScanPartition {
    let docs = documents_dir.trim_end_matches('/').to_string();
    let c = SCAN.lock().unwrap();
    let mut cached = Vec::new();
    let mut uncached = Vec::new();
    for p in paths {
        let hit = stamp(&p).and_then(|(t, sz)| c.entries.get(&scan_key(&p, &docs)).filter(|e| e.file_size == sz && (e.mtime - t).abs() < 0.001));
        match hit {
            Some(e) if p.starts_with('/') => {
                let mut s = e.song.clone();
                s["url"] = Value::String(file_url(&p));
                cached.push(s);
            }
            _ => uncached.push(p),
        }
    }
    ScanPartition { cached_songs_json: serde_json::to_vec(&cached).unwrap_or_default(), uncached_paths: uncached }
}

/// Remember a freshly read song for `path` (stamped now).
#[uniffi::export]
pub fn scan_cache_store(path: String, documents_dir: String, song_json: Vec<u8>) {
    let Some((t, sz)) = stamp(&path) else { return };
    let Ok(song) = serde_json::from_slice::<Value>(&song_json) else { return };
    let mut c = SCAN.lock().unwrap();
    let k = scan_key(&path, documents_dir.trim_end_matches('/'));
    c.entries.insert(k, ScanEntry { mtime: t, file_size: sz, song });
    c.dirty = true;
}

/// Drop entries whose file no longer exists.
#[uniffi::export]
pub fn scan_cache_evict_missing(documents_dir: String) {
    let docs = documents_dir.trim_end_matches('/').to_string();
    let mut c = SCAN.lock().unwrap();
    let before = c.entries.len();
    c.entries.retain(|k, _| {
        let p = if k.starts_with('/') { k.clone() } else { format!("{docs}/{k}") };
        Path::new(&p).exists()
    });
    if c.entries.len() != before {
        c.dirty = true;
    }
}

/// Write the cache atomically if anything changed.
#[uniffi::export]
pub fn scan_cache_persist() {
    let mut c = SCAN.lock().unwrap();
    if !c.dirty {
        return;
    }
    let Some(path) = c.path.clone() else { return };
    if let Ok(b) = serde_json::to_vec(&c.entries) {
        if library_snapshot_save(path, b) {
            c.dirty = false;
        }
    }
}

// ---- scan-time metadata ----------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug)]
pub struct ScannedTrack {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_inferred_from_folder: bool,
    pub genre: String,
    pub year: String,
    pub track_number: i64,
    pub source_track_id: Option<String>,
    pub duration: f64,
    pub sample_rate: i64,
    pub bitrate_kbps: i64,
}

/// Tags + stream properties for a library file (`.lms` read through its
/// unlocked copy), with the app's fallbacks: filename as title, "Artist -
/// Title" filenames split, the parent folder as album (except the import
/// roots). None when the file can't be parsed (caller falls back).
#[uniffi::export]
pub fn scan_read_track(path: String, cache_dir: String) -> Option<ScannedTrack> {
    let readable = crate::lock::lms_playable_path(path.clone(), cache_dir);
    let info = lumisound_media::tags::read_info(Path::new(&readable))?;
    let f = crate::import::tag_apply_fallbacks(path, info.title.clone().unwrap_or_default(), info.artist.clone().unwrap_or_default(), info.album.clone().unwrap_or_default());
    let (title, artist, album, inferred) = (f.title, f.artist, f.album, f.album_inferred_from_folder);
    Some(ScannedTrack {
        title,
        artist,
        album,
        album_inferred_from_folder: inferred,
        genre: info.genre.map(crate::import::tag_clean_genre).unwrap_or_default(),
        year: info.year.map(crate::import::tag_parse_year).unwrap_or_default(),
        track_number: info.track.unwrap_or(0) as i64,
        source_track_id: info.source_id,
        duration: info.duration,
        sample_rate: info.sample_rate as i64,
        bitrate_kbps: info.bitrate_kbps as i64,
    })
}

// ---- M3U / M3U8 playlist import ----------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug)]
pub struct M3uCandidate {
    pub id: String,
    /// Library file name (last path component).
    pub filename: Option<String>,
    pub display_name: String,
    pub artist_name: String,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct M3uResult {
    pub matched_song_ids: Vec<String>,
    pub total_entries: u32,
}

/// Match an M3U playlist (UTF-8 or Latin-1) against the library: by file
/// name first, then by the #EXTINF "Artist - Title" (case-insensitive).
#[uniffi::export]
pub fn m3u_match(data: Vec<u8>, library: Vec<M3uCandidate>) -> M3uResult {
    let text = String::from_utf8(data.clone()).unwrap_or_else(|_| data.iter().map(|b| *b as char).collect());
    let mut by_name: HashMap<String, &M3uCandidate> = HashMap::new();
    for c in &library {
        if let Some(f) = &c.filename {
            by_name.entry(f.to_lowercase()).or_insert(c);
        }
    }
    let (mut ids, mut seen, mut total) = (Vec::new(), std::collections::HashSet::new(), 0u32);
    let mut pending: Option<(String, String)> = None;
    for raw in text.split('\n') {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXTINF:") {
            if let Some((_, info)) = rest.split_once(',') {
                let parts: Vec<&str> = info.split(" - ").collect();
                pending = Some(if parts.len() >= 2 { (parts[1..].join(" - "), parts[0].to_string()) } else { (info.to_string(), String::new()) });
            }
            continue;
        }
        if line.starts_with('#') {
            continue;
        }
        total += 1;
        let ext = pending.take();
        let fname = line.rsplit(['/', '\\']).next().unwrap_or(line).to_lowercase();
        let mut m = by_name.get(&fname).copied();
        if m.is_none() {
            if let Some((t, a)) = ext.filter(|(t, _)| !t.is_empty()) {
                let (t, a) = (t.to_lowercase(), a.to_lowercase());
                m = library.iter().find(|c| c.display_name.to_lowercase() == t && (a.is_empty() || c.artist_name.to_lowercase() == a));
            }
        }
        if let Some(c) = m {
            if seen.insert(c.id.clone()) {
                ids.push(c.id.clone());
            }
        }
    }
    M3uResult { matched_song_ids: ids, total_entries: total }
}

// ---- artwork ------------------------------------------------------------------------------------

/// Embedded cover art of a library file (front cover preferred).
#[uniffi::export]
pub fn artwork_embedded(path: String, cache_dir: String) -> Option<Vec<u8>> {
    let readable = crate::lock::lms_playable_path(path, cache_dir);
    lumisound_media::artwork::embedded(Path::new(&readable))
}

/// The app's artwork cleanup: trim letterbox bars, square, fit `max_dim`, JPEG.
#[uniffi::export]
pub fn artwork_process(image_data: Vec<u8>, max_dim: u32) -> Option<Vec<u8>> {
    lumisound_media::artwork::process(&image_data, max_dim.max(16))
}
