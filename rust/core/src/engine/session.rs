//! Queue playback on the engine.
//!
//! `AudioEngine` plays what it is handed: a file now, a file next. Which
//! file comes next, what happens at the end of one, how shuffle and repeat
//! change that, when a crossfade starts, what to do when a file can't be
//! opened — on Apple platforms that bookkeeping grew up in Swift. This is
//! the same bookkeeping in the core, so an app only has to mirror it: the
//! Android app's player is a thin shell over a `PlaySession`.
//!
//! The session never touches the network or the media library. Items are
//! opaque keys; when it needs the file behind one it asks
//! (`SessionListener::need_source`) and the app answers with a path
//! (`provide_source`) once the file is on disk. It asks for the next item
//! ahead of time, so by the end of a track its successor is already open
//! and the hand-over is gapless (or a crossfade, when one is set).

use super::{AudioEngine, EngineListener};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, Weak};

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SessionItem {
    /// The app's id for the track (unique per track, may repeat in a queue).
    pub key: String,
    /// ReplayGain / loudness normalization, in dB.
    pub gain_db: f32,
    /// Where playback starts when the track comes up (Skip Silent Intros).
    pub start_secs: f64,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionState {
    /// Nothing loaded.
    Idle,
    /// The current item's file isn't available yet.
    Buffering,
    /// The current item is loaded (playing or paused).
    Ready,
    /// The queue played to its end.
    Ended,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionRepeat {
    Off,
    One,
    All,
}

#[uniffi::export(with_foreign)]
pub trait SessionListener: Send + Sync {
    /// The session wants the file for `key`: make it available and call
    /// `provide_source` (with a path, or an error).
    fn need_source(&self, key: String);
    /// The item at `index` is now the current one. `automatic` when the
    /// previous track ran into it (gapless, crossfade, end of track).
    fn on_current_changed(&self, index: u32, key: String, automatic: bool);
    fn on_state_changed(&self, state: SessionState);
    /// An item could not be played and was skipped.
    fn on_item_failed(&self, key: String, message: String);
}

struct Prepared {
    index: usize,
    deck: u64,
}

enum Out {
    Need(String),
    Current(u32, String, bool),
    State(SessionState),
    Failed(String, String),
}

struct Inner {
    items: Vec<SessionItem>,
    /// Play order: positions into `items` (the identity unless shuffled).
    order: Vec<usize>,
    shuffle: bool,
    repeat: SessionRepeat,
    current: Option<usize>,
    deck: u64,
    /// The current item is waiting for its file; start position once it has it.
    waiting: Option<f64>,
    next: Option<Prepared>,
    sources: HashMap<String, String>,
    failed: HashSet<String>,
    asked: HashSet<String>,
    play: bool,
    state: SessionState,
    crossfade: f64,
    fail_streak: usize,
    rng: u64,
}

impl Inner {
    fn rand(&mut self) -> u64 {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        self.rng
    }

    fn reorder(&mut self) {
        let n = self.items.len();
        self.order = (0..n).collect();
        if self.shuffle && n > 1 {
            for i in (1..n).rev() {
                let j = (self.rand() % (i as u64 + 1)) as usize;
                self.order.swap(i, j);
            }
            // The playing track stays where the listener is: first.
            if let Some(p) = self.current.and_then(|c| self.order.iter().position(|&x| x == c)) {
                self.order.swap(0, p);
            }
        }
    }

    fn set_state(&mut self, s: SessionState, out: &mut Vec<Out>) {
        if self.state != s {
            self.state = s;
            out.push(Out::State(s));
        }
    }

    fn ask(&mut self, key: &str, out: &mut Vec<Out>) {
        if self.asked.insert(key.to_string()) {
            out.push(Out::Need(key.to_string()));
        }
    }

    /// The item after `from` in play order. `automatic`: the track ran out
    /// (repeat-one repeats it); a manual skip moves on.
    fn after(&self, from: usize, automatic: bool) -> Option<usize> {
        if automatic && self.repeat == SessionRepeat::One {
            return Some(from);
        }
        let p = self.order.iter().position(|&x| x == from)?;
        match self.order.get(p + 1) {
            Some(&n) => Some(n),
            None if self.repeat != SessionRepeat::Off => self.order.first().copied(),
            None => None,
        }
    }

    fn before(&self, from: usize) -> Option<usize> {
        let p = self.order.iter().position(|&x| x == from)?;
        if p > 0 {
            Some(self.order[p - 1])
        } else if self.repeat == SessionRepeat::All {
            self.order.last().copied()
        } else {
            None
        }
    }

    /// Make `index` the current item, starting at `start` seconds.
    fn start(&mut self, index: usize, start: f64, automatic: bool, eng: &AudioEngine, out: &mut Vec<Out>) {
        self.current = Some(index);
        self.next = None;
        eng.clear_next();
        out.push(Out::Current(index as u32, self.items[index].key.clone(), automatic));
        self.load_current(start, eng, out);
    }

    fn load_current(&mut self, start: f64, eng: &AudioEngine, out: &mut Vec<Out>) {
        let Some(index) = self.current else { return };
        let item = self.items[index].clone();
        let Some(path) = self.sources.get(&item.key).cloned() else {
            // Nothing to play until the file is here: the old track stops
            // rather than carrying on under the new title.
            self.waiting = Some(start);
            eng.stop();
            self.set_state(SessionState::Buffering, out);
            self.ask(&item.key, out);
            return;
        };
        self.waiting = None;
        match eng.load(path, start.max(0.0), item.gain_db) {
            Ok(id) => {
                self.deck = id;
                self.fail_streak = 0;
                if self.play {
                    eng.play();
                }
                self.set_state(SessionState::Ready, out);
                self.prepare(eng, out);
            }
            Err(e) => self.skip_failed(e.to_string(), eng, out),
        }
    }

    /// The current item can't be played: report it and move on.
    fn skip_failed(&mut self, message: String, eng: &AudioEngine, out: &mut Vec<Out>) {
        let Some(index) = self.current else { return };
        let key = self.items[index].key.clone();
        self.failed.insert(key.clone());
        out.push(Out::Failed(key, message));
        self.fail_streak += 1;
        self.waiting = None;
        // A queue of nothing but broken files stops instead of spinning.
        let next = if self.fail_streak >= self.items.len() { None } else { self.after(index, false).filter(|&n| n != index) };
        match next {
            Some(n) => {
                let s = self.items[n].start_secs;
                self.start(n, s, true, eng, out);
            }
            None => {
                eng.stop();
                self.set_state(SessionState::Ended, out);
            }
        }
    }

    /// Open the next item behind the playing one (gapless), or ask for its file.
    fn prepare(&mut self, eng: &AudioEngine, out: &mut Vec<Out>) {
        if self.next.is_some() || self.waiting.is_some() || self.state != SessionState::Ready {
            return;
        }
        let Some(cur) = self.current else { return };
        let Some(n) = self.after(cur, true) else { return };
        let item = self.items[n].clone();
        if self.failed.contains(&item.key) {
            return;
        }
        let Some(path) = self.sources.get(&item.key).cloned() else {
            self.ask(&item.key, out);
            return;
        };
        if self.crossfade > 0.0 && n != cur {
            return; // `tick` starts the fade near the end of the track
        }
        match eng.queue_next_at(path, item.start_secs, item.gain_db) {
            Ok(id) => self.next = Some(Prepared { index: n, deck: id }),
            Err(e) => {
                self.failed.insert(item.key.clone());
                out.push(Out::Failed(item.key, e.to_string()));
            }
        }
    }

    /// The successor changed (queue edit, shuffle, repeat): drop what was
    /// opened for the old one.
    fn renext(&mut self, eng: &AudioEngine, out: &mut Vec<Out>) {
        let want = self.current.and_then(|c| self.after(c, true));
        if self.next.as_ref().map(|p| p.index) != want || self.crossfade > 0.0 {
            if self.next.take().is_some() {
                eng.clear_next();
            }
        }
        self.prepare(eng, out);
    }

    fn tick(&mut self, eng: &AudioEngine, out: &mut Vec<Out>) {
        if self.crossfade <= 0.0 || !self.play || self.state != SessionState::Ready || self.next.is_some() || self.waiting.is_some() {
            return;
        }
        let Some(cur) = self.current else { return };
        let Some(n) = self.after(cur, true).filter(|&n| n != cur) else { return };
        let item = self.items[n].clone();
        let Some(path) = self.sources.get(&item.key).cloned() else { return };
        if self.failed.contains(&item.key) {
            return;
        }
        let (dur, pos) = (eng.duration(), eng.position());
        if dur <= 0.0 || pos <= 0.0 || dur - pos > self.crossfade {
            return;
        }
        // A track shorter than two fades just hands over.
        let r = if dur > self.crossfade * 2.0 { eng.crossfade_to(path, (dur - pos).min(self.crossfade), item.start_secs, item.gain_db, true, 1.0) } else { eng.queue_next_at(path, item.start_secs, item.gain_db) };
        match r {
            Ok(id) => self.next = Some(Prepared { index: n, deck: id }),
            Err(e) => {
                self.failed.insert(item.key.clone());
                out.push(Out::Failed(item.key, e.to_string()));
            }
        }
    }

    /// Re-index after a queue edit. `old_of[new]` is the item's index before
    /// the edit (None for an inserted item).
    fn remap(&mut self, items: Vec<SessionItem>, old_of: Vec<Option<usize>>, eng: &AudioEngine, out: &mut Vec<Out>) {
        let mut new_of: HashMap<usize, usize> = HashMap::new();
        for (new, old) in old_of.iter().enumerate() {
            if let Some(o) = old {
                new_of.insert(*o, new);
            }
        }
        let was = self.current;
        let mut order: Vec<usize> = self.order.iter().filter_map(|o| new_of.get(o).copied()).collect();
        let mut added: Vec<usize> = old_of.iter().enumerate().filter(|(_, o)| o.is_none()).map(|(i, _)| i).collect();
        self.items = items;
        if self.shuffle {
            // New songs join the part of the shuffle still to come.
            let from = was.and_then(|c| new_of.get(&c)).and_then(|c| order.iter().position(|x| x == c)).map_or(0, |p| p + 1);
            for a in added.drain(..) {
                let at = from + (self.rand() as usize % (order.len() - from.min(order.len()) + 1));
                order.insert(at.min(order.len()), a);
            }
        } else {
            order = (0..self.items.len()).collect();
        }
        self.order = order;
        if let Some(n) = self.next.as_mut() {
            match new_of.get(&n.index) {
                Some(&i) => n.index = i,
                None => {
                    self.next = None;
                    eng.clear_next();
                }
            }
        }
        match was {
            None => {}
            Some(c) => match new_of.get(&c) {
                Some(&i) => {
                    self.current = Some(i);
                    self.renext(eng, out);
                }
                None => {
                    // The playing item was removed: the one that took its
                    // place plays, or the queue is over.
                    self.next = None;
                    if self.items.is_empty() {
                        self.current = None;
                        self.waiting = None;
                        eng.stop();
                        self.set_state(SessionState::Idle, out);
                    } else if c < self.items.len() {
                        let s = self.items[c].start_secs;
                        self.start(c, s, false, eng, out);
                    } else {
                        let last = self.items.len() - 1;
                        self.current = Some(last);
                        self.waiting = None;
                        eng.stop();
                        out.push(Out::Current(last as u32, self.items[last].key.clone(), false));
                        self.set_state(SessionState::Ended, out);
                    }
                }
            },
        }
    }
}

struct Hook(Weak<PlaySession>);

impl EngineListener for Hook {
    fn on_track_ended(&self, id: u64) {
        if let Some(s) = self.0.upgrade() {
            s.with(|i, eng, out| {
                if id != i.deck || i.waiting.is_some() || i.state != SessionState::Ready {
                    return;
                }
                let Some(cur) = i.current else { return };
                match i.after(cur, true) {
                    Some(n) => {
                        let start = i.items[n].start_secs;
                        i.start(n, start, true, eng, out);
                    }
                    None => i.set_state(SessionState::Ended, out),
                }
            });
        }
    }

    fn on_track_started(&self, id: u64) {
        if let Some(s) = self.0.upgrade() {
            s.with(|i, eng, out| {
                let Some(p) = i.next.take_if(|p| p.deck == id) else { return };
                let item = i.items[p.index].clone();
                i.current = Some(p.index);
                i.deck = id;
                i.fail_streak = 0;
                if let Some(path) = i.sources.get(&item.key) {
                    eng.adopt_current(path.clone(), item.gain_db);
                }
                out.push(Out::Current(p.index as u32, item.key, true));
                i.prepare(eng, out);
            });
        }
    }

    fn on_track_failed(&self, id: u64) {
        if let Some(s) = self.0.upgrade() {
            s.with(|i, eng, out| {
                if id == i.deck && i.state == SessionState::Ready {
                    i.skip_failed("could not be decoded".into(), eng, out);
                } else if let Some(p) = i.next.take_if(|p| p.deck == id) {
                    let key = i.items[p.index].key.clone();
                    i.failed.insert(key.clone());
                    out.push(Out::Failed(key, "could not be decoded".into()));
                }
            });
        }
    }
}

/// See the module docs. One per player.
#[derive(uniffi::Object)]
pub struct PlaySession {
    engine: Arc<AudioEngine>,
    listener: Arc<dyn SessionListener>,
    inner: Mutex<Inner>,
}

impl PlaySession {
    fn with<R>(&self, f: impl FnOnce(&mut Inner, &AudioEngine, &mut Vec<Out>) -> R) -> R {
        let mut out = Vec::new();
        let r = {
            let mut i = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            f(&mut i, &self.engine, &mut out)
        };
        // Outside the lock: the app may call straight back in.
        for o in out {
            match o {
                Out::Need(k) => self.listener.need_source(k),
                Out::Current(i, k, a) => self.listener.on_current_changed(i, k, a),
                Out::State(s) => self.listener.on_state_changed(s),
                Out::Failed(k, m) => self.listener.on_item_failed(k, m),
            }
        }
        r
    }
}

#[uniffi::export]
impl PlaySession {
    #[uniffi::constructor]
    pub fn new(listener: Arc<dyn SessionListener>) -> Arc<Self> {
        let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1) | 1;
        let s = Arc::new_cyclic(|weak: &Weak<PlaySession>| PlaySession {
            engine: AudioEngine::new(Arc::new(Hook(weak.clone()))),
            listener,
            inner: Mutex::new(Inner {
                items: Vec::new(),
                order: Vec::new(),
                shuffle: false,
                repeat: SessionRepeat::Off,
                current: None,
                deck: 0,
                waiting: None,
                next: None,
                sources: HashMap::new(),
                failed: HashSet::new(),
                asked: HashSet::new(),
                play: false,
                state: SessionState::Idle,
                crossfade: 0.0,
                fail_streak: 0,
                rng: seed,
            }),
        });
        let weak = Arc::downgrade(&s);
        let _ = std::thread::Builder::new().name("lumisound-session".into()).spawn(move || {
            loop {
                std::thread::sleep(std::time::Duration::from_millis(100));
                let Some(s) = weak.upgrade() else { break };
                s.with(|i, eng, out| i.tick(eng, out));
            }
        });
        s
    }

    /// The engine underneath (sound settings, output, meters).
    pub fn engine(&self) -> Arc<AudioEngine> {
        self.engine.clone()
    }

    /// Replace the queue and make `start_index` the current item.
    pub fn set_queue(&self, items: Vec<SessionItem>, start_index: u32, start_secs: f64) {
        self.with(|i, eng, out| {
            i.items = items;
            i.next = None;
            i.waiting = None;
            i.sources.clear();
            i.failed.clear();
            i.asked.clear();
            i.fail_streak = 0;
            if i.items.is_empty() {
                i.current = None;
                i.order.clear();
                eng.stop();
                i.set_state(SessionState::Idle, out);
                return;
            }
            let at = (start_index as usize).min(i.items.len() - 1);
            i.current = Some(at);
            i.reorder();
            i.start(at, start_secs, false, eng, out);
        });
    }

    /// Insert `items` before position `index` (past the end appends).
    pub fn insert(&self, index: u32, items: Vec<SessionItem>) {
        self.with(|i, eng, out| {
            let at = (index as usize).min(i.items.len());
            let mut all = i.items.clone();
            let mut old_of: Vec<Option<usize>> = (0..all.len()).map(Some).collect();
            let n = items.len();
            all.splice(at..at, items);
            old_of.splice(at..at, std::iter::repeat_n(None, n));
            let empty = i.current.is_none();
            i.remap(all, old_of, eng, out);
            if empty && !i.items.is_empty() && i.state == SessionState::Idle {
                i.reorder();
                let s = i.items[0].start_secs;
                i.start(0, s, false, eng, out);
            }
        });
    }

    /// Remove positions `from..to`.
    pub fn remove(&self, from: u32, to: u32) {
        self.with(|i, eng, out| {
            let (a, b) = ((from as usize).min(i.items.len()), (to as usize).min(i.items.len()));
            if a >= b {
                return;
            }
            let mut all = i.items.clone();
            let mut old_of: Vec<Option<usize>> = (0..all.len()).map(Some).collect();
            all.drain(a..b);
            old_of.drain(a..b);
            i.remap(all, old_of, eng, out);
        });
    }

    /// Move positions `from..to` so the first of them lands at `new_index`.
    pub fn move_items(&self, from: u32, to: u32, new_index: u32) {
        self.with(|i, eng, out| {
            let (a, b) = ((from as usize).min(i.items.len()), (to as usize).min(i.items.len()));
            if a >= b {
                return;
            }
            let mut all = i.items.clone();
            let mut old_of: Vec<Option<usize>> = (0..all.len()).map(Some).collect();
            let moved: Vec<SessionItem> = all.drain(a..b).collect();
            let moved_idx: Vec<Option<usize>> = old_of.drain(a..b).collect();
            let at = (new_index as usize).min(all.len());
            all.splice(at..at, moved);
            old_of.splice(at..at, moved_idx);
            i.remap(all, old_of, eng, out);
        });
    }

    /// Jump to the item at `index`.
    pub fn jump(&self, index: u32, start_secs: f64) {
        self.with(|i, eng, out| {
            if (index as usize) < i.items.len() {
                i.fail_streak = 0;
                i.start(index as usize, start_secs, false, eng, out);
            }
        });
    }

    /// Skip to the next item in play order. False at the end of the queue.
    pub fn next(&self) -> bool {
        self.with(|i, eng, out| {
            let Some(n) = i.current.and_then(|c| i.after(c, false)) else { return false };
            let s = i.items[n].start_secs;
            i.fail_streak = 0;
            i.start(n, s, false, eng, out);
            true
        })
    }

    /// Skip to the previous item in play order. False at the start.
    pub fn previous(&self) -> bool {
        self.with(|i, eng, out| {
            let Some(n) = i.current.and_then(|c| i.before(c)) else { return false };
            let s = i.items[n].start_secs;
            i.fail_streak = 0;
            i.start(n, s, false, eng, out);
            true
        })
    }

    /// The position in the queue `next` / `previous` would move to.
    pub fn peek(&self, forward: bool) -> Option<u32> {
        let i = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let c = i.current?;
        if forward { i.after(c, false) } else { i.before(c) }.map(|n| n as u32)
    }

    pub fn seek(&self, secs: f64) {
        self.with(|i, eng, out| {
            let Some(cur) = i.current else { return };
            if i.waiting.is_some() {
                i.waiting = Some(secs.max(0.0));
            } else if i.state == SessionState::Ended {
                i.start(cur, secs, false, eng, out);
            } else if let Ok(id) = eng.seek(secs) {
                i.deck = id;
            }
        });
    }

    pub fn set_play(&self, play: bool) {
        self.with(|i, eng, _| {
            i.play = play;
            if i.state == SessionState::Ready {
                if play { eng.play() } else { eng.pause(0.04) }
            }
        });
    }

    pub fn set_repeat(&self, repeat: SessionRepeat) {
        self.with(|i, eng, out| {
            i.repeat = repeat;
            i.renext(eng, out);
        });
    }

    pub fn set_shuffle(&self, shuffle: bool) {
        self.with(|i, eng, out| {
            i.shuffle = shuffle;
            i.reorder();
            i.renext(eng, out);
        });
    }

    /// Seconds of crossfade between tracks (0 = gapless hand-over).
    pub fn set_crossfade(&self, secs: f64) {
        self.with(|i, eng, out| {
            i.crossfade = secs.clamp(0.0, 30.0);
            i.renext(eng, out);
        });
    }

    /// Pitch-preserving speed and pitch shift for everything played.
    pub fn set_speed_pitch(&self, speed: f64, pitch_semitones: f64) {
        self.with(|i, eng, out| {
            if let Ok(Some(id)) = eng.set_speed_pitch(speed, pitch_semitones) {
                // The engine reopened the track and dropped what was queued.
                i.deck = id;
                i.next = None;
                i.prepare(eng, out);
            }
        });
    }

    /// Answer to `need_source`: the file for `key` (or why there is none).
    pub fn provide_source(&self, key: String, path: Option<String>, error: Option<String>) {
        self.with(|i, eng, out| {
            i.asked.remove(&key);
            let is_current = i.current.is_some_and(|c| i.items[c].key == key);
            match path {
                Some(p) => {
                    i.failed.remove(&key);
                    i.sources.insert(key, p);
                    if is_current && i.waiting.is_some() {
                        let start = i.waiting.take().unwrap_or(0.0);
                        i.load_current(start, eng, out);
                    } else {
                        i.prepare(eng, out);
                    }
                }
                None => {
                    if is_current && i.waiting.is_some() {
                        i.skip_failed(error.unwrap_or_else(|| "not available".into()), eng, out);
                    } else {
                        i.failed.insert(key.clone());
                        out.push(Out::Failed(key, error.unwrap_or_else(|| "not available".into())));
                    }
                }
            }
        });
    }

    pub fn current_index(&self) -> Option<u32> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).current.map(|c| c as u32)
    }

    pub fn state(&self) -> SessionState {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).state
    }

    /// Seconds into the current item.
    pub fn position(&self) -> f64 {
        let i = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        match (i.state, i.waiting) {
            (_, Some(w)) => w,
            (SessionState::Ready, _) => self.engine.position(),
            (SessionState::Ended, _) => self.engine.duration(),
            _ => 0.0,
        }
    }

    /// Length of the current item in seconds (0 until it is loaded).
    pub fn duration(&self) -> f64 {
        let i = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if i.state == SessionState::Ready && i.waiting.is_none() { self.engine.duration() } else { 0.0 }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[derive(Default)]
    struct Log {
        events: Mutex<Vec<String>>,
        session: Mutex<Weak<PlaySession>>,
        dir: Mutex<std::path::PathBuf>,
        hold: Mutex<HashSet<String>>,
    }

    impl SessionListener for Log {
        fn need_source(&self, key: String) {
            self.events.lock().unwrap().push(format!("need {key}"));
            if self.hold.lock().unwrap().contains(&key) {
                return;
            }
            let s = self.session.lock().unwrap().upgrade();
            let path = self.dir.lock().unwrap().join(&key);
            if let Some(s) = s {
                // Like the app: answered from another thread, a moment later.
                std::thread::spawn(move || {
                    if path.exists() { s.provide_source(key, Some(path.to_string_lossy().into()), None) } else { s.provide_source(key, None, Some("missing".into())) }
                });
            }
        }
        fn on_current_changed(&self, index: u32, key: String, automatic: bool) {
            self.events.lock().unwrap().push(format!("current {index} {key} {}", if automatic { "auto" } else { "manual" }));
        }
        fn on_state_changed(&self, state: SessionState) {
            self.events.lock().unwrap().push(format!("state {state:?}"));
        }
        fn on_item_failed(&self, key: String, message: String) {
            self.events.lock().unwrap().push(format!("failed {key} {message}"));
        }
    }

    fn wav(path: &std::path::Path, secs: f32, freq: f32) {
        let rate = 48_000u32;
        let n = (secs * rate as f32) as u32;
        let mut b = Vec::new();
        b.extend_from_slice(b"RIFF");
        b.extend_from_slice(&(36 + n * 4).to_le_bytes());
        b.extend_from_slice(b"WAVEfmt ");
        b.extend_from_slice(&16u32.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&2u16.to_le_bytes());
        b.extend_from_slice(&rate.to_le_bytes());
        b.extend_from_slice(&(rate * 4).to_le_bytes());
        b.extend_from_slice(&4u16.to_le_bytes());
        b.extend_from_slice(&16u16.to_le_bytes());
        b.extend_from_slice(b"data");
        b.extend_from_slice(&(n * 4).to_le_bytes());
        for i in 0..n {
            let v = ((std::f32::consts::TAU * freq * i as f32 / rate as f32).sin() * 0.5 * 32767.0) as i16;
            b.extend_from_slice(&v.to_le_bytes());
            b.extend_from_slice(&v.to_le_bytes());
        }
        std::fs::write(path, b).unwrap();
    }

    fn setup(name: &str, tracks: &[(&str, f32, f32)]) -> (Arc<PlaySession>, Arc<Log>) {
        let dir = std::env::temp_dir().join(format!("lumi-session-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for (file, secs, freq) in tracks {
            wav(&dir.join(file), *secs, *freq);
        }
        let log = Arc::new(Log::default());
        *log.dir.lock().unwrap() = dir;
        let s = PlaySession::new(log.clone());
        *log.session.lock().unwrap() = Arc::downgrade(&s);
        (s, log)
    }

    fn items(keys: &[&str]) -> Vec<SessionItem> {
        keys.iter().map(|k| SessionItem { key: k.to_string(), gain_db: 0.0, start_secs: 0.0 }).collect()
    }

    /// Render like an audio device would, until `done` or `secs` of audio.
    fn run(s: &PlaySession, secs: f64, done: impl Fn() -> bool) -> Vec<f32> {
        let eng = s.engine();
        let mut all = Vec::new();
        let chunk = 1024;
        let mut frames = 0usize;
        while (frames as f64) < secs * eng.output_rate() as f64 && !done() {
            let t = std::time::Instant::now();
            while s.state() == SessionState::Ready && !eng.mixer.lock().unwrap().decks_ready(chunk) && t.elapsed() < Duration::from_millis(300) {
                std::thread::sleep(Duration::from_millis(1));
            }
            all.extend(eng.render_offline(chunk));
            frames += chunk;
            // Let the engine's event thread and the session's timer keep up.
            std::thread::sleep(Duration::from_micros(300));
        }
        all
    }

    fn has(log: &Log, what: &str) -> bool {
        log.events.lock().unwrap().iter().any(|e| e == what)
    }

    fn wait(log: &Log, what: &str) {
        let t = std::time::Instant::now();
        while !has(log, what) && t.elapsed() < Duration::from_secs(5) {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(has(log, what), "never saw `{what}` in {:?}", log.events.lock().unwrap());
    }

    /// Dominant frequency of a mono slice (zero crossings).
    fn freq(samples: &[f32], rate: u32) -> f32 {
        let mono: Vec<f32> = samples.chunks(2).map(|c| c[0]).collect();
        let crossings = mono.windows(2).filter(|w| w[0] <= 0.0 && w[1] > 0.0).count();
        crossings as f32 * rate as f32 / mono.len() as f32
    }

    #[test]
    fn plays_through_the_queue_gaplessly_and_ends() {
        let (s, log) = setup("through", &[("a.wav", 1.0, 440.0), ("b.wav", 1.0, 880.0), ("c.wav", 0.6, 1320.0)]);
        s.set_play(true);
        s.set_queue(items(&["a.wav", "b.wav", "c.wav"]), 0, 0.0);
        wait(&log, "state Ready");
        let audio = run(&s, 6.0, || has(&log, "state Ended"));
        wait(&log, "state Ended");
        let e = log.events.lock().unwrap().clone();
        assert!(e.contains(&"current 0 a.wav manual".to_string()), "{e:?}");
        assert!(e.contains(&"current 1 b.wav auto".to_string()), "{e:?}");
        assert!(e.contains(&"current 2 c.wav auto".to_string()), "{e:?}");
        assert_eq!(s.current_index(), Some(2));
        // Gapless: about 2.6 s of sound, no silent stretch inside it.
        let rate = s.engine().output_rate() as usize;
        let loud: Vec<bool> = audio.chunks(rate / 50 * 2).map(|c| c.iter().any(|x| x.abs() > 0.05)).collect();
        let first = loud.iter().position(|&l| l).unwrap();
        let last = loud.iter().rposition(|&l| l).unwrap();
        assert!(loud[first..=last].iter().all(|&l| l), "a gap inside the queue");
        let secs = (last - first + 1) as f32 / 50.0;
        assert!((2.4..2.9).contains(&secs), "played {secs} s");
    }

    #[test]
    fn waits_for_a_file_and_skips_one_that_never_comes() {
        let (s, log) = setup("wait", &[("a.wav", 0.5, 440.0), ("c.wav", 0.5, 660.0)]);
        log.hold.lock().unwrap().insert("a.wav".into());
        s.set_play(true);
        s.set_queue(items(&["a.wav", "missing.wav", "c.wav"]), 0, 0.0);
        assert_eq!(s.state(), SessionState::Buffering);
        run(&s, 0.2, || false);
        let dir = log.dir.lock().unwrap().clone();
        s.provide_source("a.wav".into(), Some(dir.join("a.wav").to_string_lossy().into()), None);
        assert_eq!(s.state(), SessionState::Ready);
        run(&s, 4.0, || has(&log, "state Ended"));
        wait(&log, "state Ended");
        let e = log.events.lock().unwrap().clone();
        assert!(e.iter().any(|x| x.starts_with("failed missing.wav")), "{e:?}");
        assert!(e.contains(&"current 2 c.wav auto".to_string()), "{e:?}");
    }

    #[test]
    fn skip_repeat_and_shuffle() {
        let (s, log) = setup("skip", &[("a.wav", 2.0, 440.0), ("b.wav", 2.0, 880.0), ("c.wav", 2.0, 1320.0)]);
        s.set_play(true);
        s.set_queue(items(&["a.wav", "b.wav", "c.wav"]), 0, 0.0);
        wait(&log, "state Ready");
        run(&s, 0.3, || false);
        assert!(s.next());
        assert_eq!(s.current_index(), Some(1));
        let audio = run(&s, 0.5, || false);
        let f = freq(&audio[audio.len() / 2..], s.engine().output_rate());
        assert!((f - 880.0).abs() < 40.0, "playing {f} Hz after skip");
        assert!(s.previous());
        assert_eq!(s.current_index(), Some(0));
        assert!(!s.previous());
        s.jump(2, 0.0);
        assert_eq!(s.peek(true), None);
        s.set_repeat(SessionRepeat::All);
        assert_eq!(s.peek(true), Some(0));
        // Repeat one: the same track comes round again on its own.
        s.set_repeat(SessionRepeat::One);
        log.events.lock().unwrap().clear();
        run(&s, 3.0, || has(&log, "current 2 c.wav auto"));
        wait(&log, "current 2 c.wav auto");
        // Shuffle keeps the playing track and still visits everything once.
        s.set_repeat(SessionRepeat::Off);
        s.set_shuffle(true);
        let mut seen = vec![s.current_index().unwrap()];
        while s.next() {
            seen.push(s.current_index().unwrap());
        }
        seen.sort();
        assert_eq!(seen, vec![0, 1, 2]);
    }

    #[test]
    fn queue_edits_keep_the_playing_track() {
        let (s, log) = setup("edit", &[("a.wav", 2.0, 440.0), ("b.wav", 2.0, 880.0), ("c.wav", 2.0, 1320.0), ("d.wav", 2.0, 300.0)]);
        s.set_play(true);
        s.set_queue(items(&["a.wav", "b.wav", "c.wav"]), 1, 0.0);
        wait(&log, "state Ready");
        s.insert(0, items(&["d.wav"]));
        assert_eq!(s.current_index(), Some(2));
        s.move_items(2, 3, 0);
        assert_eq!(s.current_index(), Some(0));
        assert_eq!(s.peek(true), Some(1)); // d
        s.remove(1, 2);
        assert_eq!(s.peek(true), Some(1)); // a
        // Removing the playing track plays what took its place.
        log.events.lock().unwrap().clear();
        s.remove(0, 1);
        assert_eq!(s.current_index(), Some(0));
        wait(&log, "current 0 a.wav manual");
        s.remove(0, 5);
        assert_eq!(s.state(), SessionState::Idle);
        assert_eq!(s.current_index(), None);
    }

    #[test]
    fn crossfade_overlaps_the_two_tracks() {
        let (s, log) = setup("xfade", &[("a.wav", 3.0, 440.0), ("b.wav", 3.0, 1760.0)]);
        s.set_crossfade(1.0);
        s.set_play(true);
        s.set_queue(items(&["a.wav", "b.wav"]), 0, 0.0);
        wait(&log, "state Ready");
        let rate = s.engine().output_rate();
        // Real time matters here (the fade is started by a timer), so pace the render.
        let mut audio = Vec::new();
        let t = std::time::Instant::now();
        while !has(&log, "current 1 b.wav auto") && t.elapsed() < Duration::from_secs(8) {
            audio.extend(s.engine().render_offline(480));
            std::thread::sleep(Duration::from_millis(9));
        }
        assert!(has(&log, "current 1 b.wav auto"), "{:?}", log.events.lock().unwrap());
        // The fade began before the first track was over.
        let played = audio.len() as f64 / 2.0 / rate as f64;
        assert!(played < 2.9, "second track only started after {played} s");
        assert!(played > 1.5, "second track started too early ({played} s)");
    }
}
