//! Cross-device track identity.
//!
//! Favorites, playlist entries and history rows are stored on the bridge
//! with the id of whichever device wrote them: the iPhone's library path
//! ("local:Imported Music/Album/Song.opus.lms"), an Android cloud path
//! ("Song.opus.lms"), a stream id ("youtube:dQw4w9WgXcQ") — plus title and
//! artist. A device can only show "this is a favorite" or play a playlist
//! entry if it can tell which of *its own* tracks that row means. This is
//! that lookup, shared so every app resolves the same row to the same song:
//!
//! 1. the same id;
//! 2. the same source (stream URL / video id);
//! 3. the same file name (ignoring folders, the `.lms` lock suffix and case);
//! 4. the same normalised title + artist (durations within 3 s when both known);
//! 5. the same normalised title when exactly one track has it.

use crate::duplicates::{dup_normalize, dup_normalize_artist};
use std::collections::HashMap;
use std::sync::Arc;

/// A row written by some device.
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct TrackRef {
    pub id: Option<String>,
    pub track_url: Option<String>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub duration_seconds: Option<f64>,
}

/// One of this device's own tracks.
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct CatalogTrack {
    pub id: String,
    pub title: String,
    pub artist: String,
    /// File name or path, when the track is a file.
    pub filename: Option<String>,
    /// Where it was downloaded / streams from.
    pub track_url: Option<String>,
    pub duration_seconds: Option<f64>,
}

#[derive(uniffi::Object)]
pub struct TrackResolver {
    tracks: Vec<CatalogTrack>,
    by_id: HashMap<String, usize>,
    by_source: HashMap<String, usize>,
    by_file: HashMap<String, Vec<usize>>,
    by_identity: HashMap<String, Vec<usize>>,
    by_title: HashMap<String, Vec<usize>>,
}

const AUDIO_EXTS: &[&str] = &["opus", "mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "webm", "mka", "mp4", "aiff", "aif", "alac", "caf", "wma"];

/// "local:Imported Music/A/Song Name.opus.lms" -> "song name".
pub fn file_key(path: &str) -> Option<String> {
    let name = path.rsplit(['/', '\\']).next()?.trim();
    let mut stem = name.to_lowercase();
    if let Some(s) = stem.strip_suffix(".lms") {
        stem = s.to_string();
    }
    if let Some((s, ext)) = stem.rsplit_once('.') {
        if AUDIO_EXTS.contains(&ext) {
            stem = s.to_string();
        }
    }
    let stem = stem.trim().to_string();
    (!stem.is_empty()).then_some(stem)
}

/// A stable key for where a track came from: the YouTube video id, the
/// SoundCloud path, or the URL without scheme / query noise. Also accepts
/// the apps' "youtube:<id>" / "soundcloud:<id>" stream ids.
pub fn source_key(s: &str) -> Option<String> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    for p in ["youtube:", "yt:"] {
        if let Some(id) = s.strip_prefix(p) {
            return (!id.is_empty()).then(|| format!("yt:{id}"));
        }
    }
    if let Some(id) = s.strip_prefix("soundcloud:") {
        return (!id.is_empty()).then(|| format!("sc:{}", id.to_lowercase()));
    }
    let Ok(u) = url::Url::parse(s) else { return None };
    let host = u.host_str()?.trim_start_matches("www.").trim_start_matches("m.").trim_start_matches("music.").to_lowercase();
    if host == "youtu.be" {
        let id = u.path().trim_matches('/');
        return (!id.is_empty()).then(|| format!("yt:{id}"));
    }
    if host.ends_with("youtube.com") {
        if let Some((_, v)) = u.query_pairs().find(|(k, _)| k == "v") {
            return Some(format!("yt:{v}"));
        }
        let mut seg = u.path_segments()?;
        if matches!(seg.next(), Some("shorts" | "embed" | "live")) {
            return seg.next().filter(|i| !i.is_empty()).map(|i| format!("yt:{i}"));
        }
        return None;
    }
    if host.ends_with("soundcloud.com") {
        return Some(format!("sc:{}", u.path().trim_matches('/').to_lowercase()));
    }
    Some(format!("{host}{}", u.path().trim_end_matches('/')))
}

