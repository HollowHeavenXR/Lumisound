//! Background loops that have moved from the Python bridge. Each one is
//! enabled by name in RUST_LOOPS (default: all ported ones); the Python
//! bridge skips the same names via LEGACY_DISABLE_LOOPS.

use crate::analysis;
use crate::state::AppState;
use crate::storage::{self, safe_join};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const PORTED: &[&str] = &["media_backfill", "duplicate_scan", "storage_quota", "weekly_mix", "artist_image", "rooms"];

pub fn spawn_all(st: &AppState) {
    let enabled: Vec<String> = match std::env::var("RUST_LOOPS") {
        Ok(v) => v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect(),
        Err(_) => PORTED.iter().map(|s| s.to_string()).collect(),
    };
    let on = |n: &str| enabled.iter().any(|e| e == n || e == "all");
    if on("media_backfill") {
        let st = st.clone();
        tokio::spawn(async move { media_backfill_loop(st).await });
    }
    if on("duplicate_scan") {
        let st = st.clone();
        tokio::spawn(async move { duplicate_scan_loop(st).await });
    }
    if on("storage_quota") {
        let st = st.clone();
        tokio::spawn(async move { storage_quota_loop(st).await });
    }
    if on("weekly_mix") {
        let st = st.clone();
        tokio::spawn(async move { weekly_mix_loop(st).await });
    }
    if on("artist_image") {
        let st = st.clone();
        tokio::spawn(async move { artist_image_loop(st).await });
    }
    if on("rooms") {
        let st = st.clone();
        tokio::spawn(async move { crate::routes::social::rooms_janitor(st).await });
    }
    tracing::info!("background loops enabled: {enabled:?}");
}

// ---- media backfill (artwork, BPM, transition + spectral profiles) ----------------------------

static FAILED: Mutex<Option<HashSet<String>>> = Mutex::new(None);

fn failed_has(id: &str) -> bool {
    FAILED.lock().unwrap().as_ref().is_some_and(|s| s.contains(id))
}

fn failed_add(id: &str) {
    FAILED.lock().unwrap().get_or_insert_with(HashSet::new).insert(id.to_string());
}

async fn media_backfill_loop(st: AppState) {
    loop {
        tokio::time::sleep(Duration::from_secs(300)).await;
        if let Err(e) = media_backfill_tick(&st).await {
            tracing::warn!("media backfill tick failed: {e}");
        }
    }
}

type Cand = (String, String, String, Option<bool>, Option<f64>, bool, bool);

#[derive(Clone)]
struct T {
    id: String,
    user: String,
    rel: String,
    path: PathBuf,
    dir: PathBuf,
    has_art: Option<bool>,
}

fn art_file(t: &T) -> PathBuf {
    t.dir.join(".artwork").join(format!("{}.jpg", t.id.chars().filter(|c| c.is_alphanumeric()).collect::<String>()))
}

async fn artwork_one(st: AppState, t: T, deadline: Instant) -> (String, Option<bool>) {
    if Instant::now() >= deadline {
        return (t.id, None);
    }
    let readable = storage::readable_copy(&t.path).await;
    let (data, source) = analysis::recover_artwork(&st.http, readable.path()).await;
    drop(readable);
    if let Some(d) = data {
        let cp = art_file(&t);
        let ok = tokio::fs::create_dir_all(cp.parent().unwrap()).await.is_ok() && tokio::fs::write(&cp, &d).await.is_ok();
        if !ok {
            tracing::warn!("media backfill: could not write artwork for {}", t.rel);
            return (t.id, None);
        }
        let _ = sqlx::query("UPDATE ios_user_music_metadata SET has_artwork = TRUE WHERE user_id = $1 AND id = $2").bind(&t.user).bind(&t.id).execute(&st.db).await;
        tracing::info!("media backfill: {source} artwork for {}", t.rel);
        return (t.id, Some(true));
    }
    if t.has_art == Some(true) {
        let _ = sqlx::query("UPDATE ios_user_music_metadata SET has_artwork = FALSE WHERE user_id = $1 AND id = $2").bind(&t.user).bind(&t.id).execute(&st.db).await;
    }
    (t.id, Some(false))
}

