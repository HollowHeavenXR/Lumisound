//! Listening-taste helpers shared by social, stations and the AI prompts
//! (non-AI parts of intelligence.py + aria_apis.py).

use crate::analysis::pyround;
use crate::state::AppState;
use serde_json::{Value, json};
use std::time::Duration;

impl AppState {
    /// `get_user_taste_profile` (cached for an hour per user).
    pub async fn taste_profile(&self, user_id: &str) -> Value {
        if let Some(v) = self.taste_cache.get(&user_id.to_string()) {
            return v;
        }
        let v: Value = sqlx::query_scalar(
            "SELECT json_build_object( \
               'top_played_artists', COALESCE((SELECT json_agg(artist ORDER BY weight DESC) FROM ( \
                  SELECT artist, SUM(LEAST(listen_seconds, 600) * POWER(0.5, (EXTRACT(EPOCH FROM (NOW() - played_at)) / 3600.0) / 720.0)) AS weight \
                  FROM ios_play_history WHERE user_id = $1 AND artist IS NOT NULL AND artist != '' GROUP BY artist ORDER BY weight DESC LIMIT 15) a), '[]'::json), \
               'favorited_artists', COALESCE((SELECT json_agg(artist) FROM (SELECT DISTINCT artist FROM ios_user_favorites \
                  WHERE user_id = $1 AND artist IS NOT NULL AND artist != '' LIMIT 30) f), '[]'::json), \
               'favorited_albums', COALESCE((SELECT json_agg(album) FROM (SELECT DISTINCT album FROM ios_user_favorites \
                  WHERE user_id = $1 AND album IS NOT NULL AND album != '' LIMIT 30) f), '[]'::json), \
               'library_genres', COALESCE((SELECT json_agg(genre ORDER BY n DESC) FROM (SELECT genre, COUNT(*) AS n FROM ios_user_music_metadata \
                  WHERE user_id = $1 AND genre IS NOT NULL AND genre != '' GROUP BY genre ORDER BY n DESC LIMIT 10) g), '[]'::json), \
               'playlists', COALESCE((SELECT json_agg(json_build_object('name', name, 'track_count', n) ORDER BY upd DESC) FROM ( \
                  SELECT p.name, COUNT(t.id) AS n, p.updated_at AS upd FROM ios_user_playlists p LEFT JOIN ios_playlist_tracks t ON t.playlist_id = p.id \
                  WHERE p.user_id = $1 GROUP BY p.id, p.name ORDER BY p.updated_at DESC LIMIT 10) pl), '[]'::json), \
               'recent_housekeeping', COALESCE((SELECT json_agg(json_build_object('action_type', action_type, 'title', title, 'artist', artist, \
                  'created_at', lumi_iso(created_at), 'reverted', reverted_at IS NOT NULL) ORDER BY created_at DESC) FROM ( \
                  SELECT * FROM ios_aria_actions WHERE user_id = $1 AND created_at > NOW() - INTERVAL '14 days' ORDER BY created_at DESC LIMIT 20) h), '[]'::json))",
        )
        .bind(user_id)
        .fetch_one(&self.db)
        .await
        .unwrap_or_else(|e| {
            tracing::error!("failed to build taste profile for user {user_id}: {e}");
            json!({"top_played_artists": [], "favorited_artists": [], "favorited_albums": [], "library_genres": [], "playlists": [], "recent_housekeeping": []})
        });
        self.taste_cache.set_ttl(user_id.to_string(), v.clone(), Duration::from_secs(3600));
        v
    }

