//! Aria Lyrics: the "Generate with Aria" lyrics engine, run entirely on the
//! bridge (no cloud AI).
//!
//! 1. Vocals: Demucs (htdemucs, already in the image) splits the singing
//!    from the music, so recognition hears the voice, not the drums.
//! 2. Phrases: voice-activity detection on the vocal stem (20 ms frames,
//!    level relative to the stem's own floor and peak, 60 ms to start,
//!    300 ms to end) finds where the singer actually sings. A stem with no
//!    real voice (its peak 20 dB+ under the mix, or under 4 s of singing)
//!    is reported as instrumental instead of inventing words.
//! 3. Recognition: whisper.cpp (statically linked through whisper-rs; model
//!    `ARIA_LYRICS_MODEL`, default ggml small q5_1) runs only on the sung
//!    phrases, grouped into windows of up to 25 s, with per-token
//!    timestamps. Language is detected once on the loudest window and then
//!    fixed. Typical whisper hallucinations on music ("thanks for
//!    watching", subtitle credits, a word looped over and over, text where
//!    the stem is silent) are dropped.
//! 4. Lines: when the lyrics text is known (the app's hint, or LRCLIB's
//!    plain lyrics), the recognized words are aligned to it (global
//!    alignment with fuzzy word matching) and each line takes the time of
//!    its first matched word; unmatched lines are placed between their
//!    neighbours inside sung phrases. Without known text, lines are built
//!    from the recognized words, broken at pauses (0.5 s+) and at ~42
//!    characters. Every line start is snapped to the vocal onset it sits on.
//!
//! The job contract (`/user/intelligence/lyrics-transcribe`) is unchanged.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub const SR: usize = 16_000;
const FRAME: usize = SR / 50; // 20 ms
static SEM: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Seg {
    pub start: f64,
    pub end: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Word {
    pub text: String,
    pub start: f64,
    pub end: f64,
    pub p: f32,
    /// Index of the whisper segment it came from (line-break hint).
    pub seg: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Line {
    pub time: f64,
    pub text: String,
}

#[derive(Debug, Clone)]
pub struct Outcome {
    pub lines: Vec<Line>,
    pub instrumental: bool,
    pub language: Option<String>,
    /// Share of known-text lines that got a recognized timing (aligned mode).
    pub aligned: Option<f64>,
    pub mean_p: f64,
    pub confidence: &'static str,
    pub stages: Vec<(String, f64)>,
}

fn frame_db(pcm: &[f32]) -> Vec<f32> {
    pcm.chunks(FRAME).map(|c| 10.0 * ((c.iter().map(|v| v * v).sum::<f32>() / c.len().max(1) as f32).max(1e-12)).log10()).collect()
}

fn pct(v: &[f32], p: f64) -> f32 {
    if v.is_empty() {
        return -120.0;
    }
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.total_cmp(b));
    s[((s.len() - 1) as f64 * p) as usize]
}

/// Sung phrases in a vocal stem (16 kHz mono).
pub fn voice_segments(vocals: &[f32]) -> Vec<Seg> {
    let db = frame_db(vocals);
    if db.is_empty() {
        return vec![];
    }
    let (floor, peak) = (pct(&db, 0.15), pct(&db, 0.97));
    let th = (floor + 10.0).max(peak - 32.0);
    let dt = FRAME as f64 / SR as f64;
    let mut segs = Vec::new();
    let (mut run_on, mut run_off) = (0usize, 0usize);
    let mut cur: Option<usize> = None;
    for (i, d) in db.iter().enumerate() {
        if *d > th {
            run_on += 1;
            run_off = 0;
            if cur.is_none() && run_on >= 3 {
                cur = Some(i + 1 - run_on);
            }
        } else {
            run_on = 0;
            run_off += 1;
            if let Some(s) = cur {
                if run_off >= 15 {
                    segs.push(Seg { start: s as f64 * dt, end: (i + 1 - run_off) as f64 * dt + dt });
                    cur = None;
                }
            }
        }
    }
    if let Some(s) = cur {
        segs.push(Seg { start: s as f64 * dt, end: db.len() as f64 * dt });
    }
    // Merge short gaps, drop blips.
    let mut out: Vec<Seg> = Vec::new();
    for s in segs {
        match out.last_mut() {
            Some(l) if s.start - l.end < 0.35 => l.end = s.end,
            _ => out.push(s),
        }
    }
    out.retain(|s| s.end - s.start >= 0.3);
    out
}

/// True when the vocal stem holds no real singing.
pub fn is_instrumental(vocals: &[f32], mix: &[f32], segs: &[Seg], duration: f64) -> bool {
    let sung: f64 = segs.iter().map(|s| s.end - s.start).sum();
    let (vp, mp) = (pct(&frame_db(vocals), 0.97), pct(&frame_db(mix), 0.97));
    vp < mp - 20.0 || sung < 4.0f64.max(duration * 0.03)
}

/// Windows (start, end) of at most `max` seconds covering the segments.
pub fn windows(segs: &[Seg], max: f64) -> Vec<(f64, f64)> {
    let mut out: Vec<(f64, f64)> = Vec::new();
    for s in segs {
        let (a, b) = ((s.start - 0.2).max(0.0), s.end + 0.25);
        match out.last_mut() {
            Some(w) if b - w.0 <= max && a - w.1 < 4.0 => w.1 = b,
            _ => {
                // A single phrase longer than `max` is cut into pieces.
                let mut x = a;
                while b - x > max {
                    out.push((x, x + max));
                    x += max;
                }
                out.push((x, b));
            }
        }
    }
    out
}

pub fn norm_word(w: &str) -> String {
    w.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect()
}

fn lev(a: &str, b: &str) -> usize {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut cur = vec![i; b.len() + 1];
        for j in 1..=b.len() {
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + usize::from(a[i - 1] != b[j - 1]));
        }
        prev = cur;
    }
    prev[b.len()]
}

