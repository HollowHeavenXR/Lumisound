//! File responses with Range support (Starlette FileResponse equivalent).

use axum::body::Body;
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use std::path::Path;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

/// `attachment; filename=...` the way Starlette builds it.
pub fn content_disposition(filename: &str) -> String {
    let quoted: String = urlencoding::encode(filename).replace("%2F", "/");
    if quoted != filename {
        format!("attachment; filename*=utf-8''{quoted}")
    } else {
        format!("attachment; filename=\"{filename}\"")
    }
}

fn parse_range(h: &str, len: u64) -> Option<(u64, u64)> {
    let spec = h.strip_prefix("bytes=")?.split(',').next()?.trim();
    let (a, b) = spec.split_once('-')?;
    if a.is_empty() {
        let n: u64 = b.parse().ok()?;
        if n == 0 {
            return None;
        }
        return Some((len.saturating_sub(n), len - 1));
    }
    let start: u64 = a.parse().ok()?;
    let end: u64 = if b.is_empty() { len - 1 } else { b.parse::<u64>().ok()?.min(len - 1) };
    if start > end || start >= len { None } else { Some((start, end)) }
}

/// Serve `path`. `on_done` runs after the body has been fully sent (or the
/// client went away), which is how claimed downloads get deleted.
pub async fn serve(
    path: &Path,
    media_type: &str,
    filename: Option<&str>,
    req: &HeaderMap,
    on_done: Option<Box<dyn FnOnce() + Send>>,
) -> Response {
    let mut file = match tokio::fs::File::open(path).await {
        Ok(f) => f,
        Err(_) => return crate::error::AppError::not_found("File not found").into_response(),
    };
    let meta = match file.metadata().await {
        Ok(m) => m,
        Err(_) => return crate::error::AppError::not_found("File not found").into_response(),
    };
    let len = meta.len();
    let mtime = meta.modified().ok();
    let etag = format!(
        "\"{:x}-{:x}\"",
        mtime.and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0),
        len
    );
    let range = req.get(header::RANGE).and_then(|v| v.to_str().ok()).and_then(|r| if len > 0 { parse_range(r, len) } else { None });
    let (status, start, end) = match range {
        Some((s, e)) => (StatusCode::PARTIAL_CONTENT, s, e),
        None => (StatusCode::OK, 0, len.saturating_sub(1)),
    };
    let count = if len == 0 { 0 } else { end - start + 1 };
    if start > 0 && file.seek(std::io::SeekFrom::Start(start)).await.is_err() {
        return crate::error::AppError::internal("seek failed").into_response();
    }
    let reader = file.take(count);
    let stream = ReaderStream::with_capacity(reader, 256 * 1024);
    let body = match on_done {
        None => Body::from_stream(stream),
        Some(f) => Body::from_stream(OnDone { inner: stream, f: Some(f) }),
    };
    let mut res = Response::builder().status(status);
    let h = res.headers_mut().unwrap();
    h.insert(header::CONTENT_TYPE, HeaderValue::from_str(media_type).unwrap_or(HeaderValue::from_static("application/octet-stream")));
    h.insert(header::CONTENT_LENGTH, HeaderValue::from(count));
    h.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    h.insert(header::ETAG, HeaderValue::from_str(&etag).unwrap());
    if let Some(t) = mtime {
        h.insert(header::LAST_MODIFIED, HeaderValue::from_str(&httpdate(t)).unwrap());
    }
    if status == StatusCode::PARTIAL_CONTENT {
        h.insert(header::CONTENT_RANGE, HeaderValue::from_str(&format!("bytes {start}-{end}/{len}")).unwrap());
    }
    if let Some(name) = filename {
        if let Ok(v) = HeaderValue::from_str(&content_disposition(name)) {
            h.insert(header::CONTENT_DISPOSITION, v);
        }
    }
    res.body(body).unwrap()
}

pub fn httpdate(t: std::time::SystemTime) -> String {
    let dt: chrono::DateTime<chrono::Utc> = t.into();
    dt.format("%a, %d %b %Y %H:%M:%S GMT").to_string()
}

struct OnDone<S> {
    inner: S,
    f: Option<Box<dyn FnOnce() + Send>>,
}

impl<S: futures_util::Stream + Unpin> futures_util::Stream for OnDone<S> {
    type Item = S::Item;
    fn poll_next(mut self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<Option<Self::Item>> {
        let r = std::pin::Pin::new(&mut self.inner).poll_next(cx);
        if let std::task::Poll::Ready(None) = r {
            if let Some(f) = self.f.take() {
                f();
            }
        }
        r
    }
}

impl<S> Drop for OnDone<S> {
    fn drop(&mut self) {
        if let Some(f) = self.f.take() {
            f();
        }
    }
}
