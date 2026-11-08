//! Music Haptics on real cloud tracks.
//!
//!   LUMI_CLOUD_DIR=<dir of .lms / audio files> [LUMI_SAMPLE=40] cargo test --release \
//!       -p lumisound-core --test haptics_cloud -- --nocapture --test-threads=1
//!
//! For an even spread of tracks (decoded straight from the locked files, as
//! the app does), builds the haptic score and checks it against independent
//! references:
//! - beat alignment: share of the beat grid (the old system's only signal)
//!   that gets a haptic within 35 ms, and share of haptics that sit on a
//!   musical onset of any band (no stray buzzes)
//! - silence: no haptic where the mix is near-silent
//! - comfort: never more than 12 transients in any second
//! - expression: intensities and sharpness actually vary (not one canned tap)
//! - speed: analysis time vs track length; cache round trip
//! Skipped when LUMI_CLOUD_DIR is unset.

use lumisound_core::haptics::{self, HapticScheduler};
use std::path::{Path, PathBuf};
use std::time::Instant;

/// An even spread of `sample` tracks; LUMI_OFFSET shifts the picks (a
/// different set), LUMI_MAX_MB raises the size limit (long DJ mixes).
fn tracks(dir: &Path, sample: usize) -> Vec<PathBuf> {
    let env = |k: &str, d: u64| std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d);
    let max = env("LUMI_MAX_MB", 20) * 1_000_000;
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "lms") && std::fs::metadata(p).is_ok_and(|m| m.len() < max))
        .collect();
    v.sort();
    let step = (v.len() / sample.max(1)).max(1);
    let offset = env("LUMI_OFFSET", 0) as usize % step;
    let mut picked: Vec<PathBuf> = v.iter().skip(offset).step_by(step).take(sample).cloned().collect();
    // Always include the largest file when the limit admits it (long-track check).
    if let Some(big) = v.iter().max_by_key(|p| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)) {
        if !picked.contains(big) && std::fs::metadata(big).is_ok_and(|m| m.len() >= 20_000_000) {
            picked.push(big.clone());
        }
    }
    picked
}

/// Mix level (dB) per 10 ms.
fn levels(s: &[i16], sr: f64) -> Vec<f32> {
    let w = (sr / 100.0) as usize;
    s.chunks(w).map(|c| (10.0 * (c.iter().map(|v| (*v as f64 / 32768.0).powi(2)).sum::<f64>() / c.len() as f64 + 1e-12).log10()) as f32).collect()
}

fn pct(v: &mut [f64], p: f64) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(|a, b| a.total_cmp(b));
    v[((v.len() - 1) as f64 * p).round() as usize]
}

