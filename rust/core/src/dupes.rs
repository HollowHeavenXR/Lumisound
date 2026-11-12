//! Lumisound Duplicate Engine.
//!
//! Finds copies of the same track, explains why it thinks so, picks the copy
//! to keep, and plans a reversible clean-up. Everything is decided here; the
//! app supplies the library and applies the plan.
//!
//! Evidence, strongest first:
//! 1. **Exact file** — same size and same SHA-256.
//! 2. **Same source** — same source track id ("youtube:abc…") from the song,
//!    the vault tag or the Lumisound tag.
//! 3. **Same recording** — the LumiPrint acoustic print (below) of every probe
//!    lines up. Catches re-encodes, retitled and re-tagged copies.
//! 4. **Likely same** — title/artist match (noise tags stripped, feature
//!    aware, small typos tolerated), duration within 2 s, same *variant* (a
//!    "Live", "Remix", "Sped Up", "Acoustic"… is never a duplicate of the
//!    original). An acoustic mismatch vetoes it.
//!
//! LumiPrint: 11.025 kHz mono, 2048-point frames every 512 samples, 33
//! log-spaced bands over 300–3000 Hz, one bit per band pair from the sign of
//! the time/frequency energy gradient (32 bits a frame). Three 18 s probes
//! at 15 %, 50 % and 82 % of the track; a probe matches when the middle 9 s
//! of one lines up with the other at some offset within ±4.5 s with a bit
//! error rate ≤ 0.30 (unrelated audio sits near 0.5). Prints are cached on
//! disk by path, size and mtime, and the per-scan budget makes big libraries
//! converge over several scans instead of stalling one.

use crate::duplicates::{dup_feature_name, dup_normalize, dup_normalize_artist, near_match};
use crate::store;
use regex_lite::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::Path;
use std::sync::{Arc, LazyLock, Mutex};

const PRINT_RATE: u32 = 11_025;
const FRAME: usize = 2048;
const HOP: usize = 512;
const BANDS: usize = 33;
const PROBE_SECS: f64 = 18.0;
const PROBE_AT: [f64; 3] = [0.15, 0.50, 0.82];
/// Frames kept off each side of a probe's core (≈ 4.5 s): the search range.
const MARGIN: usize = 98;
const MATCH_BER: f32 = 0.30;
const TEXT_DURATION_TOL: f64 = 2.0;
/// Acoustic candidates: durations within this many seconds.
const ACOUSTIC_DURATION_TOL: f64 = 4.0;
const MAX_ACOUSTIC_CLUSTER: usize = 40;
const PRINT_FILE: &str = "lumiprint-v1.bin";
const IGNORED: &str = "dupe_ignored_pairs";
const JOURNAL: &str = "dupe_journal";

static PRINT_LOCK: Mutex<()> = Mutex::new(());

// ---- public types --------------------------------------------------------------------------

