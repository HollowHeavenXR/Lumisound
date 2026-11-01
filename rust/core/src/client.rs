//! Bridge API client: base URL + bearer token, JSON in/out, FastAPI error
//! bodies, retries for idempotent GETs, 401 -> `CoreError::Unauthorized`.
//! Swift's AccountService/StreamingService route every request through here.

use crate::error::{CoreError, CoreResult};
use crate::{on_rt, retry};
use std::sync::{Arc, RwLock};
use std::time::Duration;

pub const DEFAULT_TIMEOUT_SECS: f64 = 20.0;

#[derive(uniffi::Record, Clone, Debug)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
    pub content_type: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct HttpHeader {
    pub name: String,
    pub value: String,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct HttpExchange {
    pub status: u16,
    pub headers: Vec<HttpHeader>,
    pub body: Vec<u8>,
    /// Final URL after redirects.
    pub url: String,
}

#[derive(uniffi::Object)]
pub struct ApiClient {
    base: RwLock<String>,
    token: RwLock<Option<String>>,
    api_key: RwLock<Option<String>>,
    http: reqwest::Client,
}

pub(crate) fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .pool_idle_timeout(Duration::from_secs(90))
        .tcp_keepalive(Duration::from_secs(30))
        .user_agent(concat!("Lumisound-Core/", env!("CARGO_PKG_VERSION")))
        .build()
        .expect("http client")
}

fn join(base: &str, path: &str) -> String {
    let base = base.trim_matches('/');
    if path.starts_with('/') { format!("{base}{path}") } else { format!("{base}/{path}") }
}

/// FastAPI `{"detail": "..."}` (string) or a generic message.
pub(crate) fn error_for(status: u16, body: &[u8]) -> CoreError {
    if status == 401 {
        return CoreError::Unauthorized;
    }
    let detail = serde_json::from_slice::<serde_json::Value>(body).ok().and_then(|v| v.get("detail").and_then(|d| d.as_str()).map(str::to_string));
    CoreError::Http { status, message: detail.unwrap_or_else(|| format!("Server error (HTTP {status})")) }
}

#[uniffi::export]
impl ApiClient {
    #[uniffi::constructor]
    pub fn new(base_url: String) -> Arc<Self> {
        Arc::new(Self { base: RwLock::new(base_url), token: RwLock::new(None), api_key: RwLock::new(None), http: http_client() })
    }

    pub fn set_base_url(&self, url: String) {
        *self.base.write().unwrap() = url;
    }

    pub fn base_url(&self) -> String {
        self.base.read().unwrap().clone()
    }

    pub fn set_token(&self, token: Option<String>) {
        *self.token.write().unwrap() = token.filter(|t| !t.is_empty());
    }

    pub fn has_token(&self) -> bool {
        self.token.read().unwrap().is_some()
    }

    /// Shared bridge API key (X-API-Key) for the public /api routes.
    pub fn set_api_key(&self, key: Option<String>) {
        *self.api_key.write().unwrap() = key.filter(|k| !k.is_empty());
    }

    /// Authenticated JSON request. GETs retry up to 3 times on transient
    /// failures; writes never retry (could double-apply). Returns the body.
    pub async fn request(&self, path: String, method: String, body: Option<Vec<u8>>, timeout_secs: Option<f64>) -> CoreResult<Vec<u8>> {
        let attempts = if method.eq_ignore_ascii_case("GET") { 3 } else { 1 };
        self.request_with_retry(path, method, body, timeout_secs, attempts, 0.4).await
    }

    /// `request` with an explicit retry budget (for idempotent bulk writes
    /// like the inventory replace).
    pub async fn request_with_retry(&self, path: String, method: String, body: Option<Vec<u8>>, timeout_secs: Option<f64>, max_attempts: u32, base_delay: f64) -> CoreResult<Vec<u8>> {
        let (http, url, tok, key) = (self.http.clone(), join(&self.base_url(), &path), self.token.read().unwrap().clone(), self.api_key.read().unwrap().clone());
        let timeout = Duration::from_secs_f64(timeout_secs.unwrap_or(DEFAULT_TIMEOUT_SECS).max(1.0));
        let method = reqwest::Method::from_bytes(method.to_uppercase().as_bytes()).map_err(|_| CoreError::invalid("bad method"))?;
        on_rt(async move {
            retry::with_retry(max_attempts, base_delay, || {
                let mut rq = http.request(method.clone(), &url).timeout(timeout);
                if let Some(t) = &tok {
                    rq = rq.bearer_auth(t);
                }
                if let Some(k) = &key {
                    rq = rq.header("X-API-Key", k);
                }
                if let Some(b) = &body {
                    rq = rq.header("Content-Type", "application/json").body(b.clone());
                }
                async move {
                    let r = rq.send().await?;
                    let status = r.status().as_u16();
                    let bytes = r.bytes().await?.to_vec();
                    if !(200..300).contains(&status) {
                        return Err(error_for(status, &bytes));
                    }
                    Ok(bytes)
                }
            })
            .await
        })
        .await
    }

