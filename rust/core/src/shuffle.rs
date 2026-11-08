//! Shuffle orders for the play queue and every "Shuffle" button.
//!
//! Smart shuffle is still random, but it:
//! - spreads artists and albums out (no back-to-back songs by one artist
//!   while others are available),
//! - plays songs heard in the last hours/days later in the order,
//! - plays songs the listener keeps skipping early later in the order,
//! - avoids big tempo jumps between neighbours when BPMs are known.
//!
//! Plain shuffle is a uniform Fisher–Yates shuffle.

use std::collections::{HashMap, HashSet, VecDeque};

#[derive(uniffi::Record, Clone, Debug)]
pub struct ShuffleItem {
    pub id: String,
    pub artist: String,
    pub album: String,
    pub bpm: Option<f64>,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct ShuffleOptions {
    /// Smart shuffle (see module docs); false = plain uniform shuffle.
    pub smart: bool,
    /// Tempo of the song playing just before the shuffled list.
    pub anchor_bpm: Option<f64>,
    /// Artist of the song playing just before the shuffled list.
    pub previous_artist: Option<String>,
    /// Fixed seed for a reproducible order; None = random.
    pub seed: Option<u64>,
}

/// A shuffled order of `items`, as indices into `items`.
#[uniffi::export]
pub fn shuffle_order(items: Vec<ShuffleItem>, options: ShuffleOptions) -> Vec<u32> {
    let (plays, skips) = if options.smart { crate::stores::listening_stats() } else { Default::default() };
    shuffle_with(&items, &options, &plays, &skips, crate::store::now())
}

// ---- random numbers -------------------------------------------------------------------------

/// SplitMix64: tiny, fast, good enough for ordering songs.
struct Rng(u64);

impl Rng {
    fn new(seed: Option<u64>) -> Self {
        Rng(seed.unwrap_or_else(|| {
            use std::sync::atomic::{AtomicU64, Ordering};
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(0);
            t ^ COUNTER.fetch_add(0x9E37_79B9_7F4A_7C15, Ordering::Relaxed).rotate_left(17)
        }))
    }

    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in (0, 1].
    fn unit(&mut self) -> f64 {
        ((self.next_u64() >> 11) as f64 + 1.0) / (1u64 << 53) as f64
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next_u64() % n as u64) as usize
    }
}

// ---- smart shuffle --------------------------------------------------------------------------

/// How far ahead in the weighted order the spreading pass looks for a better
/// next song. Small enough to keep the order random, big enough to find a
/// different artist in a library dominated by one.
const WINDOW: usize = 24;

/// Primary artist, normalised; None for blank/unknown (never constrained).
fn artist_key(a: &str) -> Option<String> {
    let mut s = a.trim().to_lowercase();
    for sep in [" feat.", " feat ", " ft.", " ft ", " featuring ", ", ", " x ", " & "] {
        if let Some(i) = s.find(sep) {
            s.truncate(i);
        }
    }
    let s = s.trim_end_matches(" - topic").trim().to_string();
    (!s.is_empty() && s != "unknown artist" && s != "unknown" && s != "various artists").then_some(s)
}

fn album_key(a: &str) -> Option<String> {
    let s = a.trim().to_lowercase();
    (!s.is_empty() && s != "unknown album").then_some(s)
}

/// Relative tempo distance in percent, treating half/double time as close.
fn tempo_gap(a: f64, b: f64) -> f64 {
    if !(a > 0.0 && b > 0.0) {
        return 0.0;
    }
    let mut r = a.max(b) / a.min(b);
    if r > 1.9 {
        r /= 2.0;
        r = r.max(1.0 / r);
    }
    (r - 1.0).abs() * 100.0
}

/// How much to favour a song (1 = normal). Recently played and often-skipped
/// songs get lower weights, so they tend to come later.
fn weight(id: &str, plays: &HashMap<String, (i64, Option<f64>)>, skips: &HashMap<String, i64>, now: f64) -> f64 {
    let (count, last) = plays.get(id).copied().unwrap_or((0, None));
    let mut w = 1.0;
    if let Some(last) = last {
        let hours = (now - last) / 3600.0;
        w *= match hours {
            h if h < 2.0 => 0.12,
            h if h < 24.0 => 0.3,
            h if h < 72.0 => 0.6,
            h if h < 168.0 => 0.85,
            _ => 1.0,
        };
    }
    let s = skips.get(id).copied().unwrap_or(0);
    if s >= 2 {
        let ratio = s as f64 / (s + count.max(0)) as f64;
        w *= (1.0 - 0.85 * ratio).max(0.1);
    }
    w
}

