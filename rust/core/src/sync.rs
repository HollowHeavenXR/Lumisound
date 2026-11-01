//! Account sync (`/user/sync`): builds the push payload from the device's
//! state and turns a pulled payload into a merge plan. Swift only reads and
//! writes UserDefaults / library state; every rule lives here:
//!
//! * push is skipped while the library hasn't loaded but favourites or
//!   playlists exist (the server REPLACES both, so an early push wipes them);
//! * favourites, playlists and stores only ever merge in (never removed by a
//!   pull — a server behind the device must not delete local data);
//! * settings restore only into keys that are unset locally (first-run /
//!   new-device bootstrap), so a fresher local value is never clobbered;
//! * badges union.

use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet};

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum PrefValue {
    Bool { v: bool },
    Int { v: i64 },
    Double { v: f64 },
    Str { v: String },
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrefKind {
    Bool,
    Int,
    Double,
    Str,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrefEntry {
    pub key: String,
    pub value: PrefValue,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct PrefKey {
    pub key: String,
    pub kind: PrefKind,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SyncFavoriteRec {
    pub song_id: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SyncTrackRec {
    pub local_song_id: Option<String>,
    pub track_url: Option<String>,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_seconds: Option<i64>,
    pub position: Option<i64>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SyncPlaylistRec {
    pub id: String,
    pub name: String,
    pub folder: Option<String>,
    pub tags: Vec<String>,
    pub tracks: Vec<SyncTrackRec>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct BpmEntry {
    pub source_track_id: String,
    pub bpm: f64,
}

/// Opaque JSON blobs owned by other stores, passed through as-is.
#[derive(uniffi::Record, Clone, Debug, Default, PartialEq)]
pub struct SyncBlobs {
    pub audio_settings_json: Option<String>,
    pub track_audio_settings_json: Option<String>,
    pub play_history_json: Option<String>,
    pub smart_playlists_json: Option<String>,
    pub tracked_playlists_json: Option<String>,
    pub bookmarks_json: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct SyncLocal {
    pub favorites: Vec<SyncFavoriteRec>,
    pub playlists: Vec<SyncPlaylistRec>,
    /// Every set key from `sync_pref_keys()`.
    pub prefs: Vec<PrefEntry>,
    pub theme_hex: Option<String>,
    pub earned_badges: Vec<String>,
    pub blobs: SyncBlobs,
    pub bpm_by_source: Vec<BpmEntry>,
}

const VINYL_LEGACY: &str = "nowPlaying_showVinylDisc";
const ARTWORK_STYLE: &str = "nowPlaying_artworkStyle";

/// Dedicated payload columns <- UserDefaults key.
const COLUMNS: &[(&str, &str, PrefKind)] = &[
    ("show_queue_preview", "nowPlaying_showQueuePreview", PrefKind::Bool),
    ("songs_per_row", "library_songs_columns", PrefKind::Int),
    ("albums_per_row", "library_albums_columns", PrefKind::Int),
    ("bg_animation", "bgService.animation", PrefKind::Str),
    ("bg_opacity", "bgService.opacity", PrefKind::Double),
    ("bg_enabled", "bgService.isEnabled", PrefKind::Bool),
    ("bg_blur_radius", "bgService.blurRadius", PrefKind::Double),
    ("bg_shuffle_interval", "bgService.shuffleInterval", PrefKind::Double),
    ("preferred_audio_format", "streaming_preferred_format", PrefKind::Str),
    ("download_path", "download_path_key", PrefKind::Str),
    ("car_mode_enabled", "carModeEnabled", PrefKind::Bool),
    ("library_artists_columns", "library_artists_columns", PrefKind::Int),
    ("now_playing_artwork_style", ARTWORK_STYLE, PrefKind::Str),
    ("now_playing_seeker_style", "nowPlaying_seekerStyle", PrefKind::Str),
];

/// Preferences backed up as one JSON bag (`extra_settings_json`). Adding a
/// backed-up preference is one line here.
const EXTRA: &[(&str, PrefKind)] = &[
    ("library_cardStyle", PrefKind::Str),
    ("autoRadio_enabled", PrefKind::Bool),
    ("notifications_enabled", PrefKind::Bool),
    ("ytdlp_use_aria2", PrefKind::Bool),
    ("glass_tintStrength", PrefKind::Double),
    ("glass_tintHue", PrefKind::Double),
    ("glass_useAccentTint", PrefKind::Bool),
    ("glass_translucency", PrefKind::Double),
    ("library_favorites_columns", PrefKind::Int),
    ("library_genres_columns", PrefKind::Int),
    ("library_folders_columns", PrefKind::Int),
    ("folderDetail_columns", PrefKind::Int),
    ("albumDetail_columns", PrefKind::Int),
    ("app_background_theme", PrefKind::Str),
    ("app_font_style", PrefKind::Str),
    ("launch_screen_style", PrefKind::Str),
    ("tab_transition_style", PrefKind::Str),
    ("panel_material_style", PrefKind::Str),
    ("panel_opacity", PrefKind::Double),
    ("app_reduce_motion", PrefKind::Bool),
    ("ytdlp_download_folder", PrefKind::Str),
    ("ytdlp_throttle_seconds", PrefKind::Int),
    ("ytdlp_concurrent_fragments", PrefKind::Int),
    ("autoCloudBackup", PrefKind::Bool),
    ("navbarDisplayMode", PrefKind::Str),
    ("navbarShowTabLabels", PrefKind::Bool),
    ("navbarSelectionStyle", PrefKind::Str),
    ("navbarHiddenTabs", PrefKind::Str),
    ("galleryBackground_source", PrefKind::Str),
    ("bgService.kenBurnsEnabled", PrefKind::Bool),
    ("home_hub_section_order", PrefKind::Str),
    ("home_hub_hidden_sections", PrefKind::Str),
    ("home_hub_custom_greeting", PrefKind::Str),
    ("home_hub_accent_hex", PrefKind::Str),
    ("wifiOnlyDownloads.enabled", PrefKind::Bool),
];

/// Every UserDefaults key sync reads/writes, with its type.
#[uniffi::export]
pub fn sync_pref_keys() -> Vec<PrefKey> {
    let mut v = vec![PrefKey { key: VINYL_LEGACY.into(), kind: PrefKind::Bool }];
    v.extend(COLUMNS.iter().map(|(_, k, kind)| PrefKey { key: (*k).into(), kind: *kind }));
    v.extend(EXTRA.iter().map(|(k, kind)| PrefKey { key: (*k).into(), kind: *kind }));
    v
}

/// The server replaces favourites and playlist tracks with what a push
/// carries; before the library loads, playlists resolve empty — so wait.
#[uniffi::export]
pub fn sync_should_push(library_loaded: bool, favorite_count: u32, has_nonempty_playlist: bool) -> bool {
    library_loaded || (favorite_count == 0 && !has_nonempty_playlist)
}

fn pref_json(v: &PrefValue) -> Value {
    match v {
        PrefValue::Bool { v } => json!(v),
        PrefValue::Int { v } => json!(v),
        PrefValue::Double { v } => json!(v),
        PrefValue::Str { v } => json!(v),
    }
}

fn pref_from_json(v: &Value, kind: PrefKind) -> Option<PrefValue> {
    Some(match kind {
        PrefKind::Bool => PrefValue::Bool { v: v.as_bool()? },
        PrefKind::Int => PrefValue::Int { v: v.as_i64().or_else(|| v.as_f64().map(|f| f as i64))? },
        PrefKind::Double => PrefValue::Double { v: v.as_f64()? },
        PrefKind::Str => PrefValue::Str { v: v.as_str()?.to_string() },
    })
}

fn opt(s: &Option<String>) -> Value {
    s.as_ref().map_or(Value::Null, |s| json!(s))
}

/// POST /user/sync body (same keys the Swift `SyncData` encoded).
#[uniffi::export]
pub fn sync_build_payload(local: SyncLocal) -> Vec<u8> {
    let prefs: HashMap<&str, &PrefValue> = local.prefs.iter().map(|p| (p.key.as_str(), &p.value)).collect();
    let mut seen = HashSet::new();
    let favorites: Vec<Value> = local
        .favorites
        .iter()
        .filter(|f| seen.insert(f.song_id.clone()))
        .map(|f| json!({"song_id": f.song_id, "title": opt(&f.title), "artist": opt(&f.artist), "album": opt(&f.album)}))
        .collect();
    let playlists: Vec<Value> = local
        .playlists
        .iter()
        .map(|p| {
            let tracks: Vec<Value> = p
                .tracks
                .iter()
                .map(|t| {
                    json!({"local_song_id": opt(&t.local_song_id), "track_url": opt(&t.track_url), "title": t.title, "artist": opt(&t.artist),
                           "album": opt(&t.album), "duration_seconds": t.duration_seconds, "position": t.position})
                })
                .collect();
            json!({"id": p.id, "name": p.name, "description": Value::Null, "folder": opt(&p.folder), "tags": p.tags, "tracks": tracks})
        })
        .collect();
    let mut m = Map::new();
    m.insert("favorites".into(), Value::Array(favorites));
    m.insert("playlists".into(), Value::Array(playlists));
    m.insert("audio_settings_json".into(), opt(&local.blobs.audio_settings_json));
    m.insert("track_audio_settings_json".into(), opt(&local.blobs.track_audio_settings_json));
    m.insert("theme_color".into(), json!(local.theme_hex.clone().unwrap_or_else(|| "#EC4079".into())));
    // Legacy bool if present, else derived from the artwork style.
    let vinyl = match (prefs.get(VINYL_LEGACY), prefs.get(ARTWORK_STYLE)) {
        (Some(PrefValue::Bool { v }), _) => json!(v),
        (_, Some(PrefValue::Str { v })) => json!(v == "vinylDisc"),
        _ => Value::Null,
    };
    m.insert("vinyl_disc_enabled".into(), vinyl);
    for (col, key, _) in COLUMNS {
        m.insert((*col).into(), prefs.get(key).map_or(Value::Null, |v| pref_json(v)));
    }
    let mut badges: Vec<&String> = local.earned_badges.iter().collect::<HashSet<_>>().into_iter().collect();
    badges.sort();
    m.insert("earned_badges_json".into(), if badges.is_empty() { Value::Null } else { json!(serde_json::to_string(&badges).unwrap_or_default()) });
    let extra: Map<String, Value> = EXTRA.iter().filter_map(|(k, _)| prefs.get(k).map(|v| ((*k).to_string(), pref_json(v)))).collect();
    m.insert("extra_settings_json".into(), if extra.is_empty() { Value::Null } else { json!(Value::Object(extra).to_string()) });
    m.insert("play_history_json".into(), opt(&local.blobs.play_history_json));
    m.insert("smart_playlists_json".into(), opt(&local.blobs.smart_playlists_json));
    m.insert("tracked_playlists_json".into(), opt(&local.blobs.tracked_playlists_json));
    m.insert("bookmarks_json".into(), opt(&local.blobs.bookmarks_json));
    let bpm: Map<String, Value> = local.bpm_by_source.iter().map(|b| (b.source_track_id.clone(), json!(b.bpm))).collect();
    m.insert("bpm_by_source_track_id_json".into(), if bpm.is_empty() { Value::Null } else { json!(Value::Object(bpm).to_string()) });
    serde_json::to_vec(&Value::Object(m)).unwrap_or_default()
}

// MARK: - Pull

#[derive(uniffi::Record, Clone, Debug)]
pub struct SyncPullLocal {
    pub favorite_ids: Vec<String>,
    pub playlist_names: Vec<String>,
    /// Keys from `sync_pref_keys()` that already have a local value.
    pub set_keys: Vec<String>,
    pub has_audio_settings: bool,
    pub has_track_audio_settings: bool,
    pub has_accent_color: bool,
    pub earned_badges: Vec<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AccentRgb {
    pub r: f64,
    pub g: f64,
    pub b: f64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SyncPullPlan {
    pub favorites_to_add: Vec<String>,
    pub playlists_to_create: Vec<SyncPlaylistRec>,
    pub prefs_to_set: Vec<PrefEntry>,
    /// Restore only when nothing is saved locally.
    pub audio_settings_json: Option<String>,
    pub track_audio_settings_json: Option<String>,
    pub accent: Option<AccentRgb>,
    /// The union, when it differs from the local set.
    pub merged_badges: Option<Vec<String>>,
    /// Store-owned blobs: each store merges with its own policy.
    pub blobs: SyncBlobs,
    pub bpm_by_source: Vec<BpmEntry>,
    pub remote_favorite_count: u32,
    pub remote_playlist_count: u32,
}

fn s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| x.as_str()).map(str::to_string)
}

fn parse_hex(hex: &str) -> Option<AccentRgb> {
    let h = hex.strip_prefix('#')?;
    if h.len() != 6 {
        return None;
    }
    let n = u32::from_str_radix(h, 16).ok()?;
    Some(AccentRgb { r: ((n >> 16) & 0xFF) as f64 / 255.0, g: ((n >> 8) & 0xFF) as f64 / 255.0, b: (n & 0xFF) as f64 / 255.0 })
}

/// Turn a GET /user/sync body into what to apply locally.
#[uniffi::export]
pub fn sync_pull_plan(remote: Vec<u8>, local: SyncPullLocal) -> Result<SyncPullPlan, crate::error::CoreError> {
    let v: Value = serde_json::from_slice(&remote).map_err(|e| crate::error::CoreError::invalid(format!("sync payload: {e}")))?;
    let have_fav: HashSet<&str> = local.favorite_ids.iter().map(String::as_str).collect();
    let mut seen = HashSet::new();
    let remote_favs: Vec<String> = v["favorites"].as_array().into_iter().flatten().filter_map(|f| s(f, "song_id")).collect();
    let favorites_to_add = remote_favs.iter().filter(|id| !have_fav.contains(id.as_str()) && seen.insert((*id).clone())).cloned().collect();

    let mut names: HashSet<String> = local.playlist_names.iter().cloned().collect();
    let remote_pls = v["playlists"].as_array().cloned().unwrap_or_default();
    let mut playlists_to_create = Vec::new();
    for p in &remote_pls {
        let Some(name) = s(p, "name") else { continue };
        if !names.insert(name.clone()) {
            continue;
        }
        let tracks = p["tracks"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|t| {
                Some(SyncTrackRec {
                    local_song_id: s(t, "local_song_id"),
                    track_url: s(t, "track_url"),
                    title: s(t, "title")?,
                    artist: s(t, "artist"),
                    album: s(t, "album"),
                    duration_seconds: t["duration_seconds"].as_i64(),
                    position: t["position"].as_i64(),
                })
            })
            .collect();
        playlists_to_create.push(SyncPlaylistRec {
            id: s(p, "id").unwrap_or_default(),
            name,
            folder: s(p, "folder"),
            tags: p["tags"].as_array().into_iter().flatten().filter_map(|t| t.as_str().map(str::to_string)).collect(),
            tracks,
        });
    }

    let set: HashSet<&str> = local.set_keys.iter().map(String::as_str).collect();
    let mut prefs_to_set = Vec::new();
    let put = |key: &str, val: Option<PrefValue>, prefs: &mut Vec<PrefEntry>| {
        if let Some(value) = val {
            if !set.contains(key) && !prefs.iter().any(|p: &PrefEntry| p.key == key) {
                prefs.push(PrefEntry { key: key.into(), value });
            }
        }
    };
    if !set.contains(ARTWORK_STYLE) {
        put(VINYL_LEGACY, pref_from_json(&v["vinyl_disc_enabled"], PrefKind::Bool), &mut prefs_to_set);
    }
    for (col, key, kind) in COLUMNS {
        put(key, pref_from_json(&v[*col], *kind), &mut prefs_to_set);
    }
    if let Some(extra) = s(&v, "extra_settings_json").and_then(|j| serde_json::from_str::<Value>(&j).ok()) {
        for (k, kind) in EXTRA {
            put(k, pref_from_json(&extra[*k], *kind), &mut prefs_to_set);
        }
    }

    let merged_badges = s(&v, "earned_badges_json").and_then(|j| serde_json::from_str::<Vec<String>>(&j).ok()).and_then(|remote| {
        let local_set: HashSet<String> = local.earned_badges.iter().cloned().collect();
        let mut all: Vec<String> = local_set.union(&remote.into_iter().collect()).cloned().collect();
        (all.len() != local_set.len()).then(|| {
            all.sort();
            all
        })
    });

    let bpm_by_source = s(&v, "bpm_by_source_track_id_json")
        .and_then(|j| serde_json::from_str::<HashMap<String, f64>>(&j).ok())
        .map(|m| m.into_iter().filter(|(_, b)| *b > 0.0).map(|(source_track_id, bpm)| BpmEntry { source_track_id, bpm }).collect())
        .unwrap_or_default();

    Ok(SyncPullPlan {
        favorites_to_add,
        playlists_to_create,
        prefs_to_set,
        audio_settings_json: (!local.has_audio_settings).then(|| s(&v, "audio_settings_json")).flatten(),
        track_audio_settings_json: (!local.has_track_audio_settings).then(|| s(&v, "track_audio_settings_json")).flatten(),
        accent: (!local.has_accent_color).then(|| s(&v, "theme_color").and_then(|h| parse_hex(&h))).flatten(),
        merged_badges,
        blobs: SyncBlobs {
            audio_settings_json: None,
            track_audio_settings_json: None,
            play_history_json: s(&v, "play_history_json"),
            smart_playlists_json: s(&v, "smart_playlists_json"),
            tracked_playlists_json: s(&v, "tracked_playlists_json"),
            bookmarks_json: s(&v, "bookmarks_json"),
        },
        bpm_by_source,
        remote_favorite_count: remote_favs.len() as u32,
        remote_playlist_count: remote_pls.len() as u32,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local() -> SyncLocal {
        SyncLocal {
            favorites: vec![
                SyncFavoriteRec { song_id: "a".into(), title: Some("A".into()), artist: None, album: None },
                SyncFavoriteRec { song_id: "a".into(), title: None, artist: None, album: None },
            ],
            playlists: vec![SyncPlaylistRec {
                id: "P".into(),
                name: "Mix".into(),
                folder: None,
                tags: vec!["x".into()],
                tracks: vec![SyncTrackRec { local_song_id: Some("a".into()), track_url: None, title: "A".into(), artist: None, album: None, duration_seconds: Some(200), position: Some(0) }],
            }],
            prefs: vec![
                PrefEntry { key: ARTWORK_STYLE.into(), value: PrefValue::Str { v: "vinylDisc".into() } },
                PrefEntry { key: "library_songs_columns".into(), value: PrefValue::Int { v: 3 } },
                PrefEntry { key: "panel_opacity".into(), value: PrefValue::Double { v: 0.5 } },
            ],
            theme_hex: None,
            earned_badges: vec!["b2".into(), "b1".into()],
            blobs: SyncBlobs { play_history_json: Some("{}".into()), ..Default::default() },
            bpm_by_source: vec![BpmEntry { source_track_id: "youtube:1".into(), bpm: 120.0 }],
        }
    }

    #[test]
    fn payload_has_server_shape() {
        let v: Value = serde_json::from_slice(&sync_build_payload(local())).unwrap();
        assert_eq!(v["favorites"].as_array().unwrap().len(), 1);
        assert_eq!(v["playlists"][0]["tracks"][0]["duration_seconds"], 200);
        assert_eq!(v["vinyl_disc_enabled"], true);
        assert_eq!(v["songs_per_row"], 3);
        assert_eq!(v["albums_per_row"], Value::Null);
        assert_eq!(v["theme_color"], "#EC4079");
        assert_eq!(v["earned_badges_json"], "[\"b1\",\"b2\"]");
        let extra: Value = serde_json::from_str(v["extra_settings_json"].as_str().unwrap()).unwrap();
        assert_eq!(extra["panel_opacity"], 0.5);
        assert_eq!(v["play_history_json"], "{}");
        assert!(v["bpm_by_source_track_id_json"].as_str().unwrap().contains("youtube:1"));
    }

    #[test]
    fn pull_only_adds_and_bootstraps_unset_keys() {
        let remote = sync_build_payload(local());
        let plan = sync_pull_plan(
            remote,
            SyncPullLocal {
                favorite_ids: vec![],
                playlist_names: vec!["Mix".into()],
                set_keys: vec!["library_songs_columns".into()],
                has_audio_settings: true,
                has_track_audio_settings: false,
                has_accent_color: false,
                earned_badges: vec!["b1".into()],
            },
        )
        .unwrap();
        assert_eq!(plan.favorites_to_add, vec!["a".to_string()]);
        assert!(plan.playlists_to_create.is_empty());
        assert!(!plan.prefs_to_set.iter().any(|p| p.key == "library_songs_columns"));
        assert!(plan.prefs_to_set.contains(&PrefEntry { key: ARTWORK_STYLE.into(), value: PrefValue::Str { v: "vinylDisc".into() } }));
        assert!(plan.prefs_to_set.contains(&PrefEntry { key: "panel_opacity".into(), value: PrefValue::Double { v: 0.5 } }));
        assert_eq!(plan.merged_badges, Some(vec!["b1".into(), "b2".into()]));
        assert_eq!(plan.accent, parse_hex("#EC4079"));
        assert_eq!(plan.bpm_by_source.len(), 1);
        assert!(sync_should_push(false, 0, false) && !sync_should_push(false, 1, false) && sync_should_push(true, 5, true));
    }
}

// MARK: - Library inventory (/user/library/inventory)

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum InventoryOutcome {
    /// The library hasn't loaded (uploading would tell the server we own nothing).
    NotLoaded,
    /// Same set as the last successful upload.
    Unchanged,
    Uploaded { count: u32 },
}

static LAST_INVENTORY: std::sync::Mutex<Option<u64>> = std::sync::Mutex::new(None);

fn set_hash(ids: &[String]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    ids.hash(&mut h);
    h.finish()
}

/// Owned source ids: songs' own ids plus download-ledger entries whose file
/// is still in the library (tags that didn't survive conversion). Sorted.
#[uniffi::export]
pub fn sync_inventory_ids(song_source_ids: Vec<String>, present_filenames: Vec<String>) -> Vec<String> {
    let mut set: HashSet<String> = song_source_ids.into_iter().filter(|s| !s.is_empty()).collect();
    set.extend(crate::downloads::ledger_present_ids(present_filenames));
    let mut v: Vec<String> = set.into_iter().collect();
    v.sort();
    v
}

/// Replace the server's inventory with `ids` (idempotent, so retried 3x with
/// a 90 s timeout: it's the one request whose size scales with the library).
/// Skipped when the library isn't loaded or the set is unchanged since the
/// last successful upload.
#[uniffi::export]
pub async fn sync_inventory_upload(client: std::sync::Arc<crate::client::ApiClient>, ids: Vec<String>, library_loaded: bool) -> Result<InventoryOutcome, crate::error::CoreError> {
    if !library_loaded {
        return Ok(InventoryOutcome::NotLoaded);
    }
    let h = set_hash(&ids);
    if *LAST_INVENTORY.lock().unwrap() == Some(h) {
        return Ok(InventoryOutcome::Unchanged);
    }
    let body = serde_json::to_vec(&json!({ "source_ids": ids })).unwrap_or_default();
    client.request_with_retry("/user/library/inventory".into(), "POST".into(), Some(body), Some(90.0), 3, 1.0).await?;
    *LAST_INVENTORY.lock().unwrap() = Some(h);
    Ok(InventoryOutcome::Uploaded { count: ids.len() as u32 })
}

/// Forget the last upload (sign-out / account switch).
#[uniffi::export]
pub fn sync_inventory_reset() {
    *LAST_INVENTORY.lock().unwrap() = None;
}