fn identity(title: &str, artist: &str) -> Option<String> {
    let t = dup_normalize(title.to_string());
    (!t.is_empty()).then(|| format!("{t}|{}", dup_normalize_artist(artist.to_string())))
}

fn duration_ok(a: Option<f64>, b: Option<f64>) -> bool {
    match (a, b) {
        (Some(x), Some(y)) if x > 0.0 && y > 0.0 => (x - y).abs() <= 3.0,
        _ => true,
    }
}

impl TrackResolver {
    fn pick(&self, hits: Option<&Vec<usize>>, r: &TrackRef, need_unique: bool) -> Option<usize> {
        let hits = hits?;
        let fit: Vec<usize> = hits.iter().copied().filter(|&i| duration_ok(r.duration_seconds, self.tracks[i].duration_seconds)).collect();
        match fit.len() {
            0 => None,
            1 => Some(fit[0]),
            _ if need_unique => None,
            _ => {
                // Several candidates: prefer the one whose artist also agrees.
                let want = r.artist.as_deref().map(|a| dup_normalize_artist(a.to_string())).unwrap_or_default();
                fit.iter().copied().find(|&i| !want.is_empty() && dup_normalize_artist(self.tracks[i].artist.clone()) == want).or(Some(fit[0]))
            }
        }
    }

    fn index_of(&self, r: &TrackRef) -> Option<usize> {
        if let Some(id) = r.id.as_deref() {
            if let Some(&i) = self.by_id.get(id) {
                return Some(i);
            }
        }
        for s in [r.track_url.as_deref(), r.id.as_deref()].into_iter().flatten() {
            if let Some(&i) = source_key(s).as_ref().and_then(|k| self.by_source.get(k)) {
                return Some(i);
            }
        }
        if let Some(i) = r.id.as_deref().and_then(file_key).and_then(|k| self.pick(self.by_file.get(&k), r, false)) {
            return Some(i);
        }
        let title = r.title.as_deref().unwrap_or("");
        if let Some(i) = identity(title, r.artist.as_deref().unwrap_or("")).and_then(|k| self.pick(self.by_identity.get(&k), r, false)) {
            return Some(i);
        }
        let t = dup_normalize(title.to_string());
        if t.is_empty() {
            return None;
        }
        self.pick(self.by_title.get(&t), r, true)
    }
}

#[uniffi::export]
impl TrackResolver {
    #[uniffi::constructor]
    pub fn new(catalog: Vec<CatalogTrack>) -> Arc<Self> {
        let mut by_id = HashMap::new();
        let mut by_source = HashMap::new();
        let mut by_file: HashMap<String, Vec<usize>> = HashMap::new();
        let mut by_identity: HashMap<String, Vec<usize>> = HashMap::new();
        let mut by_title: HashMap<String, Vec<usize>> = HashMap::new();
        for (i, t) in catalog.iter().enumerate() {
            by_id.entry(t.id.clone()).or_insert(i);
            for s in [t.track_url.as_deref(), Some(t.id.as_str())].into_iter().flatten() {
                if let Some(k) = source_key(s) {
                    by_source.entry(k).or_insert(i);
                }
            }
            if let Some(k) = t.filename.as_deref().and_then(file_key).or_else(|| file_key(&t.id).filter(|_| t.id.contains('.'))) {
                by_file.entry(k).or_default().push(i);
            }
            if let Some(k) = identity(&t.title, &t.artist) {
                by_identity.entry(k).or_default().push(i);
            }
            let n = dup_normalize(t.title.clone());
            if !n.is_empty() {
                by_title.entry(n).or_default().push(i);
            }
        }
        Arc::new(Self { tracks: catalog, by_id, by_source, by_file, by_identity, by_title })
    }

    /// This device's track id for `row`, if it has that song.
    pub fn resolve(&self, row: TrackRef) -> Option<String> {
        self.index_of(&row).map(|i| self.tracks[i].id.clone())
    }

    /// Whether `id` is one of this device's tracks.
    pub fn contains(&self, id: String) -> bool {
        self.by_id.contains_key(&id)
    }

