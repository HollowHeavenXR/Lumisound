//! Skip Silent Intros on real cloud tracks.
//!
//!   LUMI_CLOUD_DIR=<dir of .lms files> cargo test --release -p lumisound-core \
//!       --test intro_cloud -- --nocapture --test-threads=1
//!
//! Every track (decoded straight from the locked file, as the app does) is
//! analysed, then checked:
//! - nothing audible is skipped: the skipped stretch never holds 80 ms of
//!   sound within 25 dB of the track's level
//! - playback lands right before the music: sustained sound within 0.3 s
//! - independent reference: ffmpeg's silencedetect (-60 dB, 0.3 s) on an
//!   unlocked temporary copy, for every skipped track and a sample of the
//!   rest; a silence skip must not start before ffmpeg's silence end, and may
//!   start after it (by > 0.1 s) only across a floor 40 dB+ under the track,
//!   and a track ffmpeg sees 1 s+ of leading silence in must be skipped
//! Skipped when LUMI_CLOUD_DIR is unset (ffmpeg checks skipped without ffmpeg).

use lumisound_core::intro::{self, IntroKind};
use std::path::{Path, PathBuf};
use std::process::Command;

fn levels(s: &[i16], sr: f64) -> (Vec<f32>, f64) {
    let w = (sr / 100.0) as usize;
    let lv = s.chunks(w).map(|c| (10.0 * (c.iter().map(|v| (*v as f64 / 32768.0).powi(2)).sum::<f64>() / c.len() as f64 + 1e-13).log10()) as f32).collect();
    (lv, w as f64 / sr)
}

/// Loudest 80 ms average in [a, b) seconds.
fn sustained_max(lv: &[f32], step: f64, a: f64, b: f64) -> f32 {
    let (i, j) = ((a / step) as usize, ((b / step) as usize).min(lv.len()));
    if j <= i + 8 {
        return lv[i.min(lv.len() - 1)..j.max(i + 1).min(lv.len())].iter().cloned().fold(-200.0, f32::max);
    }
    let pw: Vec<f64> = lv[i..j].iter().map(|d| 10f64.powf(*d as f64 / 10.0)).collect();
    pw.windows(8).map(|w| (10.0 * (w.iter().sum::<f64>() / 8.0).log10()) as f32).fold(-200.0, f32::max)
}

/// ffmpeg silencedetect: end of a silence that starts at 0, if any.
fn ffmpeg_lead_silence(locked: &Path, tmp: &Path) -> Option<Option<f64>> {
    let out = tmp.join(format!("x.{}", lumisound_media::lock::inner_ext(&locked.file_name()?.to_string_lossy())?));
    if !lumisound_core::lock::lms_unlock(locked.to_string_lossy().into(), out.to_string_lossy().into()) {
        return None;
    }
    let o = Command::new("ffmpeg").args(["-hide_banner", "-nostats", "-t", "40", "-i"]).arg(&out).args(["-af", "silencedetect=noise=-60dB:d=0.3", "-f", "null", "-"]).output().ok()?;
    let _ = std::fs::remove_file(&out);
    let err = String::from_utf8_lossy(&o.stderr);
    let mut start0 = false;
    for l in err.lines() {
        if let Some(v) = l.split("silence_start: ").nth(1) {
            start0 = v.trim().parse::<f64>().is_ok_and(|s| s <= 0.05);
            if !start0 {
                return Some(None);
            }
        }
        if let Some(v) = l.split("silence_end: ").nth(1) {
            if start0 {
                return Some(v.split_whitespace().next().and_then(|x| x.parse().ok()));
            }
        }
    }
    Some(if start0 { Some(40.0) } else { None })
}

