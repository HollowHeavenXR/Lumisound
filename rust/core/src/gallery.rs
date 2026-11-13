//! Lumisound's background gallery engine: the photo store and the slideshow.
//!
//! The app only draws; everything else lives here:
//! * Store: `<dir>/gallery.json` (entries + settings + where the slideshow
//!   is), one file per image plus a small thumbnail, every write atomic.
//! * Import: rejects images too small to be real photos (iOS hands back tiny
//!   placeholder bitmaps for assets it can't read), skips duplicates (same
//!   Photos asset, or byte-identical content), normalizes stills to a
//!   screen-sized JPEG, keeps GIFs as they are (animated).
//! * Slideshow: timing (`tick`), sequential or shuffled order (each photo
//!   once per round, no immediate repeat across rounds), and resuming on the
//!   same photo after a relaunch.
//!
//! Only the current and next image are ever decoded by the app (the old
//! Swift gallery kept every photo decoded in memory).

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// Long side of a stored still (screens are ≤ ~2800 px tall; it's usually
/// shown blurred, so this is plenty).
const STILL_MAX: u32 = 2048;
const THUMB_MAX: u32 = 240;
/// Below this on the long side it isn't a real photo.
const MIN_PHOTO: u32 = 200;
/// GIFs are kept as-is; refuse ones big enough to hurt.
const GIF_MAX_BYTES: usize = 24 * 1024 * 1024;

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct GalleryEntry {
    pub id: String,
    /// Absolute paths (filled in from the store dir; stored relative).
    #[serde(skip)]
    pub path: String,
    #[serde(skip)]
    pub thumb_path: String,
    pub file: String,
    pub thumb: String,
    pub animated: bool,
    pub width: u32,
    pub height: u32,
    pub asset_id: Option<String>,
    pub sha256: String,
    pub added_at: f64,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct GallerySettings {
    pub enabled: bool,
    pub interval_secs: f64,
    /// Transition name (the app's BackgroundAnimation raw value).
    pub animation: String,
    pub opacity: f64,
    pub blur_radius: f64,
    pub ken_burns: bool,
    pub shuffle: bool,
}

impl Default for GallerySettings {
    fn default() -> Self {
        Self { enabled: false, interval_secs: 30.0, animation: "Fade".into(), opacity: 0.35, blur_radius: 16.0, ken_burns: false, shuffle: false }
    }
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum GalleryAddResult {
    Added { entry: GalleryEntry },
    Duplicate { id: String },
    Rejected { reason: String },
}

/// What to show now.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct GalleryFrame {
    pub entry: GalleryEntry,
    pub index: u32,
    pub count: u32,
    /// True when this call moved to a new image (animate the change).
    pub advanced: bool,
    /// Transition length: never longer than 60% of the interval, so a
    /// transition always finishes before the next one starts.
    pub transition_secs: f64,
}

#[derive(Serialize, Deserialize, Default)]
struct Store {
    entries: Vec<GalleryEntry>,
    settings: GallerySettings,
    /// Id of the image on screen (resume point).
    current: Option<String>,
    /// Shuffle round still to show (ids), front first.
    #[serde(default)]
    round: Vec<String>,
}

struct State {
    dir: PathBuf,
    store: Store,
    last_advance: f64,
    rng: u64,
}

#[derive(uniffi::Object)]
pub struct GalleryEngine {
    st: Mutex<State>,
}

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn write_atomic(path: &Path, bytes: &[u8]) -> bool {
    let tmp = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4().simple()));
    if std::fs::write(&tmp, bytes).is_ok() && std::fs::rename(&tmp, path).is_ok() {
        return true;
    }
    let _ = std::fs::remove_file(&tmp);
    false
}

impl State {
    fn fill_paths(&self, mut e: GalleryEntry) -> GalleryEntry {
        e.path = self.dir.join(&e.file).to_string_lossy().into_owned();
        e.thumb_path = self.dir.join(&e.thumb).to_string_lossy().into_owned();
        e
    }

    fn save(&self) {
        if let Ok(b) = serde_json::to_vec_pretty(&self.store) {
            write_atomic(&self.dir.join("gallery.json"), &b);
        }
    }