    /// `resolve` for many rows (same order).
    pub fn resolve_all(&self, rows: Vec<TrackRef>) -> Vec<Option<String>> {
        rows.iter().map(|r| self.index_of(r).map(|i| self.tracks[i].id.clone())).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cat(id: &str, title: &str, artist: &str, file: Option<&str>, url: Option<&str>, dur: Option<f64>) -> CatalogTrack {
        CatalogTrack { id: id.into(), title: title.into(), artist: artist.into(), filename: file.map(Into::into), track_url: url.map(Into::into), duration_seconds: dur }
    }

    fn row(id: Option<&str>, title: Option<&str>, artist: Option<&str>) -> TrackRef {
        TrackRef { id: id.map(Into::into), title: title.map(Into::into), artist: artist.map(Into::into), ..Default::default() }
    }

    fn resolver() -> Arc<TrackResolver> {
        TrackResolver::new(vec![
            cat("Painted Faces.opus.lms", "Painted Faces", "Trickywi", Some("Painted Faces.opus.lms"), None, Some(201.0)),
            cat("Life is a Runway.opus.lms", "Life is a Runway", "Rarity", Some("Life is a Runway.opus.lms"), None, Some(118.0)),
            cat("youtube:dQw4w9WgXcQ", "Never Gonna Give You Up", "Rick Astley", None, Some("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), Some(213.0)),
            cat("a/Intro.mp3", "Intro", "Band One", Some("a/Intro.mp3"), None, Some(60.0)),
            cat("b/Intro.mp3", "Intro", "Band Two", Some("b/Intro.mp3"), None, Some(95.0)),
        ])
    }

    #[test]
    fn an_iphone_library_id_finds_the_cloud_copy_by_file_name() {
        let r = resolver();
        let got = r.resolve(row(Some("local:Imported Music/Five Night's At Freddy's/Painted Faces.opus.lms"), None, None));
        assert_eq!(got.as_deref(), Some("Painted Faces.opus.lms"));
        // An unlocked copy of the same file, different case.
        assert_eq!(r.resolve(row(Some("local:Music/LIFE IS A RUNWAY.opus"), None, None)).as_deref(), Some("Life is a Runway.opus.lms"));
    }

    #[test]
    fn stream_rows_match_by_video_id_whatever_the_url_shape() {
        let r = resolver();
        for u in ["https://youtu.be/dQw4w9WgXcQ?t=3", "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=x", "youtube:dQw4w9WgXcQ"] {
            let got = r.resolve(TrackRef { track_url: Some(u.into()), ..Default::default() });
            assert_eq!(got.as_deref(), Some("youtube:dQw4w9WgXcQ"), "{u}");
        }
    }

    #[test]
    fn title_and_artist_match_when_ids_share_nothing() {
        let r = resolver();
        assert_eq!(r.resolve(row(Some("local:whatever/track07.m4a"), Some("painted faces"), Some("TRICKYWI"))).as_deref(), Some("Painted Faces.opus.lms"));
        // Title alone is enough only when it's unambiguous.
        assert_eq!(r.resolve(row(None, Some("Life Is A Runway"), None)).as_deref(), Some("Life is a Runway.opus.lms"));
        assert_eq!(r.resolve(row(None, Some("Intro"), None)), None);
        assert_eq!(r.resolve(row(None, Some("Intro"), Some("Band Two"))).as_deref(), Some("b/Intro.mp3"));
    }

    #[test]
    fn duration_separates_same_named_files() {
        let r = resolver();
        let mut q = row(Some("local:x/Intro.mp3"), None, None);
        q.duration_seconds = Some(94.0);
        assert_eq!(r.resolve(q).as_deref(), Some("b/Intro.mp3"));
        let mut far = row(Some("local:x/Painted Faces.opus.lms"), None, None);
        far.duration_seconds = Some(500.0);
        assert_eq!(r.resolve(far), None);
    }

    #[test]
    fn unknown_rows_stay_unresolved() {
        let r = resolver();
        assert_eq!(r.resolve_all(vec![row(Some("local:a/Nope.mp3"), Some("Nope"), Some("Nobody")), row(None, None, None)]), vec![None, None]);
    }
}
