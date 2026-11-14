//! Three-way merge for favorites and playlists (`/user/sync`).
//!
//! The first sync design only ever added on a pull and replaced on a push,
//! so nothing could be removed across devices: a favorite removed on one
//! phone was still in the other phone's set, and its next push put it back.
//!
//! Each device now remembers the state it last agreed on with the server
//! (the *base*). Comparing base, local and remote says who changed what:
//!
//! * in base and local, gone from remote  → removed elsewhere: remove here;
//! * in base, gone from local             → removed here: tell the server;
//! * in remote, not local, not in base    → added elsewhere: add here;
//! * in local, not in base                → added here: push it.
//!
//! A push made with this (`"merge": true`) is merged by the bridge instead
//! of replacing the account: pushed rows are upserted, only the rows listed
//! as removed are deleted, and playlist rows this device has never seen
//! (added by another device a moment ago, or songs this device doesn't
//! have) are kept.
//!
//! Playlist entries are compared as this device's own track ids, through
//! `TrackResolver`, because every device writes its own id for a song.

use crate::crossdevice::{TrackRef, TrackResolver};
use crate::error::CoreError;
use crate::sync::{SyncLocal, sync_build_payload};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

const NS: &str = "sync_base";

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
struct BasePlaylist {
    remote_id: String,
    local_id: String,
    name: String,
    /// This device's track ids that were in the playlist on both sides.
    local_ids: Vec<String>,
    /// Server rows this device has accounted for (see `row_identity`).
    seen: Vec<String>,
}

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
struct SyncBase {
    account: String,
    favorites: Vec<String>,
    playlists: Vec<BasePlaylist>,
}

/// The base a successful push will leave behind (`sync_push_committed`).
static PENDING: Mutex<Option<SyncBase>> = Mutex::new(None);

fn load_base(account: &str) -> SyncBase {
    let b: SyncBase = crate::store::load(NS);
    if b.account == account { b } else { SyncBase { account: account.to_string(), ..Default::default() } }
}