async fn media_backfill_tick(st: &AppState) -> anyhow::Result<()> {
    let rows: Vec<Cand> = sqlx::query_as(
        "SELECT id, user_id, COALESCE(relative_path, filename), has_artwork, bpm, \
                transition_profiled_at IS NOT NULL, spectral_profiled_at IS NOT NULL \
         FROM ios_user_music_metadata \
         WHERE bpm IS NULL OR bpm <= 0 OR has_artwork IS NOT TRUE OR transition_profiled_at IS NULL OR spectral_profiled_at IS NULL \
         ORDER BY uploaded_at DESC NULLS LAST LIMIT 600",
    )
    .fetch_all(&st.db)
    .await?;
    let cands: Vec<Cand> = rows.into_iter().filter(|r| !failed_has(&r.0)).take(200).collect();
    if cands.is_empty() {
        return Ok(());
    }
    let deadline = Instant::now() + Duration::from_secs(60);
    let (mut art, mut bpm, mut prof, mut spec) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for (id, user, rel, has_art, b, profiled, spectral) in &cands {
        let Some(dir) = st.user_music_dir(user) else { continue };
        let Some(path) = safe_join(&dir, rel).filter(|p| p.is_file()) else {
            failed_add(id);
            continue;
        };
        let t = || T { id: id.clone(), user: user.clone(), rel: rel.clone(), path: path.clone(), dir: dir.clone(), has_art: *has_art };
        if !dir.join(".artwork").join(format!("{}.jpg", id.chars().filter(|c| c.is_alphanumeric()).collect::<String>())).exists() {
            art.push(t());
        }
        if b.is_none_or(|b| b <= 0.0) {
            bpm.push(t());
        }
        if !profiled {
            prof.push(t());
        }
        if !spectral {
            spec.push(t());
        }
    }
    // Artwork: up to 6 at a time.
    let art_out: Vec<(String, Option<bool>)> = futures_util::StreamExt::collect(futures_util::StreamExt::buffer_unordered(
        futures_util::stream::iter(art.clone().into_iter().map(|t| artwork_one(st.clone(), t, deadline))),
        6,
    ))
    .await;
    let art_out: std::collections::HashMap<String, Option<bool>> = art_out.into_iter().collect();

    let mut bpm_out = std::collections::HashMap::new();
    let mut prof_out = std::collections::HashMap::new();
    let mut spec_out = std::collections::HashMap::new();
    let mut phases: Vec<&str> = vec!["bpm", "profile", "spectral"];
    let rot = (chrono::Utc::now().timestamp() / 300) as usize % 3;
    phases.rotate_left(rot);
    let pending: Vec<&str> = phases
        .into_iter()
        .filter(|p| match *p {
            "bpm" => !bpm.is_empty(),
            "profile" => !prof.is_empty(),
            _ => !spec.is_empty(),
        })
        .collect();
    let (mut n_bpm, mut n_prof, mut n_spec) = (0, 0, 0);
    if !pending.is_empty() {
        let slice = deadline.saturating_duration_since(Instant::now()) / pending.len() as u32;
        for phase in pending {
            let stop = (Instant::now() + slice).min(deadline);
            let list = match phase {
                "bpm" => &bpm,
                "profile" => &prof,
                _ => &spec,
            };
            for t in list {
                if Instant::now() >= stop {
                    break;
                }
                let readable = storage::readable_copy(&t.path).await;
                match phase {
                    "bpm" => {
                        let v = analysis::estimate_bpm(readable.path()).await;
                        bpm_out.insert(t.id.clone(), v.is_some());
                        if let Some(b) = v.filter(|b| *b != 0.0) {
                            let _ = sqlx::query("UPDATE ios_user_music_metadata SET bpm = $1 WHERE user_id = $2 AND id = $3").bind(b).bind(&t.user).bind(&t.id).execute(&st.db).await;
                            n_bpm += 1;
                        }
                    }
                    "profile" => {
                        let p = analysis::transition_profile(readable.path()).await;
                        prof_out.insert(t.id.clone(), p.is_some());
                        let _ = sqlx::query(
                            "UPDATE ios_user_music_metadata SET trailing_silence_s = $1, outro_slope_db = $2, outro_cold_stop = $3, \
                             intro_lead_in_s = $4, intro_onset_hardness = $5, transition_profiled_at = NOW() WHERE user_id = $6 AND id = $7",
                        )
                        .bind(p.as_ref().map(|p| p.trailing_silence_s))
                        .bind(p.as_ref().map(|p| p.outro_slope_db_per_s))
                        .bind(p.as_ref().map(|p| p.outro_cold_stop))
                        .bind(p.as_ref().map(|p| p.intro_lead_in_s))
                        .bind(p.as_ref().map(|p| p.intro_onset_hardness))
                        .bind(&t.user)
                        .bind(&t.id)
                        .execute(&st.db)
                        .await;
                        if p.is_some() {
                            n_prof += 1;
                        }
                    }
                    _ => {
                        let b = analysis::spectral_profile(readable.path()).await;
                        spec_out.insert(t.id.clone(), b.is_some());
                        let _ = sqlx::query("UPDATE ios_user_music_metadata SET spectral_profile = $1, spectral_profiled_at = NOW() WHERE user_id = $2 AND id = $3")
                            .bind(b.as_ref().filter(|b| !b.is_empty()).map(|b| serde_json::to_string(b).unwrap()))
                            .bind(&t.user)
                            .bind(&t.id)
                            .execute(&st.db)
                            .await;
                        if b.is_some() {
                            n_spec += 1;
                        }
                    }
                }
            }
        }
    }
    // A track that every needed pass has now looked at, with nothing gained, is skipped from now on.
    let ids = |v: &Vec<T>| v.iter().map(|t| t.id.clone()).collect::<HashSet<_>>();
    let (need_bpm, need_prof, need_spec) = (ids(&bpm), ids(&prof), ids(&spec));
    for c in &cands {
        let id = &c.0;
        let art_r = art_out.get(id).copied().flatten();
        let settled = (!art_out.contains_key(id) || art_r.is_some())
            && (!need_bpm.contains(id) || bpm_out.contains_key(id))
            && (!need_prof.contains(id) || prof_out.contains_key(id))
            && (!need_spec.contains(id) || spec_out.contains_key(id));
        let gained = art_r == Some(true) || bpm_out.get(id) == Some(&true) || prof_out.get(id) == Some(&true) || spec_out.get(id) == Some(&true);
        if settled && !gained {
            failed_add(id);
        }
    }
    let n_art = art_out.values().filter(|v| **v == Some(true)).count();
    if n_art + n_bpm + n_prof + n_spec > 0 {
        tracing::info!("media backfill: {n_art} artwork, {n_bpm} bpm, {n_prof} profiles, {n_spec} spectra ({} candidates)", cands.len());
    }
    Ok(())
}

