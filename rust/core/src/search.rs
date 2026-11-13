//! Lumisound library search: songs, artists, albums, playlists and lyrics
//! from one query, ranked, with highlight ranges.
//!
//! Text is folded for matching (lower case, accents removed, punctuation
//! dropped) while every folded character remembers where it came from, so
//! highlights land on the original text (as UTF-16 offsets, which is what
//! Swift's `String.Index(utf16Offset:in:)` takes).
//!
//! A query matches when every word matches somewhere (title, artist, album
//! or genre). Per word: exact word 3, prefix 2.2 for the word being typed
//! (1.6 otherwise), one or two typos 1.2, inside a word 0.8; title counts
//! most. A phrase that appears as typed, an exact title and plays /
//! favourites add on top. Lyrics are searched line by line from the app's
//! Lyrics folder (`<id>.lrc` / `<id>.txt`); a hit on a synced line carries
//! its time so the app can start the song right there.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use unicode_normalization::UnicodeNormalization;

// ---- records ----------------------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug)]
pub struct SearchSongInput {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub genre: String,
    pub plays: u32,
    pub favorite: bool,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct SearchPlaylistInput {
    pub id: String,
    pub name: String,
    pub song_ids: Vec<String>,
}

/// A highlight: UTF-16 offsets into the original string.
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq)]
pub struct SearchRange {
    pub start: u32,
    pub end: u32,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct SongHit {
    pub id: String,
    pub score: f64,
    pub title: Vec<SearchRange>,
    pub artist: Vec<SearchRange>,
    pub album: Vec<SearchRange>,
    /// Where the best match was: "title", "artist", "album" or "genre".
    pub matched_in: String,
}

/// An artist, album or playlist.
#[derive(uniffi::Record, Clone, Debug)]
pub struct GroupHit {
    pub key: String,
    pub name: String,
    pub subtitle: String,
    pub count: u32,
    /// A song whose artwork stands for the group.
    pub art_song_id: Option<String>,
    /// Songs in the group, most played first (max 100).
    pub song_ids: Vec<String>,
    pub name_ranges: Vec<SearchRange>,
    pub score: f64,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct LyricHit {
    pub song_id: String,
    pub line: String,
    pub ranges: Vec<SearchRange>,
    /// Seconds into the song for a synced (LRC) line.
    pub time: Option<f64>,
    pub score: f64,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct SearchResults {
    pub query: String,
    /// "song", "artist", "album", "playlist" or "" (nothing found): which
    /// list's first entry is the overall best match.
    pub top_kind: String,
    pub songs: Vec<SongHit>,
    pub artists: Vec<GroupHit>,
    pub albums: Vec<GroupHit>,
    pub playlists: Vec<GroupHit>,
    pub lyrics: Vec<LyricHit>,
    /// Songs that matched (the list is capped).
    pub total_songs: u32,
    pub elapsed_ms: f64,
}

// ---- folded text ------------------------------------------------------------------------------

#[derive(Clone, Debug, Default)]
struct Tok {
    start: usize,
    end: usize,
    text: String,
    chars: Vec<char>,
}

/// Folded text with a map back to the original.
#[derive(Clone, Debug, Default)]
struct Folded {
    chars: Vec<char>,
    /// UTF-16 offset in the original of each folded char, plus the end.
    map: Vec<u32>,
    tokens: Vec<Tok>,
    joined: String,
}

fn is_mark(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}

/// Scripts written without spaces: matched inside text, not by word.
fn is_cjk(c: char) -> bool {
    matches!(c as u32, 0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF)
}

fn fold(s: &str) -> Folded {
    let mut f = Folded::default();
    let mut off = 0u32;
    for c in s.chars() {
        let here = off;
        off += c.len_utf16() as u32;
        let special: Option<&str> = match c {
            'ß' => Some("ss"),
            'æ' | 'Æ' => Some("ae"),
            'ø' | 'Ø' => Some("o"),
            'đ' | 'Đ' => Some("d"),
            'ł' | 'Ł' => Some("l"),
            '&' => Some("&"),
            _ => None,
        };
        if let Some(rep) = special {
            for r in rep.chars() {
                f.chars.push(r);
                f.map.push(here);
            }
            continue;
        }
        for d in c.nfd() {
            if is_mark(d) {
                continue;
            }
            for l in d.to_lowercase() {
                f.chars.push(if l.is_alphanumeric() || l == '&' { l } else { ' ' });
                f.map.push(here);
            }
        }
    }
    f.map.push(off);
    let mut i = 0;
    while i < f.chars.len() {
        if f.chars[i] == ' ' {
            i += 1;
            continue;
        }
        let start = i;
        while i < f.chars.len() && f.chars[i] != ' ' {
            i += 1;
        }
        let text: String = f.chars[start..i].iter().collect();
        if text != "&" {
            f.tokens.push(Tok { start, end: i, chars: f.chars[start..i].to_vec(), text });
        }
    }
    f.joined = f.tokens.iter().map(|t| t.text.as_str()).collect::<Vec<_>>().join(" ");
    f
}

impl Folded {
    fn range(&self, s: usize, e: usize) -> SearchRange {
        SearchRange { start: self.map[s.min(self.map.len() - 1)], end: self.map[e.min(self.map.len() - 1)] }
    }

    /// Folded-char start of the `n`th occurrence position of `needle` in `chars`.
    fn find(&self, needle: &[char], from: usize) -> Option<usize> {
        if needle.is_empty() || needle.len() > self.chars.len() {
            return None;
        }
        (from..=self.chars.len() - needle.len()).find(|&i| self.chars[i..i + needle.len()] == *needle)
    }
}

/// Optimal string alignment distance, stopping early past `max`. Three
/// rolling rows on the stack (words are short); long words fall back to
/// "no typo match".
fn osa(a: &[char], b: &[char], max: usize) -> usize {
    const W: usize = 48;
    if a.len().abs_diff(b.len()) > max {
        return max + 1;
    }
    let (n, m) = (a.len(), b.len());
    if m + 1 > W || n == 0 || m == 0 {
        return if n.max(m) <= max { n.max(m) } else { max + 1 };
    }
    let mut prev2 = [0usize; W];
    let mut prev: [usize; W] = std::array::from_fn(|j| j);
    let mut cur = [0usize; W];
    for i in 1..=n {
        cur[0] = i;
        let mut row_min = cur[0];
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            let mut v = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                v = v.min(prev2[j - 2] + 1);
            }
            cur[j] = v;
            row_min = row_min.min(v);
        }
        if row_min > max {
            return max + 1;
        }
        prev2 = prev;
        prev = cur;
    }
    prev[m]
}

fn char_bit(c: char) -> u64 {
    match c {
        'a'..='z' => 1 << (c as u32 - 'a' as u32),
        '0'..='9' => 1 << (26 + c as u32 - '0' as u32),
        ' ' => 0,
        _ => 1 << (36 + (c as u32 % 28)),
    }
}

fn char_mask(s: &str) -> u64 {
    s.chars().fold(0, |m, c| m | char_bit(c))
}

/// Whether a song can possibly match every word (no false negatives).
fn may_match(blob: &str, mask: u64, q: &[QWord]) -> bool {
    q.iter().all(|w| {
        if w.cjk {
            return blob.contains(w.text.as_str());
        }
        let budget = typo_budget(w.chars.len());
        if budget == 0 {
            return blob.contains(w.text.as_str());
        }
        let missing = w.chars.iter().filter(|c| mask & char_bit(**c) == 0).count();
        missing <= budget
    })
}

fn typo_budget(len: usize) -> usize {
    match len {
        0..=3 => 0,
        4..=7 => 1,
        _ => 2,
    }
}

/// Best match of one query word in a field: (score, folded start, end).
/// A query word, prepared once per query.
struct QWord {
    text: String,
    chars: Vec<char>,
    cjk: bool,
}

/// More than `budget` of `w`'s letters missing from `t`: no typo match.
fn too_different(w: &[char], t: &[char], budget: usize) -> bool {
    let mut missing = 0;
    for c in w {
        if !t.contains(c) {
            missing += 1;
            if missing > budget {
                return true;
            }
        }
    }
    false
}

fn match_word(f: &Folded, q: &QWord, last: bool) -> Option<(f64, usize, usize)> {
    let (w, wc) = (q.text.as_str(), &q.chars);
    if q.cjk {
        return f.find(&wc, 0).map(|i| (2.0, i, i + wc.len()));
    }
    let mut best: Option<(f64, usize, usize)> = None;
    let mut take = |s: f64, a: usize, b: usize| {
        if best.is_none_or(|x| s > x.0) {
            best = Some((s, a, b));
        }
    };
    let budget = typo_budget(wc.len());
    for t in &f.tokens {
        if t.text == w {
            take(3.0, t.start, t.end);
            continue;
        }
        if t.text.starts_with(w) {
            take(if last { 2.2 } else { 1.6 }, t.start, t.start + wc.len());
            continue;
        }
        if budget > 0 && t.chars.len() + budget >= wc.len() && !too_different(wc, &t.chars, budget) {
            let tc = &t.chars;
            let full = tc.len().abs_diff(wc.len()) <= budget && osa(wc, tc, budget) <= budget;
            // The word being typed may be a misspelt prefix ("beatls" → "beatles").
            let pre = last && tc.len() > wc.len() && osa(wc, &tc[..wc.len()], budget) <= budget;
            if full || pre {
                take(1.2, t.start, if full { t.end } else { t.start + wc.len() });
                continue;
            }
        }
        if wc.len() >= 3 {
            if let Some(p) = t.text.find(w) {
                let s = t.start + t.text[..p].chars().count();
                take(0.8, s, s + wc.len());
            }
        }
    }
    best
}

fn merge(mut r: Vec<SearchRange>) -> Vec<SearchRange> {
    r.sort_by_key(|x| x.start);
    let mut out: Vec<SearchRange> = Vec::with_capacity(r.len());
    for x in r {
        match out.last_mut() {
            Some(l) if x.start <= l.end => l.end = l.end.max(x.end),
            _ => out.push(x),
        }
    }
    out
}

/// Every query word matched against one field set; None unless all match.
/// Returns (score, ranges per field, index of the strongest field).
fn score_fields(q: &[QWord], fields: &[(&Folded, f64)]) -> Option<(f64, Vec<Vec<SearchRange>>, usize)> {
    score_fields_with(q, fields, true)
}

/// Like `score_fields`; `ranges` off skips building highlights (ranking pass).
fn score_fields_with(q: &[QWord], fields: &[(&Folded, f64)], want_ranges: bool) -> Option<(f64, Vec<Vec<SearchRange>>, usize)> {
    let mut total = 0.0;
    let mut ranges = if want_ranges { vec![Vec::new(); fields.len()] } else { Vec::new() };
    let mut field_score = [0.0f64; 8];
    for (k, w) in q.iter().enumerate() {
        let last = k + 1 == q.len();
        let mut best: Option<(f64, usize, usize, usize)> = None;
        for (fi, (f, weight)) in fields.iter().enumerate() {
            if let Some((s, a, b)) = match_word(f, w, last) {
                let s = s * weight;
                if best.is_none_or(|x| s > x.0) {
                    best = Some((s, fi, a, b));
                }
            }
        }
        let (s, fi, a, b) = best?;
        total += s;
        field_score[fi.min(7)] += s;
        if want_ranges {
            ranges[fi].push(fields[fi].0.range(a, b));
        }
    }
    let strongest = field_score[..fields.len().min(8)].iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).map(|x| x.0).unwrap_or(0);
    Some((total, ranges.into_iter().map(merge).collect(), strongest))
}