    /// Raw request for callers that need status + content type (uploads,
    /// file downloads that are not JSON). Never retried.
    pub async fn send_raw(&self, path: String, method: String, body: Option<Vec<u8>>, content_type: Option<String>, timeout_secs: Option<f64>) -> CoreResult<HttpResponse> {
        let (http, url, tok, key) = (self.http.clone(), join(&self.base_url(), &path), self.token.read().unwrap().clone(), self.api_key.read().unwrap().clone());
        let timeout = Duration::from_secs_f64(timeout_secs.unwrap_or(DEFAULT_TIMEOUT_SECS).max(1.0));
        let method = reqwest::Method::from_bytes(method.to_uppercase().as_bytes()).map_err(|_| CoreError::invalid("bad method"))?;
        on_rt(async move {
            let mut rq = http.request(method, &url).timeout(timeout);
            if let Some(t) = &tok {
                rq = rq.bearer_auth(t);
            }
            if let Some(k) = &key {
                rq = rq.header("X-API-Key", k);
            }
            if let Some(b) = body {
                rq = rq.header("Content-Type", content_type.unwrap_or_else(|| "application/octet-stream".into())).body(b);
            }
            let r = rq.send().await?;
            let status = r.status().as_u16();
            let ct = r.headers().get("content-type").and_then(|v| v.to_str().ok()).map(str::to_string);
            Ok(HttpResponse { status, body: r.bytes().await?.to_vec(), content_type: ct })
        })
        .await
    }
}

static SHARED: std::sync::LazyLock<reqwest::Client> = std::sync::LazyLock::new(http_client);

fn build(method: &str, url: &str, headers: &[HttpHeader], timeout_secs: f64) -> CoreResult<reqwest::RequestBuilder> {
    let m = reqwest::Method::from_bytes(method.to_uppercase().as_bytes()).map_err(|_| CoreError::invalid("bad method"))?;
    let mut rq = SHARED.request(m, url).timeout(Duration::from_secs_f64(timeout_secs.max(1.0)));
    for h in headers {
        rq = rq.header(&h.name, &h.value);
    }
    Ok(rq)
}

async fn exchange(rq: reqwest::RequestBuilder) -> CoreResult<HttpExchange> {
    let r = rq.send().await?;
    let status = r.status().as_u16();
    let url = r.url().to_string();
    let headers = r.headers().iter().filter_map(|(k, v)| Some(HttpHeader { name: k.as_str().to_string(), value: v.to_str().ok()?.to_string() })).collect();
    let body = r.bytes().await?.to_vec();
    Ok(HttpExchange { status, headers, body, url })
}

/// One HTTP exchange for an arbitrary request (any status is returned, not
/// thrown) — the transport behind Swift's `Core.data(for:)`.
#[uniffi::export]
pub async fn http_send(method: String, url: String, headers: Vec<HttpHeader>, body: Option<Vec<u8>>, timeout_secs: f64) -> CoreResult<HttpExchange> {
    on_rt(async move {
        let mut rq = build(&method, &url, &headers, timeout_secs)?;
        if let Some(b) = body {
            rq = rq.body(b);
        }
        exchange(rq).await
    })
    .await
}

/// Like `http_send`, streaming the body from a file (uploads never load the
/// whole track into memory).
#[uniffi::export]
pub async fn http_upload_file(method: String, url: String, headers: Vec<HttpHeader>, file_path: String, timeout_secs: f64) -> CoreResult<HttpExchange> {
    on_rt(async move {
        let f = tokio::fs::File::open(&file_path).await?;
        let len = f.metadata().await?.len();
        let stream = tokio_util::io::ReaderStream::with_capacity(f, 256 * 1024);
        let rq = build(&method, &url, &headers, timeout_secs)?.header("Content-Length", len).body(reqwest::Body::wrap_stream(stream));
        exchange(rq).await
    })
    .await
}
