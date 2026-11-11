//! Strata: Lumisound's third interface, composed in Rust.
//!
//! Classic and Lumen are SwiftUI screens. Strata is different in kind: every
//! screen — what sections it has, in which order, what each row says, what
//! a tap does — is decided here, and the theme (colours, type scale,
//! spacing, motion) is computed here too. Swift only draws the description
//! (`StrataScreen`) with a generic renderer and carries out the actions it
//! gets back. So the interface itself is Rust; SwiftUI is its display.
//!
//! Structure (not a restyle of the tab-bar apps): no tab bar. Screens are
//! layers ("strata") stacked under a persistent Now band; the bottom
//! command capsule searches and jumps between layers. Sections come in a
//! small set of editorial forms — Hero, Stack (layered offset cards),
//! Ribbon (wide cards), Ledger (numbered dense rows), Grid, Chips, Stats,
//! Note — so each screen reads like a magazine page rather than a list.
//!
//! The library is handed over once (`StrataCore::set_library`) and indexed
//! here; long sections are paged (`page`), so a 6 000-song library costs
//! one transfer, not one per screen.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, RwLock};

// ---- input ------------------------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct StrataSong {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub genre: String,
    pub year: String,
    pub duration: f64,
    /// Unix seconds (0 = unknown).
    pub added: f64,
    pub plays: u32,
    pub last_played: f64,
    pub favorite: bool,
    pub bpm: f64,
    /// Cloud / stream-only (not downloaded).
    pub remote: bool,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct StrataPlaylist {
    pub id: String,
    pub name: String,
    pub song_ids: Vec<String>,
    pub created: f64,
    pub folder: Option<String>,
}