/// Bonus when the folded query appears as a phrase / is the whole field.
fn phrase_bonus(f: &Folded, phrase: &str, exact: f64, contained: f64) -> f64 {
    if phrase.is_empty() || f.joined.is_empty() {
        0.0
    } else if f.joined == phrase {
        exact
    } else if phrase.contains(' ') && f.joined.contains(phrase) {
        contained
    } else {
        0.0
    }
}

// ---- index ------------------------------------------------------------------------------------

struct SongEntry {
    /// Every folded token of every field, space-joined, and which
    /// characters occur: a cheap reject before per-token matching.
    blob: String,
    mask: u64,
    input: SearchSongInput,
    title: Folded,
    artist: Folded,
    album: Folded,
    genre: Folded,
    boost: f64,
}

struct Group {
    key: String,
    name: String,
    folded: Folded,
    subtitle: String,
    songs: Vec<usize>,
}

struct LyricLine {
    time: Option<f64>,
    text: String,
    folded: Folded,
}

#[derive(Default)]
struct Index {
    songs: Vec<SongEntry>,
    by_id: HashMap<String, usize>,
    artists: Vec<Group>,
    albums: Vec<Group>,
    playlists: Vec<(String, Group)>,
    lyrics: HashMap<String, Vec<LyricLine>>,
}