pub fn word_sim(a: &str, b: &str) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    if a == b {
        return 1.0;
    }
    let n = a.chars().count().max(b.chars().count());
    1.0 - lev(a, b) as f64 / n as f64
}

/// Is this a lyric line (not a "[Chorus]" label or blank)?
fn lyric_line(l: &str) -> Option<String> {
    let t = l.trim();
    if t.is_empty() || (t.starts_with('[') && t.ends_with(']')) || (t.starts_with('(') && t.ends_with(')') && t.len() < 24 && t.to_lowercase().contains("chorus")) {
        return None;
    }
    Some(t.to_string())
}

/// Known text + recognized words -> timed lines. Returns the lines and the
/// share of lines that got a timing from a matched word.
pub fn align(reference: &str, words: &[Word], segs: &[Seg], duration: f64) -> (Vec<Line>, f64) {
    let lines: Vec<String> = reference.lines().filter_map(lyric_line).collect();
    if lines.is_empty() {
        return (vec![], 0.0);
    }
    // Reference word list with its line index.
    let mut rw: Vec<(String, usize)> = Vec::new();
    for (li, l) in lines.iter().enumerate() {
        for w in l.split_whitespace() {
            let n = norm_word(w);
            if !n.is_empty() {
                rw.push((n, li));
            }
        }
    }
    let hw: Vec<String> = words.iter().map(|w| norm_word(&w.text)).collect();
    let (n, m) = (rw.len(), hw.len());
    // Global alignment (Needleman–Wunsch), fuzzy match score.
    let gap = -0.6;
    let mut dp = vec![vec![0.0f64; m + 1]; n + 1];
    for i in 1..=n {
        dp[i][0] = dp[i - 1][0] + gap;
    }
    for j in 1..=m {
        // Leading recognized junk is free (intros, ad-libs).
        dp[0][j] = 0.0;
    }
    let sc = |i: usize, j: usize| {
        let s = word_sim(&rw[i].0, &hw[j]);
        if s >= 0.6 { 2.0 * s } else { -1.0 }
    };
    for i in 1..=n {
        for j in 1..=m {
            dp[i][j] = (dp[i - 1][j - 1] + sc(i - 1, j - 1)).max(dp[i - 1][j] + gap).max(dp[i][j - 1] + gap * 0.5);
        }
    }
    // Trailing recognized junk is free too: end at the best cell of the last row.
    let mut j = (0..=m).max_by(|a, b| dp[n][*a].total_cmp(&dp[n][*b])).unwrap_or(m);
    let mut i = n;
    let mut matched: Vec<Option<usize>> = vec![None; n];
    while i > 0 && j > 0 {
        if (dp[i][j] - (dp[i - 1][j - 1] + sc(i - 1, j - 1))).abs() < 1e-9 {
            if sc(i - 1, j - 1) > 0.0 {
                matched[i - 1] = Some(j - 1);
            }
            i -= 1;
            j -= 1;
        } else if (dp[i][j] - (dp[i - 1][j] + gap)).abs() < 1e-9 {
            i -= 1;
        } else {
            j -= 1;
        }
    }
    // Line time = first matched word of the line; also the last matched word (for interpolation).
    let mut first: Vec<Option<f64>> = vec![None; lines.len()];
    let mut last_end: Vec<Option<f64>> = vec![None; lines.len()];
    for (k, (_, li)) in rw.iter().enumerate() {
        if let Some(h) = matched[k] {
            last_end[*li] = Some(words[h].end);
            // Words matched late in a line pull its start back by their offset in the line.
            let pos_in_line = rw[..k].iter().rev().take_while(|(_, l)| l == li).count() as f64;
            let t = (words[h].start - pos_in_line * 0.28).max(0.0);
            if first[*li].is_none() {
                first[*li] = Some(if pos_in_line == 0.0 { words[h].start } else { t });
            }
        }
    }
    let got = first.iter().filter(|t| t.is_some()).count();
    // Monotonic: a matched time earlier than the previous line's is suspect.
    let mut last = -1.0;
    for t in first.iter_mut() {
        if let Some(v) = *t {
            if v <= last + 0.3 {
                *t = None;
            } else {
                last = v;
            }
        }
    }
    // Fill the gaps: spread unmatched lines between the neighbours by length,
    // placed on sung time only.
    let sung_at = |a: f64, b: f64, frac: f64| -> f64 {
        let parts: Vec<(f64, f64)> = segs.iter().map(|s| (s.start.max(a), s.end.min(b))).filter(|(x, y)| y > x).collect();
        let total: f64 = parts.iter().map(|(x, y)| y - x).sum();
        if total <= 0.0 {
            return a + (b - a) * frac;
        }
        let mut want = total * frac;
        for (x, y) in parts {
            if want <= y - x {
                return x + want;
            }
            want -= y - x;
        }
        b
    };
    let mut times: Vec<f64> = vec![0.0; lines.len()];
    let mut k = 0;
    while k < lines.len() {
        if let Some(t) = first[k] {
            times[k] = t;
            k += 1;
            continue;
        }
        let run_start = k;
        while k < lines.len() && first[k].is_none() {
            k += 1;
        }
        let a = if run_start == 0 { segs.first().map_or(0.0, |s| s.start) - 0.01 } else { last_end[run_start - 1].map_or(times[run_start - 1] + 0.5, |e| e.max(times[run_start - 1] + 0.3)) };
        let b = if k < lines.len() { first[k].unwrap() - 0.3 } else { segs.last().map_or(duration, |s| s.end).min(duration) };
        // Enough sung phrases start in the gap: one line per phrase start.
        let starts: Vec<f64> = segs.iter().map(|s| s.start).filter(|t| *t > a + 0.05 && *t < b).collect();
        let run = k - run_start;
        if starts.len() >= run {
            for o in 0..run {
                times[run_start + o] = starts[(o * starts.len()) / run];
            }
            continue;
        }
        let chars: Vec<f64> = lines[run_start..k].iter().map(|l| l.chars().count() as f64 + 8.0).collect();
        let total: f64 = chars.iter().sum::<f64>() + if k < lines.len() { 0.0 } else { chars.last().copied().unwrap_or(0.0) };
        let mut acc = 0.0;
        for (o, c) in chars.iter().enumerate() {
            let frac = if run_start == 0 && o == 0 { 0.0 } else { acc / total.max(1.0) };
            times[run_start + o] = sung_at(a, b.max(a + 0.1), frac);
            acc += c;
        }
    }
    let out = lines.into_iter().zip(times).map(|(text, time)| Line { time, text }).collect::<Vec<_>>();
    (snap(out, segs), got as f64 / first.len() as f64)
}