// ---- output -----------------------------------------------------------------------------------

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq, Hash)]
pub enum StrataRoute {
    Home,
    Library { tab: String },
    Search { query: String },
    Album { key: String },
    Artist { name: String },
    Playlist { id: String },
    Genre { name: String },
    Favorites,
    History,
    Queue,
    You,
    /// Cloud: your uploaded library (empty query) or online search results.
    Cloud { query: String },
    Settings { page: String },
    Account,
    /// Pick a playlist for these songs.
    AddToPlaylist { ids: Vec<String> },
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum StrataAction {
    /// Play `ids` starting at `index` (shuffled when `shuffle`).
    Play { ids: Vec<String>, index: u32, shuffle: bool },
    /// Play a long list by reference: Swift asks `section_ids(route,
    /// section)` once on tap. (Every row of a 6 000-song list carrying all
    /// 6 000 ids was millions of strings across the FFI: the phone ran out
    /// of memory opening Library.)
    PlayFrom { route: StrataRoute, section: String, index: u32, shuffle: bool },
    PlayNext { ids: Vec<String> },
    AddToQueue { ids: Vec<String> },
    Open { route: StrataRoute },
    ToggleFavorite { id: String },
    /// Jump to queue position.
    QueueJump { index: u32 },
    /// New playlist (Swift asks for the name when `name` is None), with songs.
    CreatePlaylist { name: Option<String>, ids: Vec<String> },
    RenamePlaylist { id: String },
    DeletePlaylist { id: String },
    AddToPlaylist { playlist: String, ids: Vec<String> },
    RemoveFromPlaylist { playlist: String, id: String },
    /// Library tab sort order (kept by the core, persisted by Swift).
    SetSort { tab: String, sort: String },
    /// A setting changed (key as in the settings screens).
    SetSetting { key: String, value: StrataValue },
    /// Ask for text, then SetSetting(key, text).
    PromptSetting { key: String, title: String, value: String },
    /// Online result: stream now / download to the library.
    StreamPlay { id: String },
    StreamDownload { id: String },
    /// Play from the cloud library.
    CloudPlay { id: String },
    /// Open one of the full classic screens (rare advanced settings).
    OpenClassic { page: String },
    SignIn,
    SignOut,
    None,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum StrataValue {
    Flag { on: bool },
    Number { value: f64 },
    Text { value: String },
}

/// One option of a choice control.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StrataOption {
    pub value: String,
    pub label: String,
}

/// The control a settings row carries.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum StrataControl {
    Toggle { key: String, on: bool },
    Slider { key: String, value: f64, min: f64, max: f64, step: f64, unit: String },
    Choice { key: String, selected: String, options: Vec<StrataOption> },
    /// Colour swatches ("#RRGGBB" values).
    Swatches { key: String, selected: String, colors: Vec<String> },
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum StrataStyle {
    Hero,
    Stack,
    Ribbon,
    Ledger,
    Grid,
    Chips,
    Stats,
    Note,
    /// Settings rows (title, help, control).
    Controls,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StrataItem {
    pub id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub meta: Option<String>,
    /// Song id whose artwork represents this item.
    pub art: Option<String>,
    /// SF Symbol name for items without artwork.
    pub glyph: Option<String>,
    pub number: Option<u32>,
    pub emphasis: bool,
    pub action: StrataAction,
    /// Long-press / swipe action.
    pub secondary: Option<StrataAction>,
    /// Settings rows: the control drawn on the right.
    pub control: Option<StrataControl>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StrataSection {
    pub id: String,
    pub style: StrataStyle,
    pub title: Option<String>,
    pub caption: Option<String>,
    pub items: Vec<StrataItem>,
    /// Items available in total (`page` fetches beyond `items`).
    pub total: u32,
    pub more: Option<StrataAction>,
    /// Alphabet index letters for Ledger sections sorted by name…
    pub index: Vec<String>,
    /// …and the row each letter starts at (the rail can jump past what's loaded).
    pub index_positions: Vec<u32>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StrataScreen {
    pub route: StrataRoute,
    pub kicker: Option<String>,
    pub title: String,
    pub subtitle: Option<String>,
    /// Song id whose artwork tints the screen's head.
    pub art: Option<String>,
    /// Main actions shown under the title (Play, Shuffle...).
    pub actions: Vec<StrataItem>,
    pub sections: Vec<StrataSection>,
}

// ---- helpers ----------------------------------------------------------------------------------

fn fold(s: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    s.nfkd().filter(|c| !unicode_normalization::char::is_combining_mark(*c)).flat_map(char::to_lowercase).collect()
}

fn words(s: &str) -> Vec<String> {
    fold(s).split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(str::to_string).collect()
}

pub fn album_key(artist: &str, album: &str) -> String {
    format!("{}\u{1f}{}", fold(album).trim(), fold(artist).trim())
}

fn sort_key(s: &str) -> String {
    let f = fold(s);
    let f = f.trim();
    let f = f.strip_prefix("the ").unwrap_or(f);
    f.trim_start_matches(|c: char| !c.is_alphanumeric()).to_string()
}

fn letter(s: &str) -> String {
    match sort_key(s).chars().next() {
        Some(c) if c.is_ascii_alphabetic() => c.to_ascii_uppercase().to_string(),
        Some(c) if c.is_alphabetic() => "★".into(),
        _ => "#".into(),
    }
}

pub fn dur(secs: f64) -> String {
    let s = secs.max(0.0).round() as u64;
    if s >= 3600 { format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60) } else { format!("{}:{:02}", s / 60, s % 60) }
}

fn hours_label(secs: f64) -> String {
    let h = secs / 3600.0;
    if h >= 10.0 { format!("{:.0} h", h) } else if h >= 1.0 { format!("{:.1} h", h) } else { format!("{:.0} min", secs / 60.0) }
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

fn item(id: impl Into<String>, title: impl Into<String>) -> StrataItem {
    StrataItem { id: id.into(), title: title.into(), subtitle: None, meta: None, art: None, glyph: None, number: None, emphasis: false, action: StrataAction::None, secondary: None, control: None }
}

fn section(id: &str, style: StrataStyle, title: Option<&str>, items: Vec<StrataItem>) -> StrataSection {
    let total = items.len() as u32;
    StrataSection { id: id.into(), style, title: title.map(str::to_string), caption: None, items, total, more: None, index: vec![], index_positions: vec![] }
}

// ---- core -------------------------------------------------------------------------------------

#[derive(Default)]
struct Lib {
    songs: Vec<StrataSong>,
    by_id: HashMap<String, usize>,
    playlists: Vec<StrataPlaylist>,
    /// album key -> song indexes (track order as given).
    albums: BTreeMap<String, Vec<usize>>,
    artists: BTreeMap<String, Vec<usize>>,
    /// Display name per artist key.
    artist_name: HashMap<String, String>,
    genres: BTreeMap<String, Vec<usize>>,
    /// Search tokens per song.
    tokens: Vec<Vec<String>>,
    /// Sort order per Library tab (SetSort).
    sorts: HashMap<String, String>,
}

/// An online search result or a cloud-library track (Cloud screens).
#[derive(uniffi::Record, Clone, Debug, Default, PartialEq)]
pub struct StrataRemote {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub duration: f64,
    pub thumbnail: String,
    /// "youtube" / "soundcloud" ... for results, "cloud" for your uploads.
    pub source: String,
    /// Already in the local library.
    pub downloaded: bool,
}

#[derive(Default)]
struct Remote {
    cloud: Vec<StrataRemote>,
    query: String,
    results: Vec<StrataRemote>,
    searching: bool,
}

/// The Strata interface engine (one per app).
#[derive(uniffi::Object, Default)]
pub struct StrataCore {
    lib: RwLock<Lib>,
    remote: RwLock<Remote>,
}

const PAGE: usize = 120;

#[uniffi::export]
impl StrataCore {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Hand over the library (replaces it). Builds every index once.
    pub fn set_library(&self, songs: Vec<StrataSong>, playlists: Vec<StrataPlaylist>) {
        let sorts = std::mem::take(&mut self.lib.write().unwrap().sorts);
        let mut l = Lib { songs, playlists, sorts, ..Default::default() };
        for (i, s) in l.songs.iter().enumerate() {
            l.by_id.insert(s.id.clone(), i);
            let artist = if s.artist.trim().is_empty() { "Unknown Artist".to_string() } else { s.artist.trim().to_string() };
            let ak = fold(&artist);
            l.artist_name.entry(ak.clone()).or_insert(artist.clone());
            l.artists.entry(ak).or_default().push(i);
            if !s.album.trim().is_empty() {
                l.albums.entry(album_key(&artist, &s.album)).or_default().push(i);
            }
            if !s.genre.trim().is_empty() {
                l.genres.entry(s.genre.trim().to_string()).or_default().push(i);
            }
            let mut t = words(&s.title);
            t.extend(words(&artist));
            t.extend(words(&s.album));
            l.tokens.push(t);
        }
        *self.lib.write().unwrap() = l;
    }

    /// Update play counts / favorites without re-sending the library.
    pub fn update_song_stats(&self, id: String, plays: u32, last_played: f64, favorite: bool) {
        let mut l = self.lib.write().unwrap();
        if let Some(&i) = l.by_id.get(&id) {
            let s = &mut l.songs[i];
            s.plays = plays;
            s.last_played = last_played;
            s.favorite = favorite;
        }
    }

    pub fn song_count(&self) -> u32 {
        self.lib.read().unwrap().songs.len() as u32
    }

    /// The screen for a route. `now` = unix seconds, `hour` = local hour,
    /// `current` = the playing song, `queue` + `queue_index` for Queue.
    pub fn screen(&self, route: StrataRoute, now: f64, hour: u32, current: Option<String>, queue: Vec<String>, queue_index: u32, values: HashMap<String, StrataValue>) -> StrataScreen {
        let l = self.lib.read().unwrap();
        let v = Values(&values);
        match route.clone() {
            StrataRoute::Home => home(&l, now, hour, current.as_deref()),
            StrataRoute::Library { tab } => library(&l, &tab),
            StrataRoute::Search { query } => search(&l, &query),
            StrataRoute::Album { key } => album(&l, &key),
            StrataRoute::Artist { name } => artist(&l, &name, now),
            StrataRoute::Playlist { id } => playlist(&l, &id),
            StrataRoute::Genre { name } => genre(&l, &name),
            StrataRoute::Favorites => favorites(&l),
            StrataRoute::History => history(&l),
            StrataRoute::Queue => queue_screen(&l, &queue, queue_index as usize),
            StrataRoute::You => you(&l, now),
            StrataRoute::Cloud { query } => cloud(&l, &self.remote.read().unwrap(), &query),
            StrataRoute::Settings { page } => settings(&page, &v),
            StrataRoute::Account => account(&l, &v),
            StrataRoute::AddToPlaylist { ids } => add_to_playlist(&l, &ids),
        }
    }

    /// Library tab sort order (persisted by Swift, restored at launch).
    pub fn set_sort(&self, tab: String, sort: String) {
        self.lib.write().unwrap().sorts.insert(tab, sort);
    }

    /// Your uploaded cloud library (Cloud screen with no query).
    pub fn set_cloud(&self, tracks: Vec<StrataRemote>) {
        self.remote.write().unwrap().cloud = tracks;
    }

    /// Online results for `query` (`searching` while the request is out).
    pub fn set_results(&self, query: String, results: Vec<StrataRemote>, searching: bool) {
        let mut r = self.remote.write().unwrap();
        r.query = query;
        r.results = results;
        r.searching = searching;
    }

    /// More items of a paged section (`offset` onward).
    pub fn page(&self, route: StrataRoute, section_id: String, offset: u32, limit: u32) -> Vec<StrataItem> {
        let l = self.lib.read().unwrap();
        section_page(&l, &route, &section_id, offset as usize, limit.clamp(1, 500) as usize)
    }

    /// Song ids of a long section, in play order (for `PlayFrom`).
    pub fn section_ids(&self, route: StrataRoute, section_id: String) -> Vec<String> {
        let l = self.lib.read().unwrap();
        section_order(&l, &route, &section_id).map(|(idx, _)| idx.iter().map(|&i| l.songs[i].id.clone()).collect()).unwrap_or_default()
    }
}

/// Lists up to this long carry their ids in the action; longer ones play by reference.
const INLINE_IDS: usize = 200;

/// Where a song row's list lives: small lists inline, long ones by reference.
#[derive(Clone, Copy)]
enum Ctx<'a> {
    Inline,
    Section(&'a StrataRoute, &'a str),
}

fn song_row(l: &Lib, i: usize, action: StrataAction, number: Option<u32>) -> StrataItem {
    let s = &l.songs[i];
    let mut it = item(&s.id, if s.title.is_empty() { "Untitled" } else { &s.title });
    let artist = if s.artist.is_empty() { "Unknown Artist" } else { &s.artist };
    it.subtitle = Some(if s.album.is_empty() { artist.to_string() } else { format!("{artist} · {}", s.album) });
    it.meta = (s.duration > 0.0).then(|| dur(s.duration));
    it.art = Some(s.id.clone());
    it.number = number;
    it.emphasis = s.favorite;
    it.action = action;
    it.secondary = Some(StrataAction::PlayNext { ids: vec![s.id.clone()] });
    it
}

/// Rows for `idx[range]` of a list, each playing the whole list from itself.
fn song_rows_range(l: &Lib, idx: &[usize], range: std::ops::Range<usize>, numbered: bool, ctx: Ctx) -> Vec<StrataItem> {
    // Rows of a named section always play by reference: inline ids would be
    // rows × list length (an artist's 150 songs put 18 000 ids on one screen).
    let inline: Option<Vec<String>> = match ctx {
        Ctx::Inline => Some(idx.iter().take(INLINE_IDS).map(|&i| l.songs[i].id.clone()).collect()),
        Ctx::Section(..) => None,
    };
    let end = range.end.min(idx.len());
    (range.start.min(end)..end)
        .map(|p| {
            let action = match (&inline, ctx) {
                (Some(ids), _) if p < ids.len() => StrataAction::Play { ids: ids.clone(), index: p as u32, shuffle: false },
                (_, Ctx::Section(route, sec)) => StrataAction::PlayFrom { route: route.clone(), section: sec.to_string(), index: p as u32, shuffle: false },
                _ => StrataAction::Play { ids: vec![l.songs[idx[p]].id.clone()], index: 0, shuffle: false },
            };
            song_row(l, idx[p], action, numbered.then_some(p as u32 + 1))
        })
        .collect()
}

fn song_rows(l: &Lib, idx: &[usize], numbered: bool) -> Vec<StrataItem> {
    song_rows_range(l, idx, 0..idx.len(), numbered, Ctx::Inline)
}

/// Ledger section of songs: only the first page of rows is built (the
/// rest come from `page`), each playing the list by reference.
fn paged_songs(l: &Lib, route: &StrataRoute, id: &str, title: Option<&str>, idx: &[usize], numbered: bool, with_index: bool) -> StrataSection {
    let rows = song_rows_range(l, idx, 0..PAGE, numbered, Ctx::Section(route, id));
    let mut sec = section(id, StrataStyle::Ledger, title, rows);
    sec.total = idx.len() as u32;
    if with_index {
        for (p, &i) in idx.iter().enumerate() {
            let c = letter(&l.songs[i].title);
            if sec.index.last() != Some(&c) {
                sec.index.push(c);
                sec.index_positions.push(p as u32);
            }
        }
    }
    sec
}

/// Play / Shuffle / Play next for a list that lives in `route`'s `section`.
fn play_actions_for(l: &Lib, route: &StrataRoute, section: &str, idx: &[usize]) -> Vec<StrataItem> {
    if idx.len() <= INLINE_IDS {
        let ids: Vec<String> = idx.iter().map(|&i| l.songs[i].id.clone()).collect();
        return play_actions(&ids);
    }
    let mut p = item("play", "Play");
    p.glyph = Some("play.fill".into());
    p.emphasis = true;
    p.action = StrataAction::PlayFrom { route: route.clone(), section: section.into(), index: 0, shuffle: false };
    let mut sh = item("shuffle", "Shuffle");
    sh.glyph = Some("shuffle".into());
    sh.action = StrataAction::PlayFrom { route: route.clone(), section: section.into(), index: 0, shuffle: true };
    vec![p, sh]
}

fn play_actions(ids: &[String]) -> Vec<StrataItem> {
    if ids.is_empty() {
        return vec![];
    }
    let mut p = item("play", "Play");
    p.glyph = Some("play.fill".into());
    p.emphasis = true;
    p.action = StrataAction::Play { ids: ids.to_vec(), index: 0, shuffle: false };
    let mut s = item("shuffle", "Shuffle");
    s.glyph = Some("shuffle".into());
    s.action = StrataAction::Play { ids: ids.to_vec(), index: 0, shuffle: true };
    let mut q = item("queue", "Play next");
    q.glyph = Some("text.line.first.and.arrowtriangle.forward".into());
    q.action = StrataAction::PlayNext { ids: ids.to_vec() };
    vec![p, s, q]
}

fn part_of_day(hour: u32) -> (&'static str, &'static str) {
    match hour {
        5..=11 => ("Morning", "Good morning"),
        12..=16 => ("Afternoon", "Good afternoon"),
        17..=21 => ("Evening", "Good evening"),
        _ => ("Late night", "Still up"),
    }
}

/// Recency-weighted play score (half-life 14 days).
fn heat(s: &StrataSong, now: f64) -> f64 {
    if s.plays == 0 {
        return 0.0;
    }
    let age_days = if s.last_played > 0.0 { ((now - s.last_played) / 86400.0).max(0.0) } else { 90.0 };
    s.plays as f64 * 0.5f64.powf(age_days / 14.0)
}

fn home(l: &Lib, now: f64, hour: u32, current: Option<&str>) -> StrataScreen {
    let (kicker, greeting) = part_of_day(hour);
    let mut sections = Vec::new();
    // Resume: what's playing, else the last thing played.
    let resume = current.and_then(|c| l.by_id.get(c).copied()).or_else(|| (0..l.songs.len()).filter(|&i| l.songs[i].last_played > 0.0).max_by(|&a, &b| l.songs[a].last_played.total_cmp(&l.songs[b].last_played)));
    if let Some(i) = resume {
        let s = &l.songs[i];
        let mut it = song_row(l, i, StrataAction::Play { ids: vec![s.id.clone()], index: 0, shuffle: false }, None);
        it.meta = Some(if current.is_some() { "Now playing".into() } else { "Pick up where you left off".into() });
        let mut sec = section("resume", StrataStyle::Hero, None, vec![it]);
        sec.caption = Some(s.artist.clone());
        sections.push(sec);
    }
    // On rotation: hottest songs right now.
    let mut hot: Vec<usize> = (0..l.songs.len()).filter(|&i| heat(&l.songs[i], now) > 0.05).collect();
    hot.sort_by(|&a, &b| heat(&l.songs[b], now).total_cmp(&heat(&l.songs[a], now)));
    hot.truncate(12);
    if hot.len() >= 3 {
        let mut sec = section("rotation", StrataStyle::Stack, Some("On rotation"), song_rows(l, &hot, false));
        sec.caption = Some("What you keep coming back to".into());
        sections.push(sec);
    }
    // Fresh: recently added.
    let mut fresh: Vec<usize> = (0..l.songs.len()).filter(|&i| l.songs[i].added > 0.0).collect();
    fresh.sort_by(|&a, &b| l.songs[b].added.total_cmp(&l.songs[a].added));
    fresh.truncate(16);
    if !fresh.is_empty() {
        let mut sec = section("fresh", StrataStyle::Ribbon, Some("Fresh in your library"), song_rows(l, &fresh, false));
        sec.more = Some(StrataAction::Open { route: StrataRoute::Library { tab: "recent".into() } });
        sections.push(sec);
    }
    // Rediscover: loved or once-played songs not heard for 45+ days.
    let mut old: Vec<usize> = (0..l.songs.len())
        .filter(|&i| {
            let s = &l.songs[i];
            (s.favorite || s.plays >= 3) && s.last_played > 0.0 && now - s.last_played > 45.0 * 86400.0
        })
        .collect();
    old.sort_by(|&a, &b| (l.songs[b].plays as f64 + if l.songs[b].favorite { 5.0 } else { 0.0 }).total_cmp(&(l.songs[a].plays as f64 + if l.songs[a].favorite { 5.0 } else { 0.0 })));
    old.truncate(12);
    if old.len() >= 3 {
        let mut sec = section("rediscover", StrataStyle::Ribbon, Some("Rediscover"), song_rows(l, &old, false));
        sec.caption = Some("Loved once, quiet lately".into());
        sections.push(sec);
    }
    // Tempo chips: songs bucketed by BPM.
    let buckets: [(&str, &str, f64, f64); 4] = [("slow", "Slow burn", 0.0, 90.0), ("mid", "Easy pace", 90.0, 118.0), ("drive", "Driving", 118.0, 140.0), ("rush", "Rush", 140.0, 400.0)];
    let mut chips = Vec::new();
    for (id, name, lo, hi) in buckets {
        let ids: Vec<String> = l.songs.iter().filter(|s| s.bpm >= lo.max(1.0) && s.bpm < hi).map(|s| s.id.clone()).collect();
        if ids.len() >= 8 {
            let mut c = item(format!("tempo-{id}"), name);
            c.meta = Some(ids.len().to_string());
            c.glyph = Some("metronome".into());
            c.action = StrataAction::Play { ids, index: 0, shuffle: true };
            chips.push(c);
        }
    }
    if !chips.is_empty() {
        let mut sec = section("tempo", StrataStyle::Chips, Some("By tempo"), chips);
        sec.caption = Some("Shuffle a pace".into());
        sections.push(sec);
    }
    // Top artists ledger.
    let mut arts: Vec<(&String, f64, usize)> = l.artists.iter().map(|(k, v)| (k, v.iter().map(|&i| heat(&l.songs[i], now) + l.songs[i].plays as f64 * 0.05).sum::<f64>(), v[0])).filter(|x| x.1 > 0.0).collect();
    arts.sort_by(|a, b| b.1.total_cmp(&a.1));
    let top: Vec<StrataItem> = arts.iter().take(8).enumerate().map(|(n, (k, _, first))| {
        let name = l.artist_name.get(*k).cloned().unwrap_or_default();
        let count = l.artists.get(*k).map_or(0, |v| v.len());
        let mut it = item(format!("artist-{k}"), &name);
        it.subtitle = Some(plural(count, "song", "songs"));
        it.number = Some(n as u32 + 1);
        it.art = Some(l.songs[*first].id.clone());
        it.action = StrataAction::Open { route: StrataRoute::Artist { name } };
        it
    }).collect();
    if top.len() >= 3 {
        sections.push(section("top-artists", StrataStyle::Ledger, Some("Your artists"), top));
    }
    sections.push(stats_section(l));
    StrataScreen { route: StrataRoute::Home, kicker: Some(kicker.into()), title: greeting.into(), subtitle: Some(format!("{} in your library", plural(l.songs.len(), "song", "songs"))), art: resume.map(|i| l.songs[i].id.clone()), actions: vec![], sections }
}

fn stats_section(l: &Lib) -> StrataSection {
    let total: f64 = l.songs.iter().map(|s| s.duration).sum();
    let favs = l.songs.iter().filter(|s| s.favorite).count();
    let mut a = item("stat-songs", l.songs.len().to_string());
    a.subtitle = Some("songs".into());
    a.action = StrataAction::Open { route: StrataRoute::Library { tab: "songs".into() } };
    let mut b = item("stat-artists", l.artists.len().to_string());
    b.subtitle = Some("artists".into());
    b.action = StrataAction::Open { route: StrataRoute::Library { tab: "artists".into() } };
    let mut c = item("stat-hours", hours_label(total));
    c.subtitle = Some("of music".into());
    let mut d = item("stat-favs", favs.to_string());
    d.subtitle = Some("favorites".into());
    d.action = StrataAction::Open { route: StrataRoute::Favorites };
    section("stats", StrataStyle::Stats, None, vec![a, b, c, d])
}

pub const LIBRARY_TABS: [(&str, &str); 7] = [("songs", "Songs"), ("albums", "Albums"), ("artists", "Artists"), ("playlists", "Playlists"), ("genres", "Genres"), ("recent", "Recently added"), ("favorites", "Favorites")];

fn sort_of<'a>(l: &'a Lib, tab: &str, default: &'a str) -> &'a str {
    l.sorts.get(tab).map(String::as_str).unwrap_or(default)
}

/// All songs in the Library "songs" tab order.
fn sorted_songs(l: &Lib) -> Vec<usize> {
    let mut v: Vec<usize> = (0..l.songs.len()).collect();
    let s = &l.songs;
    match sort_of(l, "songs", "title") {
        "artist" => v.sort_by_cached_key(|&i| (sort_key(&s[i].artist), sort_key(&s[i].album), sort_key(&s[i].title))),
        "album" => v.sort_by_cached_key(|&i| (sort_key(&s[i].album), sort_key(&s[i].title))),
        "added" => v.sort_by(|&a, &b| s[b].added.total_cmp(&s[a].added)),
        "plays" => v.sort_by(|&a, &b| s[b].plays.cmp(&s[a].plays).then(s[b].last_played.total_cmp(&s[a].last_played))),
        "duration" => v.sort_by(|&a, &b| s[b].duration.total_cmp(&s[a].duration)),
        _ => v.sort_by_cached_key(|&i| sort_key(&s[i].title)),
    }
    v
}

fn album_items(l: &Lib) -> Vec<StrataItem> {
    let mut keys: Vec<(&String, &Vec<usize>)> = l.albums.iter().collect();
    match sort_of(l, "albums", "title") {
        "artist" => keys.sort_by_cached_key(|(_, v)| (sort_key(&l.songs[v[0]].artist), sort_key(&l.songs[v[0]].album))),
        "year" => keys.sort_by_cached_key(|(_, v)| (std::cmp::Reverse(l.songs[v[0]].year.clone()), sort_key(&l.songs[v[0]].album))),
        _ => keys.sort_by_cached_key(|(_, v)| sort_key(&l.songs[v[0]].album)),
    }
    keys.iter().map(|(k, v)| {
        let s = &l.songs[v[0]];
        let mut it = item(format!("album-{k}"), &s.album);
        it.subtitle = Some(s.artist.clone());
        it.meta = Some(if s.year.is_empty() { plural(v.len(), "song", "songs") } else { format!("{} · {}", s.year, plural(v.len(), "song", "songs")) });
        it.art = Some(s.id.clone());
        it.action = StrataAction::Open { route: StrataRoute::Album { key: (*k).clone() } };
        it
    }).collect()
}

fn artist_items(l: &Lib) -> Vec<StrataItem> {
    let mut keys: Vec<(&String, &Vec<usize>)> = l.artists.iter().collect();
    if sort_of(l, "artists", "name") == "songs" {
        keys.sort_by(|a, b| b.1.len().cmp(&a.1.len()));
    } else {
        keys.sort_by_cached_key(|(k, _)| sort_key(l.artist_name.get(*k).map(String::as_str).unwrap_or("")));
    }
    keys.iter().map(|(k, v)| {
        let name = l.artist_name.get(*k).cloned().unwrap_or_default();
        let albums: HashSet<&str> = v.iter().map(|&i| l.songs[i].album.as_str()).filter(|a| !a.is_empty()).collect();
        let mut it = item(format!("artist-{k}"), &name);
        it.subtitle = Some(if albums.is_empty() { plural(v.len(), "song", "songs") } else { format!("{} · {}", plural(albums.len(), "album", "albums"), plural(v.len(), "song", "songs")) });
        it.art = Some(l.songs[v[0]].id.clone());
        it.action = StrataAction::Open { route: StrataRoute::Artist { name } };
        it
    }).collect()
}

fn playlist_items(l: &Lib) -> Vec<StrataItem> {
    let mut v: Vec<&StrataPlaylist> = l.playlists.iter().collect();
    v.sort_by_cached_key(|p| sort_key(&p.name));
    v.iter().map(|p| {
        let mut it = item(format!("playlist-{}", p.id), &p.name);
        it.subtitle = Some(match &p.folder {
            Some(f) if !f.is_empty() => format!("{f} · {}", plural(p.song_ids.len(), "song", "songs")),
            _ => plural(p.song_ids.len(), "song", "songs"),
        });
        it.art = p.song_ids.iter().find(|id| l.by_id.contains_key(*id)).cloned();
        it.glyph = Some("music.note.list".into());
        it.action = StrataAction::Open { route: StrataRoute::Playlist { id: p.id.clone() } };
        it
    }).collect()
}

fn genre_items(l: &Lib) -> Vec<StrataItem> {
    let mut g: Vec<(&String, &Vec<usize>)> = l.genres.iter().collect();
    g.sort_by(|a, b| b.1.len().cmp(&a.1.len()));
    g.iter().map(|(name, v)| {
        let mut it = item(format!("genre-{name}"), name.as_str());
        it.meta = Some(v.len().to_string());
        it.glyph = Some("guitars".into());
        it.action = StrataAction::Open { route: StrataRoute::Genre { name: (*name).clone() } };
        it
    }).collect()
}

fn letters_of(items: &[StrataItem]) -> (Vec<String>, Vec<u32>) {
    let (mut out, mut pos): (Vec<String>, Vec<u32>) = (Vec::new(), Vec::new());
    for (p, it) in items.iter().enumerate() {
        let c = letter(&it.title);
        if out.last() != Some(&c) {
            out.push(c);
            pos.push(p as u32);
        }
    }
    (out, pos)
}

fn tab_chips(active: &str) -> StrataSection {
    let chips = LIBRARY_TABS.iter().map(|(id, name)| {
        let mut c = item(format!("tab-{id}"), *name);
        c.emphasis = *id == active;
        c.action = StrataAction::Open { route: StrataRoute::Library { tab: id.to_string() } };
        c
    }).collect();
    section("tabs", StrataStyle::Chips, None, chips)
}

fn library(l: &Lib, tab: &str) -> StrataScreen {
    let tab = if LIBRARY_TABS.iter().any(|(t, _)| *t == tab) { tab } else { "songs" };
    let mut sections = vec![tab_chips(tab)];
    let mut actions = vec![];
    let title = LIBRARY_TABS.iter().find(|(t, _)| *t == tab).map(|x| x.1).unwrap_or("Library");
    let mut subtitle = None;
    match tab {
        "songs" | "recent" => {
            let route = StrataRoute::Library { tab: tab.into() };
            if tab == "songs" {
                sections.push(sort_chips("songs", sort_of(l, "songs", "title")));
            }
            let (sec, idx) = ordered_songs(l, &route, "list", None, tab == "songs" && sort_of(l, "songs", "title") == "title");
            actions = play_actions_for(l, &route, "list", &idx);
            subtitle = Some(format!("{} · {}", plural(idx.len(), "song", "songs"), hours_label(l.songs.iter().map(|s| s.duration).sum())));
            sections.push(sec);
        }
        "favorites" => return favorites(l),
        "albums" | "artists" | "playlists" | "genres" => {
            let all = match tab {
                "albums" => album_items(l),
                "artists" => artist_items(l),
                "playlists" => playlist_items(l),
                _ => genre_items(l),
            };
            subtitle = Some(plural(all.len(), &title.to_lowercase()[..title.len() - 1], &title.to_lowercase()));
            let style = if tab == "albums" { StrataStyle::Grid } else if tab == "genres" { StrataStyle::Chips } else { StrataStyle::Ledger };
            let total = all.len() as u32;
            if tab == "albums" || tab == "artists" {
                sections.push(sort_chips(tab, sort_of(l, tab, if tab == "albums" { "title" } else { "name" })));
            }
            if tab == "playlists" {
                let mut n = item("new-playlist", "New playlist");
                n.glyph = Some("plus".into());
                n.emphasis = true;
                n.action = StrataAction::CreatePlaylist { name: None, ids: vec![] };
                actions.push(n);
            }
            let by_name = matches!((tab, sort_of(l, tab, "")), ("albums", "" | "title") | ("artists", "" | "name") | ("playlists", _));
            let (index, positions) = if by_name { letters_of(&all) } else { (vec![], vec![]) };
            let mut sec = section("list", style, None, all.into_iter().take(PAGE).collect());
            sec.total = total;
            sec.index = index;
            sec.index_positions = positions;
            sections.push(sec);
        }
        _ => {}
    }
    StrataScreen { route: StrataRoute::Library { tab: tab.into() }, kicker: Some("Library".into()), title: title.into(), subtitle, art: None, actions, sections }
}

/// Song order of a long song section (and whether it is numbered): the
/// one ordering used for the first page, later pages and `section_ids`.
fn section_order(l: &Lib, route: &StrataRoute, id: &str) -> Option<(Vec<usize>, bool)> {
    Some(match (route, id) {
        (StrataRoute::Library { tab }, "list") if tab == "songs" => (sorted_songs(l), false),
        (StrataRoute::Library { tab }, "list") if tab == "recent" => {
            let mut idx: Vec<usize> = (0..l.songs.len()).collect();
            idx.sort_by(|&a, &b| l.songs[b].added.total_cmp(&l.songs[a].added));
            (idx, false)
        }
        (StrataRoute::Library { tab }, "list") if tab == "favorites" => ((0..l.songs.len()).filter(|&i| l.songs[i].favorite).collect(), false),
        (StrataRoute::Favorites, "list") => ((0..l.songs.len()).filter(|&i| l.songs[i].favorite).collect(), false),
        (StrataRoute::Genre { name }, "list") => (l.genres.get(name).cloned().unwrap_or_default(), false),
        (StrataRoute::Playlist { id }, "list") => (
            l.playlists.iter().find(|p| &p.id == id).map(|p| p.song_ids.iter().filter_map(|s| l.by_id.get(s).copied()).collect()).unwrap_or_default(),
            true,
        ),
        (StrataRoute::Artist { name }, "songs") => {
            let mut idx = l.artists.get(&fold(name)).cloned().unwrap_or_default();
            idx.sort_by_cached_key(|&i| sort_key(&l.songs[i].title));
            (idx, false)
        }
        (StrataRoute::History, "list") => {
            let mut idx: Vec<usize> = (0..l.songs.len()).filter(|&i| l.songs[i].last_played > 0.0).collect();
            idx.sort_by(|&a, &b| l.songs[b].last_played.total_cmp(&l.songs[a].last_played));
            (idx, false)
        }
        _ => return None,
    })
}

/// Items `offset..offset+limit` of a paged section (only those are built).
fn section_page(l: &Lib, route: &StrataRoute, id: &str, offset: usize, limit: usize) -> Vec<StrataItem> {
    if let Some((idx, numbered)) = section_order(l, route, id) {
        return song_rows_range(l, &idx, offset..offset + limit, numbered, Ctx::Section(route, id));
    }
    let all = match (route, id) {
        (StrataRoute::Library { tab }, "list") => match tab.as_str() {
            "albums" => album_items(l),
            "artists" => artist_items(l),
            "playlists" => playlist_items(l),
            "genres" => genre_items(l),
            _ => vec![],
        },
        _ => vec![],
    };
    all.into_iter().skip(offset).take(limit).collect()
}

/// Ledger of a long song section via `section_order`.
fn ordered_songs(l: &Lib, route: &StrataRoute, id: &str, title: Option<&str>, with_index: bool) -> (StrataSection, Vec<usize>) {
    let (idx, numbered) = section_order(l, route, id).unwrap_or_default();
    (paged_songs(l, route, id, title, &idx, numbered, with_index), idx)
}

fn album(l: &Lib, key: &str) -> StrataScreen {
    let idx = l.albums.get(key).cloned().unwrap_or_default();
    let Some(&first) = idx.first() else {
        return StrataScreen { route: StrataRoute::Album { key: key.into() }, kicker: Some("Album".into()), title: "Not in your library".into(), subtitle: None, art: None, actions: vec![], sections: vec![] };
    };
    let s = &l.songs[first];
    let ids: Vec<String> = idx.iter().map(|&i| l.songs[i].id.clone()).collect();
    let total: f64 = idx.iter().map(|&i| l.songs[i].duration).sum();
    let mut sections = vec![section("tracks", StrataStyle::Ledger, None, song_rows(l, &idx, true))];
    // More by the artist.
    let ak = fold(if s.artist.is_empty() { "Unknown Artist" } else { s.artist.trim() });
    let others: Vec<StrataItem> = album_items(l).into_iter().filter(|it| it.id != format!("album-{key}") && it.id.ends_with(&format!("\u{1f}{ak}"))).take(10).collect();
    if !others.is_empty() {
        sections.push(section("more", StrataStyle::Ribbon, Some(&format!("More by {}", s.artist)), others));
    }
    let sub = [s.artist.clone(), s.year.clone(), plural(idx.len(), "song", "songs"), hours_label(total)].into_iter().filter(|x| !x.is_empty()).collect::<Vec<_>>().join(" · ");
    StrataScreen { route: StrataRoute::Album { key: key.into() }, kicker: Some("Album".into()), title: s.album.clone(), subtitle: Some(sub), art: Some(s.id.clone()), actions: play_actions(&ids), sections }
}

fn artist(l: &Lib, name: &str, now: f64) -> StrataScreen {
    let route = StrataRoute::Artist { name: name.into() };
    let idx = l.artists.get(&fold(name)).cloned().unwrap_or_default();
    let mut top = idx.clone();
    top.sort_by(|&a, &b| (l.songs[b].plays as f64 + heat(&l.songs[b], now)).total_cmp(&(l.songs[a].plays as f64 + heat(&l.songs[a], now))));
    top.truncate(5);
    let mut sections = Vec::new();
    if !top.is_empty() {
        sections.push(section("top", StrataStyle::Stack, Some("Most played"), song_rows(l, &top, true)));
    }
    let ak = fold(name);
    let albums: Vec<StrataItem> = album_items(l).into_iter().filter(|it| it.id.ends_with(&format!("\u{1f}{ak}"))).collect();
    if !albums.is_empty() {
        sections.push(section("albums", StrataStyle::Ribbon, Some("Albums"), albums));
    }
    let (songs, all) = ordered_songs(l, &route, "songs", Some("All songs"), false);
    sections.push(songs);
    let display = l.artist_name.get(&ak).cloned().unwrap_or_else(|| name.to_string());
    let actions = play_actions_for(l, &route, "songs", &all);
    StrataScreen { route, kicker: Some("Artist".into()), title: display, subtitle: Some(plural(idx.len(), "song", "songs")), art: idx.first().map(|&i| l.songs[i].id.clone()), actions, sections }
}

fn playlist(l: &Lib, id: &str) -> StrataScreen {
    let route = StrataRoute::Playlist { id: id.into() };
    let Some(p) = l.playlists.iter().find(|p| p.id == id) else {
        return StrataScreen { route, kicker: Some("Playlist".into()), title: "Playlist not found".into(), subtitle: None, art: None, actions: vec![], sections: vec![] };
    };
    let (mut sec, idx) = ordered_songs(l, &route, "list", None, false);
    let total: f64 = idx.iter().map(|&i| l.songs[i].duration).sum();
    let missing = p.song_ids.len() - idx.len();
    if missing > 0 {
        sec.caption = Some(format!("{} not on this device", plural(missing, "song", "songs")));
    }
    let mut actions = play_actions_for(l, &route, "list", &idx);
    let mut rn = item("rename", "Rename");
    rn.glyph = Some("pencil".into());
    rn.action = StrataAction::RenamePlaylist { id: id.into() };
    let mut del = item("delete", "Delete");
    del.glyph = Some("trash".into());
    del.action = StrataAction::DeletePlaylist { id: id.into() };
    actions.extend([rn, del]);
    StrataScreen { kicker: Some(p.folder.clone().filter(|f| !f.is_empty()).unwrap_or_else(|| "Playlist".into())), title: p.name.clone(), subtitle: Some(format!("{} · {}", plural(idx.len(), "song", "songs"), hours_label(total))), art: idx.first().map(|&i| l.songs[i].id.clone()), actions, sections: vec![sec], route }
}

fn genre(l: &Lib, name: &str) -> StrataScreen {
    let route = StrataRoute::Genre { name: name.into() };
    let (sec, idx) = ordered_songs(l, &route, "list", None, false);
    let actions = play_actions_for(l, &route, "list", &idx);
    StrataScreen { kicker: Some("Genre".into()), title: name.into(), subtitle: Some(plural(idx.len(), "song", "songs")), art: idx.first().map(|&i| l.songs[i].id.clone()), actions, sections: vec![sec], route }
}

fn favorites(l: &Lib) -> StrataScreen {
    let route = StrataRoute::Favorites;
    let (sec, idx) = ordered_songs(l, &route, "list", None, false);
    let mut sections = vec![tab_chips("favorites")];
    if idx.is_empty() {
        let mut n = item("empty", "Nothing here yet");
        n.subtitle = Some("Tap the heart on any song and it lands here.".into());
        n.glyph = Some("heart".into());
        sections.push(section("empty", StrataStyle::Note, None, vec![n]));
    } else {
        sections.push(sec);
    }
    let actions = play_actions_for(l, &route, "list", &idx);
    StrataScreen { kicker: Some("Library".into()), title: "Favorites".into(), subtitle: Some(plural(idx.len(), "song", "songs")), art: idx.first().map(|&i| l.songs[i].id.clone()), actions, sections, route }
}

fn history(l: &Lib) -> StrataScreen {
    let route = StrataRoute::History;
    let (sec, idx) = ordered_songs(l, &route, "list", None, false);
    let actions = play_actions_for(l, &route, "list", &idx);
    StrataScreen { kicker: Some("You".into()), title: "History".into(), subtitle: Some(plural(idx.len(), "song", "songs")), art: idx.first().map(|&i| l.songs[i].id.clone()), actions, sections: vec![sec], route }
}

fn queue_screen(l: &Lib, queue: &[String], at: usize) -> StrataScreen {
    let rows = |range: std::ops::Range<usize>| -> Vec<StrataItem> {
        range.filter_map(|p| {
            let id = queue.get(p)?;
            let mut it = match l.by_id.get(id) {
                Some(&i) => song_row(l, i, StrataAction::None, None),
                None => {
                    let mut x = item(id, "Streaming track");
                    x.art = Some(id.clone());
                    x
                }
            };
            it.id = format!("q{p}");
            it.number = Some((p as i64 - at as i64).max(0) as u32);
            it.action = StrataAction::QueueJump { index: p as u32 };
            it.secondary = None;
            Some(it)
        }).collect()
    };
    let mut sections = Vec::new();
    if at < queue.len() {
        sections.push(section("now", StrataStyle::Hero, Some("Now"), rows(at..at + 1)));
    }
    let next = rows(at + 1..(at + 1 + 60).min(queue.len()));
    let left: f64 = queue.iter().skip(at + 1).filter_map(|id| l.by_id.get(id)).map(|&i| l.songs[i].duration).sum();
    if !next.is_empty() {
        let mut s = section("next", StrataStyle::Ledger, Some("Up next"), next);
        s.caption = Some(format!("{} · {} left", plural(queue.len().saturating_sub(at + 1), "song", "songs"), hours_label(left)));
        s.total = queue.len().saturating_sub(at + 1) as u32;
        sections.push(s);
    }
    StrataScreen { route: StrataRoute::Queue, kicker: Some("Playing".into()), title: "Queue".into(), subtitle: None, art: queue.get(at).cloned(), actions: vec![], sections }
}

fn you(l: &Lib, now: f64) -> StrataScreen {
    let week: f64 = l.songs.iter().filter(|s| now - s.last_played < 7.0 * 86400.0).map(|s| s.duration).sum();
    let mut sections = vec![stats_section(l)];
    let links: [(&str, &str, &str, StrataRoute); 8] = [
        ("history", "History", "clock.arrow.circlepath", StrataRoute::History),
        ("favorites", "Favorites", "heart", StrataRoute::Favorites),
        ("cloud", "Cloud library", "icloud", StrataRoute::Cloud { query: String::new() }),
        ("account", "Account", "person.crop.circle", StrataRoute::Account),
        ("sound", "Sound", "waveform", StrataRoute::Settings { page: "sound".into() }),
        ("playback", "Playback", "play.circle", StrataRoute::Settings { page: "playback".into() }),
        ("haptics", "Music Haptics", "hand.tap", StrataRoute::Settings { page: "haptics".into() }),
        ("all", "Settings", "gearshape", StrataRoute::Settings { page: "root".into() }),
    ];
    sections.push(section("places", StrataStyle::Ledger, Some("Your places"), links.into_iter().map(|(id, name, glyph, route)| {
        let mut it = item(format!("link-{id}"), name);
        it.glyph = Some(glyph.into());
        it.action = StrataAction::Open { route };
        it
    }).collect()));
    StrataScreen { route: StrataRoute::You, kicker: Some("You".into()), title: "Your Lumisound".into(), subtitle: Some(format!("{} listened this week", hours_label(week))), art: None, actions: vec![], sections }
}

// ---- search -----------------------------------------------------------------------------------

fn lev1(a: &str, b: &str) -> bool {
    // Edit distance <= 1 (typo tolerance for words of 5+ letters).
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    if a.len().abs_diff(b.len()) > 1 {
        return false;
    }
    let (mut i, mut j, mut edits) = (0, 0, 0);
    while i < a.len() && j < b.len() {
        if a[i] == b[j] {
            i += 1;
            j += 1;
            continue;
        }
        edits += 1;
        if edits > 1 {
            return false;
        }
        match a.len().cmp(&b.len()) {
            std::cmp::Ordering::Greater => i += 1,
            std::cmp::Ordering::Less => j += 1,
            std::cmp::Ordering::Equal => {
                i += 1;
                j += 1;
            }
        }
    }
    edits + (a.len() - i) + (b.len() - j) <= 1
}

/// Score of a query against one song's tokens (0 = no match).
fn match_score(q: &[String], tokens: &[String], title_words: usize) -> f64 {
    let mut total = 0.0;
    for w in q {
        let mut best = 0.0f64;
        for (k, t) in tokens.iter().enumerate() {
            let in_title = k < title_words;
            let s = if t == w {
                3.0
            } else if t.starts_with(w.as_str()) {
                2.0
            } else if w.chars().count() >= 5 && lev1(w, t) {
                1.2
            } else if w.chars().count() >= 3 && t.contains(w.as_str()) {
                0.8
            } else {
                0.0
            };
            best = best.max(if in_title { s * 1.25 } else { s });
        }
        if best == 0.0 {
            return 0.0;
        }
        total += best;
    }
    total
}

fn search(l: &Lib, query: &str) -> StrataScreen {
    let q = words(query);
    let route = StrataRoute::Search { query: query.into() };
    if q.is_empty() {
        // Browse: genres and recent favourites.
        let mut sections = vec![];
        let g = genre_items(l);
        if !g.is_empty() {
            sections.push(section("browse", StrataStyle::Chips, Some("Browse genres"), g.into_iter().take(24).collect()));
        }
        let mut lib = item("lib", "Your whole library");
        lib.glyph = Some("square.stack.3d.up".into());
        lib.action = StrataAction::Open { route: StrataRoute::Library { tab: "songs".into() } };
        sections.push(section("jump", StrataStyle::Ledger, Some("Jump to"), vec![lib]));
        return StrataScreen { route, kicker: Some("Search".into()), title: "Find anything".into(), subtitle: Some("Songs, artists, albums and playlists".into()), art: None, actions: vec![], sections };
    }
    let mut hits: Vec<(usize, f64)> = l.tokens.iter().enumerate().filter_map(|(i, t)| {
        let tw = words(&l.songs[i].title).len();
        let s = match_score(&q, t, tw);
        (s > 0.0).then(|| (i, s + (l.songs[i].plays as f64).ln_1p() * 0.15 + if l.songs[i].favorite { 0.3 } else { 0.0 }))
    }).collect();
    hits.sort_by(|a, b| b.1.total_cmp(&a.1));
    let mut sections = Vec::new();
    // Artists and albums whose names match.
    let artists: Vec<StrataItem> = l.artists.keys().filter(|k| {
        let w = words(l.artist_name.get(*k).map(String::as_str).unwrap_or(""));
        match_score(&q, &w, w.len()) > 0.0
    }).take(8).map(|k| {
        let name = l.artist_name.get(k).cloned().unwrap_or_default();
        let mut it = item(format!("artist-{k}"), &name);
        it.subtitle = Some(plural(l.artists[k].len(), "song", "songs"));
        it.art = Some(l.songs[l.artists[k][0]].id.clone());
        it.action = StrataAction::Open { route: StrataRoute::Artist { name } };
        it
    }).collect();
    let albums: Vec<StrataItem> = l.albums.iter().filter(|(_, v)| {
        let w = words(&l.songs[v[0]].album);
        match_score(&q, &w, w.len()) > 0.0
    }).take(10).map(|(k, v)| {
        let s = &l.songs[v[0]];
        let mut it = item(format!("album-{k}"), &s.album);
        it.subtitle = Some(s.artist.clone());
        it.art = Some(s.id.clone());
        it.action = StrataAction::Open { route: StrataRoute::Album { key: k.clone() } };
        it
    }).collect();
    let playlists: Vec<StrataItem> = playlist_items(l).into_iter().filter(|p| {
        let w = words(&p.title);
        match_score(&q, &w, w.len()) > 0.0
    }).take(6).collect();
    if let Some(&(i, _)) = hits.first() {
        let ids: Vec<String> = hits.iter().take(50).map(|(i, _)| l.songs[*i].id.clone()).collect();
        let mut top = song_row(l, i, StrataAction::Play { ids: ids.clone(), index: 0, shuffle: false }, None);
        top.meta = Some("Top result".into());
        sections.push(section("top", StrataStyle::Hero, None, vec![top]));
        let rest: Vec<usize> = hits.iter().skip(1).take(40).map(|x| x.0).collect();
        if !rest.is_empty() {
            let ids2: Vec<String> = rest.iter().map(|&i| l.songs[i].id.clone()).collect();
            let rows = rest.iter().enumerate().map(|(p, &i)| song_row(l, i, StrataAction::Play { ids: ids2.clone(), index: p as u32, shuffle: false }, None)).collect();
            let mut s = section("songs", StrataStyle::Ledger, Some("Songs"), rows);
            s.total = (hits.len() - 1) as u32;
            sections.push(s);
        }
    }
    if !artists.is_empty() {
        sections.push(section("artists", StrataStyle::Ribbon, Some("Artists"), artists));
    }
    if !albums.is_empty() {
        sections.push(section("albums", StrataStyle::Ribbon, Some("Albums"), albums));
    }
    if !playlists.is_empty() {
        sections.push(section("playlists", StrataStyle::Ledger, Some("Playlists"), playlists));
    }
    if sections.is_empty() {
        let mut n = item("none", format!("Nothing matches “{}”", query.trim()));
        n.subtitle = Some("Try fewer words, or search the web from Lumen/Classic search.".into());
        n.glyph = Some("magnifyingglass".into());
        sections.push(section("none", StrataStyle::Note, None, vec![n]));
    }
    StrataScreen { route, kicker: Some("Search".into()), title: query.trim().into(), subtitle: Some(plural(hits.len(), "song", "songs")), art: hits.first().map(|(i, _)| l.songs[*i].id.clone()), actions: vec![], sections }
}

// ---- theme ------------------------------------------------------------------------------------

/// Colours as "#RRGGBB" (alpha separate where needed) and metrics in points.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StrataTheme {
    pub ground: String,
    pub layer: String,
    pub raised: String,
    pub rule: String,
    pub ink: String,
    pub ink_dim: String,
    pub ink_faint: String,
    pub accent: String,
    pub on_accent: String,
    pub glow: String,
    pub danger: String,
    pub gutter: f64,
    pub rhythm: f64,
    pub radius: f64,
    pub radius_large: f64,
    /// Type scale (points): display, title, heading, body, caption, micro.
    pub type_scale: Vec<f64>,
    /// Motion (seconds): quick, standard, slow; spring damping.
    pub motion: Vec<f64>,
}

fn srgb_to_lin(c: f64) -> f64 {
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}
fn lin_to_srgb(c: f64) -> f64 {
    let c = c.clamp(0.0, 1.0);
    if c <= 0.0031308 { 12.92 * c } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 }
}

/// sRGB (0..1) -> OKLab.
pub fn oklab(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let (r, g, b) = (srgb_to_lin(r), srgb_to_lin(g), srgb_to_lin(b));
    let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
    let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
    let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
    (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}

pub fn from_oklab(l: f64, a: f64, b: f64) -> (f64, f64, f64) {
    let l_ = (l + 0.3963377774 * a + 0.2158037573 * b).powi(3);
    let m_ = (l - 0.1055613458 * a - 0.0638541728 * b).powi(3);
    let s_ = (l - 0.0894841775 * a - 1.2914855480 * b).powi(3);
    (
        lin_to_srgb(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_),
        lin_to_srgb(-1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_),
        lin_to_srgb(-0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_),
    )
}

fn hex(c: (f64, f64, f64)) -> String {
    format!("#{:02X}{:02X}{:02X}", (c.0 * 255.0).round() as u8, (c.1 * 255.0).round() as u8, (c.2 * 255.0).round() as u8)
}

fn parse_hex(s: &str) -> Option<(f64, f64, f64)> {
    let s = s.trim().trim_start_matches('#');
    if s.len() != 6 {
        return None;
    }
    let v = u32::from_str_radix(s, 16).ok()?;
    Some((((v >> 16) & 255) as f64 / 255.0, ((v >> 8) & 255) as f64 / 255.0, (v & 255) as f64 / 255.0))
}

fn luminance(c: (f64, f64, f64)) -> f64 {
    0.2126 * srgb_to_lin(c.0) + 0.7152 * srgb_to_lin(c.1) + 0.0722 * srgb_to_lin(c.2)
}

pub fn contrast(a: (f64, f64, f64), b: (f64, f64, f64)) -> f64 {
    let (x, y) = (luminance(a), luminance(b));
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}

/// Strata's palette: a deep graphite ground tinted by the playing artwork's
/// hue, one vivid accent (the artwork's own colour when it has one, else
/// the user's accent) pushed until it reads on the ground (WCAG 4.5:1), and
/// ink tones with fixed contrast steps.
#[uniffi::export]
pub fn strata_theme(accent_hex: String, artwork_rgb: Option<Vec<f64>>) -> StrataTheme {
    let user = parse_hex(&accent_hex).unwrap_or((0.98, 0.36, 0.25));
    let art = artwork_rgb.filter(|v| v.len() == 3).map(|v| (v[0].clamp(0.0, 1.0), v[1].clamp(0.0, 1.0), v[2].clamp(0.0, 1.0)));
    // Hue source: the artwork when it's colourful enough, else the user accent.
    let (_, ua, ub) = oklab(user.0, user.1, user.2);
    let (ha, hb) = match art.map(|c| oklab(c.0, c.1, c.2)) {
        Some((_, a, b)) if (a * a + b * b).sqrt() > 0.05 => (a, b),
        _ => (ua, ub),
    };
    let chroma = (ha * ha + hb * hb).sqrt().max(1e-6);
    let (ua_n, ub_n) = (ha / chroma, hb / chroma);
    let tint = |l: f64, c: f64| from_oklab(l, ua_n * c, ub_n * c);
    let ground = tint(0.155, 0.012);
    let layer = tint(0.195, 0.016);
    let raised = tint(0.245, 0.02);
    let rule = tint(0.32, 0.018);
    let ink = tint(0.97, 0.006);
    let ink_dim = tint(0.76, 0.012);
    let ink_faint = tint(0.58, 0.014);
    // Accent: vivid, then lightened until it clears 4.5:1 on the ground.
    let mut al = 0.70;
    let ac = chroma.clamp(0.12, 0.2);
    let mut accent = tint(al, ac);
    while contrast(accent, ground) < 4.5 && al < 0.95 {
        al += 0.02;
        accent = tint(al, ac);
    }
    let on_accent = if contrast((0.04, 0.04, 0.05), accent) >= contrast((1.0, 1.0, 1.0), accent) { (0.04, 0.04, 0.05) } else { (1.0, 1.0, 1.0) };
    let glow = tint(0.55, ac * 0.9);
    StrataTheme {
        ground: hex(ground),
        layer: hex(layer),
        raised: hex(raised),
        rule: hex(rule),
        ink: hex(ink),
        ink_dim: hex(ink_dim),
        ink_faint: hex(ink_faint),
        accent: hex(accent),
        on_accent: hex(on_accent),
        glow: hex(glow),
        danger: hex(from_oklab(0.68, 0.17, 0.08)),
        gutter: 20.0,
        rhythm: 8.0,
        radius: 6.0,
        radius_large: 14.0,
        type_scale: vec![44.0, 30.0, 20.0, 16.0, 13.0, 11.0],
        motion: vec![0.18, 0.32, 0.6, 0.86],
    }
}

/// Now band / Now Playing text, formatted in Rust.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StrataNow {
    pub title: String,
    pub subtitle: String,
    pub elapsed: String,
    pub remaining: String,
    pub progress: f64,
    /// "wide" for 16:9 video art (cinema layout), "square" otherwise.
    pub layout: String,
    pub up_next: Option<String>,
}

#[uniffi::export]
pub fn strata_now(title: String, artist: String, album: String, position: f64, duration: f64, art_aspect: f64, next_title: Option<String>, next_artist: Option<String>) -> StrataNow {
    let d = duration.max(0.0);
    let p = position.clamp(0.0, if d > 0.0 { d } else { f64::MAX });
    StrataNow {
        title: if title.trim().is_empty() { "Not playing".into() } else { title },
        subtitle: [artist, album].into_iter().filter(|s| !s.trim().is_empty()).collect::<Vec<_>>().join(" — "),
        elapsed: dur(p),
        remaining: if d > 0.0 { format!("-{}", dur(d - p)) } else { "--:--".into() },
        progress: if d > 0.0 { (p / d).clamp(0.0, 1.0) } else { 0.0 },
        layout: if art_aspect > 1.3 { "wide".into() } else { "square".into() },
        up_next: next_title.map(|t| match next_artist.filter(|a| !a.is_empty()) {
            Some(a) => format!("{t} · {a}"),
            None => t,
        }),
    }
}

// ---- settings, account, cloud, playlists ------------------------------------------------------

/// Current setting values handed over by Swift (key -> value).
struct Values<'a>(&'a HashMap<String, StrataValue>);