    /// `get_sonic_fingerprint`: median BPM/spread and median spectrum once 20+ tracks are analysed.
    pub async fn sonic_fingerprint(&self, user_id: &str) -> Option<Value> {
        let rows: Vec<(Option<f64>, Option<String>)> =
            sqlx::query_as("SELECT bpm, spectral_profile FROM ios_user_music_metadata WHERE user_id = $1 AND (bpm > 0 OR spectral_profile IS NOT NULL)")
                .bind(user_id)
                .fetch_all(&self.db)
                .await
                .ok()?;
        let tempos: Vec<f64> = rows.iter().filter_map(|r| r.0).filter(|b| *b > 0.0).collect();
        let spectra: Vec<Vec<f64>> = rows
            .iter()
            .filter_map(|r| r.1.as_deref())
            .filter_map(|raw| serde_json::from_str::<Vec<f64>>(raw).ok())
            .filter(|v| v.len() == 10)
            .collect();
        if tempos.len() < 20 && spectra.len() < 20 {
            return None;
        }
        let mut out = serde_json::Map::new();
        out.insert("track_count".into(), json!(tempos.len().max(spectra.len())));
        if tempos.len() >= 20 {
            out.insert("median_bpm".into(), json!(pyround(median(&tempos), 1)));
            let mean = tempos.iter().sum::<f64>() / tempos.len() as f64;
            let var = tempos.iter().map(|t| (t - mean).powi(2)).sum::<f64>() / tempos.len() as f64;
            out.insert("bpm_spread".into(), json!(pyround(var.sqrt(), 1)));
        }
        if spectra.len() >= 20 {
            out.insert("spectrum".into(), json!((0..10).map(|i| pyround(median(&spectra.iter().map(|s| s[i]).collect::<Vec<_>>()), 2)).collect::<Vec<_>>()));
        }
        Some(Value::Object(out))
    }
}

pub fn median(v: &[f64]) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = s.len();
    if n % 2 == 1 { s[n / 2] } else { (s[n / 2 - 1] + s[n / 2]) / 2.0 }
}

fn spectral_similarity(a: &[f64], b: &[f64]) -> f64 {
    if a.len() != 10 || b.len() != 10 {
        return 0.0;
    }
    let (ma, mb) = (a.iter().sum::<f64>() / 10.0, b.iter().sum::<f64>() / 10.0);
    let diff = a.iter().zip(b).map(|(x, y)| ((x - ma) - (y - mb)).abs()).sum::<f64>() / 10.0;
    (1.0 - diff / 8.0).max(0.0)
}

fn pace(bpm: f64) -> &'static str {
    if bpm >= 120.0 { "fast" } else if bpm < 95.0 { "relaxed" } else { "mid-paced" }
}

/// `describe_sonic_match`: (0..1 similarity, short reasons).
pub fn describe_sonic_match(a: &Value, b: &Value) -> (f64, Vec<String>) {
    let mut parts = Vec::new();
    let mut reasons = Vec::new();
    if let (Some(ba), Some(bb)) = (a["median_bpm"].as_f64(), b["median_bpm"].as_f64()) {
        let t = (1.0 - (ba - bb).abs() / 30.0).max(0.0);
        parts.push(t);
        if t > 0.75 {
            reasons.push(format!("you both lean {}", pace(ba)));
        } else if t < 0.35 {
            let (faster, slower) = if ba >= bb { (ba, bb) } else { (bb, ba) };
            reasons.push(format!("very different pace ({:.0} vs {:.0} bpm)", slower, faster));
        }
    }
    let sa: Option<Vec<f64>> = a["spectrum"].as_array().map(|x| x.iter().filter_map(Value::as_f64).collect());
    let sb: Option<Vec<f64>> = b["spectrum"].as_array().map(|x| x.iter().filter_map(Value::as_f64).collect());
    if let (Some(sa), Some(sb)) = (sa, sb) {
        let s = spectral_similarity(&sa, &sb);
        parts.push(s);
        if s > 0.75 {
            let top = sa[7..].iter().sum::<f64>() / 3.0;
            let bottom = sa[..3].iter().sum::<f64>() / 3.0;
            reasons.push(format!("similar tone — both {}", if top - bottom > -18.0 { "bright" } else { "bass-forward" }));
        } else if s < 0.35 {
            reasons.push("quite different tonal balance".into());
        }
    }
    if parts.is_empty() {
        return (0.0, vec![]);
    }
    (parts.iter().sum::<f64>() / parts.len() as f64, reasons)
}

pub fn fingerprint_summary(fp: &Value) -> Option<String> {
    let bpm = fp["median_bpm"].as_f64()?;
    let spread = fp["bpm_spread"].as_f64().unwrap_or(0.0);
    Some(format!("{} and {} — around {:.0} bpm", pace(bpm), if spread > 25.0 { "wide-ranging" } else { "consistent" }, bpm))
}

/// Python round() to an int (banker's rounding on .5).
pub fn py_round_int(x: f64) -> i64 {
    pyround(x, 0) as i64
}
