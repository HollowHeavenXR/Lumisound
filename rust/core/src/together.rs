//! Listen Together sync: Lumisound's own replacement for SharePlay.
//!
//! Rooms live on the bridge (`/rooms/*`, pushed over `/ws/live`). The host
//! publishes what it plays (track, position, playing) and the bridge stamps
//! each update with its own clock (`as_of`). A follower keeps the host's
//! timeline in *server* time, so neither device's clock has to be right:
//!
//! - `add_clock_sample` takes a request's send / receive times (this
//!   device's clock) and the server time in its reply. The offset is the
//!   NTP estimate from the fastest recent round trips (a slow trip has an
//!   unknown split between upload and download, a fast one doesn't).
//! - `decide` compares where the host is now with where this device is and
//!   returns one action: load the host's track, play / pause, a seek for a
//!   big gap, or a small tempo nudge (±5 %, pitch kept) that closes a small
//!   gap without an audible jump, then back to 1×.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct TogetherHost {
    /// The host's track identity (see `track_key`); empty = nothing playing.
    pub track_key: String,
    pub position: f64,
    pub playing: bool,
    /// Server time (unix seconds) the position was true at.
    pub as_of_server: f64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct TogetherLocal {
    pub track_key: String,
    pub position: f64,
    pub playing: bool,
    /// This device's clock (unix seconds) now.
    pub now: f64,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TogetherActionKind {
    /// In step: nothing to do.
    Hold,
    /// Load the host's track and start it at `position`.
    Load,
    Seek,
    Play,
    Pause,
    /// Play at `rate` × the listener's own speed until told otherwise.
    Nudge,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct TogetherAction {
    pub kind: TogetherActionKind,
    pub position: f64,
    pub rate: f64,
    /// How far this device is from the host (seconds, + = ahead).
    pub drift: f64,
}

/// A seek beyond this; a nudge between `NUDGE_FROM` and this.
const SEEK_ABOVE: f64 = 1.0;
const NUDGE_FROM: f64 = 0.08;
/// Nudge back to 1× once this close.
const SETTLE: f64 = 0.03;
const MAX_NUDGE: f64 = 0.05;
/// Seconds over which a nudge aims to close the gap.
const NUDGE_SECS: f64 = 6.0;
/// After a load / seek the player's position settles; don't correct again before.
const COOLDOWN: f64 = 1.5;
/// A seek lands this much later than asked (buffering a new deck).
const SEEK_LEAD: f64 = 0.12;

#[derive(Default)]
struct State {
    /// (round trip, offset) of recent samples.
    samples: VecDeque<(f64, f64)>,
    rate: f64,
    cooldown_until: f64,
}

#[derive(uniffi::Object)]
pub struct TogetherSync {
    state: Mutex<State>,
}

impl Default for TogetherSync {
    fn default() -> Self {
        TogetherSync { state: Mutex::new(State { rate: 1.0, ..Default::default() }) }
    }
}

#[uniffi::export]
impl TogetherSync {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// One request's timing: sent / received on this device, `server` from the reply.
    pub fn add_clock_sample(&self, sent: f64, server: f64, received: f64) {
        let rtt = received - sent;
        if !(0.0..30.0).contains(&rtt) {
            return;
        }
        let offset = server - (sent + received) / 2.0;
        let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
        s.samples.push_back((rtt, offset));
        while s.samples.len() > 12 {
            s.samples.pop_front();
        }
    }

    /// Server clock minus this device's clock (seconds); 0 until sampled.
    pub fn clock_offset(&self) -> f64 {
        let s = self.state.lock().unwrap_or_else(|e| e.into_inner());
        best_offset(&s.samples)
    }

    /// The host's position right now (seconds into its track).
    pub fn host_position(&self, host: TogetherHost, now: f64) -> f64 {
        let off = self.clock_offset();
        expected(&host, now + off)
    }

    /// What this device should do to stay with the host.
    pub fn decide(&self, host: TogetherHost, local: TogetherLocal) -> TogetherAction {
        let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let server_now = local.now + best_offset(&s.samples);
        let want = expected(&host, server_now);
        let act = |kind, position, rate, drift| TogetherAction { kind, position, rate, drift };

        if host.track_key.is_empty() {
            return act(if local.playing { TogetherActionKind::Pause } else { TogetherActionKind::Hold }, local.position, 1.0, 0.0);
        }
        if local.track_key != host.track_key {
            s.rate = 1.0;
            s.cooldown_until = local.now + COOLDOWN * 2.0;
            let at = if host.playing { want + SEEK_LEAD } else { want };
            return act(TogetherActionKind::Load, at.max(0.0), 1.0, 0.0);
        }
        let drift = local.position - want;
        if !host.playing {
            s.rate = 1.0;
            if local.playing {
                return act(TogetherActionKind::Pause, want, 1.0, drift);
            }
            if drift.abs() > 0.5 {
                return act(TogetherActionKind::Seek, want, 1.0, drift);
            }
            return act(TogetherActionKind::Hold, want, 1.0, drift);
        }
        if !local.playing {
            s.rate = 1.0;
            s.cooldown_until = local.now + COOLDOWN;
            return act(TogetherActionKind::Play, want + SEEK_LEAD, 1.0, drift);
        }
        if local.now < s.cooldown_until {
            return act(TogetherActionKind::Hold, want, s.rate, drift);
        }
        if drift.abs() > SEEK_ABOVE {
            s.rate = 1.0;
            s.cooldown_until = local.now + COOLDOWN;
            return act(TogetherActionKind::Seek, want + SEEK_LEAD, 1.0, drift);
        }
        let nudging = (s.rate - 1.0).abs() > 1e-9;
        if nudging && drift.abs() <= SETTLE {
            s.rate = 1.0;
            return act(TogetherActionKind::Nudge, want, 1.0, drift);
        }
        if drift.abs() >= NUDGE_FROM || (nudging && drift.abs() > SETTLE) {
            // Ahead: slow down; behind: speed up. Quantised to 1 % steps so a
            // jittery drift estimate doesn't reopen the deck every second.
            let raw = (1.0 - drift / NUDGE_SECS).clamp(1.0 - MAX_NUDGE, 1.0 + MAX_NUDGE);
            let rate = (raw * 100.0).round() / 100.0;
            let rate = if (rate - 1.0).abs() < 1e-9 { 1.0 + 0.01f64.copysign(-drift) } else { rate };
            if (rate - s.rate).abs() > 1e-9 {
                s.rate = rate;
                return act(TogetherActionKind::Nudge, want, rate, drift);
            }
        }
        act(TogetherActionKind::Hold, want, s.rate, drift)
    }

    /// Forget nudges and cooldowns (leaving a room, or the host changed).
    pub fn reset(&self) {
        let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
        s.rate = 1.0;
        s.cooldown_until = 0.0;
    }
}

fn best_offset(samples: &VecDeque<(f64, f64)>) -> f64 {
    // Median offset of the three fastest trips.
    let mut v: Vec<(f64, f64)> = samples.iter().copied().collect();
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut fastest: Vec<f64> = v.iter().take(3).map(|x| x.1).collect();
    fastest.sort_by(|a, b| a.total_cmp(b));
    fastest[fastest.len() / 2]
}

fn expected(host: &TogetherHost, server_now: f64) -> f64 {
    if host.playing {
        host.position + (server_now - host.as_of_server).max(0.0)
    } else {
        host.position
    }
}

/// Identity of a track across devices: the source id when there is one
/// ("youtube:abc"), else folded "title — artist".
#[uniffi::export]
pub fn together_track_key(source_track_id: Option<String>, title: String, artist: String) -> String {
    if let Some(s) = source_track_id.filter(|s| !s.trim().is_empty() && s.contains(':')) {
        return s;
    }
    let fold = |s: &str| s.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ");
    let (t, a) = (fold(&title), fold(&artist));
    if t.is_empty() {
        return String::new();
    }
    format!("lumi:{t}|{a}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use TogetherActionKind::*;

    fn host(pos: f64, playing: bool, as_of: f64) -> TogetherHost {
        TogetherHost { track_key: "youtube:a".into(), position: pos, playing, as_of_server: as_of }
    }
    fn local(pos: f64, playing: bool, now: f64) -> TogetherLocal {
        TogetherLocal { track_key: "youtube:a".into(), position: pos, playing, now }
    }

    #[test]
    fn clock_offset_prefers_fast_trips() {
        let t = TogetherSync::new();
        // Server is 100 s ahead. A slow trip with an uneven split lies.
        t.add_clock_sample(0.0, 100.9, 1.0); // rtt 1.0, offset 100.4
        t.add_clock_sample(10.0, 110.05, 10.1); // rtt 0.1, offset 100.0
        t.add_clock_sample(20.0, 120.06, 20.1);
        t.add_clock_sample(30.0, 130.04, 30.1);
        assert!((t.clock_offset() - 100.0).abs() < 0.02, "{}", t.clock_offset());
    }

    #[test]
    fn loads_the_hosts_track_where_it_is() {
        let t = TogetherSync::new();
        t.add_clock_sample(0.0, 50.0, 0.0);
        let mut l = local(0.0, false, 10.0);
        l.track_key = "youtube:other".into();
        // Host was at 30 s at server time 55 and is playing; server now = 60.
        let a = t.decide(host(30.0, true, 55.0), l);
        assert_eq!(a.kind, Load);
        assert!((a.position - (35.0 + SEEK_LEAD)).abs() < 1e-6);
    }

    #[test]
    fn follows_play_pause_and_seeks_big_gaps() {
        let t = TogetherSync::new();
        assert_eq!(t.decide(host(10.0, false, 0.0), local(10.0, true, 0.0)).kind, Pause);
        assert_eq!(t.decide(host(10.0, true, 0.0), local(10.0, false, 0.0)).kind, Play);
        let t = TogetherSync::new();
        let a = t.decide(host(10.0, true, 100.0), local(14.0, true, 100.0));
        assert_eq!(a.kind, Seek);
        assert!((a.drift - 4.0).abs() < 1e-6);
        // Cooldown: right after a seek, hold.
        assert_eq!(t.decide(host(10.0, true, 100.0), local(14.0, true, 100.5)).kind, Hold);
    }

    #[test]
    fn nudges_small_gaps_then_settles() {
        let t = TogetherSync::new();
        // 0.3 s ahead: slow down.
        let a = t.decide(host(50.0, true, 0.0), local(50.3, true, 0.0));
        assert_eq!(a.kind, Nudge);
        assert!(a.rate < 1.0 && a.rate >= 0.95, "{}", a.rate);
        // Same rate again: no new action.
        assert_eq!(t.decide(host(50.0, true, 0.0), local(50.29, true, 0.0)).kind, Hold);
        // Closed the gap: back to 1×.
        let a = t.decide(host(50.0, true, 0.0), local(50.01, true, 0.0));
        assert_eq!((a.kind, a.rate), (Nudge, 1.0));
        // Behind: speed up.
        let a = t.decide(host(50.0, true, 0.0), local(49.8, true, 0.0));
        assert!(a.kind == Nudge && a.rate > 1.0);
        // Tiny drift alone does nothing.
        let t = TogetherSync::new();
        assert_eq!(t.decide(host(50.0, true, 0.0), local(50.05, true, 0.0)).kind, Hold);
    }

    #[test]
    fn simulated_follower_converges() {
        // A follower that starts 0.6 s behind and whose clock is 3 s off
        // ends up within 40 ms using only nudges.
        let t = TogetherSync::new();
        for i in 0..5 {
            let sent = i as f64;
            t.add_clock_sample(sent, sent + 3.0 + 0.04, sent + 0.08);
        }
        let mut pos = 9.4;
        let mut rate = 1.0;
        let mut now = 0.0; // follower clock; server = now + 3
        for _ in 0..400 {
            now += 0.1;
            pos += 0.1 * rate;
            let a = t.decide(TogetherHost { track_key: "k".into(), position: 10.0, playing: true, as_of_server: 3.0 }, TogetherLocal { track_key: "k".into(), position: pos, playing: true, now });
            match a.kind {
                Nudge => rate = a.rate,
                Seek => pos = a.position,
                _ => {}
            }
        }
        let want = 10.0 + now;
        assert!((pos - want).abs() < 0.04, "drift {}", pos - want);
        assert_eq!(rate, 1.0);
    }

    #[test]
    fn track_keys() {
        assert_eq!(together_track_key(Some("youtube:abc".into()), "x".into(), "y".into()), "youtube:abc");
        assert_eq!(together_track_key(None, "Hey Jude!".into(), "The Beatles".into()), "lumi:hey jude|the beatles");
        assert_eq!(together_track_key(Some("".into()), "".into(), "".into()), "");
    }
}