impl Values<'_> {
    fn flag(&self, k: &str) -> bool {
        matches!(self.0.get(k), Some(StrataValue::Flag { on: true }))
    }
    fn num(&self, k: &str, d: f64) -> f64 {
        match self.0.get(k) {
            Some(StrataValue::Number { value }) => *value,
            _ => d,
        }
    }
    fn text(&self, k: &str) -> String {
        match self.0.get(k) {
            Some(StrataValue::Text { value }) => value.clone(),
            _ => String::new(),
        }
    }
}

fn toggle(key: &str, title: &str, help: &str, v: &Values) -> StrataItem {
    let mut it = item(format!("set-{key}"), title);
    it.subtitle = (!help.is_empty()).then(|| help.to_string());
    it.control = Some(StrataControl::Toggle { key: key.into(), on: v.flag(key) });
    it
}

fn slider(key: &str, title: &str, min: f64, max: f64, step: f64, unit: &str, default: f64, v: &Values) -> StrataItem {
    let value = v.num(key, default).clamp(min, max);
    let mut it = item(format!("set-{key}"), title);
    it.meta = Some(fmt_value(value, step, unit));
    it.control = Some(StrataControl::Slider { key: key.into(), value, min, max, step, unit: unit.into() });
    it
}

fn fmt_value(v: f64, step: f64, unit: &str) -> String {
    let n = if step < 0.1 { format!("{v:.2}") } else if step < 1.0 { format!("{v:.1}") } else { format!("{v:.0}") };
    match unit {
        "x" => format!("{n}×"),
        "st" => format!("{}{n} st", if v > 0.0 { "+" } else { "" }),
        "" => n,
        u => format!("{n} {u}"),
    }
}