// ---- acoustic duplicates ---------------------------------------------------------------------

static FP_CACHE: Mutex<Option<std::collections::HashMap<String, (f64, Vec<u32>)>>> = Mutex::new(None);

async fn chromaprint(p: &std::path::Path) -> (f64, Vec<u32>) {
    let Ok(m) = std::fs::metadata(p) else { return (0.0, vec![]) };
    let key = format!(
        "{}|{}|{}",
        p.display(),
        m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs_f64()).unwrap_or(0.0),
        m.len()
    );
    if let Some(v) = FP_CACHE.lock().unwrap().as_ref().and_then(|c| c.get(&key).cloned()) {
        return v;
    }
    let fut = tokio::process::Command::new("fpcalc").args(["-raw", "-json", "-length", "120"]).arg(p).kill_on_drop(true).output();
    let r = match tokio::time::timeout(Duration::from_secs(30), fut).await {
        Ok(Ok(o)) => serde_json::from_slice::<Value>(&o.stdout)
            .ok()
            .map(|d| {
                (
                    d["duration"].as_f64().unwrap_or(0.0),
                    d["fingerprint"].as_array().map(|a| a.iter().filter_map(|x| x.as_i64()).map(|x| x as u32).collect()).unwrap_or_default(),
                )
            })
            .unwrap_or((0.0, vec![])),
        _ => {
            tracing::warn!("fpcalc failed for {}", p.display());
            (0.0, vec![])
        }
    };
    FP_CACHE.lock().unwrap().get_or_insert_with(Default::default).insert(key, r.clone());
    r
}

fn fp_similarity(a: &[u32], b: &[u32]) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let shorter = a.len().min(b.len()) as f64;
    (-40i64..=40)
        .map(|off| {
            let (aa, bb) = if off >= 0 { (&a[(off as usize).min(a.len())..], b) } else { (a, &b[((-off) as usize).min(b.len())..]) };
            let n = aa.len().min(bb.len());
            if n == 0 || (n as f64) < shorter / 2.0 {
                return 0.0;
            }
            let diff: u32 = aa[..n].iter().zip(&bb[..n]).map(|(x, y)| (x ^ y).count_ones()).sum();
            1.0 - diff as f64 / (n as f64 * 32.0)
        })
        .fold(0.0, f64::max)
}

