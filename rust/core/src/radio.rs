//! Lumisound Radio, app side: one station session at a time.
//!
//! The bridge (`/user/radio/*`, bridge routes/radio.rs) builds and steers the
//! station; this keeps the session id, which served tracks belong to it,
//! the listener's feedback until the next refill, and when to refill (the
//! queue is down to its last radio songs). Swift only sends the bodies this
//! builds and plays the tracks it returns.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

#[derive(uniffi::Record, Clone, Debug, Default, Serialize)]
pub struct RadioSeed {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub genre: Option<String>,
    pub bpm: Option<f64>,
    pub source_track_id: Option<String>,
    pub local_hour: Option<i64>,
}

#[derive(uniffi::Record, Clone, Debug, Deserialize, PartialEq)]
pub struct RadioTrack {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub duration_seconds: i64,
    #[serde(default)]
    pub thumbnail_url: String,
    #[serde(default)]
    pub youtube_url: String,
    #[serde(default)]
    pub is_topic_channel: bool,
    /// The listener's own library song to play instead of streaming.
    #[serde(default)]
    pub local_song_id: Option<String>,
    /// mix / colisten / library / search
    #[serde(default)]
    pub radio_source: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct RadioBatch {
    pub title: String,
    pub subtitle: Option<String>,
    pub tracks: Vec<RadioTrack>,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RadioEvent {
    Played,
    Completed,
    Skipped,
    Liked,
    Disliked,
}

#[derive(Serialize, Clone)]
struct Fb {
    track_id: String,
    event: &'static str,
    listened: Option<f64>,
}

#[derive(Default)]
struct Inner {
    session: Option<String>,
    mode: String,
    served: HashSet<String>,
    /// Feedback waiting for the next refill (one entry per track: latest wins).
    pending: HashMap<String, Fb>,
    in_flight: bool,
    title: String,
}

#[derive(uniffi::Object, Default)]
pub struct RadioSession {
    inner: Mutex<Inner>,
}

fn key(t: &RadioTrack) -> String {
    t.local_song_id.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| t.id.clone())
}

#[uniffi::export]
impl RadioSession {
    /// `mode`: balanced | familiar | discover.
    #[uniffi::constructor]
    pub fn new(mode: String) -> Arc<Self> {
        let mode = if ["balanced", "familiar", "discover"].contains(&mode.as_str()) { mode } else { "balanced".into() };
        Arc::new(Self { inner: Mutex::new(Inner { mode, ..Default::default() }) })
    }

    /// Body for POST /user/radio/start.
    pub fn start_body(&self, seed: RadioSeed, count: u32) -> Vec<u8> {
        let mut g = self.inner.lock().unwrap();
        g.in_flight = true;
        let mut v = serde_json::to_value(&seed).unwrap_or_default();
        v["mode"] = serde_json::json!(g.mode);
        v["count"] = serde_json::json!(count.clamp(1, 25));
        serde_json::to_vec(&v).unwrap_or_default()
    }

    /// Body for POST /user/radio/next (sends and clears the feedback), or
    /// None when there is no session yet or a request is already out.
    pub fn next_body(&self, count: u32) -> Option<Vec<u8>> {
        let mut g = self.inner.lock().unwrap();
        let sid = g.session.clone()?;
        if g.in_flight {
            return None;
        }
        g.in_flight = true;
        let fb: Vec<Fb> = g.pending.values().cloned().collect();
        g.pending.clear();
        serde_json::to_vec(&serde_json::json!({"session_id": sid, "feedback": fb, "count": count.clamp(1, 25)})).ok()
    }

    /// Apply a /start or /next response: returns the new tracks (unplayable
    /// rows dropped, nothing served twice).
    pub fn apply_response(&self, body: Vec<u8>) -> RadioBatch {
        let mut g = self.inner.lock().unwrap();
        g.in_flight = false;
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
        if let Some(s) = v["session_id"].as_str() {
            g.session = Some(s.to_string());
        }
        if let Some(t) = v["title"].as_str() {
            g.title = t.to_string();
        }
        let tracks: Vec<RadioTrack> = v["tracks"].as_array().map(|a| a.iter().filter_map(|t| serde_json::from_value(t.clone()).ok()).collect()).unwrap_or_default();
        let mut out = Vec::new();
        for t in tracks {
            let k = key(&t);
            if k.is_empty() || (t.id.is_empty() && t.local_song_id.is_none()) || !g.served.insert(k) {
                continue;
            }
            out.push(t);
        }
        RadioBatch { title: g.title.clone(), subtitle: v["subtitle"].as_str().map(str::to_string), tracks: out }
    }