fn choice(key: &str, title: &str, options: &[(&str, &str)], default: &str, v: &Values) -> StrataItem {
    let sel = { let t = v.text(key); if t.is_empty() { default.to_string() } else { t } };
    let mut it = item(format!("set-{key}"), title);
    it.meta = options.iter().find(|o| o.0 == sel).map(|o| o.1.to_string());
    it.control = Some(StrataControl::Choice { key: key.into(), selected: sel, options: options.iter().map(|(a, b)| StrataOption { value: (*a).into(), label: (*b).into() }).collect() });
    it
}

fn link(id: &str, title: &str, glyph: &str, action: StrataAction) -> StrataItem {
    let mut it = item(id, title);
    it.glyph = Some(glyph.into());
    it.action = action;
    it
}

fn controls(id: &str, title: Option<&str>, items: Vec<StrataItem>) -> StrataSection {
    section(id, StrataStyle::Controls, title, items)
}

/// Strata accent swatches.
pub const ACCENTS: [&str; 8] = ["#FF5A3C", "#FF2E88", "#B45CFF", "#4C7DFF", "#1FB6FF", "#18C29C", "#9BD43B", "#FFB020"];

fn settings(page: &str, v: &Values) -> StrataScreen {
    let route = StrataRoute::Settings { page: page.into() };
    let page_link = |id: &str, title: &str, glyph: &str, sub: &str| {
        let mut it = link(&format!("page-{id}"), title, glyph, StrataAction::Open { route: StrataRoute::Settings { page: id.into() } });
        it.subtitle = Some(sub.into());
        it
    };
    let (title, sections): (&str, Vec<StrataSection>) = match page {
        "sound" => ("Sound", vec![
            controls("eq", Some("Equalizer"), vec![
                toggle("audio.eq", "Equalizer", "10-band EQ in the Rust engine", v),
                choice("audio.eqPreset", "Preset", &[("Flat", "Flat"), ("Bass Boost", "Bass Boost"), ("Treble Boost", "Treble Boost"), ("Vocal", "Vocal"), ("Pop", "Pop"), ("Electronic", "Electronic"), ("Rock", "Rock"), ("Classical", "Classical"), ("Jazz", "Jazz"), ("Hip-Hop", "Hip-Hop"), ("Acoustic", "Acoustic")], "Flat", v),
                toggle("audio.autoEQ", "Auto EQ", "Shapes each song toward your library's tone", v),
                toggle("audio.bassBoost", "Bass boost", "", v),
                slider("audio.bassBoostGain", "Bass boost amount", 0.0, 15.0, 1.0, "dB", 6.0, v),
            ]),
            controls("space", Some("Space"), vec![
                toggle("audio.reverb", "Reverb", "", v),
                choice("audio.reverbPreset", "Room", &[("smallRoom", "Small Room"), ("mediumRoom", "Medium Room"), ("largeRoom", "Large Room"), ("mediumHall", "Medium Hall"), ("largeHall", "Large Hall"), ("plate", "Plate"), ("cathedral", "Cathedral")], "mediumRoom", v),
                slider("audio.reverbMix", "Reverb mix", 0.0, 100.0, 1.0, "%", 18.0, v),
                toggle("audio.spatial", "Spatial audio", "Head-tracked with AirPods", v),
                toggle("audio.eightD", "8D", "Sound circles around you", v),
            ]),
            controls("tone", Some("Speed & pitch"), vec![
                slider("audio.speed", "Speed", 0.5, 2.0, 0.05, "x", 1.0, v),
                slider("audio.pitch", "Pitch", -12.0, 12.0, 0.5, "st", 0.0, v),
            ]),
            controls("level", Some("Level"), vec![
                toggle("audio.replayGain", "Even out loudness", "Plays every song at a similar volume", v),
                toggle("audio.night", "Night mode", "Quiet parts louder, loud parts softer", v),
                toggle("audio.mono", "Mono", "", v),
            ]),
        ]),
        "playback" => ("Playback", vec![
            controls("transitions", Some("Between songs"), vec![
                toggle("audio.gapless", "Gapless", "No silence between tracks", v),
                toggle("audio.smartCrossfade", "Smart Crossfade", "Bar-aligned, beat-matched blends with bass swaps", v),
                toggle("audio.crossfade", "Fixed crossfade", "A plain fade of a set length", v),
                slider("audio.crossfadeDuration", "Fade length", 1.0, 12.0, 0.5, "s", 4.0, v),
                choice("audio.crossfadeCurve", "Fade curve", &[("equalPower", "Equal power"), ("linear", "Linear")], "equalPower", v),
                toggle("intro.skip", "Skip silent intros", "Starts songs at the music", v),
            ]),
            controls("order", Some("What plays next"), vec![
                toggle("shuffle.smart", "Smart Shuffle", "Spreads artists and holds back songs you skip", v),
                toggle("radio.auto", "Lumisound Radio", "Keeps going with similar songs when the queue ends", v),
                choice("radio.mode", "Radio mix", &[("balanced", "Balanced"), ("familiar", "More of what I know"), ("discover", "Discover new music")], "balanced", v),
            ]),
        ]),
        "haptics" => ("Music Haptics", vec![
            controls("haptics", None, vec![
                toggle("audio.haptics", "Music Haptics", "Feel the beat. The Haptics Brain keeps learning even when this is off.", v),
                choice("haptics.strength", "Feel", &[("subtle", "Subtle"), ("balanced", "Balanced"), ("intense", "Intense")], "balanced", v),
            ]),
        ]),
        "library" => ("Library & downloads", vec![
            controls("cloud", Some("Cloud"), vec![
                toggle("library.autoBackup", "Back up to the cloud", "New songs upload to your cloud library", v),
                toggle("downloads.wifiOnly", "Downloads on Wi-Fi only", "", v),
            ]),
            controls("ytdlp", Some("Downloader"), vec![
                slider("ytdlp.fragments", "Parallel fragments", 1.0, 16.0, 1.0, "", 8.0, v),
                toggle("ytdlp.aria2", "Use aria2", "Faster downloads for long videos", v),
            ]),
            controls("maint", Some("Maintenance"), vec![
                link("rescan", "Rescan library", "arrow.clockwise", StrataAction::SetSetting { key: "library.rescan".into(), value: StrataValue::Flag { on: true } }),
            ]),
        ]),
        "appearance" => {
            let accent = { let a = v.text("strata.accent"); if a.is_empty() { ACCENTS[0].to_string() } else { a } };
            let mut sw = item("set-strata.accent", "Accent");
            sw.subtitle = Some("Seeds the palette; the playing artwork tints it.".into());
            sw.control = Some(StrataControl::Swatches { key: "strata.accent".into(), selected: accent, colors: ACCENTS.iter().map(|c| c.to_string()).collect() });
            ("Appearance", vec![
                controls("edition", Some("Interface"), vec![
                    choice("ui.edition", "Interface", &[("strata", "Strata"), ("lumen", "Lumen"), ("classic", "Classic")], "strata", v),
                    sw,
                ]),
                controls("motion", Some("Motion"), vec![
                    toggle("ui.reduceMotion", "Reduce motion", "", v),
                    toggle("car.mode", "Car mode", "Big controls when connected to a car", v),
                ]),
            ])
        }
        "sleep" => {
            let rem = v.num("sleep.remaining", 0.0);
            let mut sec = controls("sleep", None, [0.0, 15.0, 30.0, 45.0, 60.0, 90.0].iter().map(|m| {
                let mut it = item(format!("sleep-{m}"), if *m == 0.0 { "Off".to_string() } else { format!("{m:.0} minutes") });
                it.glyph = Some(if *m == 0.0 { "moon.zzz" } else { "timer" }.into());
                it.action = StrataAction::SetSetting { key: "sleep.minutes".into(), value: StrataValue::Number { value: *m } };
                it
            }).collect());
            if rem > 0.0 {
                sec.caption = Some(format!("Stops in {}", dur(rem)));
            }
            ("Sleep timer", vec![sec])
        }
        "about" => ("About", vec![controls("about", None, vec![
            { let mut it = item("version", "Version"); it.meta = Some(v.text("app.version")); it },
            link("updates", "Check for updates", "arrow.down.app", StrataAction::OpenClassic { page: "updates".into() }),
            link("help", "Help", "questionmark.circle", StrataAction::OpenClassic { page: "help".into() }),
        ])]),
        _ => ("Settings", vec![
            controls("pages", None, vec![
                page_link("sound", "Sound", "waveform", "EQ, reverb, spatial, speed and pitch"),
                page_link("playback", "Playback", "play.circle", "Smart Crossfade, gapless, shuffle, radio"),
                page_link("haptics", "Music Haptics", "hand.tap", "Feel the beat"),
                page_link("library", "Library & downloads", "square.and.arrow.down", "Cloud backup and the downloader"),
                page_link("appearance", "Appearance", "paintpalette", "Interface and accent"),
                page_link("sleep", "Sleep timer", "moon.zzz", "Stop playing after a while"),
                link("page-account", "Account", "person.crop.circle", StrataAction::Open { route: StrataRoute::Account }),
                page_link("about", "About", "info.circle", "Version, updates, help"),
            ]),
            controls("more", Some("Everything else"), vec![
                link("classic", "More settings", "gearshape.2", StrataAction::OpenClassic { page: "all".into() }),
            ]),
        ]),
    };
    StrataScreen { route, kicker: Some("Settings".into()), title: title.into(), subtitle: None, art: None, actions: vec![], sections }
}

