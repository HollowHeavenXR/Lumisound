//! Response headers + gzip + slow-request log (port of asgi_perf.py).

use axum::body::Body;
use axum::extract::Request;
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::middleware::Next;
use axum::response::Response;
use std::time::{Duration, Instant};
use tower_http::compression::predicate::Predicate;

const SLOW: Duration = Duration::from_secs(2);

pub async fn headers_and_timing(req: Request<Body>, next: Next) -> Response {
    let start = Instant::now();
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let mut res = next.run(req).await;
    let h = res.headers_mut();
    for (k, v) in [
        ("x-content-type-options", "nosniff"),
        ("x-frame-options", "DENY"),
        ("referrer-policy", "no-referrer"),
        ("strict-transport-security", "max-age=31536000; includeSubDomains"),
    ] {
        h.entry(k).or_insert(HeaderValue::from_static(v));
    }
    if !path.starts_with("/admin") {
        h.entry("content-security-policy")
            .or_insert(HeaderValue::from_static("default-src 'none'; frame-ancestors 'none'"));
    }
    let elapsed = start.elapsed();
    if elapsed > SLOW {
        tracing::warn!("slow request: {method} {path} took {:.2}s (status {})", elapsed.as_secs_f64(), res.status().as_u16());
    }
    res
}

/// Gzip only text-like bodies of 1 KiB or more, never ranges or 204/206/304.
#[derive(Clone, Copy, Default)]
pub struct Compressible;

impl Predicate for Compressible {
    fn should_compress<B>(&self, response: &axum::http::Response<B>) -> bool
    where
        B: axum::body::HttpBody,
    {
        let st = response.status();
        if matches!(st, StatusCode::NO_CONTENT | StatusCode::PARTIAL_CONTENT | StatusCode::NOT_MODIFIED) {
            return false;
        }
        let h: &HeaderMap = response.headers();
        if h.contains_key("content-encoding") || h.contains_key("content-range") {
            return false;
        }
        if let Some(n) = response.body().size_hint().exact() {
            if n < 1024 {
                return false;
            }
        }
        let ct = h.get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_ascii_lowercase();
        ["application/json", "text/", "application/javascript", "application/xml", "image/svg+xml"]
            .iter()
            .any(|p| ct.starts_with(p))
    }
}