#[test]
fn intros_on_cloud_tracks() {
    let Ok(dir) = std::env::var("LUMI_CLOUD_DIR") else {
        eprintln!("LUMI_CLOUD_DIR not set; skipping");
        return;
    };
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir).unwrap().filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|e| e == "lms")).collect();
    files.sort();
    assert!(!files.is_empty());
    let have_ffmpeg = Command::new("ffmpeg").arg("-version").output().is_ok();
    let tmp = std::env::temp_dir().join(format!("intro-cloud-{}", std::process::id()));
    std::fs::create_dir_all(&tmp).unwrap();
    let sr = intro::RATE as f64;
    let mut kinds = std::collections::BTreeMap::<String, usize>::new();
    let mut fails: Vec<String> = vec![];
    let mut checked_ff = 0;
    let mut undecodable = 0;
    let mut faint_floor = 0;
    let t0 = std::time::Instant::now();
    eprintln!("\n{:<50} {:>7} {:>7} {:<11} {:>7} {:>6} {:>5} {:>7}", "track (skipped / checked)", "skip", "onset", "kind", "content", "lead", "std", "ffmpeg");
    for (n, f) in files.iter().enumerate() {
        let name: String = f.file_name().unwrap().to_string_lossy().chars().skip(9).take(48).collect();
        let Some(pcm) = lumisound_media::decode::mono_pcm(f, intro::RATE, None, Some(40.0)) else {
            // The app hands these to AVFoundation for PCM; report what it is.
            let ext = lumisound_media::lock::inner_ext(&f.file_name().unwrap().to_string_lossy()).unwrap_or_default();
            let out = tmp.join(format!("probe.{ext}"));
            let codec = if lumisound_core::lock::lms_unlock(f.to_string_lossy().into(), out.to_string_lossy().into()) {
                Command::new("ffprobe").args(["-v", "error", "-show_entries", "stream=codec_name,profile", "-of", "csv=p=0"]).arg(&out).output().map(|o| String::from_utf8_lossy(&o.stdout).trim().replace('\n', " ")).unwrap_or_default()
            } else {
                "unlock failed".into()
            };
            let _ = std::fs::remove_file(&out);
            eprintln!("NOTE {name}: Rust decoder can't read it ({codec}); the app uses AVFoundation PCM");
            undecodable += 1;
            continue;
        };
        let a = intro::analyze(&pcm, sr);
        if let Ok(pat) = std::env::var("LUMI_INTRO_DUMP") {
            if pat.split('|').any(|p| name.contains(p)) {
                let (lv, _) = levels(&pcm, sr);
                let secs = (a.onset_secs + 0.5).min(8.0);
                let row: Vec<String> = lv[..((secs * 100.0) as usize).min(lv.len())].chunks(5).map(|c| format!("{:.0}", c.iter().cloned().fold(-200.0, f32::max))).collect();
                eprintln!("DUMP {name} {a:?}\n  50ms max dB: {}", row.join(" "));
            }
        }
        *kinds.entry(format!("{:?}", a.kind)).or_default() += 1;
        let (lv, step) = levels(&pcm, sr);
        // Reference for skipped tracks and every 15th of the rest.
        let ff = if have_ffmpeg && (a.skip_secs > 0.0 || n % 15 == 0) {
            checked_ff += 1;
            ffmpeg_lead_silence(f, &tmp)
        } else {
            None
        };
        if a.skip_secs > 0.0 || a.kind == IntroKind::QuietMusic || ff.is_some_and(|x| x.is_some_and(|e| e >= 1.0)) {
            eprintln!(
                "{name:<50} {:>6.2}s {:>6.2}s {:<11} {:>6.0}dB {:>5.0} {:>5.1} {:>7}",
                a.skip_secs,
                a.onset_secs,
                format!("{:?}", a.kind),
                a.content_db,
                a.lead_in_db,
                a.lead_in_std_db,
                match ff {
                    Some(Some(e)) => format!("{e:.2}s"),
                    Some(None) => "none".into(),
                    None => "-".into(),
                }
            );
        }
        if a.skip_secs > 0.0 {
            let skipped_max = sustained_max(&lv, step, 0.0, a.skip_secs);
            if skipped_max > a.content_db - 25.0 {
                fails.push(format!("{name}: skipped sound at {skipped_max:.0} dB (track {:.0} dB)", a.content_db));
            }
            let after = sustained_max(&lv, step, a.skip_secs, a.skip_secs + 0.3);
            if after < (a.content_db - 32.0).min(-70.0) {
                fails.push(format!("{name}: no sound within 0.3 s of where playback starts"));
            }
            if a.kind == IntroKind::Silence {
                if let Some(Some(end)) = ff {
                    // Starting earlier than ffmpeg's silence end would play silence;
                    // later is only allowed over a faint floor (ffmpeg's -60 dB is per
                    // sample peak, so it calls hiss or a click 45 dB+ under the music
                    // sound): nothing in between within 40 dB of the track.
                    let gap = if a.onset_secs > end + 0.1 { sustained_max(&lv, step, end, a.onset_secs - 0.03) } else { -200.0 };
                    if a.onset_secs < end - 0.1 || gap > a.content_db - 40.0 {
                        fails.push(format!("{name}: silence ends at {end:.2}s (ffmpeg) vs {:.2}s (in between {gap:.0} dB, track {:.0} dB)", a.onset_secs, a.content_db));
                    } else if a.onset_secs > end + 0.1 {
                        faint_floor += 1;
                    }
                }
            }
        }
        if let Some(Some(end)) = ff {
            if end >= 1.0 && end < 39.0 && a.skip_secs == 0.0 {
                fails.push(format!("{name}: ffmpeg finds {end:.2}s of leading silence, not skipped ({:?})", a.kind));
            }
        }
    }
    let _ = std::fs::remove_dir_all(&tmp);
    eprintln!("\n{} tracks in {:.1}s ({checked_ff} checked against ffmpeg, {faint_floor} start past a faint floor ffmpeg calls sound, {undecodable} need AVFoundation): {kinds:?}", files.len(), t0.elapsed().as_secs_f64());
    assert!(fails.is_empty(), "intro skip:\n{}", fails.join("\n"));
}