/// Recognized words -> lines (no known text).
pub fn build_lines(words: &[Word], segs: &[Seg]) -> Vec<Line> {
    let mut out: Vec<Line> = Vec::new();
    let mut cur = String::new();
    let mut start = 0.0;
    let mut prev: Option<&Word> = None;
    for w in words {
        let brk = match prev {
            None => false,
            Some(p) => {
                let pause = w.start - p.end >= 0.5;
                let crosses = segs.iter().any(|s| p.end <= s.end && w.start >= s.end - 0.05 && w.start - s.end > -0.05 && w.start > s.end);
                pause || crosses || w.seg != p.seg && cur.chars().count() > 12 || cur.chars().count() + w.text.chars().count() > 42
            }
        };
        if brk && !cur.trim().is_empty() {
            out.push(Line { time: start, text: tidy(&cur) });
            cur.clear();
        }
        if cur.is_empty() {
            start = w.start;
        }
        let t = w.text.trim();
        let cjk = t.chars().next().is_some_and(|c| ('\u{3040}'..='\u{30ff}').contains(&c) || ('\u{4e00}'..='\u{9fff}').contains(&c) || ('\u{ac00}'..='\u{d7af}').contains(&c));
        if !cur.is_empty() && !cjk {
            cur.push(' ');
        }
        cur.push_str(t);
        prev = Some(w);
    }
    if !cur.trim().is_empty() {
        out.push(Line { time: start, text: tidy(&cur) });
    }
    snap(out, segs)
}