/// Splits "A feat. B", "A, B", "A & B", "A x B" into names.
fn artist_names(s: &str) -> Vec<String> {
    let lower = s.to_lowercase();
    let mut cuts: Vec<(usize, usize)> = Vec::new();
    for sep in [" feat. ", " feat ", " ft. ", " ft ", " featuring ", ", ", " & ", " x ", " × ", "; ", " / "] {
        let mut from = 0;
        while let Some(p) = lower[from..].find(sep) {
            cuts.push((from + p, from + p + sep.len()));
            from += p + sep.len();
        }
    }
    cuts.sort();
    let mut out = Vec::new();
    let mut at = 0;
    for (a, b) in cuts {
        if a < at || !s.is_char_boundary(a) || !s.is_char_boundary(b) {
            continue;
        }
        out.push(s[at..a].trim().to_string());
        at = b;
    }
    out.push(s[at..].trim().to_string());
    out.retain(|n| !n.is_empty());
    out
}

fn by_plays(idx: &[SongEntry], v: &mut [usize]) {
    v.sort_by(|a, b| idx[*b].input.plays.cmp(&idx[*a].input.plays).then(idx[*b].input.favorite.cmp(&idx[*a].input.favorite)));
}

fn build(songs: Vec<SearchSongInput>, playlists: Vec<SearchPlaylistInput>) -> Index {
    let mut idx = Index::default();
    let mut artist_keys: HashMap<String, usize> = HashMap::new();
    let mut album_keys: HashMap<String, usize> = HashMap::new();
    for s in songs {
        if idx.by_id.contains_key(&s.id) {
            continue;
        }
        let i = idx.songs.len();
        idx.by_id.insert(s.id.clone(), i);
        for name in artist_names(&s.artist) {
            let f = fold(&name);
            if f.joined.is_empty() {
                continue;
            }
            let g = *artist_keys.entry(f.joined.clone()).or_insert_with(|| {
                idx.artists.push(Group { key: f.joined.clone(), name: name.clone(), folded: f.clone(), subtitle: String::new(), songs: vec![] });
                idx.artists.len() - 1
            });
            idx.artists[g].songs.push(i);
        }
        let album = fold(&s.album);
        if !album.joined.is_empty() {
            let primary = artist_names(&s.artist).into_iter().next().unwrap_or_default();
            let key = format!("{}|{}", album.joined, fold(&primary).joined);
            let g = *album_keys.entry(key.clone()).or_insert_with(|| {
                idx.albums.push(Group { key, name: s.album.clone(), folded: album.clone(), subtitle: primary.clone(), songs: vec![] });
                idx.albums.len() - 1
            });
            idx.albums[g].songs.push(i);
        }
        let boost = (s.plays as f64).ln_1p() * 0.15 + if s.favorite { 0.3 } else { 0.0 };
        let (title, artist, genre) = (fold(&s.title), fold(&s.artist), fold(&s.genre));
        let blob = [&title.joined, &artist.joined, &album.joined, &genre.joined].iter().map(|x| x.as_str()).collect::<Vec<_>>().join(" ");
        let mask = char_mask(&blob);
        idx.songs.push(SongEntry { blob, mask, title, artist, album, genre, boost, input: s });
    }
    let songs = &idx.songs;
    for g in idx.artists.iter_mut().chain(idx.albums.iter_mut()) {
        by_plays(songs, &mut g.songs);
    }
    for p in playlists {
        let members: Vec<usize> = p.song_ids.iter().filter_map(|id| idx.by_id.get(id).copied()).collect();
        let n = p.song_ids.len();
        idx.playlists.push((p.id.clone(), Group { key: p.id, folded: fold(&p.name), name: p.name, subtitle: if n == 1 { "1 song".into() } else { format!("{n} songs") }, songs: members }));
    }
    idx
}