pub async fn scan_acoustic_duplicates(st: &AppState, user_id: &str) -> Option<Value> {
    let dir = st.user_music_dir(user_id)?;
    let mut files: Vec<PathBuf> = tokio::task::spawn_blocking(move || storage::walk_files(&dir).into_iter().filter(|p| storage::is_audio_ext(p)).collect())
        .await
        .unwrap_or_default();
    files.sort();
    files.truncate(300);
    let mut prints = Vec::new();
    for p in files {
        let (d, fp) = chromaprint(&p).await;
        if !fp.is_empty() {
            prints.push((p, d, fp));
        }
    }
    let groups = tokio::task::spawn_blocking(move || {
        let mut used = HashSet::new();
        let mut groups: Vec<Value> = Vec::new();
        for i in 0..prints.len() {
            if used.contains(&i) {
                continue;
            }
            let mut members = vec![i];
            for j in i + 1..prints.len() {
                if used.contains(&j) || (prints[i].1 - prints[j].1).abs() > 5.0 {
                    continue;
                }
                if fp_similarity(&prints[i].2, &prints[j].2) >= 0.95 {
                    members.push(j);
                    used.insert(j);
                }
            }
            if members.len() > 1 {
                used.insert(i);
                groups.push(json!(members
                    .iter()
                    .map(|k| json!({"file": prints[*k].0.file_name().unwrap().to_string_lossy(), "duration": analysis::pyround(prints[*k].1, 1)}))
                    .collect::<Vec<_>>()));
            }
        }
        (prints.len(), groups)
    })
    .await
    .ok()?;
    Some(json!({"scanned": groups.0, "duplicate_groups": groups.1}))
}

pub async fn save_duplicate_scan(st: &AppState, user_id: &str, r: &Value) {
    let _ = sqlx::query(
        "INSERT INTO ios_duplicate_scan_cache (user_id, groups_json) VALUES ($1, $2) \
         ON CONFLICT (user_id) DO UPDATE SET groups_json = EXCLUDED.groups_json, scanned_at = NOW()",
    )
    .bind(user_id)
    .bind(r.to_string())
    .execute(&st.db)
    .await;
}

async fn duplicate_scan_loop(st: AppState) {
    loop {
        tokio::time::sleep(Duration::from_secs(3600)).await;
        let row: Option<String> = sqlx::query_scalar(
            "SELECT m.user_id FROM ios_user_music_metadata m LEFT JOIN ios_duplicate_scan_cache c ON c.user_id = m.user_id \
             WHERE c.user_id IS NULL OR c.scanned_at < NOW() - make_interval(hours => 24) \
             GROUP BY m.user_id ORDER BY MIN(c.scanned_at) IS NULL DESC, MIN(c.scanned_at) ASC LIMIT 1",
        )
        .fetch_optional(&st.db)
        .await
        .unwrap_or(None);
        let Some(uid) = row else { continue };
        if let Some(r) = scan_acoustic_duplicates(&st, &uid).await {
            save_duplicate_scan(&st, &uid, &r).await;
            let n = r["duplicate_groups"].as_array().map_or(0, Vec::len);
            if n > 0 {
                tracing::info!("duplicate scan: found {n} duplicate group(s) for user {uid}");
                st.fire_user_webhooks(&uid, "duplicate_found", json!({"duplicate_group_count": n})).await;
            }
        }
    }
}

// ---- storage quota default -------------------------------------------------------------------

async fn storage_quota_loop(st: AppState) {
    loop {
        tokio::time::sleep(Duration::from_secs(86400)).await;
        let q = storage::DEFAULT_QUOTA_BYTES;
        let a = sqlx::query(
            "UPDATE ios_user_settings SET storage_quota_bytes = $1 WHERE user_id <> $2 AND (storage_quota_bytes IS NULL OR storage_quota_bytes <> $1)",
        )
        .bind(q)
        .bind(crate::auth::OPERATOR_USER_ID)
        .execute(&st.db)
        .await;
        let b = sqlx::query(
            "INSERT INTO ios_user_settings (user_id, storage_quota_bytes) SELECT id, $1 FROM ios_users \
             WHERE id <> $2 AND id NOT IN (SELECT user_id FROM ios_user_settings) ON CONFLICT (user_id) DO NOTHING",
        )
        .bind(q)
        .bind(crate::auth::OPERATOR_USER_ID)
        .execute(&st.db)
        .await;
        match (a, b) {
            (Ok(a), Ok(b)) if a.rows_affected() + b.rows_affected() > 0 => {
                tracing::info!("storage quota janitor: reasserted {} account(s), created {} settings row(s)", a.rows_affected(), b.rows_affected())
            }
            (Err(e), _) | (_, Err(e)) => tracing::error!("storage quota janitor: reassert failed: {e}"),
            _ => {}
        }
    }
}