fn tidy(s: &str) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let s = s.trim_matches(|c: char| c == ',' || c == ' ').to_string();
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => s,
    }
}

/// Line starts onto the vocal onset they sit on (within -0.5..+0.3 s).
fn snap(mut lines: Vec<Line>, segs: &[Seg]) -> Vec<Line> {
    for l in lines.iter_mut() {
        if let Some(s) = segs.iter().filter(|s| s.start >= l.time - 0.5 && s.start <= l.time + 0.3).min_by(|a, b| (a.start - l.time).abs().total_cmp(&(b.start - l.time).abs())) {
            l.time = (s.start - 0.05).max(0.0);
        }
    }
    // Strictly increasing.
    for i in 1..lines.len() {
        if lines[i].time <= lines[i - 1].time {
            lines[i].time = lines[i - 1].time + 0.25;
        }
    }
    lines
}

const HALLUCINATIONS: [&str; 12] = [
    "thanks for watching", "thank you for watching", "subtitles by", "subscribe", "amara.org", "transcribed by", "please like", "www.", ".com", "♪", "copyright", "music by",
];

/// Drop whisper's usual inventions.
pub fn clean_words(words: Vec<Word>, segs: &[Seg]) -> Vec<Word> {
    let mut out: Vec<Word> = Vec::new();
    // Per segment: hallucination phrases.
    let mut by_seg: Vec<Vec<Word>> = Vec::new();
    for w in words {
        if by_seg.last().is_none_or(|v| v[0].seg != w.seg) {
            by_seg.push(vec![]);
        }
        by_seg.last_mut().unwrap().push(w);
    }
    for seg in by_seg {
        let text = seg.iter().map(|w| w.text.to_lowercase()).collect::<Vec<_>>().join(" ");
        if HALLUCINATIONS.iter().any(|h| text.contains(h)) {
            continue;
        }
        // A word looped 4+ times in a row is a decoder loop.
        let mut run = 1;
        let mut looped = false;
        for k in 1..seg.len() {
            if norm_word(&seg[k].text) == norm_word(&seg[k - 1].text) && !norm_word(&seg[k].text).is_empty() {
                run += 1;
                if run >= 4 {
                    looped = true;
                }
            } else {
                run = 1;
            }
        }
        if looped {
            let mut last = String::new();
            for w in seg {
                let n = norm_word(&w.text);
                if n != last {
                    last = n;
                    out.push(w);
                }
            }
            continue;
        }
        out.extend(seg);
    }
    // Words in silence (the stem has no voice there) are inventions.
    out.retain(|w| {
        let mid = 0.5 * (w.start + w.end);
        segs.iter().any(|s| mid >= s.start - 0.3 && mid <= s.end + 0.3)
    });
    out.retain(|w| !w.text.trim().is_empty());
    out
}

// ---- whisper ----------------------------------------------------------------------------------

pub struct Asr {
    pub words: Vec<Word>,
    pub language: Option<String>,
}