fn account(l: &Lib, v: &Values) -> StrataScreen {
    let signed_in = v.flag("account.signedIn");
    let mut sections = Vec::new();
    if signed_in {
        let name = { let d = v.text("account.displayName"); if d.is_empty() { v.text("account.username") } else { d } };
        let mut me = item("me", name);
        me.subtitle = Some(format!("@{}", v.text("account.username")));
        me.meta = Some(v.text("account.email")).filter(|e| !e.is_empty());
        me.glyph = Some("person.crop.circle.fill".into());
        sections.push(section("me", StrataStyle::Hero, None, vec![me]));
        let mut a = item("stat-cloud", format!("{:.0}", v.num("account.cloudCount", 0.0)));
        a.subtitle = Some("in your cloud".into());
        a.action = StrataAction::Open { route: StrataRoute::Cloud { query: String::new() } };
        let mut b = item("stat-songs", l.songs.len().to_string());
        b.subtitle = Some("on this device".into());
        b.action = StrataAction::Open { route: StrataRoute::Library { tab: "songs".into() } };
        sections.push(section("stats", StrataStyle::Stats, None, vec![a, b]));
        sections.push(controls("privacy", Some("Sharing"), vec![
            toggle("account.shareListening", "Share what I'm listening to", "Friends see your current song", v),
        ]));
        sections.push(controls("manage", Some("Manage"), vec![
            link("profile", "Profile, password & security", "person.text.rectangle", StrataAction::OpenClassic { page: "account".into() }),
            { let mut so = link("signout", "Sign out", "rectangle.portrait.and.arrow.right", StrataAction::SignOut); so.emphasis = true; so },
        ]));
    } else {
        let mut n = item("signin", "Sign in to Lumisound");
        n.subtitle = Some("Your cloud library, sync across devices, Radio and Aria lyrics.".into());
        n.glyph = Some("person.crop.circle.badge.plus".into());
        sections.push(section("note", StrataStyle::Note, None, vec![n]));
        sections.push(controls("go", None, vec![link("go", "Sign in or create an account", "arrow.right.circle", StrataAction::SignIn)]));
    }
    StrataScreen { route: StrataRoute::Account, kicker: Some("You".into()), title: "Account".into(), subtitle: None, art: None, actions: vec![], sections }
}