/// How the bridge tells two rows of one playlist apart: the id the writing
/// device gave the song, else its title and artist. Must match
/// `row_identity` in the bridge (`routes/library.rs`).
pub fn row_identity(local_song_id: Option<&str>, title: &str, artist: Option<&str>) -> String {
    match local_song_id.map(str::trim).filter(|s| !s.is_empty()) {
        Some(id) => id.to_string(),
        None => format!("t:{}|{}", title.trim().to_lowercase(), artist.unwrap_or("").trim().to_lowercase()),
    }
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct MergeLocalPlaylist {
    pub id: String,
    pub name: String,
    pub song_ids: Vec<String>,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct MergeLocal {
    /// Signed-in user id; a different account starts from an empty base.
    pub account: String,
    pub favorite_ids: Vec<String>,
    pub playlists: Vec<MergeLocalPlaylist>,
    /// False while the library is still loading: playlist entries can't be
    /// matched to songs yet, so playlists are left alone this round.
    pub library_loaded: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct MergePlaylist {
    /// The id to use on this device (for a new playlist: the server's id
    /// when it is a UUID, else a fresh one).
    pub local_id: String,
    pub name: String,
    pub folder: Option<String>,
    pub tags: Vec<String>,
    pub song_ids: Vec<String>,
}

#[derive(uniffi::Record, Clone, Debug, Default, PartialEq)]
pub struct SyncMergePlan {
    pub favorites_to_add: Vec<String>,
    pub favorites_to_remove: Vec<String>,
    pub playlists_to_create: Vec<MergePlaylist>,
    /// Existing playlists whose name or songs change.
    pub playlists_to_update: Vec<MergePlaylist>,
    /// Local ids of playlists deleted on another device.
    pub playlists_to_remove: Vec<String>,
    /// A pull that would remove most of the favorites is not applied (a
    /// wiped or rolled-back account must not empty the phone); they are
    /// pushed back instead.
    pub removal_refused: bool,
}

fn st(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).map(str::to_string)
}

fn is_uuid(s: &str) -> bool {
    uuid::Uuid::parse_str(s).is_ok()
}

fn same_id(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}

/// What to change on this device after a pull, and the new base.
#[uniffi::export]
pub fn sync_merge_plan(remote: Vec<u8>, local: MergeLocal, resolver: Arc<TrackResolver>) -> Result<SyncMergePlan, CoreError> {
    let v: Value = serde_json::from_slice(&remote).map_err(|e| CoreError::invalid(format!("sync payload: {e}")))?;
    let base = load_base(&local.account);
    let (plan, next) = merge(&v, &local, &base, &resolver);
    crate::store::save(NS, &next);
    Ok(plan)
}

fn merge(v: &Value, local: &MergeLocal, base: &SyncBase, resolver: &TrackResolver) -> (SyncMergePlan, SyncBase) {
    let mut plan = SyncMergePlan::default();
    let mut next = SyncBase { account: local.account.clone(), ..Default::default() };

    // Favorites: raw ids, as each device wrote them.
    let mut seen = HashSet::new();
    let remote_favs: Vec<String> = v["favorites"].as_array().into_iter().flatten().filter_map(|f| st(f, "song_id")).filter(|id| seen.insert(id.clone())).collect();
    let r: HashSet<&str> = remote_favs.iter().map(String::as_str).collect();
    let l: HashSet<&str> = local.favorite_ids.iter().map(String::as_str).collect();
    let b: HashSet<&str> = base.favorites.iter().map(String::as_str).collect();
    plan.favorites_to_add = remote_favs.iter().filter(|id| !l.contains(id.as_str()) && !b.contains(id.as_str())).cloned().collect();
    let mut gone: Vec<String> = local.favorite_ids.iter().filter(|id| b.contains(id.as_str()) && !r.contains(id.as_str())).cloned().collect();
    gone.sort();
    gone.dedup();
    if gone.len() > 20 && gone.len() * 2 > l.len() {
        plan.removal_refused = true;
    } else {
        plan.favorites_to_remove = gone;
    }
    next.favorites = remote_favs;

    if !local.library_loaded {
        next.playlists = base.playlists.clone();
        return (plan, next);
    }

    let remote_pls: Vec<&Value> = v["playlists"].as_array().into_iter().flatten().filter(|p| p["id"].is_string() && p["name"].is_string()).collect();
    let mut taken: HashSet<usize> = HashSet::new();
    for p in &remote_pls {
        let rid = st(p, "id").unwrap_or_default();
        let rname = st(p, "name").unwrap_or_default();
        let known = base.playlists.iter().find(|b| b.remote_id == rid);
        // Which local playlist this is: the one it was last synced as, else
        // the same id, else the same name.
        let li = known
            .and_then(|b| local.playlists.iter().position(|lp| same_id(&lp.id, &b.local_id)))
            .or_else(|| local.playlists.iter().position(|lp| same_id(&lp.id, &rid)))
            .or_else(|| if known.is_none() { local.playlists.iter().enumerate().position(|(i, lp)| lp.name == rname && !taken.contains(&i)) } else { None })
            .filter(|i| !taken.contains(i));

        let rows: Vec<&Value> = p["tracks"].as_array().into_iter().flatten().collect();
        let refs: Vec<TrackRef> = rows
            .iter()
            .map(|t| TrackRef { id: st(t, "local_song_id"), track_url: st(t, "track_url"), title: st(t, "title"), artist: st(t, "artist"), duration_seconds: t["duration_seconds"].as_f64().filter(|d| *d > 0.0) })
            .collect();
        let mut hits = resolver.resolve_all(refs);
        let local_songs: HashSet<&str> = li.map(|i| local.playlists[i].song_ids.iter().map(String::as_str).collect()).unwrap_or_default();
        let mut remote_ids: Vec<String> = Vec::new();
        let mut seen_rows: Vec<String> = Vec::new();
        let mut dedup = HashSet::new();
        for (t, hit) in rows.iter().zip(hits.iter_mut()) {
            // A row this device wrote for a song it can't load right now
            // still counts as the same entry.
            if hit.is_none() {
                *hit = st(t, "local_song_id").filter(|id| local_songs.contains(id.as_str()));
            }
            if let Some(id) = hit {
                seen_rows.push(row_identity(st(t, "local_song_id").as_deref(), &st(t, "title").unwrap_or_default(), st(t, "artist").as_deref()));
                if dedup.insert(id.clone()) {
                    remote_ids.push(id.clone());
                }
            }
        }
        let tags: Vec<String> = p["tags"].as_array().into_iter().flatten().filter_map(|t| t.as_str().map(str::to_string)).collect();

        match li {
            Some(i) => {
                taken.insert(i);
                let lp = &local.playlists[i];
                let bset: HashSet<&str> = known.map(|b| b.local_ids.iter().map(String::as_str).collect()).unwrap_or_default();
                let rset: HashSet<&str> = remote_ids.iter().map(String::as_str).collect();
                let mut songs: Vec<String> =
                    lp.song_ids.iter().filter(|id| !(bset.contains(id.as_str()) && !rset.contains(id.as_str()) && resolver.contains((*id).clone()))).cloned().collect();
                let have: HashSet<String> = lp.song_ids.iter().cloned().collect();
                songs.extend(remote_ids.iter().filter(|id| !have.contains(*id) && !bset.contains(id.as_str())).cloned());
                let name = if known.is_some_and(|b| b.name == lp.name) { rname.clone() } else { lp.name.clone() };
                if songs != lp.song_ids || name != lp.name {
                    plan.playlists_to_update.push(MergePlaylist { local_id: lp.id.clone(), name, folder: st(p, "folder"), tags, song_ids: songs });
                }
                next.playlists.push(BasePlaylist { remote_id: rid, local_id: lp.id.clone(), name: rname, local_ids: remote_ids, seen: seen_rows });
            }
            None if known.is_some() => {
                // Deleted here since the last sync; the next push removes it.
                next.playlists.push(known.cloned().unwrap());
            }
            None => {
                let local_id = if is_uuid(&rid) { rid.to_uppercase() } else { uuid::Uuid::new_v4().to_string().to_uppercase() };
                plan.playlists_to_create.push(MergePlaylist { local_id: local_id.clone(), name: rname.clone(), folder: st(p, "folder"), tags, song_ids: remote_ids.clone() });
                next.playlists.push(BasePlaylist { remote_id: rid, local_id, name: rname, local_ids: remote_ids, seen: seen_rows });
            }
        }
    }
    // Synced before, still here, gone from the server: deleted elsewhere.
    let remote_ids: HashSet<String> = remote_pls.iter().filter_map(|p| st(p, "id")).collect();
    for b in &base.playlists {
        if !remote_ids.contains(&b.remote_id) {
            if let Some(lp) = local.playlists.iter().find(|lp| same_id(&lp.id, &b.local_id)) {
                plan.playlists_to_remove.push(lp.id.clone());
            }
        }
    }
    (plan, next)
}

/// POST /user/sync body in merge mode: the usual payload plus what this
/// device removed since its last sync. Call `sync_push_committed` once the
/// server has accepted it.
#[uniffi::export]
pub fn sync_build_merge_payload(local: SyncLocal, account: String) -> Vec<u8> {
    let base = load_base(&account);
    let mut v: Value = serde_json::from_slice(&sync_build_payload(local.clone())).unwrap_or_else(|_| json!({}));
    let mut next = SyncBase { account, ..Default::default() };

    let mut pushed = HashSet::new();
    next.favorites = local.favorites.iter().map(|f| f.song_id.clone()).filter(|id| pushed.insert(id.clone())).collect();
    let removed_favs: Vec<&String> = base.favorites.iter().filter(|id| !pushed.contains(*id)).collect();

    let by_local: HashMap<String, &BasePlaylist> = base.playlists.iter().map(|b| (b.local_id.to_lowercase(), b)).collect();
    let mut live = HashSet::new();
    if let Some(pls) = v["playlists"].as_array_mut() {
        for (p, lp) in pls.iter_mut().zip(local.playlists.iter()) {
            let known = by_local.get(&lp.id.to_lowercase());
            let remote_id = known.map(|b| b.remote_id.clone()).unwrap_or_else(|| lp.id.clone());
            live.insert(remote_id.clone());
            p["id"] = json!(remote_id);
            p["seen"] = json!(known.map(|b| b.seen.clone()).unwrap_or_default());
            let ids: Vec<String> = lp.tracks.iter().filter_map(|t| t.local_song_id.clone()).collect();
            let seen = lp.tracks.iter().map(|t| row_identity(t.local_song_id.as_deref(), &t.title, t.artist.as_deref())).collect();
            next.playlists.push(BasePlaylist { remote_id, local_id: lp.id.clone(), name: lp.name.clone(), local_ids: ids, seen });
        }
    }
    let removed_pls: Vec<&String> = base.playlists.iter().map(|b| &b.remote_id).filter(|id| !live.contains(*id)).collect();
    v["merge"] = json!(true);
    v["removed_favorites"] = json!(removed_favs);
    v["removed_playlists"] = json!(removed_pls);
    *PENDING.lock().unwrap() = Some(next);
    serde_json::to_vec(&v).unwrap_or_default()
}

/// The last `sync_build_merge_payload` body was accepted by the server.
#[uniffi::export]
pub fn sync_push_committed() {
    if let Some(next) = PENDING.lock().unwrap().take() {
        crate::store::save(NS, &next);
    }
}

/// Forget the base (sign-out / account switch).
#[uniffi::export]
pub fn sync_base_reset() {
    *PENDING.lock().unwrap() = None;
    crate::store::save(NS, &SyncBase::default());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crossdevice::CatalogTrack;
    use crate::sync::{SyncBlobs, SyncFavoriteRec, SyncPlaylistRec, SyncTrackRec};

    fn resolver() -> Arc<TrackResolver> {
        let t = |id: &str, title: &str| CatalogTrack { id: id.into(), title: title.into(), artist: "X".into(), filename: Some(id.rsplit('/').next().unwrap().into()), track_url: None, duration_seconds: None };
        TrackResolver::new(vec![t("local:Music/One.opus", "One"), t("local:Music/Two.opus", "Two"), t("local:Music/Three.opus", "Three")])
    }

    fn lp(id: &str, name: &str, songs: &[&str]) -> MergeLocalPlaylist {
        MergeLocalPlaylist { id: id.into(), name: name.into(), song_ids: songs.iter().map(|s| s.to_string()).collect() }
    }

    fn local(favs: &[&str], pls: Vec<MergeLocalPlaylist>) -> MergeLocal {
        MergeLocal { account: "u".into(), favorite_ids: favs.iter().map(|s| s.to_string()).collect(), playlists: pls, library_loaded: true }
    }

    fn row(id: &str, title: &str) -> Value {
        json!({"local_song_id": id, "title": title, "artist": "X"})
    }

    #[test]
    fn favorites_three_way() {
        let base = SyncBase { account: "u".into(), favorites: vec!["a".into(), "b".into(), "c".into()], playlists: vec![] };
        // a: still everywhere. b: removed remotely. c: removed here. d: added remotely. e: added here.
        let remote = json!({"favorites": [{"song_id": "a"}, {"song_id": "c"}, {"song_id": "d"}]});
        let (plan, next) = merge(&remote, &local(&["a", "b", "e"], vec![]), &base, &resolver());
        assert_eq!(plan.favorites_to_add, vec!["d".to_string()]);
        assert_eq!(plan.favorites_to_remove, vec!["b".to_string()]);
        assert_eq!(next.favorites, vec!["a".to_string(), "c".to_string(), "d".to_string()]);
    }

    #[test]
    fn first_sync_is_a_union() {
        let remote = json!({"favorites": [{"song_id": "a"}]});
        let (plan, _) = merge(&remote, &local(&["z"], vec![]), &SyncBase::default(), &resolver());
        assert_eq!(plan.favorites_to_add, vec!["a".to_string()]);
        assert!(plan.favorites_to_remove.is_empty());
    }

    #[test]
    fn a_wiped_account_does_not_empty_the_phone() {
        let ids: Vec<String> = (0..40).map(|i| format!("s{i}")).collect();
        let base = SyncBase { account: "u".into(), favorites: ids.clone(), playlists: vec![] };
        let l = MergeLocal { account: "u".into(), favorite_ids: ids, playlists: vec![], library_loaded: true };
        let (plan, _) = merge(&json!({"favorites": []}), &l, &base, &resolver());
        assert!(plan.removal_refused && plan.favorites_to_remove.is_empty());
    }

    #[test]
    fn playlist_rows_from_another_device_resolve_and_merge() {
        // Android wrote the rows with its own ids (cloud paths).
        let remote = json!({"favorites": [], "playlists": [{"id": "6f1c2a34-0000-4000-8000-000000000001", "name": "Mix",
            "tracks": [row("One.opus", "One"), row("Two.opus", "Two"), row("Nine.opus", "Not on this phone")]}]});
        let (plan, next) = merge(&remote, &local(&[], vec![]), &SyncBase::default(), &resolver());
        let made = &plan.playlists_to_create[0];
        assert_eq!(made.local_id, "6F1C2A34-0000-4000-8000-000000000001");
        assert_eq!(made.song_ids, vec!["local:Music/One.opus".to_string(), "local:Music/Two.opus".to_string()]);
        // The song this phone doesn't have was not "seen", so a push keeps it.
        assert_eq!(next.playlists[0].seen, vec!["One.opus".to_string(), "Two.opus".to_string()]);

        // Next round: Two was removed on Android, Three added there; One removed here.
        let l = local(&[], vec![lp(&made.local_id, "Mix", &["local:Music/Two.opus"])]);
        let remote = json!({"favorites": [], "playlists": [{"id": "6f1c2a34-0000-4000-8000-000000000001", "name": "Mix",
            "tracks": [row("One.opus", "One"), row("Three.opus", "Three")]}]});
        let (plan, _) = merge(&remote, &l, &next, &resolver());
        assert_eq!(plan.playlists_to_update.len(), 1);
        assert_eq!(plan.playlists_to_update[0].song_ids, vec!["local:Music/Three.opus".to_string()]);
    }

    #[test]
    fn playlists_match_by_name_once_then_by_id_and_follow_deletes() {
        let remote = json!({"favorites": [], "playlists": [{"id": "srv-1", "name": "Road", "tracks": [row("One.opus", "One")]}]});
        let l = local(&[], vec![lp("L1", "Road", &["local:Music/Two.opus"])]);
        let (plan, next) = merge(&remote, &l, &SyncBase::default(), &resolver());
        assert!(plan.playlists_to_create.is_empty());
        assert_eq!(plan.playlists_to_update[0].song_ids, vec!["local:Music/Two.opus".to_string(), "local:Music/One.opus".to_string()]);
        assert_eq!(next.playlists[0].local_id, "L1");

        // Renamed on the other device: follows, because the local name is the synced one.
        let remote = json!({"favorites": [], "playlists": [{"id": "srv-1", "name": "Road trip", "tracks": [row("One.opus", "One")]}]});
        let l = local(&[], vec![lp("L1", "Road", &["local:Music/Two.opus", "local:Music/One.opus"])]);
        let (plan, next) = merge(&remote, &l, &next, &resolver());
        assert_eq!(plan.playlists_to_update[0].name, "Road trip");

        // Deleted on the other device.
        let l = local(&[], vec![lp("L1", "Road trip", &["local:Music/One.opus"])]);
        let (plan, next) = merge(&json!({"favorites": [], "playlists": []}), &l, &next, &resolver());
        assert_eq!(plan.playlists_to_remove, vec!["L1".to_string()]);
        assert!(next.playlists.is_empty());
    }

    #[test]
    fn nothing_is_judged_before_the_library_loads() {
        let base = SyncBase { account: "u".into(), favorites: vec![], playlists: vec![BasePlaylist { remote_id: "srv-1".into(), local_id: "L1".into(), name: "Road".into(), local_ids: vec!["local:Music/One.opus".into()], seen: vec![] }] };
        let mut l = local(&[], vec![lp("L1", "Road", &["local:Music/One.opus"])]);
        l.library_loaded = false;
        let (plan, next) = merge(&json!({"favorites": [], "playlists": []}), &l, &base, &resolver());
        assert!(plan.playlists_to_remove.is_empty() && plan.playlists_to_update.is_empty());
        assert_eq!(next.playlists, base.playlists);
    }

    #[test]
    fn push_lists_what_this_device_removed() {
        crate::store::save(
            NS,
            &SyncBase {
                account: "acct".into(),
                favorites: vec!["a".into(), "b".into()],
                playlists: vec![
                    BasePlaylist { remote_id: "srv-1".into(), local_id: "L1".into(), name: "Road".into(), local_ids: vec![], seen: vec!["One.opus".into()] },
                    BasePlaylist { remote_id: "srv-2".into(), local_id: "L2".into(), name: "Gone".into(), local_ids: vec![], seen: vec![] },
                ],
            },
        );
        let l = SyncLocal {
            favorites: vec![SyncFavoriteRec { song_id: "a".into(), title: None, artist: None, album: None }],
            playlists: vec![SyncPlaylistRec {
                id: "L1".into(),
                name: "Road".into(),
                folder: None,
                tags: vec![],
                tracks: vec![SyncTrackRec { local_song_id: Some("local:Music/Two.opus".into()), track_url: None, title: "Two".into(), artist: None, album: None, duration_seconds: None, position: Some(0) }],
            }],
            prefs: vec![],
            theme_hex: None,
            earned_badges: vec![],
            blobs: SyncBlobs::default(),
            bpm_by_source: vec![],
        };
        let v: Value = serde_json::from_slice(&sync_build_merge_payload(l, "acct".into())).unwrap();
        assert_eq!(v["merge"], true);
        assert_eq!(v["removed_favorites"], json!(["b"]));
        assert_eq!(v["removed_playlists"], json!(["srv-2"]));
        assert_eq!(v["playlists"][0]["id"], "srv-1");
        assert_eq!(v["playlists"][0]["seen"], json!(["One.opus"]));
        sync_push_committed();
        let b: SyncBase = crate::store::load(NS);
        assert_eq!(b.favorites, vec!["a".to_string()]);
        assert_eq!(b.playlists.len(), 1);
        assert_eq!(b.playlists[0].seen, vec!["local:Music/Two.opus".to_string()]);
        // Another account starts clean.
        let v: Value = serde_json::from_slice(&sync_build_merge_payload(
            SyncLocal { favorites: vec![], playlists: vec![], prefs: vec![], theme_hex: None, earned_badges: vec![], blobs: SyncBlobs::default(), bpm_by_source: vec![] },
            "other".into(),
        ))
        .unwrap();
        assert_eq!(v["removed_favorites"], json!([]));
        sync_base_reset();
    }
}
