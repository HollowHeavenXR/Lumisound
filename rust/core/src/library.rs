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

/// Move a file URL that points into an older container's Documents dir
/// into `docs` (containers change UUID on reinstall/restore).
fn reanchor_url(u: &str, docs: &str) -> Option<String> {
    let parsed = url::Url::parse(u).ok()?;
    if parsed.scheme() != "file" {
        return None;
    }
    let path = urlencoding::decode(parsed.path()).ok()?.into_owned();
    if path.starts_with(docs) {
        return None;
    }
    let i = path.find("/Documents/")?;
    let rest = &path[i + "/Documents/".len()..];
    url::Url::from_file_path(Path::new(docs).join(rest)).ok().map(|u| u.to_string())
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
}
