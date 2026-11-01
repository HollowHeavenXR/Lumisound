//! Download bookkeeping: the ledger (source id -> filename of the finished
//! file), in-flight claims (so two devices/tabs don't fetch the same track),
//! permanent-failure cool-offs, destination naming and format helpers.

use crate::store;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const LEDGER: &str = "download_ledger";
const IN_FLIGHT: &str = "download_inflight";
const FAILURES: &str = "download_failures";
const IN_FLIGHT_TTL: f64 = 5.0 * 60.0;

static LOCK: Mutex<()> = Mutex::new(());

#[derive(Serialize, Deserialize, Clone, Copy, Default)]
struct Failure {
    last_failed: f64,
    strikes: u32,
}

/// One-time import of the UserDefaults-era JSON blobs (ledger map, in-flight
/// map of unix seconds, failures map with Apple-epoch `lastFailed`).
#[uniffi::export]
pub fn downloads_import_legacy(ledger_json: Option<Vec<u8>>, failures_json: Option<Vec<u8>>) {
    let _g = LOCK.lock().unwrap();
    if !store::exists(LEDGER) {
        let m: HashMap<String, String> = ledger_json.and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        store::save(LEDGER, &m);
    }
    if !store::exists(FAILURES) {
        #[derive(Deserialize)]
        struct Legacy {
            #[serde(rename = "lastFailed")]
            last_failed: f64,
            strikes: u32,
        }
        let m: HashMap<String, Legacy> = failures_json.and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let conv: HashMap<String, Failure> = m.into_iter().map(|(k, v)| (k, Failure { last_failed: v.last_failed + store::APPLE_EPOCH, strikes: v.strikes })).collect();
        store::save(FAILURES, &conv);
    }
}

#[uniffi::export]
pub fn ledger_record(source_track_id: String, filename: String) {
    if source_track_id.is_empty() || filename.is_empty() {
        return;
    }
    let _g = LOCK.lock().unwrap();
    clear_failure(&source_track_id);
    let mut m: HashMap<String, String> = store::load(LEDGER);
    if m.get(&source_track_id) == Some(&filename) {
        return;
    }
    m.insert(source_track_id, filename);
    store::save(LEDGER, &m);
}

#[uniffi::export]
pub fn ledger_filename(source_track_id: String) -> Option<String> {
    let m: HashMap<String, String> = store::load(LEDGER);
    m.get(&source_track_id).cloned()
}

#[uniffi::export]
pub fn ledger_is_present(source_track_id: String, present_filenames: Vec<String>) -> bool {
    let m: HashMap<String, String> = store::load(LEDGER);
    m.get(&source_track_id).is_some_and(|f| present_filenames.contains(f))
}

/// Source ids whose ledgered file is still in the library.
#[uniffi::export]
pub fn ledger_present_ids(present_filenames: Vec<String>) -> Vec<String> {
    let present: HashSet<String> = present_filenames.into_iter().collect();
    let m: HashMap<String, String> = store::load(LEDGER);
    m.into_iter().filter(|(_, f)| present.contains(f)).map(|(k, _)| k).collect()
}

/// Claim a download; false if another claim is younger than 5 minutes.
#[uniffi::export]
pub fn ledger_begin(source_track_id: String) -> bool {
    if source_track_id.is_empty() {
        return true;
    }
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, f64> = store::load(IN_FLIGHT);
    let now = store::now();
    if m.get(&source_track_id).is_some_and(|t| now - t < IN_FLIGHT_TTL) {
        return false;
    }
    m.retain(|_, t| now - *t < IN_FLIGHT_TTL);
    m.insert(source_track_id, now);
    store::save(IN_FLIGHT, &m);
    true
}

#[uniffi::export]
pub fn ledger_end(source_track_id: String) {
    if source_track_id.is_empty() {
        return;
    }
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, f64> = store::load(IN_FLIGHT);
    if m.remove(&source_track_id).is_some() {
        store::save(IN_FLIGHT, &m);
    }
}

// ---- permanent failures ------------------------------------------------------------------------