pub(crate) fn shuffle_with(
    items: &[ShuffleItem],
    o: &ShuffleOptions,
    plays: &HashMap<String, (i64, Option<f64>)>,
    skips: &HashMap<String, i64>,
    now: f64,
) -> Vec<u32> {
    let n = items.len();
    let mut rng = Rng::new(o.seed);
    if !o.smart || n < 3 {
        let mut idx: Vec<u32> = (0..n as u32).collect();
        for i in (1..n).rev() {
            idx.swap(i, rng.below(i + 1));
        }
        return idx;
    }

    // 1. Weighted random order (Efraimidis–Spirakis: key = ln(u) / w, largest first).
    let mut keyed: Vec<(f64, usize)> = items.iter().enumerate().map(|(i, it)| (rng.unit().ln() / weight(&it.id, plays, skips, now), i)).collect();
    keyed.sort_unstable_by(|a, b| b.0.total_cmp(&a.0));
    let mut rest: VecDeque<usize> = keyed.into_iter().map(|(_, i)| i).collect();

    // 2. Spread artists/albums and smooth tempo, looking a short way ahead.
    let artists: Vec<Option<String>> = items.iter().map(|it| artist_key(&it.artist)).collect();
    let albums: Vec<Option<String>> = items.iter().map(|it| album_key(&it.album)).collect();
    let distinct = artists.iter().flatten().collect::<HashSet<_>>().len();
    // Keep the last `gap` artists out of the next pick where possible.
    let gap = distinct.saturating_sub(1).min(3);
    let mut recent: VecDeque<String> = VecDeque::with_capacity(gap + 1);
    if let Some(a) = o.previous_artist.as_deref().and_then(artist_key) {
        if gap > 0 {
            recent.push_back(a);
        }
    }
    let mut prev_album: Option<String> = None;
    let mut prev_bpm = o.anchor_bpm.filter(|b| *b > 0.0);
    let mut out = Vec::with_capacity(n);
    while !rest.is_empty() {
        let window = rest.len().min(WINDOW);
        let mut best = (f64::MAX, 0usize);
        for pos in 0..window {
            let i = rest[pos];
            let mut score = pos as f64;
            if let Some(a) = &artists[i] {
                if let Some(age) = recent.iter().rev().position(|r| r == a) {
                    // The artist just played is the strongest no.
                    score += if age == 0 { 1000.0 } else { 40.0 / age as f64 };
                }
            }
            if albums[i].is_some() && albums[i] == prev_album {
                score += 30.0;
            }
            if let (Some(p), Some(b)) = (prev_bpm, items[i].bpm.filter(|b| *b > 0.0)) {
                score += (tempo_gap(p, b) / 4.0).min(8.0);
            }
            if score < best.0 {
                best = (score, pos);
            }
        }
        let i = rest.remove(best.1).expect("index in window");
        if gap > 0 {
            if let Some(a) = &artists[i] {
                recent.push_back(a.clone());
                if recent.len() > gap {
                    recent.pop_front();
                }
            }
        }
        prev_album = albums[i].clone();
        if let Some(b) = items[i].bpm.filter(|b| *b > 0.0) {
            prev_bpm = Some(b);
        }
        out.push(i as u32);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, artist: &str, album: &str, bpm: Option<f64>) -> ShuffleItem {
        ShuffleItem { id: id.into(), artist: artist.into(), album: album.into(), bpm }
    }

    fn opts(smart: bool, seed: u64) -> ShuffleOptions {
        ShuffleOptions { smart, seed: Some(seed), ..Default::default() }
    }

    fn is_permutation(o: &[u32], n: usize) -> bool {
        let mut s: Vec<u32> = o.to_vec();
        s.sort_unstable();
        s == (0..n as u32).collect::<Vec<_>>()
    }

    #[test]
    fn plain_and_smart_are_permutations_and_reproducible() {
        let items: Vec<_> = (0..50).map(|i| item(&i.to_string(), &format!("A{}", i % 7), "", None)).collect();
        for smart in [false, true] {
            let a = shuffle_with(&items, &opts(smart, 42), &HashMap::new(), &HashMap::new(), 0.0);
            assert!(is_permutation(&a, items.len()));
            assert_eq!(a, shuffle_with(&items, &opts(smart, 42), &HashMap::new(), &HashMap::new(), 0.0));
            assert_ne!(a, shuffle_with(&items, &opts(smart, 43), &HashMap::new(), &HashMap::new(), 0.0));
        }
        assert!(shuffle_with(&[], &opts(true, 1), &HashMap::new(), &HashMap::new(), 0.0).is_empty());
    }

    #[test]
    fn never_back_to_back_artist_when_avoidable() {
        // Four artists, five songs each, albums per artist.
        let items: Vec<_> = (0..20).map(|i| item(&i.to_string(), ["Ado", "YOASOBI", "Aimer", "LiSA"][i % 4], ["x", "y", "z", "w"][i % 4], None)).collect();
        for seed in 0..200 {
            let o = shuffle_with(&items, &opts(true, seed), &HashMap::new(), &HashMap::new(), 0.0);
            for w in o.windows(2) {
                assert_ne!(items[w[0] as usize].artist, items[w[1] as usize].artist, "seed {seed}");
            }
        }
    }

    #[test]
    fn featured_artists_count_as_the_same_artist() {
        assert_eq!(artist_key("Ado feat. Vaundy"), artist_key("ado"));
        assert_eq!(artist_key("LiSA - Topic"), artist_key("LiSA"));
        assert_eq!(artist_key("Unknown Artist"), None);
    }

    #[test]
    fn recent_and_skipped_songs_come_later() {
        let items: Vec<_> = (0..40).map(|i| item(&format!("s{i}"), &format!("A{i}"), "", None)).collect();
        let now = 1_000_000.0;
        let plays: HashMap<_, _> = [("s0".to_string(), (5, Some(now - 600.0)))].into();
        let skips: HashMap<_, _> = [("s1".to_string(), 6)].into();
        let (mut p0, mut p1, mut p2) = (0usize, 0usize, 0usize);
        let runs = 300;
        for seed in 0..runs {
            let o = shuffle_with(&items, &opts(true, seed), &plays, &skips, now);
            p0 += o.iter().position(|&i| i == 0).unwrap();
            p1 += o.iter().position(|&i| i == 1).unwrap();
            p2 += o.iter().position(|&i| i == 2).unwrap();
        }
        let avg = |p: usize| p as f64 / runs as f64;
        // An untouched song sits around the middle; the others clearly later.
        assert!((10.0..30.0).contains(&avg(p2)), "control avg {}", avg(p2));
        assert!(avg(p0) > avg(p2) + 8.0, "recent avg {} vs {}", avg(p0), avg(p2));
        assert!(avg(p1) > avg(p2) + 5.0, "skipped avg {} vs {}", avg(p1), avg(p2));
    }

    #[test]
    fn tempo_neighbours_are_closer_than_plain_shuffle() {
        let items: Vec<_> = (0..60).map(|i| item(&i.to_string(), &format!("A{i}"), "", Some(70.0 + (i * 37 % 60) as f64 * 2.0))).collect();
        let jumps = |o: &[u32]| o.windows(2).map(|w| tempo_gap(items[w[0] as usize].bpm.unwrap(), items[w[1] as usize].bpm.unwrap())).sum::<f64>();
        let (mut smart, mut plain) = (0.0, 0.0);
        for seed in 0..50 {
            smart += jumps(&shuffle_with(&items, &opts(true, seed), &HashMap::new(), &HashMap::new(), 0.0));
            plain += jumps(&shuffle_with(&items, &opts(false, seed), &HashMap::new(), &HashMap::new(), 0.0));
        }
        assert!(smart < plain * 0.6, "smart {smart} plain {plain}");
        assert!((tempo_gap(120.0, 60.0)).abs() < 1e-9);
    }

    #[test]
    fn previous_artist_is_not_repeated_first() {
        let items: Vec<_> = (0..10).map(|i| item(&i.to_string(), if i < 5 { "Ado" } else { "LiSA" }, "", None)).collect();
        for seed in 0..100 {
            let o = ShuffleOptions { smart: true, seed: Some(seed), previous_artist: Some("Ado".into()), ..Default::default() };
            let first = shuffle_with(&items, &o, &HashMap::new(), &HashMap::new(), 0.0)[0];
            assert_eq!(items[first as usize].artist, "LiSA");
        }
    }

    #[test]
    fn large_library_is_fast() {
        let items: Vec<_> = (0..20_000).map(|i| item(&i.to_string(), &format!("A{}", i % 900), &format!("B{}", i % 2000), Some(80.0 + (i % 90) as f64))).collect();
        let t = std::time::Instant::now();
        let o = shuffle_with(&items, &opts(true, 7), &HashMap::new(), &HashMap::new(), 0.0);
        assert!(is_permutation(&o, items.len()));
        // Generous bound for debug builds on a slow CI box.
        assert!(t.elapsed().as_millis() < 2000, "{:?}", t.elapsed());
    }
}