// ---- weekly mix ------------------------------------------------------------------------------

async fn weekly_mix_loop(st: AppState) {
    loop {
        tokio::time::sleep(Duration::from_secs(3600)).await;
        let row: Option<String> = sqlx::query_scalar(
            "SELECT m.user_id FROM ios_user_music_metadata m LEFT JOIN ios_weekly_mix_cache c ON c.user_id = m.user_id \
             WHERE c.user_id IS NULL OR c.generated_at < NOW() - make_interval(days => 7) \
             GROUP BY m.user_id ORDER BY MIN(c.generated_at) IS NULL DESC, MIN(c.generated_at) ASC LIMIT 1",
        )
        .fetch_optional(&st.db)
        .await
        .unwrap_or(None);
        let Some(uid) = row else { continue };
        match crate::routes::discovery::generate_weekly_mix(&st, &uid).await {
            Ok(t) => {
                let _ = crate::routes::discovery::save_weekly_mix(&st, &uid, &t).await;
                tracing::info!("weekly mix: regenerated {} track(s) for user {uid}", t.len());
            }
            Err(e) => tracing::error!("weekly mix loop: pass failed: {e}"),
        }
    }
}

// ---- artist images ---------------------------------------------------------------------------

async fn url_is_alive(st: &AppState, url: &str) -> bool {
    for head in [true, false] {
        let req = if head { st.http.head(url) } else { st.http.get(url).header("Range", "bytes=0-0") };
        match req.timeout(Duration::from_secs(10)).send().await {
            Ok(r) if r.status().as_u16() < 400 => return true,
            Ok(r) if matches!(r.status().as_u16(), 403 | 405) => continue,
            _ => return false,
        }
    }
    false
}

async fn artist_image_loop(st: AppState) {
    loop {
        tokio::time::sleep(Duration::from_secs(300)).await;
        let rows: Vec<(String, Option<String>, Option<bool>)> = match sqlx::query_as(
            "WITH all_artists AS (SELECT DISTINCT TRIM(artist) AS artist FROM ios_user_music_metadata WHERE artist IS NOT NULL AND TRIM(artist) != '' \
               UNION SELECT DISTINCT TRIM(artist) AS artist FROM ios_play_history WHERE artist IS NOT NULL AND TRIM(artist) != '') \
             SELECT a.artist, c.image_url, c.found FROM all_artists a LEFT JOIN ios_artist_image_cache c ON c.artist_name = LOWER(a.artist) \
             WHERE c.artist_name IS NULL OR (c.found IS FALSE AND c.last_checked_at < NOW() - make_interval(days => 14)) \
                OR (c.found IS TRUE AND c.last_checked_at < NOW() - make_interval(days => 60)) \
             ORDER BY c.last_checked_at IS NULL DESC, c.last_checked_at ASC LIMIT 5",
        )
        .fetch_all(&st.db)
        .await
        {
            Ok(r) => r,
            Err(e) => {
                tracing::error!("artist image loop: tick failed: {e}");
                continue;
            }
        };
        for (name, url, found) in rows {
            let key = name.trim().to_lowercase();
            if let (Some(true), Some(u)) = (found, url.as_deref()) {
                if url_is_alive(&st, u).await {
                    let _ = sqlx::query("UPDATE ios_artist_image_cache SET last_checked_at = NOW() WHERE artist_name = $1").bind(&key).execute(&st.db).await;
                    continue;
                }
                tracing::info!("artist image: stored image for {name:?} is no longer reachable, re-resolving");
            }
            let r = crate::routes::discovery::resolve_artist_image(&st, &name, st.cfg.youtube_api_key.as_deref().unwrap_or("")).await;
            crate::routes::discovery::upsert_artist_image(&st, &key, &r).await;
        }
    }
}