#[test]
fn haptics_on_cloud_tracks() {
    let Ok(dir) = std::env::var("LUMI_CLOUD_DIR") else {
        eprintln!("LUMI_CLOUD_DIR not set; skipping");
        return;
    };
    let sample: usize = std::env::var("LUMI_SAMPLE").ok().and_then(|v| v.parse().ok()).unwrap_or(40);
    let files = tracks(Path::new(&dir), sample);
    assert!(!files.is_empty(), "no .lms tracks in LUMI_CLOUD_DIR");
    let cache = std::env::temp_dir().join(format!("haptics-cloud-{}", std::process::id()));
    lumisound_core::blobcache::blob_cache_configure(cache.to_string_lossy().into());

    let sr = haptics::RATE as f64;
    let mut recalls = vec![];
    let mut audible_recalls = vec![];
    let mut offsets: Vec<f64> = vec![];
    let mut precisions = vec![];
    let mut rates = vec![];
    let mut speeds = vec![];
    let mut fails: Vec<String> = vec![];
    eprintln!("\n{:<44} {:>6} {:>6} {:>5} {:>5} {:>5} {:>6} {:>6} {:>5} {:>5} {:>6} {:>6}", "track", "secs", "ev/s", "low", "mid", "high", "rumble", "beat%", "aud%", "on%", "int sd", "x RT");
    for f in &files {
        let name: String = f.file_name().unwrap().to_string_lossy().chars().skip(9).take(42).collect();
        let t = Instant::now();
        let Some(pcm) = lumisound_media::decode::mono_pcm(f, haptics::RATE, None, None) else {
            fails.push(format!("{name}: could not decode"));
            continue;
        };
        let decode_secs = t.elapsed().as_secs_f64();
        let t = Instant::now();
        let score = std::sync::Arc::new(haptics::analyze(&pcm, sr));
        let analyze_secs = t.elapsed().as_secs_f64();
        let st = score.stats();
        let dur = st.duration;
        let ev = score.events();
        let trans: Vec<&haptics::HapticEvent> = ev.iter().filter(|e| !e.continuous).collect();

        // Beat grid (old system's signal) at 11.025 kHz.
        let half: Vec<i16> = pcm.chunks(2).map(|c| ((c[0] as i32 + *c.get(1).unwrap_or(&c[0]) as i32) / 2) as i16).collect();
        let beats = lumisound_core::analysis::beat_grid_from(&half, sr / 2.0);
        let hit = |t: f64, tol: f64| trans.iter().any(|e| (e.time - t).abs() <= tol);
        let recall = if beats.is_empty() { f64::NAN } else { beats.iter().filter(|b| hit(**b, 0.035)).count() as f64 / beats.len() as f64 };
        let lv = levels(&pcm, sr);
        // Level windows are 220 samples (9.977 ms), not 10 ms.
        let idx = |t: f64| (t * sr / (sr / 100.0).floor()) as usize;
        // Audible beats: the mix clearly rises (>= 3 dB within ±40 ms). The
        // grid also pads a steady pulse through bars with no hit at all.
        let rises = |t: f64| {
            let i = idx(t);
            let (a, z) = (i.saturating_sub(4), (i + 4).min(lv.len().saturating_sub(1)));
            if a >= z {
                return false;
            }
            let before = lv[a.saturating_sub(3)..=a].iter().cloned().fold(f32::MAX, f32::min);
            let after = lv[a..=z].iter().cloned().fold(f32::MIN, f32::max);
            after - before >= 3.0
        };
        let audible: Vec<f64> = beats.iter().cloned().filter(|b| rises(*b)).collect();
        let recall_audible = if audible.is_empty() { f64::NAN } else { audible.iter().filter(|b| hit(**b, 0.035)).count() as f64 / audible.len() as f64 };
        // Timing: signed offset of the nearest haptic to each beat (±80 ms).
        for b in &beats {
            if let Some(e) = trans.iter().filter(|e| (e.time - b).abs() <= 0.08).min_by(|x, y| (x.time - b).abs().total_cmp(&(y.time - b).abs())) {
                offsets.push(e.time - b);
            }
        }

        let on_onset = trans
            .iter()
            .filter(|e| {
                let i = idx(e.time);
                let (a, z) = (i.saturating_sub(4), (i + 4).min(lv.len().saturating_sub(1)));
                let before = lv[a.saturating_sub(3)..=a].iter().cloned().fold(f32::MAX, f32::min);
                let after = lv[a..=z].iter().cloned().fold(f32::MIN, f32::max);
                after - before >= 1.5
            })
            .count() as f64
            / trans.len().max(1) as f64;

        // Silence: no event where the 100 ms mix level is under -60 dBFS.
        let silent_events = ev
            .iter()
            .filter(|e| {
                let i = idx(e.time);
                let w = &lv[i.min(lv.len() - 1)..(i + 10).min(lv.len())];
                w.iter().cloned().fold(f32::MIN, f32::max) < -60.0
            })
            .count();
        // Comfort: max transients in any 1 s window.
        let mut max_window = 0;
        for (i, e) in trans.iter().enumerate() {
            let n = trans[i..].iter().take_while(|x| x.time < e.time + 1.0).count();
            max_window = max_window.max(n);
        }
        let ints: Vec<f64> = trans.iter().map(|e| e.intensity as f64).collect();
        let mean = ints.iter().sum::<f64>() / ints.len().max(1) as f64;
        let int_sd = (ints.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / ints.len().max(1) as f64).sqrt();
        let bands_used = [st.low_hits, st.mid_hits, st.high_hits].iter().filter(|n| **n > 0).count();
        let rate = trans.len() as f64 / dur.max(1.0);
        let xrt = dur / (decode_secs + analyze_secs);

        // Scheduler sanity over the whole track: every transient is handed
        // over exactly once at 1x with 0.2 s ticks.
        let sched = HapticScheduler::new(score.clone());
        let mut handed = 0usize;
        let mut pos = 0.0;
        while pos < dur + 1.0 {
            handed += sched.next(pos, 0.0, 1.0, 0.45, 1.0).cues.iter().filter(|c| !c.continuous).count();
            pos += 0.2;
        }

        eprintln!(
            "{name:<44} {dur:>6.0} {rate:>6.2} {:>5} {:>5} {:>5} {:>5.0}s {:>5.0}% {:>5.0}% {:>5.0}% {int_sd:>6.2} {xrt:>6.0}",
            st.low_hits, st.mid_hits, st.high_hits, st.continuous_secs, recall * 100.0, recall_audible * 100.0, on_onset * 100.0
        );
        if std::env::var("LUMI_DIAG").is_ok() && (recall_audible < 0.6 || silent_events > 0) {
            let missed: Vec<f64> = audible.iter().cloned().filter(|b| !hit(*b, 0.035)).take(8).collect();
            for l in haptics::diagnose(&pcm, sr, &missed) {
                eprintln!("   miss {l}");
            }
            let quiet: Vec<f64> = ev
                .iter()
                .filter(|e| {
                    let i = idx(e.time);
                    lv[i.min(lv.len() - 1)..(i + 10).min(lv.len())].iter().cloned().fold(f32::MIN, f32::max) < -60.0
                })
                .map(|e| e.time)
                .take(4)
                .collect();
            for (t, l) in quiet.iter().zip(haptics::diagnose(&pcm, sr, &quiet)) {
                let e = ev.iter().find(|e| e.time == *t).unwrap();
                eprintln!("   silent {} cont={} dur={:.2}", l, e.continuous, e.duration);
            }
        }
        if silent_events > 0 {
            fails.push(format!("{name}: {silent_events} haptics in silence"));
        }
        if max_window > 12 {
            fails.push(format!("{name}: {max_window} transients in one second"));
        }
        if handed != trans.len() {
            fails.push(format!("{name}: scheduler handed {handed} of {} transients", trans.len()));
        }
        if dur > 30.0 && trans.len() > 20 {
            if int_sd < 0.06 {
                fails.push(format!("{name}: flat intensity (sd {int_sd:.3})"));
            }
            if bands_used < 2 {
                fails.push(format!("{name}: only {bands_used} band in use"));
            }
        }
        if !recall.is_nan() {
            recalls.push(recall);
        }
        if !recall_audible.is_nan() {
            audible_recalls.push(recall_audible);
        }
        precisions.push(on_onset);
        rates.push(rate);
        speeds.push(xrt);
    }
    let med_recall = pct(&mut recalls, 0.5);
    let med_audible = pct(&mut audible_recalls, 0.5);
    let p25_audible = pct(&mut audible_recalls, 0.25);
    let off_med = pct(&mut offsets, 0.5);
    let off_iqr = pct(&mut offsets, 0.75) - pct(&mut offsets, 0.25);
    eprintln!("\naudible-beat recall median {:.0}% (p25 {:.0}%) | timing vs beat grid: median {:+.1} ms, IQR {:.1} ms", med_audible * 100.0, p25_audible * 100.0, off_med * 1000.0, off_iqr * 1000.0);
    let p25_recall = pct(&mut recalls, 0.25);
    let med_prec = pct(&mut precisions, 0.5);
    let med_rate = pct(&mut rates, 0.5);
    let min_speed = pct(&mut speeds, 0.0);
    eprintln!(
        "\n{} tracks | beat recall median {:.0}% (p25 {:.0}%) | on-onset median {:.0}% | {:.1} haptics/s median | slowest {:.0}x real time",
        files.len(),
        med_recall * 100.0,
        p25_recall * 100.0,
        med_prec * 100.0,
        med_rate,
        min_speed
    );
    // Chunked analysis (long tracks) matches one-piece analysis: run the
    // first multi-minute track through 100 s pieces (the app uses 300 s).
    // Pieces set their own adaptive thresholds, so a few weak hits differ.
    if let Some(f) = files.iter().find(|f| lumisound_media::decode::probe(f).is_some_and(|p| p.duration > 150.0 && p.duration < 600.0)) {
        let whole = haptics::analyze_file(f, 10_000.0).unwrap();
        let chunked = haptics::analyze_file(f, 100.0).unwrap();
        let (a, b) = (whole.stats().transients as f64, chunked.stats().transients as f64);
        eprintln!("chunked vs whole: {b} vs {a} transients ({:+.1}%)", (b / a - 1.0) * 100.0);
        if (b / a - 1.0).abs() > 0.05 {
            fails.push(format!("chunked analysis differs by {:.1}%", (b / a - 1.0) * 100.0));
        }
        let matched = chunked.events().iter().filter(|e| !e.continuous && whole.events().iter().any(|w| !w.continuous && (w.time - e.time).abs() < 0.006)).count() as f64;
        if matched / b < 0.90 {
            fails.push(format!("chunked events only {:.0}% identical", matched / b * 100.0));
        }
    }
    // Cache round trip on the last track.
    let last = files.last().unwrap().to_string_lossy().to_string();
    let a = haptics::haptic_score(last.clone(), None).unwrap();
    let b = haptics::haptic_score_cached(last).expect("cached score");
    assert_eq!(a.event_count(), b.event_count());
    let _ = std::fs::remove_dir_all(&cache);

    if med_audible < 0.8 {
        fails.push(format!("audible-beat recall median {:.0}% < 80%", med_audible * 100.0));
    }
    if off_med.abs() > 0.015 {
        fails.push(format!("haptics {:+.1} ms off the beat (median)", off_med * 1000.0));
    }
    if med_prec < 0.8 {
        fails.push(format!("on-onset median {:.0}% < 80%", med_prec * 100.0));
    }
    if !(1.5..=9.0).contains(&med_rate) {
        fails.push(format!("median {med_rate:.1} haptics/s outside 1.5-9"));
    }
    if min_speed < 20.0 {
        fails.push(format!("analysis only {min_speed:.0}x real time"));
    }
    assert!(fails.is_empty(), "haptics quality:\n{}", fails.join("\n"));
}