fn cooloff(strikes: u32) -> f64 {
    const DAY: f64 = 86_400.0;
    match strikes {
        0 => 0.0,
        1 => DAY,
        2 => 3.0 * DAY,
        3 => 7.0 * DAY,
        _ => 30.0 * DAY,
    }
}

fn skip(f: &Failure, now: f64) -> bool {
    now - f.last_failed < cooloff(f.strikes)
}

fn clear_failure(id: &str) {
    let mut m: HashMap<String, Failure> = store::load(FAILURES);
    if m.remove(id).is_some() {
        store::save(FAILURES, &m);
    }
}

/// Inside its cool-off (1 day, 3 days, 1 week, then a month per strike).
#[uniffi::export]
pub fn failure_should_skip(source_track_id: String) -> bool {
    let m: HashMap<String, Failure> = store::load(FAILURES);
    m.get(&source_track_id).is_some_and(|f| skip(f, store::now()))
}

#[uniffi::export]
pub fn failure_record(source_track_id: String) {
    if source_track_id.is_empty() {
        return;
    }
    let _g = LOCK.lock().unwrap();
    let mut m: HashMap<String, Failure> = store::load(FAILURES);
    let now = store::now();
    let e = m.entry(source_track_id).or_default();
    e.strikes += 1;
    e.last_failed = now;
    let cutoff = now - cooloff(u32::MAX);
    m.retain(|_, f| f.last_failed > cutoff);
    store::save(FAILURES, &m);
}

#[uniffi::export]
pub fn failure_clear(source_track_id: String) {
    let _g = LOCK.lock().unwrap();
    clear_failure(&source_track_id);
}

#[uniffi::export]
pub fn failure_clear_all() {
    let _g = LOCK.lock().unwrap();
    store::save(FAILURES, &HashMap::<String, Failure>::new());
}

#[uniffi::export]
pub fn failure_suppressed_count(source_track_ids: Vec<String>) -> u32 {
    let m: HashMap<String, Failure> = store::load(FAILURES);
    let now = store::now();
    source_track_ids.iter().filter(|id| m.get(*id).is_some_and(|f| skip(f, now))).count() as u32
}

#[uniffi::export]
pub fn failure_suppressed_total() -> u32 {
    let m: HashMap<String, Failure> = store::load(FAILURES);
    let now = store::now();
    m.values().filter(|f| skip(f, now)).count() as u32
}

// ---- naming / formats ------------------------------------------------------------------------

/// Bridge download format -> file extension.
#[uniffi::export]
pub fn download_extension(format: String) -> String {
    match format.as_str() {
        "mp3" | "flac" | "opus" | "wav" => format,
        _ => "m4a".into(),
    }
}

#[uniffi::export]
pub fn content_type_extension(content_type: Option<String>) -> Option<String> {
    let base = content_type?.split(';').next()?.trim().to_lowercase();
    Some(
        match base.as_str() {
            "audio/mpeg" => "mp3",
            "audio/mp4" => "m4a",
            "audio/flac" => "flac",
            "audio/ogg" => "opus",
            "audio/wav" | "audio/x-wav" | "audio/wave" => "wav",
            "audio/webm" => "webm",
            _ => return None,
        }
        .into(),
    )
}

/// First free "<name> (n).ext" next to `preferred` (preferred itself if free).
#[uniffi::export]
pub fn unique_destination(preferred: String) -> String {
    let p = Path::new(&preferred);
    if !p.exists() {
        return preferred;
    }
    let dir = p.parent().map(Path::to_path_buf).unwrap_or_default();
    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("");
    let base = p.file_stem().and_then(|s| s.to_str()).unwrap_or("track");
    let mut n = 2;
    loop {
        let name = if ext.is_empty() { format!("{base} ({n})") } else { format!("{base} ({n}).{ext}") };
        let c: PathBuf = dir.join(name);
        if !c.exists() {
            return c.to_string_lossy().into_owned();
        }
        n += 1;
    }
}