/// File-name stem the app uses for a song's lyrics (LyricsSyncLockService.fileStem).
pub fn lyrics_stem(id: &str) -> String {
    id.chars().map(|c| if "/:\\*?\"<>|".contains(c) { '_' } else { c }).collect()
}

/// Lines of an LRC (with times) or plain lyrics file.
pub fn parse_lyrics(text: &str) -> Vec<(Option<f64>, String)> {
    let mut out = Vec::new();
    for raw in text.lines() {
        let mut rest = raw.trim();
        let mut times = Vec::new();
        while let Some(stripped) = rest.strip_prefix('[') {
            let Some(close) = stripped.find(']') else { break };
            let tag = &stripped[..close];
            rest = stripped[close + 1..].trim_start();
            let mut parts = tag.splitn(2, ':');
            let (m, s) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
            match (m.trim().parse::<f64>(), s.trim().parse::<f64>()) {
                (Ok(m), Ok(s)) => times.push(m * 60.0 + s),
                _ => {
                    // Metadata tag ([ar:…], [ti:…]): not a lyric line.
                    if times.is_empty() {
                        rest = "";
                    }
                }
            }
        }
        // Word-level timing (<mm:ss.xx>) inside enhanced LRC lines.
        let line: String = {
            let mut s = String::with_capacity(rest.len());
            let mut skip = false;
            for c in rest.chars() {
                match c {
                    '<' => skip = true,
                    '>' if skip => skip = false,
                    _ if !skip => s.push(c),
                    _ => {}
                }
            }
            s.trim().to_string()
        };
        if line.is_empty() {
            continue;
        }
        if times.is_empty() {
            out.push((None, line));
        } else {
            for t in times {
                out.push((Some(t), line.clone()));
            }
        }
    }
    out.sort_by(|a, b| a.0.unwrap_or(f64::MAX).total_cmp(&b.0.unwrap_or(f64::MAX)));
    out
}

