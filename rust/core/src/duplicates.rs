//! Title/artist matching helpers (noise tags stripped, feature-aware,
//! Levenshtein ≤ 15 %) and the pre-download "do we already have this?"
//! index. Library duplicate scanning is the Duplicate Engine (`dupes.rs`).
//! Text helpers are exported: playlist matching and dead-link healing use them.

use regex_lite::Regex;
use std::collections::HashMap;
use std::sync::LazyLock;
use unicode_normalization::UnicodeNormalization;

const DURATION_TOLERANCE: f64 = 2.0;

static FEAT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)[\(\[]?\s*(feat\.?|ft\.?|featuring)\s+([^()\[\],]+)[\)\]]?").unwrap());
static BRACKET: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\(\[]([^()\[\]]+)[\)\]]").unwrap());
static TOPIC: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\s*[-–—]\s*Topic\s*$").unwrap());
static SEP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\s*(,|&|/| x | vs\.?\s| with )\s*").unwrap());
const NOISE: &[&str] = &[
    "official video", "official music video", "official audio", "official lyric video", "official lyrics video", "lyric video", "lyrics", "audio", "video", "hd", "hq",
    "4k", "music video", "visualizer", "mv", "full video", "with lyrics", "explicit", "clean", "clean version", "monstercat release", "audio only",
];

fn strip_noise(t: &str) -> String {
    let mut out = t.to_string();
    let ranges: Vec<(usize, usize, String)> = BRACKET.captures_iter(t).map(|c| (c.get(0).unwrap().start(), c.get(0).unwrap().end(), c[1].trim().to_lowercase())).collect();
    for (s, e, inner) in ranges.into_iter().rev() {
        if NOISE.contains(&inner.as_str()) {
            out.replace_range(s..e, "");
        }
    }
    out
}

