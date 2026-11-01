//! Smart playlists: rule matching (all/any), sorting and limits over the
//! library. Play counts and last-played dates come from the core's play
//! history store. The playlist definition is the app's JSON encoding.

use crate::store::now;
use serde::Deserialize;
use std::collections::{HashMap, HashSet};

#[derive(uniffi::Record, Clone, Debug)]
pub struct SmartSong {
    pub id: String,
    pub display_name: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub genre: String,
    pub year: String,
    pub duration: f64,
    pub bpm: Option<f64>,
    pub source_track_id: Option<String>,
    /// Unix seconds.
    pub date_added: Option<f64>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Rule {
    field: String,
    op: String,
    text: String,
    number: f64,
    number2: f64,
    source: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Playlist {
    #[serde(rename = "match")]
    matching: String,
    rules: Vec<Rule>,
    limit: i64,
    sort: String,
}

fn source_of(s: &SmartSong) -> &'static str {
    match s.source_track_id.as_deref().map(str::to_lowercase) {
        Some(x) if x.starts_with("youtube") => "youtube",
        Some(x) if x.starts_with("soundcloud") => "soundcloud",
        _ => "local",
    }
}

struct Hist(HashMap<String, (i64, Option<f64>)>);

impl Hist {
    fn load() -> Self {
        Hist(crate::stores::play_history_all().into_iter().map(|r| (r.song_id, (r.play_count, r.last_played_at))).collect())
    }
    fn count(&self, id: &str) -> i64 {
        self.0.get(id).map(|h| h.0).unwrap_or(0)
    }
    fn last(&self, id: &str) -> Option<f64> {
        self.0.get(id).and_then(|h| h.1)
    }
}

fn number(field: &str, s: &SmartSong, h: &Hist, t: f64) -> Option<f64> {
    match field {
        "year" => s.year.trim().parse().ok(),
        "duration" => (s.duration > 0.0).then_some(s.duration),
        "bpm" => s.bpm,
        "playCount" => Some(h.count(&s.id) as f64),
        "daysSincePlayed" => Some(h.last(&s.id).map(|l| (t - l) / 86_400.0).unwrap_or(f64::MAX)),
        "daysSinceAdded" => s.date_added.map(|d| (t - d) / 86_400.0),
        _ => None,
    }
}

fn rule_ok(r: &Rule, s: &SmartSong, favs: &HashSet<String>, h: &Hist, t: f64) -> bool {
    match r.field.as_str() {
        "title" | "artist" | "album" | "genre" => {
            let v = match r.field.as_str() { "title" => &s.title, "artist" => &s.artist, "album" => &s.album, _ => &s.genre }.to_lowercase();
            let q = r.text.to_lowercase();
            match r.op.as_str() {
                "contains" => v.contains(&q),
                "notContains" => !v.contains(&q),
                "equals" => v == q,
                _ => false,
            }
        }
        "favorite" => favs.contains(&s.id) == (r.op == "isTrue"),
        "source" => source_of(s) == r.source,
        f => {
            let Some(v) = number(f, s, h, t) else { return false };
            match r.op.as_str() {
                "equals" => (v - r.number).abs() < 0.5,
                "greaterThan" => v > r.number,
                "lessThan" => v < r.number,
                "between" => v >= r.number.min(r.number2) && v <= r.number.max(r.number2),
                _ => false,
            }
        }
    }
}

/// Ids of songs matching the playlist's rules (unsorted, unlimited).
#[uniffi::export]
pub fn smart_filter(playlist_json: Vec<u8>, songs: Vec<SmartSong>, favorites: Vec<String>) -> Vec<String> {
    let p: Playlist = serde_json::from_slice(&playlist_json).unwrap_or_default();
    let favs: HashSet<String> = favorites.into_iter().collect();
    let h = Hist::load();
    let t = now();
    songs
        .into_iter()
        .filter(|s| {
            if p.rules.is_empty() {
                return true;
            }
            let mut it = p.rules.iter().map(|r| rule_ok(r, s, &favs, &h, t));
            if p.matching == "any" { it.any(|x| x) } else { it.all(|x| x) }
        })
        .map(|s| s.id)
        .collect()
}

/// Sort + limit already-filtered songs per the playlist; returns ids.
#[uniffi::export]
pub fn smart_order(playlist_json: Vec<u8>, songs: Vec<SmartSong>) -> Vec<String> {
    let p: Playlist = serde_json::from_slice(&playlist_json).unwrap_or_default();
    let h = Hist::load();
    let mut v = songs;
    let ci = |a: &str, b: &str| a.to_lowercase().cmp(&b.to_lowercase());
    match p.sort.as_str() {
        "artistAsc" => v.sort_by(|a, b| ci(&a.artist, &b.artist)),
        "yearDesc" => v.sort_by_key(|s| std::cmp::Reverse(s.year.trim().parse::<i64>().unwrap_or(0))),
        "bpmAsc" => v.sort_by(|a, b| a.bpm.unwrap_or(0.0).partial_cmp(&b.bpm.unwrap_or(0.0)).unwrap_or(std::cmp::Ordering::Equal)),
        "durationAsc" => v.sort_by(|a, b| a.duration.partial_cmp(&b.duration).unwrap_or(std::cmp::Ordering::Equal)),
        "random" => {
            // Fisher–Yates with a time seed (no RNG crate).
            let mut seed = (now() * 1e6) as u64 | 1;
            for i in (1..v.len()).rev() {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                v.swap(i, (seed % (i as u64 + 1)) as usize);
            }
        }
        "playCountDesc" => v.sort_by_key(|s| std::cmp::Reverse(h.count(&s.id))),
        "recentlyPlayedDesc" => v.sort_by(|a, b| h.last(&b.id).unwrap_or(f64::MIN).partial_cmp(&h.last(&a.id).unwrap_or(f64::MIN)).unwrap_or(std::cmp::Ordering::Equal)),
        "recentlyAddedDesc" => v.sort_by(|a, b| b.date_added.unwrap_or(f64::MIN).partial_cmp(&a.date_added.unwrap_or(f64::MIN)).unwrap_or(std::cmp::Ordering::Equal)),
        _ => v.sort_by(|a, b| ci(&a.display_name, &b.display_name)),
    }
    let mut ids: Vec<String> = v.into_iter().map(|s| s.id).collect();
    if p.limit > 0 {
        ids.truncate(p.limit as usize);
    }
    ids
}

#[cfg(test)]
mod tests {
    use super::*;
    fn song(id: &str, t: &str, d: f64) -> SmartSong {
        SmartSong { id: id.into(), display_name: t.into(), title: t.into(), artist: "A".into(), album: "".into(), genre: "Rock".into(), year: "2001".into(), duration: d, bpm: None, source_track_id: None, date_added: None }
    }
    #[test]
    fn filters_and_sorts() {
        let pl = br#"{"match":"all","rules":[{"field":"duration","op":"lessThan","number":180},{"field":"genre","op":"contains","text":"ro"}],"limit":0,"sort":"durationAsc"}"#.to_vec();
        let songs = vec![song("1", "b", 170.0), song("2", "a", 200.0), song("3", "c", 120.0)];
        let ids = smart_filter(pl.clone(), songs.clone(), vec![]);
        assert_eq!(ids, vec!["1", "3"]);
        let kept: Vec<SmartSong> = songs.into_iter().filter(|s| ids.contains(&s.id)).collect();
        assert_eq!(smart_order(pl, kept), vec!["3", "1"]);
    }
}