pub fn model_path() -> PathBuf {
    std::env::var("ARIA_LYRICS_MODEL").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("/app/models/ggml-small-q5_1.bin"))
}

/// Run whisper over `windows` of `pcm` (16 kHz mono vocals).
pub fn recognize(pcm: &[f32], wins: &[(f64, f64)], prompt: &str, threads: i32) -> Result<Asr, String> {
    use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};
    let model = model_path();
    if !model.exists() {
        return Err(format!("lyrics model missing at {}", model.display()));
    }
    let mut cp = WhisperContextParameters::default();
    cp.use_gpu = false;
    let ctx = WhisperContext::new_with_params(model.to_str().unwrap_or_default(), cp).map_err(|e| format!("load model: {e}"))?;
    let mut state = ctx.create_state().map_err(|e| format!("state: {e}"))?;
    let eot = ctx.token_eot();
    let slice = |a: f64, b: f64| -> &[f32] {
        let (i, j) = (((a * SR as f64) as usize).min(pcm.len()), ((b * SR as f64) as usize).min(pcm.len()));
        &pcm[i..j]
    };
    // Language: detect on the loudest window.
    let loudest = wins.iter().copied().max_by(|x, y| {
        let e = |w: (f64, f64)| slice(w.0, w.1).iter().map(|v| v * v).sum::<f32>();
        e(*x).total_cmp(&e(*y))
    });
    let mut language: Option<String> = None;
    if let Some(w) = loudest {
        let mut p = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        p.set_n_threads(threads);
        p.set_language(Some("auto"));
        p.set_detect_language(true);
        p.set_print_progress(false);
        p.set_print_realtime(false);
        p.set_print_special(false);
        p.set_print_timestamps(false);
        let audio = slice(w.0, (w.0 + 30.0).min(w.1));
        if state.full(p, audio).is_ok() {
            language = whisper_rs::get_lang_str(state.full_lang_id_from_state()).map(str::to_string);
        }
    }
    let lang = language.clone().unwrap_or_else(|| "en".into());
    let mut words: Vec<Word> = Vec::new();
    let mut seg_index = 0usize;
    for &(a, b) in wins {
        let audio = slice(a, b);
        if audio.len() < SR / 2 {
            continue;
        }
        let mut p = FullParams::new(SamplingStrategy::BeamSearch { beam_size: 3, patience: -1.0 });
        p.set_n_threads(threads);
        p.set_language(Some(&lang));
        p.set_token_timestamps(true);
        p.set_no_context(true);
        p.set_suppress_blank(true);
        p.set_suppress_nst(true);
        p.set_no_speech_thold(0.6);
        p.set_print_progress(false);
        p.set_print_realtime(false);
        p.set_print_special(false);
        p.set_print_timestamps(false);
        if !prompt.is_empty() {
            p.set_initial_prompt(prompt);
        }
        state.full(p, audio).map_err(|e| format!("whisper: {e}"))?;
        for seg in state.as_iter() {
            if seg.no_speech_probability() > 0.6 {
                continue;
            }
            seg_index += 1;
            for k in 0..seg.n_tokens() {
                let Some(t) = seg.get_token(k) else { continue };
                let d = t.token_data();
                if d.id >= eot {
                    continue;
                }
                let Ok(s) = t.to_str_lossy() else { continue };
                let s = s.to_string();
                if s.trim().is_empty() {
                    continue;
                }
                let (t0, t1) = (a + d.t0 as f64 / 100.0, a + d.t1 as f64 / 100.0);
                let new_word = s.starts_with(' ') || words.last().is_none_or(|w| w.seg != seg_index) || s.chars().next().is_some_and(|c| ('\u{3040}'..='\u{9fff}').contains(&c));
                if new_word {
                    words.push(Word { text: s.trim().to_string(), start: t0, end: t1.max(t0), p: d.p, seg: seg_index });
                } else if let Some(w) = words.last_mut() {
                    w.text.push_str(s.trim());
                    w.end = t1.max(w.end);
                    w.p = w.p.min(d.p);
                }
            }
        }
    }
    Ok(Asr { words, language })
}

// ---- pipeline ---------------------------------------------------------------------------------