fn remote_row(r: &StrataRemote) -> StrataItem {
    let mut it = item(format!("r-{}-{}", r.source, r.id), &r.title);
    it.subtitle = Some(if r.artist.is_empty() { r.source.clone() } else { r.artist.clone() });
    it.meta = (r.duration > 0.0).then(|| dur(r.duration));
    it.glyph = Some(if r.source == "cloud" { "icloud" } else { "globe" }.into());
    it.art = Some(format!("remote:{}", r.thumbnail));
    if r.source == "cloud" {
        it.action = StrataAction::CloudPlay { id: r.id.clone() };
    } else {
        it.action = StrataAction::StreamPlay { id: r.id.clone() };
        it.secondary = (!r.downloaded).then(|| StrataAction::StreamDownload { id: r.id.clone() });
        it.emphasis = r.downloaded;
    }
    it
}

fn cloud(l: &Lib, r: &Remote, query: &str) -> StrataScreen {
    let q = words(query);
    let route = StrataRoute::Cloud { query: query.into() };
    let mut sections = Vec::new();
    if q.is_empty() {
        if r.cloud.is_empty() {
            let mut n = item("empty", "Your cloud is empty");
            n.subtitle = Some("Turn on cloud backup in Settings, or search above to stream and download.".into());
            n.glyph = Some("icloud".into());
            sections.push(section("empty", StrataStyle::Note, None, vec![n]));
        } else {
            let mut s = section("cloud", StrataStyle::Ledger, Some("In your cloud"), r.cloud.iter().take(400).map(remote_row).collect());
            s.caption = Some(plural(r.cloud.len(), "song", "songs"));
            sections.push(s);
        }
        return StrataScreen { route, kicker: Some("Cloud".into()), title: "Cloud".into(), subtitle: Some("Stream, download and your uploads".into()), art: None, actions: vec![], sections };
    }
    // Your cloud uploads that match.
    let mine: Vec<StrataItem> = r.cloud.iter().filter(|t| {
        let mut w = words(&t.title);
        w.extend(words(&t.artist));
        match_score(&q, &w, w.len()) > 0.0
    }).take(20).map(remote_row).collect();
    if r.query == query && !r.results.is_empty() {
        let rows: Vec<StrataItem> = r.results.iter().map(remote_row).collect();
        let mut s = section("results", StrataStyle::Ledger, Some("Online"), rows);
        s.caption = Some("Tap to stream · hold to download".into());
        sections.push(s);
    } else if r.searching || r.query != query {
        let mut n = item("searching", "Searching…");
        n.glyph = Some("globe".into());
        sections.push(section("searching", StrataStyle::Note, None, vec![n]));
    } else {
        let mut n = item("none", format!("Nothing online for “{}”", query.trim()));
        n.glyph = Some("globe".into());
        sections.push(section("none", StrataStyle::Note, None, vec![n]));
    }
    if !mine.is_empty() {
        sections.push(section("mine", StrataStyle::Ledger, Some("In your cloud"), mine));
    }
    let local = l.tokens.iter().enumerate().filter(|(i, t)| match_score(&q, t, words(&l.songs[*i].title).len()) > 0.0).count();
    if local > 0 {
        let mut it = link("local", &format!("{} in your library", plural(local, "song", "songs")), "square.stack.3d.up", StrataAction::Open { route: StrataRoute::Search { query: query.into() } });
        it.subtitle = Some("Open in Search".into());
        sections.push(controls("local", None, vec![it]));
    }
    StrataScreen { route, kicker: Some("Cloud".into()), title: query.trim().into(), subtitle: None, art: None, actions: vec![], sections }
}