#[derive(uniffi::Record, Clone, Debug)]
pub struct DupeCandidate {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub duration: f64,
    /// Local file path (None for streams / Apple Music items).
    pub path: Option<String>,
    pub source_track_id: Option<String>,
    pub bitrate_kbps: u32,
    pub sample_rate: u32,
    pub is_favorite: bool,
    pub play_count: u32,
    pub playlist_count: u32,
    pub has_artwork: bool,
    pub has_lyrics: bool,
    /// Playing now or queued: never removed by a clean-up.
    pub protected: bool,
    /// The app can delete this copy (a downloaded/imported file).
    pub removable: bool,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum DupeKind {
    /// Ordered weakest first so `min` gives a group's weakest link.
    LikelySame,
    SameRecording,
    SameSource,
    ExactFile,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct DupeCopy {
    pub id: String,
    pub score: f32,
    /// Why this copy is good ("Lossless", "Favorite", "In 3 playlists").
    pub strengths: Vec<String>,
    /// Why it is worse or risky ("31 s shorter — may be cut", "Playing now").
    pub warnings: Vec<String>,
    pub file_size: u64,
    pub format: String,
    pub removable: bool,
    pub protected: bool,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct DupeGroup {
    /// Stable for the same set of songs.
    pub id: String,
    pub kind: DupeKind,
    /// 0…1.
    pub confidence: f32,
    /// Human-readable evidence, strongest first.
    pub evidence: Vec<String>,
    /// Best copy first.
    pub copies: Vec<DupeCopy>,
    pub keeper_id: String,
    /// Songs a clean-up of this group would remove.
    pub remove_ids: Vec<String>,
    pub reclaim_bytes: u64,
    /// Strong evidence and nothing to warn about: safe for "Clean up all".
    pub auto_safe: bool,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct DupeReport {
    pub groups: Vec<DupeGroup>,
    pub scanned: u32,
    pub fingerprinted: u32,
    /// Songs that still need a print (budget ran out); the next scan continues.
    pub pending_prints: u32,
    pub reclaim_bytes: u64,
    /// Matches skipped because the listener said "not duplicates".
    pub ignored: u32,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct DupeScanOptions {
    /// Unlock cache for `.lms` files and the LumiPrint cache.
    pub cache_dir: String,
    /// New prints to compute this scan (cached ones are free).
    pub print_budget: u32,
    pub acoustic: bool,
}

#[uniffi::export(with_foreign)]
pub trait DupeProgress: Send + Sync {
    fn on_progress(&self, phase: String, done: u32, total: u32);
}

// ---- variants --------------------------------------------------------------------------------

static VARIANTS: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    [
        ("live", r"(?i)\blive\b"),
        ("remix", r"(?i)\b(re-?mix|rmx|bootleg|flip|vip)\b"),
        ("acoustic", r"(?i)\b(acoustic|unplugged)\b"),
        ("instrumental", r"(?i)\b(instrumental|karaoke|off ?vocal|backing track)\b"),
        ("acapella", r"(?i)\ba ?cap+el+a\b"),
        ("sped", r"(?i)\b(sped ?up|speed ?up|nightcore)\b"),
        ("slowed", r"(?i)\b(slowed|reverb(ed)?|chopped)\b"),
        ("8d", r"(?i)\b8d\b"),
        ("cover", r"(?i)\bcover\b"),
        ("extended", r"(?i)\b(extended|club mix|long version)\b"),
        ("edit", r"(?i)\b(radio edit|short version|single edit)\b"),
        ("demo", r"(?i)\bdemo\b"),
        ("remaster", r"(?i)\bremaster(ed)?\b"),
        ("bassboost", r"(?i)\bbass ?boost(ed)?\b"),
        ("orchestral", r"(?i)\b(orchestral|symphonic|piano version)\b"),
    ]
    .into_iter()
    .map(|(k, p)| (k, Regex::new(p).unwrap()))
    .collect()
});

/// Variant tags in a title ("live", "remix"…), sorted.
#[uniffi::export]
pub fn dupe_variant_tags(title: String) -> Vec<String> {
    let mut v: Vec<String> = VARIANTS.iter().filter(|(_, r)| r.is_match(&title)).map(|(k, _)| k.to_string()).collect();
    v.sort();
    v
}

// ---- LumiPrint ---------------------------------------------------------------------------------

/// Probes of 32-bit sub-fingerprints (None = probe couldn't be decoded).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LumiPrint {
    pub probes: Vec<Vec<u32>>,
}

fn band_edges() -> [usize; BANDS + 1] {
    let mut e = [0usize; BANDS + 1];
    let (lo, hi) = (300f64.ln(), 3000f64.ln());
    for (i, x) in e.iter_mut().enumerate() {
        let f = (lo + (hi - lo) * i as f64 / BANDS as f64).exp();
        *x = ((f * FRAME as f64 / PRINT_RATE as f64).round() as usize).clamp(1, FRAME / 2 - 1);
    }
    e
}

/// 32-bit sub-fingerprints of mono PCM at 11.025 kHz.
pub fn print_pcm(pcm: &[i16]) -> Vec<u32> {
    if pcm.len() < FRAME * 2 {
        return Vec::new();
    }
    let mut planner = rustfft::FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(FRAME);
    let window: Vec<f32> = (0..FRAME).map(|i| 0.5 - 0.5 * (std::f32::consts::TAU * i as f32 / FRAME as f32).cos()).collect();
    let edges = band_edges();
    let mut buf = vec![rustfft::num_complex::Complex32::new(0.0, 0.0); FRAME];
    let mut prev: Option<[f32; BANDS]> = None;
    let mut out = Vec::with_capacity(pcm.len() / HOP);
    let mut start = 0;
    while start + FRAME <= pcm.len() {
        for i in 0..FRAME {
            buf[i] = rustfft::num_complex::Complex32::new(pcm[start + i] as f32 / 32768.0 * window[i], 0.0);
        }
        fft.process(&mut buf);
        let mut e = [0f32; BANDS];
        for b in 0..BANDS {
            let (a, z) = (edges[b], edges[b + 1].max(edges[b] + 1));
            e[b] = buf[a..z].iter().map(|c| c.norm_sqr()).sum::<f32>();
        }
        if let Some(p) = prev {
            let mut bits = 0u32;
            for m in 0..32 {
                let d = (e[m] - e[m + 1]) - (p[m] - p[m + 1]);
                if d > 0.0 {
                    bits |= 1 << m;
                }
            }
            out.push(bits);
        }
        prev = Some(e);
        start += HOP;
    }
    out
}

/// Probe start times (seconds) for a track of `duration`.
fn probe_starts(duration: f64) -> Vec<f64> {
    if duration <= 0.0 {
        return vec![0.0];
    }
    if duration < 60.0 {
        return vec![(duration * 0.2).min((duration - PROBE_SECS).max(0.0))];
    }
    PROBE_AT.iter().map(|f| (duration * f - PROBE_SECS / 2.0).clamp(0.0, (duration - PROBE_SECS).max(0.0))).collect()
}

fn compute_print(path: &str, cache_dir: &str, duration: f64) -> Option<LumiPrint> {
    let dur = if duration > 0.0 { duration } else { crate::analysis::probe_duration(path.to_string(), cache_dir.to_string()) };
    let mut probes = Vec::new();
    for s in probe_starts(dur) {
        let pcm = crate::analysis::decode_mono(path.to_string(), cache_dir.to_string(), PRINT_RATE, s, PROBE_SECS).unwrap_or_default();
        probes.push(print_pcm(&pcm));
    }
    probes.iter().any(|p| !p.is_empty()).then_some(LumiPrint { probes })
}

/// Best bit error rate of `a`'s core over `b` at offsets within the margin.
fn probe_ber(a: &[u32], b: &[u32]) -> Option<f32> {
    let (short, long) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    if short.len() < 2 * MARGIN + 40 {
        // Short probe: slide the whole thing.
        if short.len() < 40 {
            return None;
        }
        let mut best = f32::MAX;
        let span = long.len().saturating_sub(short.len());
        for off in 0..=span {
            best = best.min(ber(short, &long[off..off + short.len()]));
        }
        return Some(best);
    }
    let core = &short[MARGIN..short.len() - MARGIN];
    let max_off = long.len().saturating_sub(core.len());
    let mut best = f32::MAX;
    for off in 0..=max_off.min(2 * MARGIN + (long.len() - short.len())) {
        if off + core.len() > long.len() {
            break;
        }
        best = best.min(ber(core, &long[off..off + core.len()]));
    }
    (best < f32::MAX).then_some(best)
}

fn ber(a: &[u32], b: &[u32]) -> f32 {
    let diff: u32 = a.iter().zip(b).map(|(x, y)| (x ^ y).count_ones()).sum();
    diff as f32 / (32.0 * a.len() as f32)
}

/// (matching probes, compared probes, mean BER of compared).
pub fn compare_prints(a: &LumiPrint, b: &LumiPrint) -> (usize, usize, f32) {
    let (mut hit, mut n, mut sum) = (0, 0, 0f32);
    for (pa, pb) in a.probes.iter().zip(&b.probes) {
        if let Some(e) = probe_ber(pa, pb) {
            n += 1;
            sum += e;
            if e <= MATCH_BER {
                hit += 1;
            }
        }
    }
    (hit, n, if n > 0 { sum / n as f32 } else { 0.5 })
}

/// Acoustic verdict: Some(true) same recording, Some(false) different, None unknown.
fn acoustic_verdict(a: &LumiPrint, b: &LumiPrint) -> (Option<bool>, f32) {
    let (hit, n, mean) = compare_prints(a, b);
    if n == 0 {
        return (None, 0.0);
    }
    let conf = (1.0 - mean / 0.5).clamp(0.0, 1.0);
    if hit == n {
        (Some(true), conf)
    } else if hit == 0 || (n >= 2 && hit * 2 < n) {
        (Some(false), conf)
    } else {
        (None, conf)
    }
}

// Disk cache: [u16 key len][key][u8 probes]{[u16 n][u32 × n]}…

fn load_prints(cache_dir: &str) -> HashMap<String, LumiPrint> {
    let mut m = HashMap::new();
    let Ok(mut f) = std::fs::File::open(Path::new(cache_dir).join(PRINT_FILE)) else { return m };
    let mut bytes = Vec::new();
    if f.read_to_end(&mut bytes).is_err() {
        return m;
    }
    let mut i = 0usize;
    let rd16 = |b: &[u8], i: &mut usize| -> Option<usize> {
        let v = u16::from_le_bytes(b.get(*i..*i + 2)?.try_into().ok()?) as usize;
        *i += 2;
        Some(v)
    };
    while i < bytes.len() {
        let Some(kl) = rd16(&bytes, &mut i) else { break };
        let Some(k) = bytes.get(i..i + kl).and_then(|s| std::str::from_utf8(s).ok()).map(str::to_string) else { break };
        i += kl;
        let Some(&np) = bytes.get(i) else { break };
        i += 1;
        let mut probes = Vec::with_capacity(np as usize);
        for _ in 0..np {
            let Some(n) = rd16(&bytes, &mut i) else { return m };
            let Some(raw) = bytes.get(i..i + n * 4) else { return m };
            probes.push(raw.chunks_exact(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect());
            i += n * 4;
        }
        m.insert(k, LumiPrint { probes });
    }
    m
}

fn save_prints(cache_dir: &str, m: &HashMap<String, LumiPrint>) {
    let mut out = Vec::new();
    for (k, p) in m {
        let kb = k.as_bytes();
        if kb.len() > u16::MAX as usize {
            continue;
        }
        out.extend_from_slice(&(kb.len() as u16).to_le_bytes());
        out.extend_from_slice(kb);
        out.push(p.probes.len().min(255) as u8);
        for pr in p.probes.iter().take(255) {
            let n = pr.len().min(u16::MAX as usize);
            out.extend_from_slice(&(n as u16).to_le_bytes());
            for v in &pr[..n] {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
    }
    let _ = std::fs::create_dir_all(cache_dir);
    let dst = Path::new(cache_dir).join(PRINT_FILE);
    let tmp = dst.with_extension("tmp");
    if std::fs::File::create(&tmp).and_then(|mut f| f.write_all(&out)).is_ok() {
        let _ = std::fs::rename(tmp, dst);
    }
}

// ---- union-find over evidence edges ---------------------------------------------------------

struct Edge {
    a: usize,
    b: usize,
    kind: DupeKind,
    conf: f32,
    note: String,
}

struct Uf {
    p: Vec<usize>,
}

impl Uf {
    fn find(&mut self, x: usize) -> usize {
        let mut r = x;
        while self.p[r] != r {
            r = self.p[r];
        }
        let mut c = x;
        while self.p[c] != r {
            let n = self.p[c];
            self.p[c] = r;
            c = n;
        }
        r
    }
}

fn pair_key(a: &str, b: &str) -> String {
    if a < b { format!("{a}|{b}") } else { format!("{b}|{a}") }
}

fn ignored_pairs() -> HashSet<String> {
    store::load::<Vec<String>>(IGNORED).into_iter().collect()
}

/// "These aren't duplicates": every pair among `song_ids` is never grouped again.
#[uniffi::export]
pub fn dupe_ignore(song_ids: Vec<String>) {
    let mut s = ignored_pairs();
    for i in 0..song_ids.len() {
        for j in i + 1..song_ids.len() {
            s.insert(pair_key(&song_ids[i], &song_ids[j]));
        }
    }
    let mut v: Vec<String> = s.into_iter().collect();
    v.sort();
    store::save(IGNORED, &v);
}

#[uniffi::export]
pub fn dupe_ignored_count() -> u32 {
    ignored_pairs().len() as u32
}

#[uniffi::export]
pub fn dupe_unignore_all() {
    store::save(IGNORED, &Vec::<String>::new());
}

// ---- scoring ------------------------------------------------------------------------------------

fn format_of(path: Option<&str>) -> String {
    path.and_then(|p| Path::new(p).extension()).and_then(|e| e.to_str()).map(|e| e.to_lowercase()).unwrap_or_else(|| "stream".into())
}

fn is_lossless(fmt: &str) -> bool {
    matches!(fmt, "flac" | "alac" | "wav" | "aiff" | "aif" | "caf")
}

fn fmt_secs(s: f64) -> String {
    format!("{} s", s.round() as i64)
}

/// Score one copy against the group's longest copy; returns (score, strengths, warnings).
fn score_copy(c: &DupeCandidate, fmt: &str, exists: bool, longest: f64, max_bitrate: u32) -> (f32, Vec<String>, Vec<String>) {
    let (mut s, mut good, mut bad) = (0f32, Vec::new(), Vec::new());
    if c.path.is_some() && !exists {
        s -= 100.0;
        bad.push("File is missing".into());
    }
    if is_lossless(fmt) {
        s += 32.0;
        good.push("Lossless".into());
    } else if c.bitrate_kbps > 0 {
        s += (c.bitrate_kbps.min(320) as f32 / 320.0) * 26.0;
        if c.bitrate_kbps + 16 < max_bitrate {
            bad.push(format!("Lower bitrate ({} vs {} kbps)", c.bitrate_kbps, max_bitrate));
        } else if max_bitrate > 0 && c.bitrate_kbps >= max_bitrate {
            good.push(format!("Best bitrate ({} kbps)", c.bitrate_kbps));
        }
    } else {
        s += match fmt {
            "lms" | "opus" => 19.0,
            "m4a" | "aac" | "mp4" => 17.0,
            "ogg" | "webm" => 15.0,
            "mp3" => 13.0,
            _ => 10.0,
        };
    }
    if fmt == "lms" {
        s += 6.0;
        good.push("Lumisound engine file".into());
    }
    if c.sample_rate > 0 && c.sample_rate < 32_000 {
        s -= 8.0;
        bad.push(format!("Low sample rate ({} Hz)", c.sample_rate));
    }
    let short = longest - c.duration;
    if c.duration > 0.0 && short > 3.0 {
        s -= 12.0 + (short as f32).min(60.0) * 0.3;
        bad.push(format!("{} shorter than the longest copy — may be cut", fmt_secs(short)));
    } else if c.duration > 0.0 {
        good.push("Full length".into());
    }
    if c.is_favorite {
        s += 8.0;
        good.push("Favorite".into());
    }
    if c.playlist_count > 0 {
        s += (c.playlist_count as f32 * 2.0).min(6.0);
        good.push(if c.playlist_count == 1 { "In 1 playlist".into() } else { format!("In {} playlists", c.playlist_count) });
    }
    if c.play_count > 0 {
        s += ((c.play_count as f32 + 1.0).log2()).min(6.0);
        good.push(format!("Played {}×", c.play_count));
    }
    if c.has_artwork {
        s += 3.0;
    } else {
        bad.push("No artwork".into());
    }
    if c.has_lyrics {
        s += 3.0;
        good.push("Has lyrics".into());
    }
    if c.source_track_id.as_deref().is_some_and(|x| !x.is_empty()) {
        s += 2.0;
    }
    if c.protected {
        bad.push("Playing or queued — won't be removed".into());
    }
    if !c.removable {
        bad.push("Can't be deleted from Lumisound".into());
    }
    (s, good, bad)
}

fn group_id(ids: &[String]) -> String {
    use sha2::Digest;
    let mut v = ids.to_vec();
    v.sort();
    let h = sha2::Sha256::digest(v.join("\n").as_bytes());
    hex::encode(&h[..8])
}

fn sha256_file(path: &str) -> Option<[u8; 32]> {
    use sha2::Digest;
    let mut f = std::fs::File::open(path).ok()?;
    let mut h = sha2::Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = f.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Some(h.finalize().into())
}

// ---- scan --------------------------------------------------------------------------------------

/// Scan `songs` for duplicates. Touches the disk (hashing, decoding): call
/// off the main thread. Groups come back strongest and largest first.
#[uniffi::export]
pub fn dupe_scan(songs: Vec<DupeCandidate>, options: DupeScanOptions, progress: Option<Arc<dyn DupeProgress>>) -> DupeReport {
    let report = |phase: &str, d: usize, t: usize| {
        if let Some(p) = &progress {
            p.on_progress(phase.to_string(), d as u32, t as u32);
        }
    };
    let n = songs.len();
    let meta: Vec<Option<std::fs::Metadata>> = songs.iter().map(|s| s.path.as_ref().and_then(|p| std::fs::metadata(p).ok())).collect();
    let exists: Vec<bool> = meta.iter().map(|m| m.is_some()).collect();
    let sizes: Vec<u64> = meta.iter().map(|m| m.as_ref().map(|m| m.len()).unwrap_or(0)).collect();
    let ignored = ignored_pairs();
    let mut ignored_hits = 0u32;
    let mut edges: Vec<Edge> = Vec::new();
    let push = |edges: &mut Vec<Edge>, a: usize, b: usize, kind: DupeKind, conf: f32, note: String, ignored_hits: &mut u32| {
        if ignored.contains(&pair_key(&songs[a].id, &songs[b].id)) {
            *ignored_hits += 1;
            return;
        }
        edges.push(Edge { a, b, kind, conf, note });
    };

    // 1. Exact files: same size, then same hash.
    report("Comparing files", 0, n);
    let mut by_size: HashMap<u64, Vec<usize>> = HashMap::new();
    for i in 0..n {
        if exists[i] && sizes[i] > 0 {
            by_size.entry(sizes[i]).or_default().push(i);
        }
    }
    let mut hashes: HashMap<usize, [u8; 32]> = HashMap::new();
    for v in by_size.values().filter(|v| v.len() > 1) {
        for &i in v {
            if let Some(h) = sha256_file(songs[i].path.as_deref().unwrap()) {
                hashes.insert(i, h);
            }
        }
        for x in 0..v.len() {
            for y in x + 1..v.len() {
                if let (Some(a), Some(b)) = (hashes.get(&v[x]), hashes.get(&v[y])) {
                    if a == b {
                        push(&mut edges, v[x], v[y], DupeKind::ExactFile, 1.0, "Byte-for-byte identical files".into(), &mut ignored_hits);
                    }
                }
            }
        }
    }

    // 2. Same source track.
    let mut by_src: HashMap<String, Vec<usize>> = HashMap::new();
    for (i, s) in songs.iter().enumerate() {
        let src = s.source_track_id.clone().filter(|x| !x.is_empty()).or_else(|| {
            let p = s.path.as_ref().filter(|_| exists[i])?;
            crate::lock::track_read_tag(p.clone())
                .map(|t| t.track_id)
                .or_else(|| crate::downloads::tags_read_lumisound(p.clone()).source_track_id)
                .filter(|x| !x.is_empty())
        });
        if let Some(src) = src {
            by_src.entry(src).or_default().push(i);
        }
    }
    for (src, v) in by_src.iter().filter(|(_, v)| v.len() > 1) {
        let label = src.split(':').next().unwrap_or("source");
        for x in 1..v.len() {
            push(&mut edges, v[0], v[x], DupeKind::SameSource, 0.97, format!("Same {label} track ({src})"), &mut ignored_hits);
        }
    }

    // Text keys for every song.
    let keys: Vec<(String, String, Option<String>, Vec<String>)> =
        songs.iter().map(|s| (dup_normalize(s.title.clone()), dup_normalize_artist(s.artist.clone()), dup_feature_name(s.title.clone()), dupe_variant_tags(s.title.clone()))).collect();

    // Candidate pairs for acoustic / text checks: duration-sorted sweep.
    let mut order: Vec<usize> = (0..n).filter(|&i| songs[i].duration > 0.0).collect();
    order.sort_by(|&a, &b| songs[a].duration.total_cmp(&songs[b].duration));
    let mut pairs: Vec<(usize, usize)> = Vec::new();
    for x in 0..order.len() {
        let mut taken = 0;
        for y in x + 1..order.len() {
            let (a, b) = (order[x], order[y]);
            if songs[b].duration - songs[a].duration > ACOUSTIC_DURATION_TOL {
                break;
            }
            taken += 1;
            if taken > MAX_ACOUSTIC_CLUSTER {
                break;
            }
            pairs.push((a, b));
        }
    }
    let text_match = |a: usize, b: usize| -> bool {
        let (ka, kb) = (&keys[a], &keys[b]);
        if ka.0.is_empty() || ka.1.is_empty() || ka.1 != kb.1 || ka.3 != kb.3 {
            return false;
        }
        let feat_ok = match (&ka.2, &kb.2) {
            (Some(x), Some(y)) => x == y || near_match(x, y),
            (None, None) => true,
            _ => false,
        };
        feat_ok && (ka.0 == kb.0 || near_match(&ka.0, &kb.0))
    };

    // 3. Acoustic prints for songs in a candidate pair.
    let mut prints: HashMap<usize, LumiPrint> = HashMap::new();
    let (mut fingerprinted, mut pending) = (0u32, 0u32);
    if options.acoustic {
        let _g = PRINT_LOCK.lock().unwrap();
        let mut cache = load_prints(&options.cache_dir);
        let mut dirty = false;
        let mut need: Vec<usize> = pairs.iter().flat_map(|&(a, b)| [a, b]).filter(|&i| exists[i]).collect();
        need.sort_unstable();
        need.dedup();
        // Text-matched pairs first: they decide the "likely" verdicts.
        need.sort_by_key(|&i| !pairs.iter().any(|&(a, b)| (a == i || b == i) && text_match(a, b)));
        let mut budget = options.print_budget;
        let total = need.len();
        for (done, &i) in need.iter().enumerate() {
            report("Listening", done, total);
            let path = songs[i].path.clone().unwrap();
            let key = crate::analysis::cache_key(&path);
            if let Some(p) = cache.get(&key) {
                prints.insert(i, p.clone());
                continue;
            }
            if budget == 0 {
                pending += 1;
                continue;
            }
            budget -= 1;
            if let Some(p) = compute_print(&path, &options.cache_dir, songs[i].duration) {
                cache.insert(key, p.clone());
                prints.insert(i, p);
                fingerprinted += 1;
                dirty = true;
            } else {
                // Undecodable: remember so it isn't retried every scan.
                cache.insert(key, LumiPrint::default());
                dirty = true;
            }
        }
        if dirty {
            let live: HashSet<String> = songs.iter().filter_map(|s| s.path.as_ref()).map(|p| crate::analysis::cache_key(p)).collect();
            cache.retain(|k, _| live.contains(k));
            save_prints(&options.cache_dir, &cache);
        }
    }

    report("Matching", 0, pairs.len());
    for &(a, b) in &pairs {
        let verdict = match (prints.get(&a), prints.get(&b)) {
            (Some(x), Some(y)) if !x.probes.is_empty() && !y.probes.is_empty() => acoustic_verdict(x, y),
            _ => (None, 0.0),
        };
        match verdict {
            (Some(true), conf) => {
                let c = 0.8 + 0.2 * conf;
                push(&mut edges, a, b, DupeKind::SameRecording, c, "Sounds identical all the way through".into(), &mut ignored_hits);
            }
            (Some(false), _) => {} // Acoustic veto: different recordings.
            (None, _) => {
                if text_match(a, b) && (songs[a].duration - songs[b].duration).abs() <= TEXT_DURATION_TOL {
                    let exact = keys[a].0 == keys[b].0;
                    push(&mut edges, a, b, DupeKind::LikelySame, if exact { 0.75 } else { 0.62 }, if exact { "Same title, artist and length".into() } else { "Near-identical title, same artist and length".into() }, &mut ignored_hits);
                }
            }
        }
    }

    // Union strongest evidence first; a group's kind is its weakest link.
    edges.sort_by(|x, y| y.kind.cmp(&x.kind).then(y.conf.total_cmp(&x.conf)));
    let mut uf = Uf { p: (0..n).collect() };
    let mut links: HashMap<usize, Vec<(DupeKind, f32, String)>> = HashMap::new();
    let mut merged: Vec<(usize, usize, DupeKind, f32, String)> = Vec::new();
    for e in &edges {
        let (ra, rb) = (uf.find(e.a), uf.find(e.b));
        if ra != rb {
            uf.p[ra] = rb;
            merged.push((e.a, e.b, e.kind, e.conf, e.note.clone()));
        }
    }
    for (a, _, kind, conf, note) in merged {
        let r = uf.find(a);
        links.entry(r).or_default().push((kind, conf, note));
    }
    let mut members: HashMap<usize, Vec<usize>> = HashMap::new();
    for i in 0..n {
        let r = uf.find(i);
        if links.contains_key(&r) {
            members.entry(r).or_default().push(i);
        }
    }

    let mut groups = Vec::new();
    for (root, idx) in members {
        let l = &links[&root];
        let kind = l.iter().map(|x| x.0).min().unwrap();
        let conf = l.iter().map(|x| x.1).fold(1f32, f32::min);
        let mut evidence: Vec<String> = Vec::new();
        for (_, _, note) in l {
            if !evidence.contains(note) {
                evidence.push(note.clone());
            }
        }
        let longest = idx.iter().map(|&i| songs[i].duration).fold(0f64, f64::max);
        let max_bitrate = idx.iter().map(|&i| songs[i].bitrate_kbps).max().unwrap_or(0);
        let mut copies: Vec<(usize, DupeCopy)> = idx
            .iter()
            .map(|&i| {
                let fmt = format_of(songs[i].path.as_deref());
                let (score, strengths, warnings) = score_copy(&songs[i], &fmt, exists[i], longest, max_bitrate);
                (i, DupeCopy { id: songs[i].id.clone(), score, strengths, warnings, file_size: sizes[i], format: fmt, removable: songs[i].removable && exists[i], protected: songs[i].protected })
            })
            .collect();
        copies.sort_by(|a, b| b.1.score.total_cmp(&a.1.score));
        // Keeper: best copy that still exists; a protected (playing) copy wins ties.
        let keeper = copies
            .iter()
            .filter(|(i, _)| exists[*i] || songs[*i].path.is_none())
            .max_by(|a, b| (a.1.score + if a.1.protected { 0.5 } else { 0.0 }).total_cmp(&(b.1.score + if b.1.protected { 0.5 } else { 0.0 })))
            .map(|(_, c)| c.id.clone())
            .unwrap_or_else(|| copies[0].1.id.clone());
        let remove: Vec<&DupeCopy> = copies.iter().map(|(_, c)| c).filter(|c| c.id != keeper && c.removable && !c.protected).collect();
        let reclaim: u64 = remove.iter().map(|c| c.file_size).sum();
        let loser_risky = copies.iter().any(|(_, c)| c.id != keeper && c.warnings.iter().any(|w| w.starts_with("File is missing") || w.contains("Playing")));
        let auto_safe = kind >= DupeKind::SameRecording && conf >= 0.85 && !remove.is_empty() && !loser_risky;
        let ids: Vec<String> = copies.iter().map(|(_, c)| c.id.clone()).collect();
        groups.push(DupeGroup {
            id: group_id(&ids),
            kind,
            confidence: conf,
            evidence,
            remove_ids: remove.iter().map(|c| c.id.clone()).collect(),
            copies: copies.into_iter().map(|(_, c)| c).collect(),
            keeper_id: keeper,
            reclaim_bytes: reclaim,
            auto_safe,
        });
    }
    groups.sort_by(|a, b| b.kind.cmp(&a.kind).then(b.copies.len().cmp(&a.copies.len())).then(b.reclaim_bytes.cmp(&a.reclaim_bytes)));
    let reclaim_bytes = groups.iter().map(|g| g.reclaim_bytes).sum();
    report("Done", n, n);
    DupeReport { groups, scanned: n as u32, fingerprinted, pending_prints: pending, reclaim_bytes, ignored: ignored_hits }
}

/// Re-plan a group with the listener's own keeper choice.
#[uniffi::export]
pub fn dupe_choose_keeper(group: DupeGroup, keeper_id: String) -> DupeGroup {
    let mut g = group;
    if !g.copies.iter().any(|c| c.id == keeper_id) {
        return g;
    }
    g.keeper_id = keeper_id.clone();
    let remove: Vec<&DupeCopy> = g.copies.iter().filter(|c| c.id != keeper_id && c.removable && !c.protected).collect();
    g.reclaim_bytes = remove.iter().map(|c| c.file_size).sum();
    g.remove_ids = remove.iter().map(|c| c.id.clone()).collect();
    g
}

// ---- merge planning ---------------------------------------------------------------------------

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug)]
pub struct DupePlaylist {
    pub id: String,
    pub song_ids: Vec<String>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug)]
pub struct DupeSlot {
    pub playlist_id: String,
    pub index: u32,
    /// The keeper took this place (it wasn't in the playlist yet).
    pub keeper_took_slot: bool,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug)]
pub struct DupeRemoved {
    pub song_id: String,
    pub was_favorite: bool,
    pub play_count: u32,
    /// Where it sat in playlists before the merge (for undo).
    pub slots: Vec<DupeSlot>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct DupeMergePlan {
    pub keeper_id: String,
    /// Keeper becomes a favorite (any copy was).
    pub keeper_favorite: bool,
    /// Play counts added to the keeper.
    pub extra_plays: u32,
    /// Playlists whose song lists change: copies replaced by the keeper (or
    /// dropped where the keeper is already in that playlist).
    pub playlists: Vec<DupePlaylist>,
    pub removed: Vec<DupeRemoved>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct DupeCopyStats {
    pub song_id: String,
    pub is_favorite: bool,
    pub play_count: u32,
}

/// How to fold the removed copies into the keeper: favorites, plays and
/// playlist places carry over, so nothing the listener built is lost.
#[uniffi::export]
pub fn dupe_merge_plan(keeper: DupeCopyStats, losers: Vec<DupeCopyStats>, playlists: Vec<DupePlaylist>) -> DupeMergePlan {
    let gone: HashSet<&str> = losers.iter().map(|l| l.song_id.as_str()).collect();
    let mut removed: Vec<DupeRemoved> = losers.iter().map(|l| DupeRemoved { song_id: l.song_id.clone(), was_favorite: l.is_favorite, play_count: l.play_count, slots: Vec::new() }).collect();
    let mut changed = Vec::new();
    for p in &playlists {
        if !p.song_ids.iter().any(|s| gone.contains(s.as_str())) {
            continue;
        }
        let mut has_keeper = p.song_ids.iter().any(|s| *s == keeper.song_id);
        let mut out = Vec::with_capacity(p.song_ids.len());
        for (i, s) in p.song_ids.iter().enumerate() {
            if gone.contains(s.as_str()) {
                let took = !has_keeper;
                if let Some(r) = removed.iter_mut().find(|r| r.song_id == *s) {
                    r.slots.push(DupeSlot { playlist_id: p.id.clone(), index: i as u32, keeper_took_slot: took });
                }
                if took {
                    out.push(keeper.song_id.clone());
                    has_keeper = true;
                }
            } else {
                out.push(s.clone());
            }
        }
        changed.push(DupePlaylist { id: p.id.clone(), song_ids: out });
    }
    DupeMergePlan {
        keeper_id: keeper.song_id.clone(),
        keeper_favorite: keeper.is_favorite || losers.iter().any(|l| l.is_favorite),
        extra_plays: losers.iter().map(|l| l.play_count).sum(),
        playlists: changed,
        removed,
    }
}

// ---- journal (undo) -----------------------------------------------------------------------------

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug)]
pub struct DupeResolution {
    pub id: String,
    pub at: f64,
    pub keeper_id: String,
    pub keeper_title: String,
    pub keeper_was_favorite: bool,
    pub extra_plays: u32,
    pub removed: Vec<DupeRemoved>,
    pub bytes: u64,
}

/// Remember a clean-up so it can be undone (kept 30 days, like the trash).
#[uniffi::export]
pub fn dupe_journal_record(keeper_id: String, keeper_title: String, keeper_was_favorite: bool, extra_plays: u32, removed: Vec<DupeRemoved>, bytes: u64) -> DupeResolution {
    let r = DupeResolution { id: uuid::Uuid::new_v4().to_string(), at: store::now(), keeper_id, keeper_title, keeper_was_favorite, extra_plays, removed, bytes };
    let mut v: Vec<DupeResolution> = store::load(JOURNAL);
    let cutoff = store::now() - 30.0 * 86_400.0;
    v.retain(|e| e.at >= cutoff);
    v.push(r.clone());
    store::save(JOURNAL, &v);
    r
}

/// Newest first.
#[uniffi::export]
pub fn dupe_journal() -> Vec<DupeResolution> {
    let mut v: Vec<DupeResolution> = store::load(JOURNAL);
    let cutoff = store::now() - 30.0 * 86_400.0;
    v.retain(|e| e.at >= cutoff);
    v.reverse();
    v
}

#[uniffi::export]
pub fn dupe_journal_remove(id: String) {
    let mut v: Vec<DupeResolution> = store::load(JOURNAL);
    v.retain(|e| e.id != id);
    store::save(JOURNAL, &v);
}

/// Undo a resolution's playlist changes: put each restored copy back in its
/// old places (`playlists` = current lists; `restored` = ids that came back
/// from the trash). Returns the playlists that change.
#[uniffi::export]
pub fn dupe_undo_playlists(resolution: DupeResolution, restored: Vec<String>, playlists: Vec<DupePlaylist>) -> Vec<DupePlaylist> {
    let back: HashSet<&str> = restored.iter().map(String::as_str).collect();
    let mut out = Vec::new();
    for p in playlists {
        let mine: Vec<(u32, &str, bool)> = resolution
            .removed
            .iter()
            .filter(|r| back.contains(r.song_id.as_str()))
            .flat_map(|r| r.slots.iter().filter(|s| s.playlist_id == p.id).map(move |s| (s.index, r.song_id.as_str(), s.keeper_took_slot)))
            .collect();
        if mine.is_empty() {
            continue;
        }
        let mut slots = mine;
        slots.sort();
        let mut ids = p.song_ids.clone();
        // Where the keeper took a removed copy's place, take it back out of
        // that place (only if it is still exactly there).
        if let Some(&(idx, _, true)) = slots.iter().find(|s| s.2) {
            if let Some(pos) = ids.iter().position(|s| *s == resolution.keeper_id) {
                if pos == idx as usize || ids.iter().filter(|s| **s == resolution.keeper_id).count() == 1 {
                    ids.remove(pos);
                }
            }
        }
        for (idx, id, _) in slots {
            if ids.iter().any(|s| s == id) {
                continue;
            }
            let at = (idx as usize).min(ids.len());
            ids.insert(at, id.to_string());
        }
        out.push(DupePlaylist { id: p.id, song_ids: ids });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand(id: &str, title: &str, dur: f64) -> DupeCandidate {
        DupeCandidate {
            id: id.into(),
            title: title.into(),
            artist: "Band".into(),
            duration: dur,
            path: None,
            source_track_id: None,
            bitrate_kbps: 0,
            sample_rate: 0,
            is_favorite: false,
            play_count: 0,
            playlist_count: 0,
            has_artwork: true,
            has_lyrics: false,
            protected: false,
            removable: true,
        }
    }

    fn opts() -> DupeScanOptions {
        DupeScanOptions { cache_dir: std::env::temp_dir().join("dupes-test").to_string_lossy().into(), print_budget: 0, acoustic: false }
    }

    #[test]
    fn variants_are_not_duplicates() {
        let r = dupe_scan(vec![cand("1", "Song", 200.0), cand("2", "Song (Live)", 200.5), cand("3", "Song (Official Video)", 201.0), cand("4", "Song (Sped Up)", 200.0)], opts(), None);
        assert_eq!(r.groups.len(), 1);
        let mut ids: Vec<String> = r.groups[0].copies.iter().map(|c| c.id.clone()).collect();
        ids.sort();
        assert_eq!(ids, vec!["1", "3"]);
        assert_eq!(r.groups[0].kind, DupeKind::LikelySame);
        assert!(!r.groups[0].auto_safe);
    }

    #[test]
    fn same_source_groups_and_keeper_prefers_quality() {
        let mut a = cand("a", "Track", 180.0);
        a.source_track_id = Some("youtube:x".into());
        a.bitrate_kbps = 128;
        let mut b = cand("b", "Track (different title)", 150.0);
        b.source_track_id = Some("youtube:x".into());
        b.bitrate_kbps = 256;
        let r = dupe_scan(vec![a, b], opts(), None);
        assert_eq!(r.groups.len(), 1);
        let g = &r.groups[0];
        assert_eq!(g.kind, DupeKind::SameSource);
        // b has the better bitrate but is 30 s short: a (full length) wins.
        assert_eq!(g.keeper_id, "a");
        assert!(g.copies.iter().find(|c| c.id == "b").unwrap().warnings.iter().any(|w| w.contains("shorter")));
    }

    #[test]
    fn ignore_list_suppresses_group() {
        dupe_ignore(vec!["i1".into(), "i2".into()]);
        let r = dupe_scan(vec![cand("i1", "Ignored Song", 100.0), cand("i2", "Ignored Song", 100.0)], opts(), None);
        assert!(r.groups.is_empty());
        assert_eq!(r.ignored, 1);
    }

    #[test]
    fn protected_copy_is_never_removed() {
        let mut a = cand("p1", "Same", 100.0);
        a.protected = true;
        a.has_artwork = false;
        let b = cand("p2", "Same", 100.0);
        let r = dupe_scan(vec![a, b], opts(), None);
        let g = &r.groups[0];
        assert!(!g.remove_ids.contains(&"p1".to_string()));
    }

    #[test]
    fn merge_plan_carries_playlists_and_undo_restores() {
        let pls = vec![
            DupePlaylist { id: "P".into(), song_ids: vec!["x".into(), "loser".into(), "y".into()] },
            DupePlaylist { id: "Q".into(), song_ids: vec!["keeper".into(), "loser".into()] },
            DupePlaylist { id: "R".into(), song_ids: vec!["z".into()] },
        ];
        let plan = dupe_merge_plan(
            DupeCopyStats { song_id: "keeper".into(), is_favorite: false, play_count: 3 },
            vec![DupeCopyStats { song_id: "loser".into(), is_favorite: true, play_count: 5 }],
            pls.clone(),
        );
        assert!(plan.keeper_favorite);
        assert_eq!(plan.extra_plays, 5);
        let p = plan.playlists.iter().find(|p| p.id == "P").unwrap();
        assert_eq!(p.song_ids, vec!["x", "keeper", "y"]);
        let q = plan.playlists.iter().find(|p| p.id == "Q").unwrap();
        assert_eq!(q.song_ids, vec!["keeper"]);
        assert_eq!(plan.playlists.len(), 2);

        let res = DupeResolution { id: "r".into(), at: 0.0, keeper_id: "keeper".into(), keeper_title: "t".into(), keeper_was_favorite: false, extra_plays: 5, removed: plan.removed.clone(), bytes: 0 };
        let after = vec![DupePlaylist { id: "P".into(), song_ids: vec!["x".into(), "keeper".into(), "y".into()] }];
        let undone = dupe_undo_playlists(res, vec!["loser".into()], after);
        assert_eq!(undone[0].song_ids, vec!["x", "loser", "y"]);
    }

    #[test]
    fn lumiprint_matches_reencode_and_rejects_other_audio() {
        // Synthetic broadband "music": 48 partials (150 Hz – 4 kHz), each
        // swelling at its own rate, so every print band carries signal.
        let make = |seed: u32, len: usize, noise: f32| -> Vec<i16> {
            let mut x = seed.wrapping_mul(2654435761).max(1);
            let mut rnd = move || {
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                x as f32 / u32::MAX as f32
            };
            let parts: Vec<(f32, f32, f32)> = (0..48).map(|i| (150.0 * (4000f32 / 150.0).powf(i as f32 / 47.0) * (0.97 + rnd() * 0.06), 0.2 + rnd() * 1.8, rnd() * 6.28)).collect();
            let mut nz = 0x9e3779b9u32;
            (0..len)
                .map(|i| {
                    let t = i as f32 / PRINT_RATE as f32;
                    let mut s = 0f32;
                    for (f, rate, ph) in &parts {
                        let env = (0.5 + 0.5 * (std::f32::consts::TAU * rate * t + ph).sin()).powi(2);
                        s += (std::f32::consts::TAU * f * t).sin() * env;
                    }
                    nz ^= nz << 13;
                    nz ^= nz >> 17;
                    nz ^= nz << 5;
                    let n = (nz as f32 / u32::MAX as f32 - 0.5) * noise;
                    ((s / 12.0 + n) * 20000.0) as i16
                })
                .collect()
        };
        let len = (PROBE_SECS * PRINT_RATE as f64) as usize;
        let a = make(1, len, 0.0);
        // Same audio, shifted by 1.3 s and noisier (a lossy re-encode).
        let shift = (1.3 * PRINT_RATE as f64) as usize;
        let mut b = vec![0i16; shift];
        b.extend(make(1, len - shift, 0.12).iter());
        let c = make(2, len, 0.0);
        let (pa, pb, pc) = (print_pcm(&a), print_pcm(&b), print_pcm(&c));
        let same = probe_ber(&pa, &pb).unwrap();
        let diff = probe_ber(&pa, &pc).unwrap();
        assert!(same <= MATCH_BER, "same {same}");
        assert!(diff > MATCH_BER, "diff {diff}");
    }

    #[test]
    fn print_cache_round_trips() {
        let dir = std::env::temp_dir().join(format!("lumiprint-{}", uuid::Uuid::new_v4()));
        let dir = dir.to_string_lossy().to_string();
        let mut m = HashMap::new();
        m.insert("k|1|2".to_string(), LumiPrint { probes: vec![vec![1, 2, 3], vec![], vec![u32::MAX]] });
        save_prints(&dir, &m);
        assert_eq!(load_prints(&dir), m);
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// Real-track check (copies of `.lms` files in LUMI_DUPE_DIR):
/// `cargo test -p lumisound-core --lib dupes::real -- --ignored --nocapture`.
#[cfg(test)]
mod real {
    use super::*;

    #[test]
    #[ignore]
    fn real_tracks_reencode_matches_other_track_does_not() {
        let Ok(dir) = std::env::var("LUMI_DUPE_DIR") else { return };
        let mut files: Vec<String> = std::fs::read_dir(&dir).unwrap().filter_map(|e| e.ok()).map(|e| e.path().to_string_lossy().to_string()).filter(|p| p.ends_with(".lms")).collect();
        files.sort();
        assert!(files.len() >= 2);
        let cache = std::env::temp_dir().join("lumiprint-real").to_string_lossy().to_string();
        let (a, other) = (&files[0], &files[1]);
        let dur = crate::analysis::probe_duration(a.clone(), cache.clone());
        // Re-encode: decode A whole at 44.1 kHz, pad 1.3 s of silence, MP3 96 kbps.
        let pcm = crate::analysis::decode_mono(a.clone(), cache.clone(), 44_100, 0.0, dur + 1.0).unwrap();
        let wav = std::env::temp_dir().join("lumi-reenc.wav");
        let mut w = Vec::new();
        let pad = (1.3 * 44_100.0) as usize;
        let n = (pcm.len() + pad) as u32;
        w.extend_from_slice(b"RIFF");
        w.extend_from_slice(&(36 + n * 2).to_le_bytes());
        w.extend_from_slice(b"WAVEfmt ");
        w.extend_from_slice(&16u32.to_le_bytes());
        w.extend_from_slice(&1u16.to_le_bytes());
        w.extend_from_slice(&1u16.to_le_bytes());
        w.extend_from_slice(&44_100u32.to_le_bytes());
        w.extend_from_slice(&(88_200u32).to_le_bytes());
        w.extend_from_slice(&2u16.to_le_bytes());
        w.extend_from_slice(&16u16.to_le_bytes());
        w.extend_from_slice(b"data");
        w.extend_from_slice(&(n * 2).to_le_bytes());
        for _ in 0..pad {
            w.extend_from_slice(&0i16.to_le_bytes());
        }
        for s in &pcm {
            w.extend_from_slice(&s.to_le_bytes());
        }
        std::fs::write(&wav, w).unwrap();
        let mp3 = std::env::temp_dir().join("lumi-reenc.mp3");
        let ok = std::process::Command::new("ffmpeg").args(["-y", "-loglevel", "error", "-i"]).arg(&wav).args(["-b:a", "96k"]).arg(&mp3).status().unwrap();
        assert!(ok.success());
        let mp3 = mp3.to_string_lossy().to_string();
        let t = std::time::Instant::now();
        let pa = compute_print(a, &cache, 0.0).unwrap();
        println!("print in {:?} ({} probes)", t.elapsed(), pa.probes.len());
        let pb = compute_print(&mp3, &cache, 0.0).unwrap();
        let po = compute_print(other, &cache, 0.0).unwrap();
        let same = compare_prints(&pa, &pb);
        let diff = compare_prints(&pa, &po);
        println!("re-encode: {same:?}  other track: {diff:?}");
        assert_eq!(same.0, same.1, "re-encode must match on every probe");
        assert_eq!(diff.0, 0, "other track must not match");
    }
}