async fn run_cmd(st: &crate::state::AppState, prog: &str, args: &[String], secs: u64) -> Result<(), String> {
    match st.ytdlp.run(prog, args, Duration::from_secs(secs)).await {
        Ok(o) if o.status == Some(0) => Ok(()),
        Ok(o) => Err(format!("{prog} failed: {}", String::from_utf8_lossy(&o.stderr).chars().rev().take(400).collect::<String>().chars().rev().collect::<String>())),
        Err(e) => Err(format!("{prog}: {e}")),
    }
}

async fn pcm16k(st: &crate::state::AppState, input: &Path, out: &Path) -> Result<Vec<f32>, String> {
    let a: Vec<String> = vec!["-v".into(), "error".into(), "-y".into(), "-i".into(), input.to_string_lossy().into_owned(), "-ac".into(), "1".into(), "-ar".into(), SR.to_string(), "-f".into(), "s16le".into(), out.to_string_lossy().into_owned()];
    run_cmd(st, "ffmpeg", &a, 180).await?;
    let b = tokio::fs::read(out).await.map_err(|e| e.to_string())?;
    let _ = tokio::fs::remove_file(out).await;
    Ok(b.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0).collect())
}

/// Full pipeline on an audio file. `progress` gets stage names.
pub async fn generate(st: &crate::state::AppState, audio: &Path, title: &str, artist: &str, reference: Option<&str>, progress: impl Fn(&str)) -> Result<Outcome, String> {
    let _permit = SEM.acquire().await.map_err(|e| e.to_string())?;
    let work = std::env::temp_dir().join(format!("aria-lyrics-{}", uuid::Uuid::new_v4().simple()));
    tokio::fs::create_dir_all(&work).await.map_err(|e| e.to_string())?;
    let r = generate_in(st, audio, &work, title, artist, reference, &progress).await;
    let _ = tokio::fs::remove_dir_all(&work).await;
    r
}

async fn generate_in(st: &crate::state::AppState, audio: &Path, work: &Path, title: &str, artist: &str, reference: Option<&str>, progress: &impl Fn(&str)) -> Result<Outcome, String> {
    let mut stages = Vec::new();
    let t = Instant::now();
    progress("separating");
    let mix = pcm16k(st, audio, &work.join("mix.raw")).await?;
    let duration = mix.len() as f64 / SR as f64;
    let input = work.join("input.wav");
    run_cmd(st, "ffmpeg", &["-v", "error", "-y", "-i", &audio.to_string_lossy(), "-ac", "2", "-ar", "44100", &input.to_string_lossy()].map(String::from), 180).await?;
    let vocals_wav = crate::routes::stems::vocals_only(st, &input, work).await?;
    let vocals = pcm16k(st, &vocals_wav, &work.join("vocals.raw")).await?;
    stages.push(("separate".into(), t.elapsed().as_secs_f64()));
    let segs = voice_segments(&vocals);
    if is_instrumental(&vocals, &mix, &segs, duration) {
        return Ok(Outcome { lines: vec![], instrumental: true, language: None, aligned: None, mean_p: 0.0, confidence: "high", stages });
    }
    progress("listening");
    let t = Instant::now();
    let wins = windows(&segs, 25.0);
    // Only known lyrics prime the recognizer: a title/artist prompt got
    // echoed back as an invented closing line ("The Jackson 5 song is about...").
    let prompt: String = reference.map(|r| r.lines().filter_map(lyric_line).collect::<Vec<_>>().join(" ").chars().take(220).collect()).unwrap_or_default();
    let _ = (title, artist);
    // The container gets 3 CPUs: whisper takes two, leaving room for requests.
    let threads = std::env::var("ARIA_LYRICS_THREADS").ok().and_then(|v| v.parse().ok()).unwrap_or(2);
    let vocals2 = vocals.clone();
    let asr = tokio::task::spawn_blocking(move || recognize(&vocals2, &wins, &prompt, threads)).await.map_err(|e| e.to_string())??;
    stages.push(("recognize".into(), t.elapsed().as_secs_f64()));
    let words = clean_words(asr.words, &segs);
    let mean_p = if words.is_empty() { 0.0 } else { words.iter().map(|w| w.p as f64).sum::<f64>() / words.len() as f64 };
    progress("aligning");
    let (lines, aligned) = match reference.filter(|r| r.lines().filter_map(lyric_line).count() >= 3) {
        Some(r) => {
            let (l, a) = align(r, &words, &segs, duration);
            (l, Some(a))
        }
        None => (build_lines(&words, &segs), None),
    };
    let confidence = match aligned {
        Some(a) if a >= 0.6 => "high",
        Some(a) if a >= 0.3 => "medium",
        Some(_) => "low",
        None if mean_p >= 0.6 && !lines.is_empty() => "medium",
        None => "low",
    };
    Ok(Outcome { lines, instrumental: false, language: asr.language, aligned, mean_p, confidence, stages })
}