// ---- engine -----------------------------------------------------------------------------------

/// The search engine (one per app). Feed it the library, then query on
/// every keystroke; queries are cheap (folding happened at index time).
#[derive(uniffi::Object, Default)]
pub struct LibrarySearch {
    index: RwLock<Index>,
}

const SONG_LIMIT: usize = 200;
const PARALLEL_FROM: usize = 4_000;

/// A song's fields with their weights (title counts most).
fn song_fields(s: &SongEntry) -> [(&Folded, f64); 4] {
    [(&s.title, 1.25), (&s.artist, 1.0), (&s.album, 0.8), (&s.genre, 0.5)]
}

#[uniffi::export]
impl LibrarySearch {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Replaces the songs and playlists (lyrics already loaded are kept).
    pub fn set_library(&self, songs: Vec<SearchSongInput>, playlists: Vec<SearchPlaylistInput>) {
        let mut fresh = build(songs, playlists);
        let mut idx = self.index.write().unwrap_or_else(|e| e.into_inner());
        fresh.lyrics = std::mem::take(&mut idx.lyrics);
        *idx = fresh;
    }

    /// Reads every `<stem>.lrc` / `<stem>.txt` in `dir` for the songs in
    /// the library (LRC wins). Returns how many songs have lyrics indexed.
    pub fn load_lyrics(&self, dir: String) -> u32 {
        let ids: Vec<String> = {
            let idx = self.index.read().unwrap_or_else(|e| e.into_inner());
            idx.songs.iter().map(|s| s.input.id.clone()).collect()
        };
        let dir = std::path::Path::new(&dir);
        let mut lyrics = HashMap::new();
        for id in ids {
            let stem = lyrics_stem(&id);
            let text = std::fs::read_to_string(dir.join(format!("{stem}.lrc"))).or_else(|_| std::fs::read_to_string(dir.join(format!("{stem}.txt"))));
            let Ok(text) = text else { continue };
            let lines: Vec<LyricLine> = parse_lyrics(&text).into_iter().map(|(time, text)| LyricLine { time, folded: fold(&text), text }).collect();
            if !lines.is_empty() {
                lyrics.insert(id, lines);
            }
        }
        let n = lyrics.len() as u32;
        self.index.write().unwrap_or_else(|e| e.into_inner()).lyrics = lyrics;
        n
    }

    /// Adds or replaces one song's lyrics (after a fetch or an edit).
    pub fn set_lyrics(&self, song_id: String, text: String) {
        let lines: Vec<LyricLine> = parse_lyrics(&text).into_iter().map(|(time, text)| LyricLine { time, folded: fold(&text), text }).collect();
        let mut idx = self.index.write().unwrap_or_else(|e| e.into_inner());
        if lines.is_empty() {
            idx.lyrics.remove(&song_id);
        } else {
            idx.lyrics.insert(song_id, lines);
        }
    }

    pub fn song_count(&self) -> u32 {
        self.index.read().map(|i| i.songs.len() as u32).unwrap_or(0)
    }

    pub fn lyrics_count(&self) -> u32 {
        self.index.read().map(|i| i.lyrics.len() as u32).unwrap_or(0)
    }

