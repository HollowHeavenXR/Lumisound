//! Postgres through sqlx. Queries build JSON in Postgres (`row_to_json` /
//! `json_agg`) wherever a handler just returns rows, so there is one
//! round trip and no per-column decoding in Rust.

use crate::config::Config;
use serde_json::Value;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::PgPool;
use std::time::Duration;

pub async fn connect(cfg: &Config) -> anyhow::Result<PgPool> {
    let opts = PgConnectOptions::new()
        .host(&cfg.db_host)
        .port(cfg.db_port)
        .username(&cfg.db_user)
        .password(&cfg.db_password)
        .database(&cfg.db_name)
        .application_name("lumisound-bridge");
    let pool = PgPoolOptions::new()
        .max_connections(cfg.db_pool_max)
        .min_connections(1)
        .acquire_timeout(Duration::from_secs(10))
        .idle_timeout(Duration::from_secs(300))
        .connect_lazy_with(opts);
    Ok(pool)
}

/// Runs schema.sql (idempotent CREATE ... IF NOT EXISTS / ALTER ... IF NOT
/// EXISTS statements) in one transaction, like db.init_db did.
pub async fn migrate(pool: &PgPool, schema_sql: &str) -> anyhow::Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::raw_sql(schema_sql).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(())
}

/// SQL helpers the Rust queries use. `lumi_iso` renders a timestamp exactly
/// like Python's datetime.isoformat() (6-digit fraction, or none at .000000),
/// which the apps' fixed-format date parsers depend on.
pub async fn ensure_helpers(pool: &PgPool) -> anyhow::Result<()> {
    sqlx::raw_sql(
        r#"CREATE OR REPLACE FUNCTION lumi_iso(t timestamp) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $f$
             SELECT CASE WHEN t IS NULL THEN NULL
                         WHEN date_part('microseconds', t)::bigint % 1000000 = 0 THEN to_char(t, 'YYYY-MM-DD"T"HH24:MI:SS')
                         ELSE to_char(t, 'YYYY-MM-DD"T"HH24:MI:SS.US') END
           $f$;"#,
    )
    .execute(pool)
    .await?;
    Ok(())
}

/// Python isoformat() of a naive timestamp.
pub fn py_iso(t: &chrono::NaiveDateTime) -> String {
    use chrono::Timelike;
    if t.nanosecond() / 1000 == 0 {
        t.format("%Y-%m-%dT%H:%M:%S").to_string()
    } else {
        t.format("%Y-%m-%dT%H:%M:%S%.6f").to_string()
    }
}

/// Insert into ios_app_event_log; never fails the caller.
pub async fn log_event(
    pool: &PgPool,
    category: &str,
    event: &str,
    user_id: Option<&str>,
    level: &str,
    message: &str,
    detail: Option<Value>,
) {
    let r = sqlx::query(
        "INSERT INTO ios_app_event_log (source, user_id, category, event, level, message, detail) \
         VALUES ('bridge', $1, $2, $3, $4, $5, $6)",
    )
    .bind(user_id.map(|u| truncate(u, 36)))
    .bind(truncate(category, 30))
    .bind(truncate(event, 60))
    .bind(truncate(if level.is_empty() { "info" } else { level }, 10))
    .bind(truncate(message, 2000))
    .bind(detail.map(sqlx::types::Json))
    .execute(pool)
    .await;
    if let Err(e) = r {
        tracing::error!("log_event failed (category={category} event={event}): {e}");
    }
}

/// Character-safe prefix, like Python's `s[:n]`.
pub fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}