/// Title key: feature clause and noise tags removed, diacritics and case
/// folded, letters/digits/spaces only, whitespace collapsed.
#[uniffi::export]
pub fn dup_normalize(text: String) -> String {
    let t = FEAT.replace_all(&text, "");
    let t = strip_noise(&t);
    let folded: String = t.nfd().filter(|c| !unicode_normalization::char::is_combining_mark(*c)).collect::<String>().to_lowercase();
    folded.chars().filter(|c| c.is_alphanumeric() || *c == ' ').collect::<String>().split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Artist key: "- Topic" and features removed, collaborators split on
/// , & / x vs with, each normalised, sorted.
#[uniffi::export]
pub fn dup_normalize_artist(text: String) -> String {
    let t = TOPIC.replace_all(&text, "");
    let t = FEAT.replace_all(&t, "");
    let unified = SEP.replace_all(&t, "|");
    let mut parts: Vec<String> = unified.split('|').map(|p| dup_normalize(p.to_string())).filter(|p| !p.is_empty()).collect();
    parts.sort();
    parts.join(" ")
}

#[uniffi::export]
pub fn dup_feature_name(text: String) -> Option<String> {
    let c = FEAT.captures(&text)?;
    let n = dup_normalize(c.get(2)?.as_str().to_string());
    (!n.is_empty()).then_some(n)
}

fn trailing_digits(s: &str) -> Option<String> {
    let d: String = s.chars().rev().take_while(|c| c.is_ascii_digit()).collect::<Vec<_>>().into_iter().rev().collect();
    (!d.is_empty()).then_some(d)
}

fn levenshtein(a: &[char], b: &[char]) -> usize {
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0; b.len() + 1];
    for i in 1..=a.len() {
        cur[0] = i;
        for j in 1..=b.len() {
            cur[j] = if a[i - 1] == b[j - 1] { prev[j - 1] } else { 1 + prev[j - 1].min(prev[j]).min(cur[j - 1]) };
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

pub fn near_match(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    if a.is_empty() || b.is_empty() {
        return false;
    }
    if let (Some(x), Some(y)) = (trailing_digits(a), trailing_digits(b)) {
        if x != y {
            return false;
        }
    }
    let (ac, bc): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    if ac.len().abs_diff(bc.len()) > 3 {
        return false;
    }
    let thr = (((ac.len().max(bc.len()) as f64) * 0.15) as usize).clamp(1, 3);
    levenshtein(&ac, &bc) <= thr
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn normalises_like_the_app() {
        assert_eq!(dup_normalize("Beyoncé – Halo (Official Video) [HD]".into()), "beyonce halo");
        assert_eq!(dup_normalize("Song (feat. X) (Lyrics)".into()), "song");
        assert_eq!(dup_normalize_artist("B & A - Topic".into()), "a b");
        assert_eq!(dup_feature_name("Song (feat. Drake)".into()).as_deref(), Some("drake"));
        assert!(near_match("helo world", "hello world"));
        assert!(!near_match("track 1", "track 2"));
    }
}

// MARK: - Local-copy index (pre-download gate)

#[derive(uniffi::Record, Clone, Debug)]
pub struct LibraryEntry {
    pub path: String,
    pub source_track_id: Option<String>,
    pub title: String,
    pub artist: String,
    pub duration: f64,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct RemoteCandidate {
    /// "<source>:<id>".
    pub source_track_id: String,
    pub title: String,
    pub artist: String,
    /// Seconds; 0 = unknown.
    pub duration: f64,
}

/// "Do we already have this?" for many remote tracks at once: a source id
/// whose file still exists (embedded tag, or the vault xattr for untagged
/// files), a download-ledger entry whose file is present, or a normalized
/// title + artist (+ duration within 2 s) match. Built once per pass; each
/// lookup is O(1).
#[derive(uniffi::Object)]
pub struct LocalCopyIndex {
    ids: std::collections::HashSet<String>,
    by_key: HashMap<String, Vec<f64>>,
}

fn identity_key(title: &str, artist: &str) -> String {
    format!("{}|{}", dup_normalize(title.to_string()), dup_normalize_artist(artist.to_string()))
}

impl LocalCopyIndex {
    fn has(&self, c: &RemoteCandidate) -> bool {
        if self.ids.contains(&c.source_track_id) {
            return true;
        }
        let key = identity_key(&c.title, &c.artist);
        let Some(durs) = (key != "|").then(|| self.by_key.get(&key)).flatten() else { return false };
        c.duration <= 0.0 || durs.iter().any(|d| (d - c.duration).abs() <= DURATION_TOLERANCE)
    }
}

#[uniffi::export]
impl LocalCopyIndex {
    /// Touches the disk (existence checks, xattr reads): build off the main thread.
    #[uniffi::constructor]
    pub fn new(library: Vec<LibraryEntry>) -> std::sync::Arc<Self> {
        let mut ids = std::collections::HashSet::new();
        let mut present = Vec::new();
        let mut by_key: HashMap<String, Vec<f64>> = HashMap::new();
        for e in &library {
            let key = identity_key(&e.title, &e.artist);
            if key != "|" {
                by_key.entry(key).or_default().push(e.duration);
            }
            let p = std::path::Path::new(&e.path);
            if !p.exists() {
                continue;
            }
            if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                present.push(name.to_string());
            }
            match e.source_track_id.as_deref().filter(|s| !s.is_empty()) {
                Some(id) => {
                    ids.insert(id.to_string());
                }
                None => {
                    if let Some(tag) = crate::lock::track_read_tag(e.path.clone()) {
                        ids.insert(tag.track_id);
                    }
                }
            }
        }
        ids.extend(crate::downloads::ledger_present_ids(present));
        std::sync::Arc::new(Self { ids, by_key })
    }

    /// Metadata only (no disk access, no ledger): the entries' own source
    /// ids plus title/artist/duration. Cheap enough for a view refresh.
    #[uniffi::constructor]
    pub fn without_disk(library: Vec<LibraryEntry>) -> std::sync::Arc<Self> {
        let mut ids = std::collections::HashSet::new();
        let mut by_key: HashMap<String, Vec<f64>> = HashMap::new();
        for e in library {
            let key = identity_key(&e.title, &e.artist);
            if key != "|" {
                by_key.entry(key).or_default().push(e.duration);
            }
            if let Some(id) = e.source_track_id.filter(|s| !s.is_empty()) {
                ids.insert(id);
            }
        }
        std::sync::Arc::new(Self { ids, by_key })
    }

    pub fn contains(&self, candidate: RemoteCandidate) -> bool {
        self.has(&candidate)
    }

    /// Indices of `candidates` not in the library, first occurrence only
    /// (resolvers can repeat a video; never two jobs for one id).
    pub fn missing(&self, candidates: Vec<RemoteCandidate>) -> Vec<u32> {
        let mut seen = std::collections::HashSet::new();
        candidates.iter().enumerate().filter(|(_, c)| seen.insert(c.source_track_id.clone()) && !self.has(c)).map(|(i, _)| i as u32).collect()
    }
}

#[cfg(test)]
mod local_copy_tests {
    use super::*;

    #[test]
    fn matches_by_id_identity_and_dedupes() {
        let d = std::env::temp_dir().join(format!("lci-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join("a.m4a");
        std::fs::write(&f, b"x").unwrap();
        let lib = vec![
            LibraryEntry { path: f.to_string_lossy().into(), source_track_id: Some("youtube:1".into()), title: "Song (Official Video)".into(), artist: "Band".into(), duration: 200.0 },
            LibraryEntry { path: d.join("gone.m4a").to_string_lossy().into(), source_track_id: Some("youtube:2".into()), title: "Other".into(), artist: "X".into(), duration: 100.0 },
        ];
        let idx = LocalCopyIndex::new(lib);
        let c = |id: &str, t: &str, a: &str, dur: f64| RemoteCandidate { source_track_id: id.into(), title: t.into(), artist: a.into(), duration: dur };
        let cands = vec![
            c("youtube:1", "?", "?", 0.0),     // id match
            c("youtube:2", "New", "Y", 0.0),   // file deleted -> missing
            c("youtube:3", "Song", "Band", 201.0), // identity match within 2 s
            c("youtube:4", "Song", "Band", 260.0), // same name, different length
            c("youtube:2", "New", "Y", 0.0),   // repeat
        ];
        assert_eq!(idx.missing(cands), vec![1, 3]);
        let _ = std::fs::remove_dir_all(d);
    }
}