    /// Everything matching `text`. `include_lyrics` off skips the lyrics scan.
    pub fn query(&self, text: String, include_lyrics: bool) -> SearchResults {
        let t0 = std::time::Instant::now();
        let qf = fold(&text);
        let q: Vec<QWord> = qf.tokens.iter().map(|t| QWord { text: t.text.clone(), chars: t.chars.clone(), cjk: t.chars.iter().any(|c| is_cjk(*c)) }).collect();
        let mut res = SearchResults { query: text.clone(), ..Default::default() };
        if q.is_empty() {
            return res;
        }
        let phrase = qf.joined.clone();
        let idx = self.index.read().unwrap_or_else(|e| e.into_inner());

        // Songs: rank everything cheaply, then build the top ones in full.
        let rank = |from: usize, songs: &[SongEntry]| -> Vec<(f64, usize)> {
            let mut out = Vec::new();
            for (k, s) in songs.iter().enumerate() {
                if !may_match(&s.blob, s.mask, &q) {
                    continue;
                }
                let Some((score, _, _)) = score_fields_with(&q, &song_fields(s), false) else { continue };
                let bonus = phrase_bonus(&s.title, &phrase, 4.0, 2.0) + phrase_bonus(&s.artist, &phrase, 1.5, 1.0);
                out.push((score + bonus + s.boost, from + k));
            }
            out
        };
        // Big libraries rank on several cores.
        let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).min(6);
        let mut ranked: Vec<(f64, usize)> = if idx.songs.len() >= PARALLEL_FROM && threads > 1 {
            let chunk = idx.songs.len().div_ceil(threads);
            std::thread::scope(|sc| {
                let handles: Vec<_> = idx.songs.chunks(chunk).enumerate().map(|(c, part)| {
                    let rank = &rank;
                    sc.spawn(move || rank(c * chunk, part))
                }).collect();
                handles.into_iter().flat_map(|h| h.join().unwrap_or_default()).collect()
            })
        } else {
            rank(0, &idx.songs)
        };
        res.total_songs = ranked.len() as u32;
        let by_score = |a: &(f64, usize), b: &(f64, usize)| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1));
        if ranked.len() > SONG_LIMIT {
            ranked.select_nth_unstable_by(SONG_LIMIT - 1, by_score);
            ranked.truncate(SONG_LIMIT);
        }
        ranked.sort_by(by_score);
        res.songs = ranked.iter().filter_map(|&(score, i)| {
            let s = &idx.songs[i];
            let (_, ranges, strongest) = score_fields(&q, &song_fields(s))?;
            let mut ranges = ranges.into_iter();
            Some(SongHit {
                id: s.input.id.clone(),
                score,
                title: ranges.next().unwrap_or_default(),
                artist: ranges.next().unwrap_or_default(),
                album: ranges.next().unwrap_or_default(),
                matched_in: ["title", "artist", "album", "genre"][strongest].into(),
            })
        }).collect();

        // Artists / albums / playlists by name.
        let group = |g: &Group, cap: usize| -> Option<GroupHit> {
            let (score, ranges, _) = score_fields(&q, &[(&g.folded, 1.0)])?;
            let size = (g.songs.len() as f64).ln_1p() * 0.25;
            let plays: f64 = g.songs.iter().take(20).map(|&i| idx.songs[i].boost).sum::<f64>() / 20.0;
            Some(GroupHit {
                key: g.key.clone(),
                name: g.name.clone(),
                subtitle: g.subtitle.clone(),
                count: g.songs.len() as u32,
                art_song_id: g.songs.first().map(|&i| idx.songs[i].input.id.clone()),
                song_ids: g.songs.iter().take(cap).map(|&i| idx.songs[i].input.id.clone()).collect(),
                name_ranges: ranges.into_iter().next().unwrap_or_default(),
                score: score + phrase_bonus(&g.folded, &phrase, 4.0, 2.0) + size + plays,
            })
        };
        let mut artists: Vec<GroupHit> = idx.artists.iter().filter_map(|g| {
            let mut h = group(g, 100)?;
            h.subtitle = if g.songs.len() == 1 { "1 song".into() } else { format!("{} songs", g.songs.len()) };
            Some(h)
        }).collect();
        let mut albums: Vec<GroupHit> = idx.albums.iter().filter_map(|g| group(g, 100)).collect();
        let mut playlists: Vec<GroupHit> = idx.playlists.iter().filter_map(|(_, g)| group(g, 100)).collect();
        for v in [&mut artists, &mut albums, &mut playlists] {
            v.sort_by(|a, b| b.score.total_cmp(&a.score));
            v.truncate(30);
        }

        // Lyrics: every word inside one line (substring), phrase first.
        if include_lyrics && phrase.chars().count() >= 3 {
            let words: Vec<&Vec<char>> = q.iter().map(|w| &w.chars).collect();
            let phrase_chars: Vec<char> = phrase.chars().collect();
            let mut lh: Vec<LyricHit> = Vec::new();
            for (id, lines) in &idx.lyrics {
                let mut best: Option<LyricHit> = None;
                for l in lines {
                    let f = &l.folded;
                    let mut ranges = Vec::new();
                    let mut ok = true;
                    for w in &words {
                        match f.find(w, 0) {
                            Some(p) => ranges.push(f.range(p, p + w.len())),
                            None => {
                                ok = false;
                                break;
                            }
                        }
                    }
                    if !ok {
                        continue;
                    }
                    // Folded line text has single spaces only between tokens, so
                    // compare the phrase against the joined form.
                    let phrase_hit = f.joined.contains(&phrase);
                    let score = 1.0 + if phrase_hit { 2.0 } else { 0.0 } + if l.time.is_some() { 0.2 } else { 0.0 };
                    if phrase_hit {
                        if let Some(p) = f.find(&phrase_chars, 0) {
                            ranges = vec![f.range(p, p + phrase_chars.len())];
                        }
                    }
                    if best.as_ref().is_none_or(|b| score > b.score) {
                        best = Some(LyricHit { song_id: id.clone(), line: l.text.clone(), ranges: merge(ranges), time: l.time, score });
                    }
                }
                if let Some(mut b) = best {
                    if let Some(&i) = idx.by_id.get(id) {
                        b.score += idx.songs[i].boost;
                    }
                    lh.push(b);
                }
            }
            lh.sort_by(|a, b| b.score.total_cmp(&a.score));
            lh.truncate(30);
            res.lyrics = lh;
        }

        // Overall best: a strong artist/album/playlist name beats a song
        // that only matched loosely.
        let cands = [
            ("song", res.songs.first().map(|h| h.score)),
            ("artist", artists.first().map(|h| h.score + 0.5)),
            ("album", albums.first().map(|h| h.score)),
            ("playlist", playlists.first().map(|h| h.score)),
        ];
        res.top_kind = cands.iter().filter_map(|(k, s)| s.map(|s| (*k, s))).max_by(|a, b| a.1.total_cmp(&b.1)).map(|x| x.0.to_string()).unwrap_or_default();
        res.artists = artists;
        res.albums = albums;
        res.playlists = playlists;
        res.elapsed_ms = t0.elapsed().as_secs_f64() * 1000.0;
        res
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn song(id: &str, title: &str, artist: &str, album: &str, plays: u32) -> SearchSongInput {
        SearchSongInput { id: id.into(), title: title.into(), artist: artist.into(), album: album.into(), genre: "Pop".into(), plays, favorite: false }
    }

    fn lib() -> Arc<LibrarySearch> {
        let s = LibrarySearch::new();
        s.set_library(
            vec![
                song("1", "Hey Jude", "The Beatles", "Past Masters", 10),
                song("2", "Let It Be", "The Beatles", "Let It Be", 3),
                song("3", "Café del Mar", "Energy 52", "Café del Mar", 0),
                song("4", "Señorita", "Shawn Mendes & Camila Cabello", "Señorita", 50),
                song("5", "Judas", "Lady Gaga", "Born This Way", 1),
                song("6", "夜に駆ける", "YOASOBI", "THE BOOK", 2),
                song("7", "Blinding Lights", "The Weeknd", "After Hours", 99),
            ],
            vec![SearchPlaylistInput { id: "p1".into(), name: "Late Night Drive".into(), song_ids: vec!["7".into(), "1".into()] }],
        );
        s
    }

    #[test]
    fn ranks_exact_then_prefix() {
        let r = lib().query("jude".into(), false);
        assert_eq!(r.songs[0].id, "1");
        assert!(r.songs.iter().any(|h| h.id == "5"), "Judas by prefix");
        // Typing a prefix finds it.
        assert_eq!(lib().query("blind".into(), false).songs[0].id, "7");
    }

    #[test]
    fn folds_accents_and_case() {
        let r = lib().query("cafe del".into(), false);
        assert_eq!(r.songs[0].id, "3");
        // Highlight lands on the original "Café" (4 UTF-16 units) and "del".
        assert_eq!(r.songs[0].title, vec![SearchRange { start: 0, end: 4 }, SearchRange { start: 5, end: 8 }]);
        assert_eq!(lib().query("SENORITA".into(), false).songs[0].id, "4");
    }

    #[test]
    fn tolerates_typos() {
        assert_eq!(lib().query("beatels".into(), false).songs.len(), 2);
        assert_eq!(lib().query("blindng lights".into(), false).songs[0].id, "7");
    }

    #[test]
    fn needs_every_word() {
        let r = lib().query("beatles jude".into(), false);
        assert_eq!(r.songs.len(), 1);
        assert_eq!(r.songs[0].id, "1");
        assert!(lib().query("beatles weeknd".into(), false).songs.is_empty());
    }

    #[test]
    fn groups_artists_albums_playlists() {
        let r = lib().query("camila".into(), false);
        assert_eq!(r.artists[0].name, "Camila Cabello");
        assert_eq!(r.top_kind, "artist");
        let r = lib().query("beatles".into(), false);
        assert_eq!(r.artists[0].name, "The Beatles");
        assert_eq!(r.artists[0].count, 2);
        assert_eq!(r.artists[0].song_ids[0], "1", "most played first");
        let r = lib().query("late night".into(), false);
        assert_eq!(r.playlists[0].key, "p1");
        assert_eq!(r.top_kind, "playlist");
        assert_eq!(lib().query("past masters".into(), false).albums[0].name, "Past Masters");
    }

    #[test]
    fn matches_inside_cjk() {
        assert_eq!(lib().query("駆ける".into(), false).songs[0].id, "6");
    }

    #[test]
    fn searches_lyrics_with_times() {
        let s = lib();
        s.set_lyrics("1".into(), "[ar:The Beatles]\n[00:01.00]Hey Jude, don't make it bad\n[00:07.50]Take a sad song and make it better".into());
        s.set_lyrics("2".into(), "When I find myself in times of trouble\nMother Mary comes to me".into());
        let r = s.query("sad song".into(), true);
        assert_eq!(r.lyrics.len(), 1);
        assert_eq!(r.lyrics[0].song_id, "1");
        assert_eq!(r.lyrics[0].time, Some(7.5));
        assert_eq!(r.lyrics[0].line, "Take a sad song and make it better");
        assert_eq!(r.lyrics[0].ranges, vec![SearchRange { start: 7, end: 15 }]);
        let r = s.query("mother mary".into(), true);
        assert_eq!(r.lyrics[0].song_id, "2");
        assert_eq!(r.lyrics[0].time, None);
        assert!(s.query("mother mary".into(), false).lyrics.is_empty());
    }

    #[test]
    fn loads_lyrics_folder() {
        let dir = std::env::temp_dir().join(format!("lyr-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let s = LibrarySearch::new();
        s.set_library(vec![song("local:Imported Music/a.mp3", "A", "B", "C", 0)], vec![]);
        std::fs::write(dir.join(format!("{}.lrc", lyrics_stem("local:Imported Music/a.mp3"))), "[00:02.00]shine on").unwrap();
        assert_eq!(s.load_lyrics(dir.to_string_lossy().into()), 1);
        assert_eq!(s.query("shine".into(), true).lyrics[0].time, Some(2.0));
        // A new library keeps the lyrics.
        s.set_library(vec![song("local:Imported Music/a.mp3", "A", "B", "C", 0)], vec![]);
        assert_eq!(s.lyrics_count(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn fast_on_a_big_library() {
        let s = LibrarySearch::new();
        let songs: Vec<SearchSongInput> = (0..20_000).map(|i| song(&i.to_string(), &format!("Track {i} midnight city"), &format!("Artist {}", i % 700), &format!("Album {}", i % 1500), i % 50)).collect();
        s.set_library(songs, vec![]);
        let t = std::time::Instant::now();
        for q in ["mid", "midnight ci", "artist 42", "albm 7", "zzz"] {
            let r = s.query(q.into(), false);
            eprintln!("  {q:<12} {:.1} ms, {} songs", r.elapsed_ms, r.total_songs);
        }
        let per = t.elapsed().as_secs_f64() * 1000.0 / 5.0;
        eprintln!("20k songs: {per:.1} ms per query");
        assert!(per < 100.0, "{per} ms");
    }
}