pub fn outcome_json(o: &Outcome) -> Value {
    json!({
        "instrumental": o.instrumental,
        "language": o.language,
        "aligned": o.aligned,
        "confidence": o.confidence,
        "mean_p": o.mean_p,
        "stages": o.stages.iter().map(|(k, v)| json!({"stage": k, "secs": v})).collect::<Vec<_>>(),
        "lines": o.lines.iter().map(|l| json!({"time_seconds": l.time, "text": l.text})).collect::<Vec<_>>(),
        "timings_ok": true,
        "engine": "aria-lyrics-2",
    })
}

// ---- scoring (tests and the lyrics-probe tool) ------------------------------------------------

/// Parse "[mm:ss.xx]text" LRC lines.
pub fn parse_lrc(s: &str) -> Vec<Line> {
    let mut out = Vec::new();
    for l in s.lines() {
        let l = l.trim();
        let Some(rest) = l.strip_prefix('[') else { continue };
        let Some((ts, text)) = rest.split_once(']') else { continue };
        let Some((m, sec)) = ts.split_once(':') else { continue };
        let (Ok(m), Ok(sec)) = (m.parse::<f64>(), sec.parse::<f64>()) else { continue };
        let text = text.trim();
        if !text.is_empty() {
            out.push(Line { time: m * 60.0 + sec, text: text.to_string() });
        }
    }
    out
}

/// (median |timing error| s of lines matched by text, share of reference
/// lines matched, word error rate of the text) of `got` against `truth`.
pub fn score(got: &[Line], truth: &[Line]) -> (f64, f64, f64) {
    let mut errs = Vec::new();
    let mut used = vec![false; got.len()];
    for t in truth {
        let tn: Vec<String> = t.text.split_whitespace().map(norm_word).collect();
        let best = got.iter().enumerate().filter(|(i, _)| !used[*i]).map(|(i, g)| {
            let gn: Vec<String> = g.text.split_whitespace().map(norm_word).collect();
            let common = tn.iter().filter(|w| gn.iter().any(|x| word_sim(w, x) >= 0.75)).count();
            (i, common as f64 / tn.len().max(1) as f64, (g.time - t.time).abs())
        }).filter(|(_, s, d)| *s >= 0.5 && *d < 20.0).min_by(|a, b| a.2.total_cmp(&b.2));
        if let Some((i, _, d)) = best {
            used[i] = true;
            errs.push(d);
        }
    }
    errs.sort_by(|a, b| a.total_cmp(b));
    let med = if errs.is_empty() { f64::NAN } else { errs[errs.len() / 2] };
    let tw: Vec<String> = truth.iter().flat_map(|l| l.text.split_whitespace().map(norm_word)).filter(|w| !w.is_empty()).collect();
    let gw: Vec<String> = got.iter().flat_map(|l| l.text.split_whitespace().map(norm_word)).filter(|w| !w.is_empty()).collect();
    let wer = if tw.is_empty() { 1.0 } else { word_edit(&tw, &gw) as f64 / tw.len() as f64 };
    (med, errs.len() as f64 / truth.len().max(1) as f64, wer)
}