fn add_to_playlist(l: &Lib, ids: &[String]) -> StrataScreen {
    let route = StrataRoute::AddToPlaylist { ids: ids.to_vec() };
    let mut new = link("new", "New playlist", "plus.square.on.square", StrataAction::CreatePlaylist { name: None, ids: ids.to_vec() });
    new.emphasis = true;
    let mut rows: Vec<StrataItem> = playlist_items(l).into_iter().map(|mut p| {
        let pid = p.id.trim_start_matches("playlist-").to_string();
        p.action = StrataAction::AddToPlaylist { playlist: pid, ids: ids.to_vec() };
        p
    }).collect();
    rows.insert(0, new);
    let what = if ids.len() == 1 { l.by_id.get(&ids[0]).map(|&i| l.songs[i].title.clone()).unwrap_or_else(|| "1 song".into()) } else { plural(ids.len(), "song", "songs") };
    StrataScreen { route, kicker: Some("Add to playlist".into()), title: what, subtitle: None, art: ids.first().cloned(), actions: vec![], sections: vec![section("playlists", StrataStyle::Ledger, None, rows)] }
}

pub const SONG_SORTS: [(&str, &str); 6] = [("title", "Title"), ("artist", "Artist"), ("album", "Album"), ("added", "Recently added"), ("plays", "Most played"), ("duration", "Length")];

/// Library sort chips for a tab.
fn sort_chips(tab: &str, current: &str) -> StrataSection {
    let opts: &[(&str, &str)] = match tab {
        "songs" => &SONG_SORTS,
        "albums" => &[("title", "Title"), ("artist", "Artist"), ("year", "Year")],
        "artists" => &[("name", "Name"), ("songs", "Most songs")],
        _ => &[],
    };
    section("sort", StrataStyle::Chips, None, opts.iter().map(|(k, label)| {
        let mut c = item(format!("sort-{k}"), *label);
        c.emphasis = *k == current;
        c.glyph = Some("arrow.up.arrow.down".into());
        c.action = StrataAction::SetSort { tab: tab.into(), sort: (*k).into() };
        c
    }).collect())
}

// ---- lyrics -----------------------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct StrataLyric {
    pub time: f64,
    pub text: String,
}

/// LRC (or plain text: all times 0) into sorted lines. Handles several
/// timestamps on one line, `[offset:ms]`, metadata tags and blank lines.
#[uniffi::export]
pub fn strata_lyrics_parse(text: String) -> Vec<StrataLyric> {
    let mut out = Vec::new();
    let mut offset = 0.0;
    let mut timed = false;
    for raw in text.lines() {
        let mut line = raw.trim();
        let mut times = Vec::new();
        while let Some(rest) = line.strip_prefix('[') {
            let Some(end) = rest.find(']') else { break };
            let tag = &rest[..end];
            if let Some(o) = tag.strip_prefix("offset:") {
                offset = o.trim().parse::<f64>().unwrap_or(0.0) / 1000.0;
            } else if let Some((m, sec)) = tag.split_once(':') {
                if let (Ok(m), Ok(sec)) = (m.trim().parse::<f64>(), sec.trim().parse::<f64>()) {
                    times.push(m * 60.0 + sec);
                }
            }
            line = rest[end + 1..].trim();
        }
        if times.is_empty() {
            if !line.is_empty() && !raw.trim_start().starts_with('[') {
                out.push(StrataLyric { time: 0.0, text: line.to_string() });
            }
            continue;
        }
        timed = true;
        for t in times {
            out.push(StrataLyric { time: (t - offset).max(0.0), text: line.to_string() });
        }
    }
    if timed {
        out.retain(|l| l.time > 0.0 || !l.text.is_empty());
        out.sort_by(|a, b| a.time.total_cmp(&b.time));
    }
    out
}

