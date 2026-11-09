//! Haptics Brain, shared side: every listener's device observes the tracks
//! it plays (haptics on or off, core `haptic_brain.rs`) and sends what it
//! learned here. The bridge folds it into
//! * one global model (timing bias, when to drop off-grid cues, how strong
//!   filled-in beats are, per-band trust) with the same learning rule the
//!   devices use, and
//! * a consensus lesson per track (by content key of the analyzed score):
//!   the most confident pulse fit and the averaged timing offset across
//!   every listener who played it,
//! and hands both back, so a track one person played teaches everyone.
//! Global by design: nothing here is per user (contributors are only
//! counted, to weigh consensus).

use crate::auth::User;
use crate::error::ApiResult;
use crate::extract::{J, Q, invalid};
use crate::state::AppState;
use axum::extract::State;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/user/haptics/learn", post(learn_route))
        .route("/user/haptics/model", get(model_route))
        .route("/user/haptics/track", get(track_route))
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Model {
    pub bias: f64,
    pub drop_below: f64,
    pub fill_strength: f64,
    pub band_trust: Vec<f64>,
    pub evidence: u64,
    pub version: u32,
}

impl Default for Model {
    fn default() -> Self {
        Self { bias: 0.0, drop_below: 0.25, fill_strength: 0.35, band_trust: vec![1.0, 1.0, 1.0], evidence: 0, version: 1 }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Lesson {
    pub period: f64,
    pub phase: f64,
    pub confidence: f64,
    pub offset: f64,
    pub observations: u32,
    #[serde(default)]
    pub grid_f1_before: f64,
    #[serde(default)]
    pub grid_f1_after: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Observation {
    pub track_key: String,
    pub content_key: String,
    pub lesson: Lesson,
    pub best_drop_below: f64,
    pub best_fill_strength: f64,
    /// NaN for bands with no cues arrives as null.
    pub band_on_grid: Vec<Option<f64>>,
}

/// The device learning rule (core haptic_brain::learn), kept identical.
pub fn learn(model: &mut Model, obs: &Observation) {
    if obs.lesson.confidence < 0.3 || !obs.lesson.confidence.is_finite() {
        return;
    }
    let lr = (1.0 / (model.evidence as f64 + 5.0)).max(0.01) * obs.lesson.confidence;
    model.bias += lr * (obs.lesson.offset.clamp(-0.025, 0.025) - model.bias);
    model.drop_below += lr * (obs.best_drop_below.clamp(0.0, 0.5) - model.drop_below);
    model.fill_strength += lr * (obs.best_fill_strength.clamp(0.0, 0.5) - model.fill_strength);
    let valid: Vec<f64> = obs.band_on_grid.iter().flatten().cloned().filter(|v| v.is_finite()).collect();
    if !valid.is_empty() {
        let mean = valid.iter().sum::<f64>() / valid.len() as f64;
        for (i, t) in model.band_trust.iter_mut().enumerate() {
            if let Some(Some(v)) = obs.band_on_grid.get(i).filter(|v| v.is_some_and(f64::is_finite)) {
                let target = (v / mean.max(1e-6)).clamp(0.6, 1.25);
                *t += lr * (target - *t);
            }
        }
    }
    model.bias = model.bias.clamp(-0.02, 0.02);
    model.drop_below = model.drop_below.clamp(0.0, 0.5);
    model.fill_strength = model.fill_strength.clamp(0.0, 0.5);
    model.evidence += 1;
}

/// Fold a new lesson into a track's consensus.
pub fn merge(old: Option<Lesson>, new: &Lesson, contributors: i64) -> Lesson {
    let Some(o) = old else { return Lesson { observations: 1, ..new.clone() } };
    let (wo, wn) = (o.confidence * o.observations as f64, new.confidence);
    let offset = if wo + wn > 0.0 { (o.offset * wo + new.offset * wn) / (wo + wn) } else { o.offset };
    // Pulse: the more confident fit wins; near-identical fits average.
    let (period, phase, confidence) = if o.period > 0.0 && new.period > 0.0 && (o.period / new.period - 1.0).abs() < 0.005 {
        let p = (o.period * wo + new.period * wn) / (wo + wn).max(1e-9);
        let base = if o.confidence >= new.confidence { o.phase } else { new.phase };
        (p, base, o.confidence.max(new.confidence))
    } else if new.confidence > o.confidence {
        (new.period, new.phase, new.confidence)
    } else {
        (o.period, o.phase, o.confidence)
    };
    let _ = contributors;
    Lesson { period, phase, confidence, offset: offset.clamp(-0.025, 0.025), observations: o.observations + 1, grid_f1_before: new.grid_f1_before, grid_f1_after: new.grid_f1_after }
}

async fn load_model(st: &AppState) -> Model {
    let v: Option<Value> = sqlx::query_scalar("SELECT model FROM ios_haptic_model WHERE id = 1").fetch_optional(&st.db).await.ok().flatten();
    v.and_then(|v| serde_json::from_value(v).ok()).unwrap_or_default()
}

#[derive(Deserialize)]
struct LearnReq {
    observations: Vec<Observation>,
}

async fn learn_route(State(st): State<AppState>, u: User, J(b): J<LearnReq>) -> ApiResult<Json<Value>> {
    if b.observations.len() > 500 {
        return Err(invalid("observations", "At most 500 per request"));
    }
    let mut tx = st.db.begin().await?;
    // One writer at a time on the model row.
    sqlx::query("INSERT INTO ios_haptic_model (id, model, updated_at) VALUES (1, $1, NOW()) ON CONFLICT (id) DO NOTHING")
        .bind(serde_json::to_value(Model::default()).unwrap())
        .execute(&mut *tx)
        .await?;
    let v: Value = sqlx::query_scalar("SELECT model FROM ios_haptic_model WHERE id = 1 FOR UPDATE").fetch_one(&mut *tx).await?;
    let mut model: Model = serde_json::from_value(v).unwrap_or_default();
    let mut tracks = serde_json::Map::new();
    for o in &b.observations {
        let key: String = o.content_key.chars().filter(|c| c.is_ascii_hexdigit()).take(32).collect();
        if key.len() < 16 || !o.lesson.period.is_finite() || !o.lesson.phase.is_finite() {
            continue;
        }
        // A listener counts once per track for the model (replays don't outvote others).
        let first: bool = sqlx::query_scalar("INSERT INTO ios_haptic_contrib (content_key, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING true")
            .bind(&key)
            .bind(&u.id)
            .fetch_optional(&mut *tx)
            .await?
            .unwrap_or(false);
        if first {
            learn(&mut model, o);
        }
        let old: Option<Value> = sqlx::query_scalar("SELECT lesson FROM ios_haptic_tracks WHERE content_key = $1 FOR UPDATE").bind(&key).fetch_optional(&mut *tx).await?;
        let contributors: i64 = sqlx::query_scalar("SELECT count(*) FROM ios_haptic_contrib WHERE content_key = $1").bind(&key).fetch_one(&mut *tx).await?;
        let merged = merge(old.and_then(|v| serde_json::from_value(v).ok()), &o.lesson, contributors);
        let mv = serde_json::to_value(&merged).unwrap();
        sqlx::query(
            "INSERT INTO ios_haptic_tracks (content_key, track_key, lesson, contributors, updated_at) VALUES ($1, $2, $3, $4, NOW()) \
             ON CONFLICT (content_key) DO UPDATE SET lesson = EXCLUDED.lesson, contributors = EXCLUDED.contributors, \
               track_key = COALESCE(NULLIF(EXCLUDED.track_key, ''), ios_haptic_tracks.track_key), updated_at = NOW()",
        )
        .bind(&key)
        .bind(o.track_key.chars().take(300).collect::<String>())
        .bind(&mv)
        .bind(contributors as i32)
        .execute(&mut *tx)
        .await?;
        tracks.insert(key, mv);
    }
    sqlx::query("UPDATE ios_haptic_model SET model = $1, updated_at = NOW() WHERE id = 1").bind(serde_json::to_value(&model).unwrap()).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(json!({"model": model, "tracks": tracks})))
}

async fn model_route(State(st): State<AppState>, _u: User) -> ApiResult<Json<Value>> {
    Ok(Json(json!({"model": load_model(&st).await})))
}

#[derive(Deserialize)]
struct TrackQ {
    key: Option<String>,
}

async fn track_route(State(st): State<AppState>, _u: User, Q(q): Q<TrackQ>) -> ApiResult<Json<Value>> {
    let key = q.key.ok_or_else(|| invalid("key", "Field required"))?;
    let row: Option<(Value, i32)> = sqlx::query_as("SELECT lesson, contributors FROM ios_haptic_tracks WHERE content_key = $1").bind(&key).fetch_optional(&st.db).await?;
    let mut tracks = serde_json::Map::new();
    if let Some((l, c)) = &row {
        tracks.insert(key.clone(), l.clone());
        let _ = c;
    }
    Ok(Json(json!({"model": load_model(&st).await, "tracks": tracks, "contributors": row.map(|r| r.1).unwrap_or(0)})))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obs(offset: f64, conf: f64) -> Observation {
        Observation { track_key: "t".into(), content_key: "0123456789abcdef0123".into(), lesson: Lesson { period: 0.5, phase: 0.1, confidence: conf, offset, observations: 1, grid_f1_before: 0.0, grid_f1_after: 0.0 }, best_drop_below: 0.35, best_fill_strength: 0.2, band_on_grid: vec![Some(0.9), Some(0.6), None] }
    }

    #[test]
    fn same_rule_as_devices() {
        // Same numbers as core haptic_brain::tests::model_learns_and_stays_bounded.
        let mut m = Model::default();
        for _ in 0..500 {
            learn(&mut m, &obs(0.01, 0.9));
        }
        assert!((m.bias - 0.01).abs() < 0.002);
        assert!((m.drop_below - 0.35).abs() < 0.02);
        assert!(m.band_trust[0] > m.band_trust[1]);
        learn(&mut m, &obs(0.01, 0.1));
        assert_eq!(m.evidence, 500, "low-confidence observations teach nothing");
    }

    #[test]
    fn consensus_averages_offsets_and_keeps_best_fit() {
        let a = merge(None, &obs(0.01, 0.6).lesson, 1);
        let mut b_l = obs(-0.01, 0.9).lesson;
        b_l.phase = 0.12;
        let b = merge(Some(a), &b_l, 2);
        assert_eq!(b.observations, 2);
        assert!(b.offset < 0.0 && b.offset > -0.01, "{b:?}");
        assert_eq!(b.phase, 0.12, "more confident fit's phase");
    }
}
