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

/// Retry policy for Swift's `NetworkRetry` (which wraps Swift closures):
/// transient HTTP statuses.
#[uniffi::export]
pub fn retry_is_transient_status(status: u16) -> bool {
    status == 408 || status == 429 || (500..=599).contains(&status)
}

/// Delay before retry number `attempt` (0-based): base·2^n + U(0, base/2).
#[uniffi::export]
pub fn retry_delay_secs(attempt: u32, base_delay: f64) -> f64 {
    base_delay * 2f64.powi(attempt as i32) + jitter_unit() * base_delay * 0.5
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn policy() {
        assert!(retry_is_transient_status(503) && retry_is_transient_status(429) && !retry_is_transient_status(404));
        let d = retry_delay_secs(2, 0.4);
        assert!((1.6..=1.8).contains(&d), "{d}");
    }
}
