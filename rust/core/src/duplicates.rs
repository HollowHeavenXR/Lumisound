//! Duplicate detection: (1) same source track id, (2) acoustic fingerprint
//! match within a 2 s duration cluster, (3) fuzzy title + artist match
//! (feature-aware, noise tags stripped, Levenshtein ≤ 15%). Text helpers are
//! exported because playlist matching and dead-link healing use them too.

use regex_lite::Regex;
use std::collections::HashMap;
use std::sync::LazyLock;
use unicode_normalization::UnicodeNormalization;

const DURATION_TOLERANCE: f64 = 2.0;
const MAX_FINGERPRINTS: usize = 150;
const MAX_ACOUSTIC_CLUSTER: usize = 20;
const MATCH_THRESHOLD: f32 = 0.99;

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

#[derive(uniffi::Record, Clone, Debug)]
pub struct DupSong {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub duration: f64,
    /// Playable file path (None for streams).
    pub path: Option<String>,
    pub source_track_id: Option<String>,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum DupReason {
    SameSourceTrack,
    AcousticMatch,
    SameTitleAndArtist,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct DupGroup {
    pub song_ids: Vec<String>,
    pub reason: DupReason,
}

struct Uf(HashMap<String, String>);

impl Uf {
    fn find(&self, x: &str) -> String {
        let mut x = x.to_string();
        while let Some(p) = self.0.get(&x) {
            if *p == x {
                break;
            }
            x = p.clone();
        }
        x
    }
    fn union(&mut self, a: &str, b: &str) {
        let (ra, rb) = (self.find(a), self.find(b));
        if ra != rb {
            self.0.insert(ra, rb);
        }
    }
}

/// Group duplicates; largest groups first.
#[uniffi::export]
pub fn find_duplicates(songs: Vec<DupSong>, cache_dir: String) -> Vec<DupGroup> {
    let mut groups = Vec::new();
    let mut consumed = std::collections::HashSet::new();
    // Pass 1: same source track (from the song, then the file's own tags).
    let mut by_src: HashMap<String, Vec<String>> = HashMap::new();
    for s in &songs {
        let src = s.source_track_id.clone().filter(|x| !x.is_empty()).or_else(|| {
            let p = s.path.as_ref()?;
            crate::lock::track_read_tag(p.clone())
                .map(|t| t.track_id)
                .or_else(|| crate::downloads::tags_read_lumisound(p.clone()).source_track_id)
                .filter(|x| !x.is_empty())
        });
        if let Some(src) = src {
            by_src.entry(src).or_default().push(s.id.clone());
        }
    }
    for ids in by_src.into_values().filter(|v| v.len() > 1) {
        consumed.extend(ids.iter().cloned());
        groups.push(DupGroup { song_ids: ids, reason: DupReason::SameSourceTrack });
    }
    // Duration clusters of the rest.
    let mut rest: Vec<&DupSong> = songs.iter().filter(|s| !consumed.contains(&s.id)).collect();
    rest.sort_by(|a, b| a.duration.partial_cmp(&b.duration).unwrap_or(std::cmp::Ordering::Equal));
    let mut clusters: Vec<Vec<&DupSong>> = Vec::new();
    let mut prev: Option<f64> = None;
    for s in rest {
        if prev.is_none_or(|p| s.duration - p > DURATION_TOLERANCE) {
            clusters.push(Vec::new());
        }
        clusters.last_mut().unwrap().push(s);
        prev = Some(s.duration);
    }
    let mut fp_budget = MAX_FINGERPRINTS;
    for cluster in clusters.into_iter().filter(|c| c.len() > 1) {
        let mut taken = std::collections::HashSet::new();
        // Pass 2: acoustic.
        let printable: Vec<&DupSong> = cluster.iter().copied().filter(|s| s.path.as_ref().is_some_and(|p| std::path::Path::new(p).exists())).collect();
        if printable.len() > 1 && printable.len() <= MAX_ACOUSTIC_CLUSTER {
            let mut vecs: Vec<(String, Vec<Vec<f32>>)> = Vec::new();
            for s in &printable {
                if fp_budget == 0 {
                    break;
                }
                if let Some(v) = crate::analysis::audio_fingerprint(s.path.clone().unwrap(), cache_dir.clone(), None) {
                    vecs.push((s.id.clone(), v));
                    fp_budget -= 1;
                }
            }
            let mut uf = Uf(vecs.iter().map(|(id, _)| (id.clone(), id.clone())).collect());
            for i in 0..vecs.len() {
                for j in i + 1..vecs.len() {
                    if crate::analysis::fingerprint_similarity(vecs[i].1.clone(), vecs[j].1.clone()) >= MATCH_THRESHOLD {
                        uf.union(&vecs[i].0, &vecs[j].0);
                    }
                }
            }
            let mut by_root: HashMap<String, Vec<String>> = HashMap::new();
            for (id, _) in &vecs {
                by_root.entry(uf.find(id)).or_default().push(id.clone());
            }
            for ids in by_root.into_values().filter(|v| v.len() > 1) {
                taken.extend(ids.iter().cloned());
                groups.push(DupGroup { song_ids: ids, reason: DupReason::AcousticMatch });
            }
        }
        // Pass 3: title + artist.
        let leftover: Vec<&DupSong> = cluster.iter().copied().filter(|s| !taken.contains(&s.id)).collect();
        let mut by_key: HashMap<String, Vec<&DupSong>> = HashMap::new();
        let mut feat: HashMap<String, Option<String>> = HashMap::new();
        let mut parts: HashMap<String, (String, String)> = HashMap::new();
        for s in &leftover {
            let (t, a) = (dup_normalize(s.title.clone()), dup_normalize_artist(s.artist.clone()));
            if t.is_empty() || a.is_empty() {
                continue;
            }
            let f = dup_feature_name(s.title.clone());
            let key = format!("{t}|{a}|{}", f.clone().unwrap_or_default());
            by_key.entry(key.clone()).or_default().push(s);
            feat.insert(key.clone(), f);
            parts.insert(key, (t, a));
        }
        let keys: Vec<String> = by_key.keys().cloned().collect();
        let mut uf = Uf(keys.iter().map(|k| (k.clone(), k.clone())).collect());
        let compatible = |a: &str, b: &str| match (feat.get(a).cloned().flatten(), feat.get(b).cloned().flatten()) {
            (Some(x), Some(y)) => x == y || near_match(&x, &y),
            _ => true,
        };
        for i in 0..keys.len() {
            for j in i + 1..keys.len() {
                let (pi, pj) = (&parts[&keys[i]], &parts[&keys[j]]);
                if pi.1 == pj.1 && compatible(&keys[i], &keys[j]) && (pi.0 == pj.0 || near_match(&pi.0, &pj.0)) {
                    uf.union(&keys[i], &keys[j]);
                }
            }
        }
        let mut by_root: HashMap<String, Vec<&DupSong>> = HashMap::new();
        for k in &keys {
            by_root.entry(uf.find(k)).or_default().extend(by_key[k].iter().copied());
        }
        for m in by_root.into_values().filter(|v| v.len() > 1) {
            let (lo, hi) = m.iter().fold((f64::MAX, f64::MIN), |(lo, hi), s| (lo.min(s.duration), hi.max(s.duration)));
            if hi - lo > DURATION_TOLERANCE {
                continue;
            }
            groups.push(DupGroup { song_ids: m.iter().map(|s| s.id.clone()).collect(), reason: DupReason::SameTitleAndArtist });
        }
    }
    groups.sort_by(|a, b| b.song_ids.len().cmp(&a.song_ids.len()));
    groups
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
    #[test]
    fn groups_title_matches_within_duration() {
        let s = |id: &str, t: &str, d: f64| DupSong { id: id.into(), title: t.into(), artist: "Band".into(), duration: d, path: None, source_track_id: None };
        let g = find_duplicates(vec![s("1", "Song (Official Video)", 200.0), s("2", "Song", 201.0), s("3", "Song", 260.0), s("4", "Other", 200.5)], String::new());
        assert_eq!(g.len(), 1);
        assert_eq!(g[0].reason, DupReason::SameTitleAndArtist);
        let mut ids = g[0].song_ids.clone();
        ids.sort();
        assert_eq!(ids, vec!["1", "2"]);
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
