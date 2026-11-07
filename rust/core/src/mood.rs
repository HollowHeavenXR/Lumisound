//! Mood buckets (Energetic / Chill / Focus / Sleep): tempo first, then
//! genre keywords, then title/artist keywords, then duration, then a stable
//! hash of the song id.

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mood {
    Energetic,
    Chill,
    Focus,
    Sleep,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct MoodSong {
    pub id: String,
    pub bpm: Option<f64>,
    pub genre: String,
    pub display_name: String,
    pub artist_name: String,
    pub duration: f64,
    /// Local file to read a tagged BPM from when `bpm` is unknown.
    pub path: Option<String>,
}

fn any(text: &str, words: &[&str]) -> bool {
    words.iter().any(|w| text.contains(w))
}

#[uniffi::export]
pub fn mood_classify(song: MoodSong, cache_dir: String) -> Mood {
    let bpm = song.bpm.or_else(|| {
        let p = song.path.as_ref()?;
        crate::lock::read_tags_with(p, &cache_dir, lumisound_media::tags::read_bpm).or_else(|| crate::analysis::bpm_cached(p.clone()))
    });
    if let Some(b) = bpm {
        return if b < 60.0 { Mood::Sleep } else if b < 90.0 { Mood::Chill } else if b < 120.0 { Mood::Focus } else { Mood::Energetic };
    }
    let g = song.genre.to_lowercase();
    if !g.is_empty() {
        if any(&g, &["rock", "metal", "hip", "hop", "dance", "punk", "rave", "drum", "edm", "electronic", "pop", "funk", "trap"]) {
            return Mood::Energetic;
        }
        if any(&g, &["classical", "jazz", "ambient", "lo-fi", "lofi", "chill", "soul", "bossa", "blues", "easy"]) {
            return Mood::Chill;
        }
        if any(&g, &["instrumental", "study", "focus", "piano", "orchestral", "soundtrack", "cinematic"]) {
            return Mood::Focus;
        }
        if any(&g, &["soft", "acoustic", "sleep", "lullaby", "new age", "meditation", "relaxation"]) {
            return Mood::Sleep;
        }
    }
    let c = format!("{} {}", song.display_name, song.artist_name).to_lowercase();
    if any(&c, &["sleep", "rain", "lofi", "lo-fi", "night", "lullaby", "relax", "calm", "peaceful", "dreamy", "drift"]) {
        return Mood::Sleep;
    }
    if any(&c, &["workout", "pump", "energy", "hype", "run", "rage", "beast", "grind", "power", "fire", "turbo"]) {
        return Mood::Energetic;
    }
    if any(&c, &["study", "focus", "work", "deep", "flow", "concentration", "think"]) {
        return Mood::Focus;
    }
    if any(&c, &["chill", "vibe", "sunset", "breeze", "lazy", "morning", "coffee", "mellow", "soft"]) {
        return Mood::Chill;
    }
    if song.duration > 0.0 {
        if song.duration < 120.0 {
            return Mood::Energetic;
        }
        if song.duration > 480.0 {
            return Mood::Focus;
        }
    }
    // Stable across launches (Swift's hashValue was reseeded per launch).
    let h = song.id.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3));
    [Mood::Energetic, Mood::Chill, Mood::Focus, Mood::Sleep][(h % 4) as usize]
}

/// BPM from the file's tags or an earlier on-device analysis.
#[uniffi::export]
pub fn known_bpm(path: String, cache_dir: String) -> Option<f64> {
    crate::lock::read_tags_with(&path, &cache_dir, lumisound_media::tags::read_bpm).or_else(|| crate::analysis::bpm_cached(path))
}
