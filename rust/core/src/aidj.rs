//! AI DJ Mode session logic: which track changes get an announcement, the
//! transition request, the duck/restore volume plan (one duck in flight at a
//! time, so the baseline can never ratchet down), and the rolling session
//! log the set export reads. Speech itself is AVSpeechSynthesizer in Swift.

use crate::client::ApiClient;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

/// Roughly the last 8 tracks plus their transitions.
const MAX_LOG: usize = 16;
/// Ducked level, as a fraction of the pre-duck volume.
const DUCK: f32 = 0.25;

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct DjCue {
    pub previous_title: Option<String>,
    pub previous_artist: Option<String>,
}

/// One log row: a track (`song_id`) or a spoken transition (`text`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct DjLogEntry {
    pub song_id: Option<String>,
    pub text: Option<String>,
}

#[derive(Default)]
struct State {
    previous: Option<(String, Option<String>)>,
    last_announced: Option<String>,
    speaking: bool,
    baseline: f32,
    log: VecDeque<DjLogEntry>,
}

#[derive(uniffi::Object, Default)]
pub struct DjSession {
    st: Mutex<State>,
}

impl State {
    fn push(&mut self, e: DjLogEntry) {
        self.log.push_back(e);
        while self.log.len() > MAX_LOG {
            self.log.pop_front();
        }
    }
}

#[uniffi::export]
impl DjSession {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// A new current track. Returns the cue to request a transition line for
    /// (previous track's title/artist), or nil when nothing should be said:
    /// mode off, not playing, or this song was already announced.
    pub fn track_changed(&self, song_id: String, title: String, artist: Option<String>, enabled: bool, playing: bool) -> Option<DjCue> {
        let mut s = self.st.lock().unwrap();
        let prev = s.previous.replace((title, artist));
        if !enabled || !playing || s.last_announced.as_deref() == Some(song_id.as_str()) {
            return None;
        }
        s.last_announced = Some(song_id.clone());
        s.push(DjLogEntry { song_id: Some(song_id), text: None });
        Some(DjCue { previous_title: prev.as_ref().map(|p| p.0.clone()), previous_artist: prev.and_then(|p| p.1) })
    }

    /// Start an announcement at `current_volume`. Returns the ducked volume
    /// to fade to, or nil if one is already in flight (dropped, not queued).
    pub fn begin_speaking(&self, text: String, current_volume: f32) -> Option<f32> {
        let mut s = self.st.lock().unwrap();
        if s.speaking {
            return None;
        }
        s.speaking = true;
        s.baseline = current_volume;
        s.push(DjLogEntry { song_id: None, text: Some(text) });
        Some(current_volume * DUCK)
    }

    /// Volume to restore to once speech ends (the pre-duck baseline).
    pub fn restore_volume(&self) -> f32 {
        self.st.lock().unwrap().baseline
    }

    /// Restore fade finished; a new announcement may start.
    pub fn finished_speaking(&self) {
        self.st.lock().unwrap().speaking = false;
    }

    pub fn is_speaking(&self) -> bool {
        self.st.lock().unwrap().speaking
    }

    pub fn log(&self) -> Vec<DjLogEntry> {
        self.st.lock().unwrap().log.iter().cloned().collect()
    }

    pub fn clear_log(&self) {
        self.st.lock().unwrap().log.clear();
    }
}

/// Volume steps for a short duck/restore fade (`steps` values ending at `to`).
#[uniffi::export]
pub fn dj_volume_ramp(from: f32, to: f32, steps: u32) -> Vec<f32> {
    let n = steps.max(1);
    (1..=n).map(|i| from + (to - from) * i as f32 / n as f32).collect()
}

/// POST /user/ai-dj/transition: the spoken line for moving into `next_*`.
/// Nil on any failure (the DJ just stays quiet).
#[uniffi::export]
pub async fn dj_transition_blurb(client: Arc<ApiClient>, next_title: String, next_artist: Option<String>, cue: DjCue) -> Option<String> {
    let body = serde_json::json!({
        "next_title": next_title,
        "next_artist": next_artist,
        "previous_title": cue.previous_title,
        "previous_artist": cue.previous_artist,
    });
    let data = client.request("/user/ai-dj/transition".into(), "POST".into(), Some(serde_json::to_vec(&body).ok()?), None).await.ok()?;
    let v: serde_json::Value = serde_json::from_slice(&data).ok()?;
    let blurb = v.get("blurb")?.as_str()?.trim().to_string();
    (!blurb.is_empty()).then_some(blurb)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn announces_once_with_previous_track() {
        let d = DjSession::new();
        assert_eq!(d.track_changed("1".into(), "A".into(), Some("x".into()), true, true), Some(DjCue { previous_title: None, previous_artist: None }));
        assert_eq!(d.track_changed("1".into(), "A".into(), Some("x".into()), true, true), None);
        let c = d.track_changed("2".into(), "B".into(), None, true, true).unwrap();
        assert_eq!(c.previous_title.as_deref(), Some("A"));
        assert_eq!(c.previous_artist.as_deref(), Some("x"));
        // Off or paused: nothing said, but the previous track still moves on.
        assert_eq!(d.track_changed("3".into(), "C".into(), None, false, true), None);
        assert_eq!(d.track_changed("4".into(), "D".into(), None, true, true).unwrap().previous_title.as_deref(), Some("C"));
    }

    #[test]
    fn one_duck_at_a_time_keeps_baseline() {
        let d = DjSession::new();
        assert_eq!(d.begin_speaking("hi".into(), 0.8), Some(0.2));
        assert_eq!(d.begin_speaking("again".into(), 0.2), None);
        assert_eq!(d.restore_volume(), 0.8);
        d.finished_speaking();
        assert_eq!(d.begin_speaking("next".into(), 0.8), Some(0.2));
        assert_eq!(d.log().len(), 2);
    }

    #[test]
    fn log_is_capped() {
        let d = DjSession::new();
        for i in 0..40 {
            d.track_changed(i.to_string(), "t".into(), None, true, true);
        }
        let log = d.log();
        assert_eq!(log.len(), MAX_LOG);
        assert_eq!(log.last().unwrap().song_id.as_deref(), Some("39"));
        assert_eq!(dj_volume_ramp(1.0, 0.0, 4), vec![0.75, 0.5, 0.25, 0.0]);
    }
}