/// Index of the line being sung at `position` (-1 before the first, or untimed).
#[uniffi::export]
pub fn strata_lyric_index(times: Vec<f64>, position: f64) -> i32 {
    if times.iter().all(|t| *t == 0.0) {
        return -1;
    }
    times.partition_point(|t| *t <= position + 0.15) as i32 - 1
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn lib() -> Arc<StrataCore> {
        let now = 1_800_000_000.0;
        let mut songs = Vec::new();
        for i in 0..300 {
            songs.push(StrataSong {
                id: format!("s{i}"),
                title: format!("{} Song {i}", ["Alpha", "Bravo", "Échelon", "the Delta", "42"][i % 5]),
                artist: ["Lana Del Rey", "Daft Punk", "Björk"][i % 3].into(),
                album: format!("Album {}", i % 7),
                genre: ["Pop", "Electronic"][i % 2].into(),
                year: "2020".into(),
                duration: 200.0 + i as f64,
                added: now - i as f64 * 3600.0,
                plays: (i % 11) as u32,
                last_played: if i % 4 == 0 { now - (i as f64) * 86400.0 } else { 0.0 },
                favorite: i % 9 == 0,
                bpm: 80.0 + (i % 90) as f64,
                remote: false,
            });
        }
        let core = StrataCore::new();
        core.set_library(songs, vec![StrataPlaylist { id: "p1".into(), name: "Night Drive".into(), song_ids: vec!["s1".into(), "s2".into(), "gone".into()], created: now, folder: None }]);
        core
    }

    #[test]
    fn home_has_editorial_sections() {
        let c = lib();
        let s = c.screen(StrataRoute::Home, 1_800_000_000.0, 23, Some("s5".into()), vec![], 0, HashMap::new());
        assert_eq!(s.title, "Still up");
        let ids: Vec<&str> = s.sections.iter().map(|x| x.id.as_str()).collect();
        assert_eq!(ids[0], "resume");
        for want in ["rotation", "fresh", "tempo", "top-artists", "stats"] {
            assert!(ids.contains(&want), "{want} missing from {ids:?}");
        }
        let resume = &s.sections[0].items[0];
        assert_eq!(resume.id, "s5");
        assert_eq!(resume.meta.as_deref(), Some("Now playing"));
    }

    #[test]
    fn library_pages_and_index() {
        let c = lib();
        let s = c.screen(StrataRoute::Library { tab: "songs".into() }, 0.0, 12, None, vec![], 0, HashMap::new());
        let list = s.sections.iter().find(|x| x.id == "list").unwrap();
        assert_eq!(list.total, 300);
        assert_eq!(list.items.len(), PAGE);
        // "the Delta" sorts under D, digits under #, accents folded (Échelon under E).
        assert!(list.index.contains(&"D".to_string()) && list.index.contains(&"#".to_string()) && list.index.contains(&"E".to_string()), "{:?}", list.index);
        let more = c.page(StrataRoute::Library { tab: "songs".into() }, "list".into(), PAGE as u32, 500);
        assert_eq!(more.len(), 300 - PAGE);
        // Tapping row k plays the whole sorted list from k.
        match &list.items[3].action {
            StrataAction::PlayFrom { section, index, .. } => {
                assert_eq!(section, "list");
                assert_eq!(*index, 3);
                let ids = c.section_ids(StrataRoute::Library { tab: "songs".into() }, "list".into());
                assert_eq!(ids.len(), 300);
                assert_eq!(ids[3], list.items[3].id);
            }
            a => panic!("{a:?}"),
        }
    }

    #[test]
    fn search_ranks_and_tolerates_typos() {
        let c = lib();
        let s = c.screen(StrataRoute::Search { query: "bjork".into() }, 0.0, 12, None, vec![], 0, HashMap::new());
        assert!(s.sections.iter().any(|x| x.id == "artists" && x.items[0].title == "Björk"), "accent-folded artist match");
        let s = c.screen(StrataRoute::Search { query: "echelon song 2".into() }, 0.0, 12, None, vec![], 0, HashMap::new());
        assert_eq!(s.sections[0].id, "top");
        assert!(s.sections[0].items[0].title.starts_with("Échelon Song 2"), "{:?}", s.sections[0].items[0].title);
        let s = c.screen(StrataRoute::Search { query: "bravvo".into() }, 0.0, 12, None, vec![], 0, HashMap::new());
        assert!(s.sections[0].items[0].title.starts_with("Bravo"), "one-letter typo still finds it");
        let s = c.screen(StrataRoute::Search { query: "zzzz".into() }, 0.0, 12, None, vec![], 0, HashMap::new());
        assert_eq!(s.sections[0].style, StrataStyle::Note);
    }

    #[test]
    fn detail_screens() {
        let c = lib();
        let a = c.screen(StrataRoute::Artist { name: "lana del rey".into() }, 1_800_000_000.0, 12, None, vec![], 0, HashMap::new());
        assert_eq!(a.title, "Lana Del Rey");
        assert_eq!(a.actions[0].title, "Play");
        let key = album_key("Daft Punk", "Album 1");
        let al = c.screen(StrataRoute::Album { key }, 0.0, 12, None, vec![], 0, HashMap::new());
        assert!(al.subtitle.unwrap().starts_with("Daft Punk"));
        let p = c.screen(StrataRoute::Playlist { id: "p1".into() }, 0.0, 12, None, vec![], 0, HashMap::new());
        assert_eq!(p.sections[0].items.len(), 2);
        assert_eq!(p.sections[0].caption.as_deref(), Some("1 song not on this device"));
        let q = c.screen(StrataRoute::Queue, 0.0, 12, None, vec!["s1".into(), "s2".into(), "yt123".into()], 1, HashMap::new());
        assert_eq!(q.sections[0].items[0].action, StrataAction::QueueJump { index: 1 });
        assert_eq!(q.sections[1].items[0].title, "Streaming track");
    }

    #[test]
    fn theme_contrast_and_tint() {
        for (accent, art) in [("#FF5A3C", None), ("#3355FF", Some(vec![0.1, 0.8, 0.3])), ("#777777", Some(vec![0.5, 0.5, 0.5])), ("bogus", None)] {
            let t = strata_theme(accent.into(), art);
            let g = parse_hex(&t.ground).unwrap();
            assert!(contrast(parse_hex(&t.accent).unwrap(), g) >= 4.5, "{accent}: accent {} on {}", t.accent, t.ground);
            assert!(contrast(parse_hex(&t.ink).unwrap(), g) >= 12.0);
            assert!(contrast(parse_hex(&t.ink_dim).unwrap(), g) >= 7.0);
            assert!(contrast(parse_hex(&t.ink_faint).unwrap(), g) >= 3.0);
            assert!(contrast(parse_hex(&t.on_accent).unwrap(), parse_hex(&t.accent).unwrap()) >= 4.5);
        }
        // Artwork colour leads the accent hue.
        let green = strata_theme("#FF0000".into(), Some(vec![0.1, 0.8, 0.3]));
        let (r, gch, _) = parse_hex(&green.accent).unwrap();
        assert!(gch > r, "accent follows the artwork: {}", green.accent);
    }

    /// The crash: Library on a big library put every song id into every
    /// row. Screens must stay small whatever the library size, and paging
    /// and `section_ids` must agree with the rows.
    #[test]
    fn big_library_screens_stay_small() {
        let n = 6000;
        let songs: Vec<StrataSong> = (0..n).map(|i| StrataSong {
            id: format!("local:Imported Music/Song {i:05}.opus.lms"),
            title: format!("Track {} {i}", ["Alpha", "Bravo", "Charlie", "Delta"][i % 4]),
            artist: format!("Artist {}", i % 40),
            album: format!("Album {}", i % 300),
            genre: "Pop".into(),
            duration: 200.0,
            added: i as f64,
            plays: (i % 7) as u32,
            last_played: if i % 2 == 0 { i as f64 } else { 0.0 },
            favorite: i % 3 == 0,
            ..Default::default()
        }).collect();
        let core = StrataCore::new();
        core.set_library(songs, vec![StrataPlaylist { id: "big".into(), name: "Everything".into(), song_ids: (0..n).map(|i| format!("local:Imported Music/Song {i:05}.opus.lms")).collect(), created: 0.0, folder: None }]);
        let weight = |sc: &StrataScreen| -> usize {
            let w = |a: &StrataAction| match a {
                StrataAction::Play { ids, .. } | StrataAction::PlayNext { ids } | StrataAction::AddToQueue { ids } => ids.len(),
                _ => 1,
            };
            sc.actions.iter().map(|i| w(&i.action)).sum::<usize>() + sc.sections.iter().flat_map(|s| &s.items).map(|i| w(&i.action) + i.secondary.as_ref().map_or(0, w)).sum::<usize>()
        };
        let routes = [
            StrataRoute::Library { tab: "songs".into() },
            StrataRoute::Library { tab: "recent".into() },
            StrataRoute::Library { tab: "albums".into() },
            StrataRoute::Library { tab: "artists".into() },
            StrataRoute::Favorites,
            StrataRoute::History,
            StrataRoute::Genre { name: "Pop".into() },
            StrataRoute::Playlist { id: "big".into() },
            StrataRoute::Artist { name: "Artist 3".into() },
            StrataRoute::Home,
            StrataRoute::Search { query: "bravo".into() },
        ];
        for r in routes {
            let t = std::time::Instant::now();
            let sc = core.screen(r.clone(), 10_000.0, 12, None, vec![], 0, HashMap::new());
            let ms = t.elapsed().as_secs_f64() * 1000.0;
            let w = weight(&sc);
            assert!(w < 2_000, "{r:?}: {w} ids in one screen");
            assert!(ms < 400.0, "{r:?}: {ms:.0} ms");
        }
        // Row k of page 2 plays section_ids from k, and they line up.
        let route = StrataRoute::Library { tab: "songs".into() };
        let ids = core.section_ids(route.clone(), "list".into());
        assert_eq!(ids.len(), n);
        let page = core.page(route.clone(), "list".into(), PAGE as u32, 50);
        assert_eq!(page.len(), 50);
        for (k, row) in page.iter().enumerate() {
            match &row.action {
                StrataAction::PlayFrom { section, index, .. } => {
                    assert_eq!(section, "list");
                    assert_eq!(*index as usize, PAGE + k);
                    assert_eq!(ids[*index as usize], row.id, "row and play order disagree");
                }
                a => panic!("{a:?}"),
            }
        }
        // Artist "All songs": first page and later pages share one order.
        let ar = StrataRoute::Artist { name: "Artist 3".into() };
        let sc = core.screen(ar.clone(), 0.0, 12, None, vec![], 0, HashMap::new());
        let first = &sc.sections.iter().find(|s| s.id == "songs").unwrap().items;
        let all = core.section_ids(ar, "songs".into());
        for (k, row) in first.iter().enumerate() {
            assert_eq!(all[k], row.id);
        }
    }

    #[test]
    fn settings_pages_reflect_values() {
        let c = lib();
        let mut v = HashMap::new();
        v.insert("audio.eq".to_string(), StrataValue::Flag { on: true });
        v.insert("audio.speed".to_string(), StrataValue::Number { value: 1.25 });
        v.insert("audio.eqPreset".to_string(), StrataValue::Text { value: "Rock".into() });
        let s = c.screen(StrataRoute::Settings { page: "sound".into() }, 0.0, 12, None, vec![], 0, v);
        let all: Vec<&StrataItem> = s.sections.iter().flat_map(|x| &x.items).collect();
        let eq = all.iter().find(|i| i.id == "set-audio.eq").unwrap();
        assert_eq!(eq.control, Some(StrataControl::Toggle { key: "audio.eq".into(), on: true }));
        let sp = all.iter().find(|i| i.id == "set-audio.speed").unwrap();
        assert_eq!(sp.meta.as_deref(), Some("1.25×"));
        let pr = all.iter().find(|i| i.id == "set-audio.eqPreset").unwrap();
        assert_eq!(pr.meta.as_deref(), Some("Rock"));
        // Every page builds and has controls.
        for page in ["root", "sound", "playback", "haptics", "library", "appearance", "sleep", "about"] {
            let s = c.screen(StrataRoute::Settings { page: page.into() }, 0.0, 12, None, vec![], 0, HashMap::new());
            assert!(!s.sections.is_empty(), "{page}");
        }
    }

    #[test]
    fn account_signed_in_and_out() {
        let c = lib();
        let s = c.screen(StrataRoute::Account, 0.0, 12, None, vec![], 0, HashMap::new());
        assert!(s.sections.iter().flat_map(|x| &x.items).any(|i| i.action == StrataAction::SignIn));
        let mut v = HashMap::new();
        v.insert("account.signedIn".to_string(), StrataValue::Flag { on: true });
        v.insert("account.username".to_string(), StrataValue::Text { value: "hx".into() });
        let s = c.screen(StrataRoute::Account, 0.0, 12, None, vec![], 0, v);
        assert_eq!(s.sections[0].items[0].subtitle.as_deref(), Some("@hx"));
        assert!(s.sections.iter().flat_map(|x| &x.items).any(|i| i.action == StrataAction::SignOut));
    }

    #[test]
    fn cloud_results_and_library_sort() {
        let c = lib();
        c.set_cloud(vec![StrataRemote { id: "c1".into(), title: "Bravo Live".into(), artist: "Daft Punk".into(), source: "cloud".into(), ..Default::default() }]);
        let s = c.screen(StrataRoute::Cloud { query: "bravo".into() }, 0.0, 12, None, vec![], 0, HashMap::new());
        assert_eq!(s.sections[0].id, "searching");
        c.set_results("bravo".into(), vec![StrataRemote { id: "yt1".into(), title: "Bravo".into(), source: "youtube".into(), ..Default::default() }], false);
        let s = c.screen(StrataRoute::Cloud { query: "bravo".into() }, 0.0, 12, None, vec![], 0, HashMap::new());
        assert_eq!(s.sections[0].items[0].action, StrataAction::StreamPlay { id: "yt1".into() });
        assert_eq!(s.sections[0].items[0].secondary, Some(StrataAction::StreamDownload { id: "yt1".into() }));
        assert!(s.sections.iter().any(|x| x.id == "mine"));
        // Sorting songs by length: longest first, and paging/section_ids follow it.
        c.set_sort("songs".into(), "duration".into());
        let ids = c.section_ids(StrataRoute::Library { tab: "songs".into() }, "list".into());
        assert_eq!(ids[0], "s299");
        let lib_s = c.screen(StrataRoute::Library { tab: "songs".into() }, 0.0, 12, None, vec![], 0, HashMap::new());
        assert!(lib_s.sections.iter().any(|x| x.id == "sort" && x.items.iter().any(|i| i.emphasis && i.id == "sort-duration")));
        assert!(lib_s.sections.iter().find(|x| x.id == "list").unwrap().index.is_empty(), "no A-Z rail when not sorted by name");
        // Add to playlist offers "New playlist" then the playlists.
        let a = c.screen(StrataRoute::AddToPlaylist { ids: vec!["s1".into()] }, 0.0, 12, None, vec![], 0, HashMap::new());
        assert_eq!(a.sections[0].items[0].action, StrataAction::CreatePlaylist { name: None, ids: vec!["s1".into()] });
        assert_eq!(a.sections[0].items[1].action, StrataAction::AddToPlaylist { playlist: "p1".into(), ids: vec!["s1".into()] });
    }

    #[test]
    fn lyrics_parse_and_follow() {
        let l = strata_lyrics_parse("[ar:Someone]\n[offset:500]\n[00:10.00][00:40.00]Chorus line\n[00:20.50]Verse two\n\n".into());
        assert_eq!(l.iter().map(|x| (x.time, x.text.as_str())).collect::<Vec<_>>(), vec![(9.5, "Chorus line"), (20.0, "Verse two"), (39.5, "Chorus line")]);
        let times: Vec<f64> = l.iter().map(|x| x.time).collect();
        assert_eq!(strata_lyric_index(times.clone(), 5.0), -1);
        assert_eq!(strata_lyric_index(times.clone(), 21.0), 1);
        assert_eq!(strata_lyric_index(times, 100.0), 2);
        let plain = strata_lyrics_parse("first\nsecond".into());
        assert_eq!(plain.len(), 2);
        assert_eq!(strata_lyric_index(plain.iter().map(|x| x.time).collect(), 50.0), -1);
    }

    #[test]
    fn now_text() {
        let n = strata_now("Song".into(), "Artist".into(), "".into(), 61.0, 200.0, 16.0 / 9.0, Some("Next".into()), Some("B".into()));
        assert_eq!((n.elapsed.as_str(), n.remaining.as_str(), n.layout.as_str()), ("1:01", "-2:19", "wide"));
        assert_eq!(n.subtitle, "Artist");
        assert_eq!(n.up_next.as_deref(), Some("Next · B"));
    }
}