    /// A request failed: allow the next one.
    pub fn request_failed(&self) {
        self.inner.lock().unwrap().in_flight = false;
    }

    /// Whether `track_id` (YouTube id or local song id) came from this station.
    pub fn is_radio_track(&self, track_id: String) -> bool {
        let id = track_id.strip_prefix("youtube:").unwrap_or(&track_id).to_string();
        self.inner.lock().unwrap().served.contains(&id)
    }

    /// Record what the listener did with a station track.
    pub fn record(&self, track_id: String, event: RadioEvent, listened_secs: f64) {
        let id = track_id.strip_prefix("youtube:").unwrap_or(&track_id).to_string();
        let mut g = self.inner.lock().unwrap();
        if !g.served.contains(&id) {
            return;
        }
        let ev = match event {
            RadioEvent::Played => "played",
            RadioEvent::Completed => "completed",
            RadioEvent::Skipped => "skipped",
            RadioEvent::Liked => "liked",
            RadioEvent::Disliked => "disliked",
        };
        // A like outranks a later "played"; otherwise the latest event wins.
        if g.pending.get(&id).is_some_and(|f| f.event == "liked") && ev == "played" {
            return;
        }
        g.pending.insert(id.clone(), Fb { track_id: id, event: ev, listened: Some(listened_secs.max(0.0)) });
    }

    /// Refill when this many station songs (or fewer) are still ahead.
    pub fn needs_refill(&self, radio_tracks_ahead: u32) -> bool {
        let g = self.inner.lock().unwrap();
        g.session.is_some() && !g.in_flight && radio_tracks_ahead <= 2
    }

    pub fn session_id(&self) -> Option<String> {
        self.inner.lock().unwrap().session.clone()
    }

    pub fn pending_feedback(&self) -> u32 {
        self.inner.lock().unwrap().pending.len() as u32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_flow() {
        let s = RadioSession::new("balanced".into());
        assert!(s.next_body(5).is_none(), "no session yet");
        let b: serde_json::Value = serde_json::from_slice(&s.start_body(RadioSeed { artist: Some("A".into()), ..Default::default() }, 8)).unwrap();
        assert_eq!(b["mode"], "balanced");
        assert_eq!(b["count"], 8);
        let resp = serde_json::json!({"session_id": "s1", "title": "A Radio", "tracks": [
            {"id": "aaaaaaaaaaa", "title": "x", "artist": "A"},
            {"id": "", "local_song_id": "local:Music/y.mp3", "title": "y", "artist": "A"},
            {"id": "", "title": "unplayable", "artist": "B"},
            {"id": "aaaaaaaaaaa", "title": "x again", "artist": "A"}
        ]});
        let batch = s.apply_response(serde_json::to_vec(&resp).unwrap());
        assert_eq!(batch.tracks.len(), 2);
        assert_eq!(batch.title, "A Radio");
        assert!(s.is_radio_track("youtube:aaaaaaaaaaa".into()));
        assert!(s.is_radio_track("local:Music/y.mp3".into()));
        s.record("aaaaaaaaaaa".into(), RadioEvent::Skipped, 12.0);
        s.record("not-ours".into(), RadioEvent::Completed, 200.0);
        assert_eq!(s.pending_feedback(), 1);
        assert!(s.needs_refill(1));
        let n: serde_json::Value = serde_json::from_slice(&s.next_body(5).unwrap()).unwrap();
        assert_eq!(n["session_id"], "s1");
        assert_eq!(n["feedback"][0]["event"], "skipped");
        assert!(s.next_body(5).is_none(), "one request at a time");
        assert!(!s.needs_refill(0));
        s.request_failed();
        assert!(s.needs_refill(0));
        assert_eq!(s.pending_feedback(), 0);
    }
}
