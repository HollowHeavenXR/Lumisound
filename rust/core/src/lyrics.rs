//! Force time-sync for plain lyrics: turns untimed lines into LRC by
//! listening to the track.
//!
//! 1. Vocal activity: decode mono at 11 kHz; per 50 ms frame, the share of
//!    energy in the voice band (250 Hz - 3.4 kHz) and overall loudness. Frames
//!    that are loud enough and voice-dominant (smoothed over ~0.5 s) are
//!    "singing"; the rest (intro, solos, breaks) get no lines.
//! 2. Placement: each line's length in syllables decides how much of the
//!    singing time it takes; lines are laid end to end across the singing
//!    regions in order.
//! 3. Snap: each line start moves to the strongest vocal onset within
//!    ±0.8 s, so lines land on the actual entry rather than an average.
//!
//! Lyrics that already carry timestamps are only normalized (sorted,
//! re-formatted), never re-timed.

use crate::error::{CoreError, CoreResult};

const RATE: u32 = 11_025;
const FRAME: usize = 551; // 50 ms

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SyncedLine {
    pub time: f64,
    pub text: String,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct LyricsSync {
    pub lrc: String,
    pub lines: Vec<SyncedLine>,
    /// The input already had timestamps (kept as they were).
    pub was_synced: bool,
    /// Seconds of detected singing (0 = none found: lines spread evenly).
    pub singing_seconds: f64,
}

/// Rough syllable count (vowel groups), at least 1 for any non-empty line.
pub fn syllables(line: &str) -> usize {
    let is_v = |c: char| matches!(c, 'a' | 'e' | 'i' | 'o' | 'u' | 'y' | 'à'..='ÿ') || (!c.is_ascii() && c.is_alphabetic());
    let mut total = 0;
    for word in line.split(|c: char| !c.is_alphanumeric() && c != '\'') {
        let w: Vec<char> = word.chars().flat_map(|c| c.to_lowercase()).collect();
        if w.is_empty() {
            continue;
        }
        let mut n = 0;
        let mut prev = false;
        for &c in &w {
            let v = is_v(c);
            if v && !prev {
                n += 1;
            }
            prev = v;
        }
        // Silent final "e" ("there", "time"), but not "-le" ("little").
        let l = w.len();
        if n > 1 && w[l - 1] == 'e' && l >= 2 && !is_v(w[l - 2]) && !(w[l - 2] == 'l' && l >= 3 && !is_v(w[l - 3])) {
            n -= 1;
        }
        total += n.max(1);
    }
    total
}

/// `[mm:ss.xx]` timestamps at line start (LRC). Returns (time, text) pairs.
fn parse_lrc(text: &str) -> Vec<SyncedLine> {
    let mut out = Vec::new();
    for raw in text.lines() {
        let mut rest = raw.trim();
        let mut times = Vec::new();
        while let Some(r) = rest.strip_prefix('[') {
            let Some(end) = r.find(']') else { break };
            let stamp = &r[..end];
            let parsed = stamp.split_once(':').and_then(|(m, s)| Some(m.trim().parse::<f64>().ok()? * 60.0 + s.trim().parse::<f64>().ok()?));
            match parsed {
                Some(t) => times.push(t),
                None => {
                    // Metadata tag like [ar:Artist]: skip the whole line.
                    times.clear();
                    rest = "";
                    break;
                }
            }
            rest = r[end + 1..].trim();
        }
        for t in times {
            out.push(SyncedLine { time: t, text: rest.to_string() });
        }
    }
    out.sort_by(|a, b| a.time.total_cmp(&b.time));
    out
}

pub fn format_lrc(lines: &[SyncedLine]) -> String {
    lines
        .iter()
        .map(|l| {
            let cs = (l.time.max(0.0) * 100.0).round() as u64;
            format!("[{:02}:{:02}.{:02}]{}", cs / 6000, (cs / 100) % 60, cs % 100, l.text)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Per-frame (voice-band share, rms) from mono PCM at `RATE`.
fn frame_features(pcm: &[f32]) -> Vec<(f32, f32)> {
    use rustfft::{FftPlanner, num_complex::Complex32};
    let n = 1024;
    let fft = FftPlanner::new().plan_fft_forward(n);
    let lo = (250.0 * n as f32 / RATE as f32) as usize;
    let hi = (3400.0 * n as f32 / RATE as f32) as usize;
    let mut buf = vec![Complex32::new(0.0, 0.0); n];
    pcm.chunks(FRAME)
        .map(|f| {
            for (i, b) in buf.iter_mut().enumerate() {
                let x = f.get(i).copied().unwrap_or(0.0);
                let w = 0.5 - 0.5 * (std::f32::consts::TAU * i as f32 / n as f32).cos();
                *b = Complex32::new(x * w, 0.0);
            }
            fft.process(&mut buf);
            let (mut band, mut total) = (0.0f32, 1e-9f32);
            for (k, c) in buf.iter().take(n / 2).enumerate() {
                let e = c.norm_sqr();
                total += e;
                if (lo..=hi).contains(&k) {
                    band += e;
                }
            }
            let rms = (f.iter().map(|x| x * x).sum::<f32>() / f.len().max(1) as f32).sqrt();
            (band / total, rms)
        })
        .collect()
}

/// Singing mask per frame + onset strength per frame.
fn vocal_activity(feat: &[(f32, f32)]) -> (Vec<bool>, Vec<f32>) {
    if feat.is_empty() {
        return (vec![], vec![]);
    }
    let mut rms: Vec<f32> = feat.iter().map(|f| f.1).collect();
    rms.sort_by(|a, b| a.total_cmp(b));
    // Loud enough: above the quieter third AND within 12 dB of the loud parts
    // (so a quiet bed or room noise never counts as singing).
    let loud = rms[rms.len() * 35 / 100].max(rms[rms.len() * 90 / 100] * 0.25).max(1e-4);
    let raw: Vec<f32> = feat.iter().map(|&(share, r)| if r >= loud { share } else { 0.0 }).collect();
    // ~0.5 s moving average of the voice share.
    let w = 10;
    let smooth: Vec<f32> = (0..raw.len()).map(|i| {
        let a = i.saturating_sub(w / 2);
        let b = (i + w / 2).min(raw.len() - 1);
        raw[a..=b].iter().sum::<f32>() / (b - a + 1) as f32
    }).collect();
    let mut s2 = smooth.clone();
    s2.sort_by(|a, b| a.total_cmp(b));
    let thr = (s2[s2.len() / 2] * 0.9).max(0.25);
    let mask: Vec<bool> = smooth.iter().map(|v| *v >= thr).collect();
    let onset: Vec<f32> = (0..feat.len()).map(|i| if i == 0 { 0.0 } else { ((feat[i].1 * feat[i].0) - (feat[i - 1].1 * feat[i - 1].0)).max(0.0) }).collect();
    (mask, onset)
}

/// Place `lines` (plain text, in order) over a track's singing.
pub fn place_lines(lines: &[String], mask: &[bool], onset: &[f32], duration: f64) -> (Vec<SyncedLine>, f64) {
    let frame_secs = FRAME as f64 / RATE as f64;
    let singing: Vec<usize> = mask.iter().enumerate().filter(|(_, m)| **m).map(|(i, _)| i).collect();
    let weights: Vec<usize> = lines.iter().map(|l| syllables(l)).collect();
    let total: usize = weights.iter().sum::<usize>().max(1);
    let singing_secs = singing.len() as f64 * frame_secs;
    let mut out = Vec::with_capacity(lines.len());
    let mut acc = 0usize;
    for (line, w) in lines.iter().zip(&weights) {
        let frac = acc as f64 / total as f64;
        let t = if singing.len() >= 20 {
            let idx = singing[((frac * singing.len() as f64) as usize).min(singing.len() - 1)];
            // Snap to the strongest onset within ±0.8 s.
            let r = (0.8 / frame_secs) as usize;
            let (a, b) = (idx.saturating_sub(r), (idx + r).min(onset.len().saturating_sub(1)));
            let best = (a..=b).max_by(|&x, &y| onset[x].total_cmp(&onset[y])).unwrap_or(idx);
            best as f64 * frame_secs
        } else {
            // No usable vocal track: spread evenly over the song.
            frac * duration
        };
        out.push(SyncedLine { time: t, text: line.clone() });
        acc += w;
    }
    // Keep order strictly increasing (snapping can collide).
    for i in 1..out.len() {
        if out[i].time <= out[i - 1].time {
            out[i].time = out[i - 1].time + 0.25;
        }
    }
    (out, singing_secs)
}

/// Force time-sync `lyrics` against the track at `path` (locked `.lms`
/// files are decoded in place). Already-timed lyrics are only normalized.
#[uniffi::export]
pub fn lyrics_force_sync(path: String, lyrics: String) -> CoreResult<LyricsSync> {
    let timed = parse_lrc(&lyrics);
    let plain: Vec<String> = lyrics.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('[')).map(str::to_string).collect();
    if timed.len() >= 2 && timed.len() * 2 >= plain.len() {
        return Ok(LyricsSync { lrc: format_lrc(&timed), lines: timed, was_synced: true, singing_seconds: 0.0 });
    }
    if plain.is_empty() {
        return Err(CoreError::invalid("no lyric lines"));
    }
    let p = std::path::Path::new(&path);
    let info = lumisound_media::decode::probe(p).ok_or_else(|| CoreError::invalid("unreadable audio"))?;
    let pcm16 = lumisound_media::decode::mono_pcm(p, RATE, None, None).ok_or_else(|| CoreError::invalid("decode failed"))?;
    let pcm: Vec<f32> = pcm16.iter().map(|s| *s as f32 / 32768.0).collect();
    let feat = frame_features(&pcm);
    let (mask, onset) = vocal_activity(&feat);
    let (lines, singing) = place_lines(&plain, &mask, &onset, info.duration.max(pcm.len() as f64 / RATE as f64));
    Ok(LyricsSync { lrc: format_lrc(&lines), lines, was_synced: false, singing_seconds: singing })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn syllable_counts() {
        assert_eq!(syllables("Hello there my friend"), 5);
        assert_eq!(syllables(""), 0);
        assert!(syllables("rhythm") >= 1);
    }

    #[test]
    fn lrc_roundtrip_and_metadata() {
        let l = parse_lrc("[ar:Someone]\n[00:12.50]First\n[00:05.00][00:30.00]Chorus\n");
        assert_eq!(l.len(), 3);
        assert_eq!(l[0], SyncedLine { time: 5.0, text: "Chorus".into() });
        assert_eq!(format_lrc(&l), "[00:05.00]Chorus\n[00:12.50]First\n[00:30.00]Chorus");
    }

    #[test]
    fn places_lines_on_vocal_entries() {
        // 30 s: silence 0-8 s, "singing" 8-14 s, break 14-18 s, singing 18-26 s.
        let n = RATE as usize * 30;
        let mut pcm = vec![0f32; n];
        let mut seed = 1u32;
        for (i, s) in pcm.iter_mut().enumerate() {
            let t = i as f32 / RATE as f32;
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            let noise = (seed >> 9) as f32 / (1u32 << 23) as f32 - 0.5;
            let bed = 0.02 * noise; // quiet non-vocal floor
            let voice = if (8.0..14.0).contains(&t) || (18.0..26.0).contains(&t) {
                0.3 * ((std::f32::consts::TAU * 440.0 * t).sin() + 0.5 * (std::f32::consts::TAU * 1320.0 * t).sin())
            } else {
                0.0
            };
            *s = bed + voice;
        }
        let feat = frame_features(&pcm);
        let (mask, onset) = vocal_activity(&feat);
        let lines: Vec<String> = ["first line here", "second line now", "third line sung", "fourth one too"].iter().map(|s| s.to_string()).collect();
        let (placed, singing) = place_lines(&lines, &mask, &onset, 30.0);
        assert!((singing - 14.0).abs() < 2.0, "singing {singing}");
        assert!((placed[0].time - 8.0).abs() < 0.8, "first line at {}", placed[0].time);
        // The second half of the lines lands in the second singing section.
        assert!(placed[2].time >= 17.0 && placed[2].time < 26.0, "third line at {}", placed[2].time);
        assert!(placed.windows(2).all(|w| w[1].time > w[0].time));
        assert!(placed.iter().all(|l| !(14.5..17.5).contains(&l.time)), "nothing placed in the break: {placed:?}");
    }
}
