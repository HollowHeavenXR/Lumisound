//! Retry with exponential backoff + jitter for transient failures
//! (timeouts, dropped connections, unreachable host, HTTP 408/429/5xx).

use crate::error::CoreError;
use std::future::Future;
use std::time::Duration;

pub fn is_transient(e: &CoreError) -> bool {
    match e {
        CoreError::Network { cancelled, .. } => !cancelled,
        CoreError::Http { status, .. } => *status == 408 || *status == 429 || (500..=599).contains(status),
        _ => false,
    }
}

/// Runs `op` up to `max_attempts` times; delays ≈ base·2^n + U(0, base/2).
pub async fn with_retry<T, F, Fut>(max_attempts: u32, base_delay: f64, mut op: F) -> Result<T, CoreError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, CoreError>>,
{
    let mut attempt = 0;
    loop {
        match op().await {
            Ok(v) => return Ok(v),
            Err(e) if attempt + 1 < max_attempts.max(1) && is_transient(&e) => {
                let backoff = base_delay * 2f64.powi(attempt as i32);
                let jitter = jitter_unit() * base_delay * 0.5;
                tokio::time::sleep(Duration::from_secs_f64(backoff + jitter)).await;
                attempt += 1;
            }
            Err(e) => return Err(e),
        }
    }
}

/// Cheap [0,1) jitter without pulling in a RNG crate.
fn jitter_unit() -> f64 {
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    (n % 1_000_000) as f64 / 1_000_000.0
}