/// Filesystem-safe filename from a title (no path separators/control chars,
/// trimmed, ≤ 240 UTF-8 bytes on a char boundary).
#[uniffi::export]
pub fn safe_filename(title: String) -> String {
    let cleaned: String = title
        .chars()
        .map(|c| if matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') || c.is_control() { '-' } else { c })
        .collect();
    let mut s = cleaned.trim().trim_matches('.').to_string();
    if s.is_empty() {
        s = "track".into();
    }
    let mut end = s.len().min(240);
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ledger_and_failures() {
        let d = std::env::temp_dir().join(format!("core-store-{}", uuid::Uuid::new_v4().simple()));
        store::core_configure(d.to_string_lossy().into_owned());
        downloads_import_legacy(Some(br#"{"youtube:a":"A.m4a"}"#.to_vec()), Some(br#"{"youtube:b":{"lastFailed":0,"strikes":1}}"#.to_vec()));
        assert_eq!(ledger_filename("youtube:a".into()).as_deref(), Some("A.m4a"));
        assert!(!failure_should_skip("youtube:b".into()));
        failure_record("youtube:c".into());
        assert!(failure_should_skip("youtube:c".into()));
        ledger_record("youtube:c".into(), "C.m4a".into());
        assert!(!failure_should_skip("youtube:c".into()));
        assert!(ledger_begin("x".into()) && !ledger_begin("x".into()));
        ledger_end("x".into());
        assert!(ledger_begin("x".into()));
        assert_eq!(ledger_present_ids(vec!["C.m4a".into()]), vec!["youtube:c".to_string()]);
        assert_eq!(safe_filename("a/b: c?".into()), "a-b- c-");
        let _ = std::fs::remove_dir_all(d);
    }
}

// ---- bridge download job: start -> poll -> fetch result ---------------------------------------

use crate::client::HttpHeader;
use futures_util::StreamExt;
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum JobError {
    #[error("timed out")]
    Timeout,
    #[error("not found")]
    NotFound { permanent: bool, detail: Option<String> },
    /// Transient (network, gateway, incomplete transfer) — worth retrying.
    #[error("{message}")]
    Retry { message: String },
    /// Content restriction etc. (bridge 422 detail, shown to the user).
    #[error("{detail}")]
    Unavailable { detail: String },
    #[error("HTTP {code}: {detail}")]
    Http { code: u16, detail: String },
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct JobResult {
    /// Downloaded file in `tmp_dir` (caller moves it into the library).
    pub file_path: String,
    pub content_type: Option<String>,
    pub bytes: u64,
    pub job_id: String,
    pub seconds: f64,
}

fn retry(m: impl Into<String>) -> JobError {
    JobError::Retry { message: m.into() }
}

fn with_job(start_url: &str, path: &str, job: &str) -> Option<String> {
    let mut u = url::Url::parse(start_url).ok()?;
    u.set_path(path);
    u.set_query(None);
    u.query_pairs_mut().append_pair("job_id", job);
    Some(u.to_string())
}

fn apply(mut rq: reqwest::RequestBuilder, headers: &[HttpHeader]) -> reqwest::RequestBuilder {
    for h in headers {
        rq = rq.header(&h.name, &h.value);
    }
    rq
}

/// Run one bridge download job (`POST|GET start_url` -> 202 {job_id}),
/// poll `/api/download/status` (0.4 s backoff to 3 s, 5 min cap), then
/// stream `/api/download/result` into `tmp_dir`, checking the byte count.
#[uniffi::export]
pub async fn bridge_download_job(method: String, start_url: String, headers: Vec<HttpHeader>, body: Option<Vec<u8>>, tmp_dir: String) -> Result<JobResult, JobError> {
    crate::on_rt(async move {
        let http = crate::client::http_client();
        let started = Instant::now();
        let m = reqwest::Method::from_bytes(method.to_uppercase().as_bytes()).map_err(|_| retry("bad method"))?;
        let mut rq = apply(http.request(m, &start_url).timeout(Duration::from_secs(30)), &headers);
        if let Some(b) = body {
            rq = rq.body(b);
        }
        let r = rq.send().await.map_err(|e| retry(format!("network error starting job: {e}")))?;
        match r.status().as_u16() {
            202 => {}
            408 => return Err(JobError::Timeout),
            404 => return Err(JobError::NotFound { permanent: false, detail: None }),
            502 | 503 | 504 | 524 => return Err(retry(format!("gateway error {}", r.status().as_u16()))),
            s => return Err(retry(format!("unexpected start status {s}"))),
        }
        let v: serde_json::Value = r.json().await.map_err(|_| retry("bad start payload"))?;
        let job = v["job_id"].as_str().ok_or_else(|| retry("no job_id"))?.to_string();
        let status_url = with_job(&start_url, "/api/download/status", &job).ok_or_else(|| retry("bad url"))?;
        let result_url = with_job(&start_url, "/api/download/result", &job).ok_or_else(|| retry("bad url"))?;
        let steps = [0.4, 0.6, 1.0, 1.5, 2.0, 2.5];
        let mut attempt = 0usize;
        let deadline = Instant::now() + Duration::from_secs(300);
        loop {
            if Instant::now() > deadline {
                return Err(retry("job poll timed out"));
            }
            let resp = match apply(http.get(&status_url).timeout(Duration::from_secs(30)), &headers).send().await {
                Ok(r) => r,
                Err(_) => {
                    tokio::time::sleep(Duration::from_secs(3)).await;
                    continue;
                }
            };
            if resp.status().as_u16() != 200 {
                return Err(retry(format!("status HTTP {}", resp.status().as_u16())));
            }
            let s: serde_json::Value = resp.json().await.map_err(|_| retry("bad status payload"))?;
            match s["status"].as_str() {
                Some("pending") => {
                    let d = steps.get(attempt).copied().unwrap_or(3.0);
                    attempt += 1;
                    tokio::time::sleep(Duration::from_secs_f64(d)).await;
                }
                Some("done") => break,
                Some("error") => {
                    let code = s["code"].as_u64().unwrap_or(500) as u16;
                    let detail = s["detail"].as_str().map(str::to_string);
                    return Err(match code {
                        408 => JobError::Timeout,
                        404 => JobError::NotFound { permanent: s["permanent"].as_bool() == Some(true), detail },
                        502 | 503 | 504 | 524 => retry(format!("job gateway error {code}")),
                        422 => JobError::Unavailable { detail: detail.unwrap_or_else(|| "This track can't be downloaded due to a YouTube content restriction.".into()) },
                        c => JobError::Http { code: c, detail: detail.unwrap_or_default() },
                    });
                }
                _ => return Err(retry("unexpected job status")),
            }
        }
        let r = apply(http.get(&result_url).timeout(Duration::from_secs(600)), &headers).send().await.map_err(|e| retry(format!("network error fetching result: {e}")))?;
        let code = r.status().as_u16();
        if code == 404 {
            return Err(JobError::NotFound { permanent: false, detail: Some("result already claimed".into()) });
        }
        if !(200..300).contains(&code) {
            return Err(retry(format!("HTTP {code} fetching result")));
        }
        let ct = r.headers().get("content-type").and_then(|v| v.to_str().ok()).map(str::to_string);
        let expected = r.content_length();
        let _ = tokio::fs::create_dir_all(&tmp_dir).await;
        let path = std::path::Path::new(&tmp_dir).join(format!("dl-{}.part", uuid::Uuid::new_v4().simple()));
        let mut f = tokio::fs::File::create(&path).await.map_err(|e| retry(e.to_string()))?;
        let mut n = 0u64;
        let mut stream = r.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let Ok(c) = chunk else {
                let _ = tokio::fs::remove_file(&path).await;
                return Err(retry("transfer interrupted"));
            };
            n += c.len() as u64;
            if f.write_all(&c).await.is_err() {
                let _ = tokio::fs::remove_file(&path).await;
                return Err(retry("write failed"));
            }
        }
        let _ = f.flush().await;
        if n == 0 || expected.is_some_and(|e| e != n) {
            let _ = tokio::fs::remove_file(&path).await;
            return Err(retry(format!("incomplete download ({n}/{} bytes)", expected.map(|e| e as i64).unwrap_or(-1))));
        }
        Ok(JobResult { file_path: path.to_string_lossy().into_owned(), content_type: ct, bytes: n, job_id: job, seconds: started.elapsed().as_secs_f64() })
    })
    .await
}