fn word_edit(a: &[String], b: &[String]) -> usize {
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut cur = vec![i; b.len() + 1];
        for j in 1..=b.len() {
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + usize::from(word_sim(&a[i - 1], &b[j - 1]) < 0.75));
        }
        prev = cur;
    }
    prev[b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone_bursts(spans: &[(f64, f64)], secs: f64) -> Vec<f32> {
        let mut seed = 7u32;
        (0..(secs * SR as f64) as usize).map(|i| {
            let t = i as f64 / SR as f64;
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            let noise = (seed as f32 / u32::MAX as f32 - 0.5) * 0.002;
            if spans.iter().any(|(a, b)| t >= *a && t < *b) { (0.3 * (std::f64::consts::TAU * 220.0 * t).sin()) as f32 + noise } else { noise }
        }).collect()
    }

    #[test]
    fn finds_sung_phrases() {
        let v = tone_bursts(&[(1.0, 3.0), (3.2, 4.0), (8.0, 10.5)], 14.0);
        let s = voice_segments(&v);
        assert_eq!(s.len(), 2, "{s:?}");
        assert!((s[0].start - 1.0).abs() < 0.08 && (s[0].end - 4.0).abs() < 0.1, "{s:?}");
        assert!((s[1].start - 8.0).abs() < 0.08, "{s:?}");
        let mix = tone_bursts(&[(0.0, 14.0)], 14.0);
        assert!(!is_instrumental(&v, &mix, &s, 14.0));
        let quiet: Vec<f32> = v.iter().map(|x| x * 0.01).collect();
        assert!(is_instrumental(&quiet, &mix, &voice_segments(&quiet), 14.0));
    }

    fn w(text: &str, start: f64, seg: usize) -> Word {
        Word { text: text.into(), start, end: start + 0.25, p: 0.8, seg }
    }

    #[test]
    fn aligns_known_text_with_misheard_words() {
        let reference = "[Verse]\nHello darkness my old friend\nI've come to talk with you again\nBecause a vision softly creeping\nLeft its seeds while I was sleeping";
        let words = vec![
            w("yeah", 2.0, 0),
            w("hello", 10.0, 1), w("darkness", 10.4, 1), w("my", 10.9, 1), w("old", 11.2, 1), w("friend", 11.6, 1),
            w("i", 14.0, 2), w("come", 14.3, 2), w("to", 14.6, 2), w("walk", 14.9, 2), w("with", 15.2, 2), w("you", 15.5, 2), w("again", 15.8, 2),
            // third line not recognized at all
            w("left", 26.0, 4), w("its", 26.3, 4), w("seeds", 26.6, 4), w("while", 27.0, 4), w("i", 27.2, 4), w("was", 27.4, 4), w("sleeping", 27.7, 4),
        ];
        let segs = vec![Seg { start: 9.9, end: 12.0 }, Seg { start: 13.95, end: 16.2 }, Seg { start: 20.0, end: 23.0 }, Seg { start: 25.9, end: 28.2 }];
        let (lines, share) = align(reference, &words, &segs, 30.0);
        assert_eq!(lines.len(), 4);
        assert!((lines[0].time - 9.85).abs() < 0.2, "{lines:?}");
        assert!((lines[1].time - 13.9).abs() < 0.2, "{lines:?}");
        assert!(lines[2].time > 16.0 && lines[2].time < 25.0, "unmatched line placed between neighbours: {lines:?}");
        assert!((lines[3].time - 25.85).abs() < 0.2, "{lines:?}");
        assert!((share - 0.75).abs() < 1e-9);
    }

    #[test]
    fn builds_lines_at_pauses_and_drops_hallucinations() {
        let segs = vec![Seg { start: 0.9, end: 3.0 }, Seg { start: 5.0, end: 7.0 }];
        let words = vec![
            w("we", 1.0, 0), w("are", 1.3, 0), w("the", 1.6, 0), w("champions", 1.9, 0),
            w("my", 5.0, 1), w("friend", 5.4, 1),
            w("thanks", 12.0, 2), w("for", 12.3, 2), w("watching", 12.6, 2),
        ];
        let words = clean_words(words, &segs);
        assert_eq!(words.len(), 6, "{words:?}");
        let lines = build_lines(&words, &segs);
        assert_eq!(lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(), vec!["We are the champions", "My friend"]);
        assert!((lines[0].time - 0.85).abs() < 0.06);
    }

    #[test]
    fn scoring_matches_lines() {
        let truth = parse_lrc("[00:10.00]Hello darkness my old friend\n[00:14.00]I've come to talk with you again");
        let got = vec![Line { time: 10.3, text: "Hello darkness my old friend".into() }, Line { time: 13.6, text: "I come to walk with you again".into() }];
        let (med, share, wer) = score(&got, &truth);
        assert!((med - 0.4).abs() < 1e-9 || (med - 0.3).abs() < 1e-9, "{med}");
        assert_eq!(share, 1.0);
        assert!(wer > 0.0 && wer < 0.3, "{wer}");
    }
}