    fn rand(&mut self) -> u64 {
        // xorshift64*
        self.rng ^= self.rng >> 12;
        self.rng ^= self.rng << 25;
        self.rng ^= self.rng >> 27;
        self.rng.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn current_index(&self) -> Option<usize> {
        let cur = self.store.current.as_ref()?;
        self.store.entries.iter().position(|e| &e.id == cur)
    }

    /// The id that follows the current one.
    fn next_id(&mut self) -> Option<String> {
        let n = self.store.entries.len();
        if n == 0 {
            return None;
        }
        if !self.store.settings.shuffle || n < 3 {
            let i = self.current_index().map_or(0, |i| (i + 1) % n);
            return Some(self.store.entries[i].id.clone());
        }
        // Drop ids that were removed since the round was dealt.
        let ids: std::collections::HashSet<&str> = self.store.entries.iter().map(|e| e.id.as_str()).collect();
        let mut round: Vec<String> = self.store.round.iter().filter(|r| ids.contains(r.as_str())).cloned().collect();
        if round.is_empty() {
            // New round: every photo once, Fisher-Yates; never start with
            // the one on screen.
            round = self.store.entries.iter().map(|e| e.id.clone()).collect();
            for i in (1..round.len()).rev() {
                let j = (self.rand() % (i as u64 + 1)) as usize;
                round.swap(i, j);
            }
            if round.first() == self.store.current.as_ref() {
                let last = round.len() - 1;
                round.swap(0, last);
            }
        }
        let next = round.remove(0);
        self.store.round = round;
        Some(next)
    }

    fn frame(&self, advanced: bool) -> Option<GalleryFrame> {
        let i = self.current_index()?;
        let s = &self.store.settings;
        Some(GalleryFrame {
            entry: self.fill_paths(self.store.entries[i].clone()),
            index: i as u32,
            count: self.store.entries.len() as u32,
            advanced,
            transition_secs: (s.interval_secs * 0.6).min(8.0).max(0.2),
        })
    }

    fn ensure_current(&mut self) {
        if self.current_index().is_none() {
            self.store.current = self.store.entries.first().map(|e| e.id.clone());
        }
    }
}

#[uniffi::export]
impl GalleryEngine {
    /// Opens (or creates) the gallery stored in `dir`.
    #[uniffi::constructor]
    pub fn new(dir: String) -> Arc<Self> {
        let dir = PathBuf::from(dir);
        let _ = std::fs::create_dir_all(&dir);
        let store: Store = std::fs::read(dir.join("gallery.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let mut st = State { dir, store, last_advance: now(), rng: (now() * 1e6) as u64 | 1 };
        // Entries whose file vanished are dropped.
        let before = st.store.entries.len();
        let dir = st.dir.clone();
        st.store.entries.retain(|e| dir.join(&e.file).exists());
        st.ensure_current();
        if st.store.entries.len() != before {
            st.save();
        }
        Arc::new(Self { st: Mutex::new(st) })
    }

    pub fn entries(&self) -> Vec<GalleryEntry> {
        let s = self.st.lock().unwrap();
        s.store.entries.iter().map(|e| s.fill_paths(e.clone())).collect()
    }

    pub fn count(&self) -> u32 {
        self.st.lock().unwrap().store.entries.len() as u32
    }

    pub fn settings(&self) -> GallerySettings {
        self.st.lock().unwrap().store.settings.clone()
    }

    pub fn set_settings(&self, settings: GallerySettings) {
        let mut s = self.st.lock().unwrap();
        let mut v = settings;
        v.interval_secs = v.interval_secs.clamp(2.0, 3600.0);
        v.opacity = v.opacity.clamp(0.0, 1.0);
        v.blur_radius = v.blur_radius.clamp(0.0, 60.0);
        if v.shuffle != s.store.settings.shuffle {
            s.store.round.clear();
        }
        s.store.settings = v;
        s.save();
    }

    pub fn contains_asset(&self, asset_id: String) -> bool {
        self.st.lock().unwrap().store.entries.iter().any(|e| e.asset_id.as_deref() == Some(&asset_id))
    }

    /// Adds an image (JPEG/PNG/WebP/GIF bytes; the app converts HEIC to JPEG).
    pub fn add(&self, data: Vec<u8>, asset_id: Option<String>) -> GalleryAddResult {
        let hash = hex::encode(Sha256::digest(&data));
        {
            let s = self.st.lock().unwrap();
            if let Some(e) = s.store.entries.iter().find(|e| e.sha256 == hash || (asset_id.is_some() && e.asset_id == asset_id)) {
                return GalleryAddResult::Duplicate { id: e.id.clone() };
            }
        }
        let gif = lumisound_media::gallery::is_gif(&data);
        let Some((w, h)) = lumisound_media::gallery::dimensions(&data) else {
            return GalleryAddResult::Rejected { reason: "not a readable image".into() };
        };
        if w.max(h) < MIN_PHOTO {
            return GalleryAddResult::Rejected { reason: format!("too small to be a photo ({w}x{h})") };
        }
        let id = uuid::Uuid::new_v4().simple().to_string();
        let (bytes, w, h, ext) = if gif {
            if data.len() > GIF_MAX_BYTES {
                return GalleryAddResult::Rejected { reason: "GIF too large".into() };
            }
            (data.clone(), w, h, "gif")
        } else {
            match lumisound_media::gallery::prepare_still(&data, STILL_MAX) {
                Some((jpeg, w, h)) => (jpeg, w, h, "jpg"),
                None => return GalleryAddResult::Rejected { reason: "could not decode image".into() },
            }
        };
        let thumb = lumisound_media::gallery::thumbnail(&bytes, THUMB_MAX);
        let mut s = self.st.lock().unwrap();
        let file = format!("{id}.{ext}");
        let thumb_file = format!("{id}.thumb.jpg");
        if !write_atomic(&s.dir.join(&file), &bytes) {
            return GalleryAddResult::Rejected { reason: "could not save".into() };
        }
        if let Some(t) = thumb {
            write_atomic(&s.dir.join(&thumb_file), &t);
        }
        let entry = GalleryEntry {
            id,
            path: String::new(),
            thumb_path: String::new(),
            file,
            thumb: thumb_file,
            animated: gif,
            width: w,
            height: h,
            asset_id,
            sha256: hash,
            added_at: now(),
        };
        s.store.entries.push(entry.clone());
        s.ensure_current();
        s.save();
        GalleryAddResult::Added { entry: s.fill_paths(entry) }
    }

    pub fn remove(&self, id: String) {
        let mut s = self.st.lock().unwrap();
        if let Some(i) = s.store.entries.iter().position(|e| e.id == id) {
            let e = s.store.entries.remove(i);
            let _ = std::fs::remove_file(s.dir.join(&e.file));
            let _ = std::fs::remove_file(s.dir.join(&e.thumb));
            if s.store.current.as_deref() == Some(id.as_str()) {
                // Continue with the photo that took its place.
                s.store.current = s.store.entries.get(i.min(s.store.entries.len().saturating_sub(1))).map(|e| e.id.clone());
            }
            s.store.round.retain(|r| r != &id);
            s.save();
        }
    }

    pub fn clear(&self) {
        let mut s = self.st.lock().unwrap();
        for e in std::mem::take(&mut s.store.entries) {
            let _ = std::fs::remove_file(s.dir.join(&e.file));
            let _ = std::fs::remove_file(s.dir.join(&e.thumb));
        }
        s.store.current = None;
        s.store.round.clear();
        s.save();
    }

    /// Moves the entry at `from` to `to` (gallery order = sequential order).
    pub fn move_entry(&self, from: u32, to: u32) {
        let mut s = self.st.lock().unwrap();
        let n = s.store.entries.len();
        let (from, to) = (from as usize, (to as usize).min(n.saturating_sub(1)));
        if from < n && from != to {
            let e = s.store.entries.remove(from);
            s.store.entries.insert(to, e);
            s.save();
        }
    }

    /// The image on screen (no advance).
    pub fn current(&self) -> Option<GalleryFrame> {
        let mut s = self.st.lock().unwrap();
        s.ensure_current();
        s.frame(false)
    }

    /// Call every second or so: moves on once the interval has passed.
    pub fn tick(&self, now_secs: f64) -> Option<GalleryFrame> {
        let mut s = self.st.lock().unwrap();
        if !s.store.settings.enabled || s.store.entries.is_empty() {
            return None;
        }
        s.ensure_current();
        if now_secs - s.last_advance < s.store.settings.interval_secs || s.store.entries.len() < 2 {
            return s.frame(false);
        }
        s.last_advance = now_secs;
        let next = s.next_id();
        s.store.current = next;
        s.save();
        s.frame(true)
    }

    /// Skip to the next image now (restarts the interval).
    pub fn advance(&self, now_secs: f64) -> Option<GalleryFrame> {
        let mut s = self.st.lock().unwrap();
        if s.store.entries.is_empty() {
            return None;
        }
        s.last_advance = now_secs;
        let next = s.next_id();
        s.store.current = next;
        s.save();
        s.frame(true)
    }

    /// Restart the interval (e.g. after the settings changed).
    pub fn restart_timer(&self, now_secs: f64) {
        self.st.lock().unwrap().last_advance = now_secs;
    }

    /// The image that will come next in sequential order (to pre-decode);
    /// None in shuffle mode until it's dealt.
    pub fn peek_next(&self) -> Option<GalleryEntry> {
        let s = self.st.lock().unwrap();
        let n = s.store.entries.len();
        if n < 2 {
            return None;
        }
        if s.store.settings.shuffle && n >= 3 {
            let id = s.store.round.first()?;
            return s.store.entries.iter().find(|e| &e.id == id).map(|e| s.fill_paths(e.clone()));
        }
        let i = s.current_index().map_or(0, |i| (i + 1) % n);
        Some(s.fill_paths(s.store.entries[i].clone()))
    }

    /// One-time import of the old Swift gallery's files (in order).
    /// Returns how many were added.
    pub fn import_files(&self, paths: Vec<String>, asset_ids: Vec<Option<String>>) -> u32 {
        let mut added = 0;
        for (i, p) in paths.iter().enumerate() {
            let Ok(data) = std::fs::read(p) else { continue };
            if let GalleryAddResult::Added { .. } = self.add(data, asset_ids.get(i).cloned().flatten()) {
                added += 1;
            }
        }
        added
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(w: u32, h: u32, seed: u8) -> Vec<u8> {
        let mut im = image::RgbImage::new(w, h);
        for (x, y, p) in im.enumerate_pixels_mut() {
            *p = image::Rgb([(x as u8).wrapping_add(seed), y as u8, seed]);
        }
        let mut out = Vec::new();
        image::DynamicImage::ImageRgb8(im).write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png).unwrap();
        out
    }

    fn dir() -> String {
        std::env::temp_dir().join(format!("gallery-{}", uuid::Uuid::new_v4().simple())).to_string_lossy().into_owned()
    }

    #[test]
    fn import_rejects_and_dedupes() {
        let d = dir();
        let g = GalleryEngine::new(d.clone());
        assert!(matches!(g.add(png(120, 90, 1), None), GalleryAddResult::Rejected { .. }), "tiny placeholder rejected");
        let GalleryAddResult::Added { entry } = g.add(png(3000, 2000, 2), Some("asset-1".into())) else { panic!() };
        assert_eq!((entry.width, entry.height), (2048, 1365), "normalized to screen size");
        assert!(Path::new(&entry.path).exists() && Path::new(&entry.thumb_path).exists());
        assert!(matches!(g.add(png(3000, 2000, 2), None), GalleryAddResult::Duplicate { .. }), "same bytes");
        assert!(matches!(g.add(png(800, 600, 3), Some("asset-1".into())), GalleryAddResult::Duplicate { .. }), "same Photos asset");
        assert!(g.contains_asset("asset-1".into()));
        assert_eq!(g.count(), 1);
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn slideshow_timing_order_and_resume() {
        let d = dir();
        let g = GalleryEngine::new(d.clone());
        for i in 0..4 {
            assert!(matches!(g.add(png(400, 300, 10 + i), None), GalleryAddResult::Added { .. }));
        }
        let ids: Vec<String> = g.entries().iter().map(|e| e.id.clone()).collect();
        let mut s = g.settings();
        s.enabled = true;
        s.interval_secs = 10.0;
        g.set_settings(s.clone());
        g.restart_timer(1000.0);
        assert!(!g.tick(1005.0).unwrap().advanced, "not yet");
        let f = g.tick(1010.0).unwrap();
        assert!(f.advanced && f.entry.id == ids[1] && f.transition_secs == 6.0);
        assert_eq!(g.advance(1011.0).unwrap().entry.id, ids[2]);
        // Resume after a relaunch on the same photo.
        drop(g);
        let g = GalleryEngine::new(d.clone());
        assert_eq!(g.current().unwrap().entry.id, ids[2]);
        // Shuffle: every photo once per round, no immediate repeat.
        let mut s = g.settings();
        s.shuffle = true;
        g.set_settings(s);
        let mut seen = Vec::new();
        let mut prev = g.current().unwrap().entry.id;
        for k in 0..12 {
            let id = g.advance(2000.0 + k as f64).unwrap().entry.id;
            assert_ne!(id, prev, "no immediate repeat");
            prev = id.clone();
            seen.push(id);
        }
        for round in seen.chunks(4) {
            let mut r = round.to_vec();
            r.sort();
            r.dedup();
            assert_eq!(r.len(), 4, "each photo once per round: {round:?}");
        }
        // Removing the current photo moves on to a remaining one.
        let cur = g.current().unwrap().entry.id;
        g.remove(cur.clone());
        assert_ne!(g.current().unwrap().entry.id, cur);
        assert_eq!(g.count(), 3);
        g.clear();
        assert!(g.current().is_none() && g.count() == 0);
        let _ = std::fs::remove_dir_all(d);
    }
}

/// Pre-blurred background still (see lumisound_media::gallery::blurred_still).
#[uniffi::export]
pub fn gallery_blurred_still(path: String, max_long: u32, sigma_frac: f32) -> Option<Vec<u8>> {
    let bytes = std::fs::read(&path).ok()?;
    lumisound_media::gallery::blurred_still(&bytes, max_long, sigma_frac)
}
