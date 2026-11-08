//! yt-dlp wrapper. The extractor itself stays the upstream yt-dlp CLI (it
//! changes too often to re-implement); this module decides the arguments,
//! runs it as a child process under concurrency/memory/pacing limits and
//! parses its JSON and stderr.

use crate::cache::TtlCache;
use crate::config::Config;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};
use tokio::process::Command;
use tokio::sync::{Semaphore, SemaphorePermit};

const MEMORY_FLOOR_MB: f64 = 900.0;
const COOKIE_CACHE_TTL: Duration = Duration::from_secs(300);
const MIN_ACCOUNT_AGE_DAYS_FOR_GLOBAL_COOKIES: i64 = 15;
const RATE_LIMIT_MARKERS: &[&str] = &[
    "sign in to confirm you're not a bot",
    "sign in to confirm that you're not a bot",
    "http error 429",
    "too many requests",
    "this content isn't available, try again later",
];
const PERMANENT_FAILURE_MARKERS: &[&str] = &[
    "video unavailable",
    "video is unavailable",
    "private video",
    "this video is private",
    "removed by the uploader",
    "has been terminated",
    "no longer available",
    "video has been removed",
    "this video is no longer available",
    "does not exist",
    "unavailable in your country",
];
pub const ARIA2_ARGS: &[&str] = &[
    "--downloader",
    "aria2c",
    "--downloader-args",
    "aria2c:-x16 -s16 -j16 -k1M --file-allocation=none --console-log-level=warn --summary-interval=0 --retry-wait=1 --max-tries=3",
];
pub const STREAM_CLIENT_ARGS: &[&str] = &["--extractor-args", "youtube:player_client=web,default"];
pub const MUXED_ITAGS: &[&str] = &["17", "18", "22", "36", "43", "59"];

pub fn available_memory_mb() -> Option<f64> {
    let s = std::fs::read_to_string("/proc/meminfo").ok()?;
    let line = s.lines().find(|l| l.starts_with("MemAvailable:"))?;
    line.split_whitespace().nth(1)?.parse::<f64>().ok().map(|kb| kb / 1024.0)
}

/// Semaphore that also holds back slots above `safe` while the host is low
/// on memory (each yt-dlp + ffmpeg pair can use a few hundred MB).
pub struct AdaptiveLimiter {
    sem: Semaphore,
    safe: usize,
    in_use: AtomicUsize,
}

pub struct Slot<'a> {
    _permit: SemaphorePermit<'a>,
    in_use: &'a AtomicUsize,
}

impl Drop for Slot<'_> {
    fn drop(&mut self) {
        self.in_use.fetch_sub(1, Ordering::SeqCst);
    }
}

impl AdaptiveLimiter {
    pub fn new(max: usize, safe: usize) -> Self {
        let max = max.max(1);
        Self { sem: Semaphore::new(max), safe: safe.clamp(1, max), in_use: AtomicUsize::new(0) }
    }

    pub fn available(&self) -> usize {
        self.sem.available_permits()
    }

    pub async fn slot(&self) -> Slot<'_> {
        let permit = self.sem.acquire().await.expect("limiter closed");
        while self.in_use.load(Ordering::SeqCst) >= self.safe {
            match available_memory_mb() {
                Some(mb) if mb < MEMORY_FLOOR_MB => {
                    tracing::info!(
                        "concurrency held back: {mb:.0}MB available (floor {MEMORY_FLOOR_MB:.0}MB), {} in use",
                        self.in_use.load(Ordering::SeqCst)
                    );
                    tokio::time::sleep(Duration::from_secs(2)).await;
                }
                _ => break,
            }
        }
        self.in_use.fetch_add(1, Ordering::SeqCst);
        Slot { _permit: permit, in_use: &self.in_use }
    }
}

/// Spaces out yt-dlp launches; widens the gap 4x after YouTube rate-limits
/// us and relaxes it again after five quiet minutes.
pub struct LaunchPacer {
    base: f64,
    max: f64,
    inner: Mutex<PacerState>,
}

struct PacerState {
    next_at: Instant,
    interval: f64,
    penalised_at: Option<Instant>,
}

impl LaunchPacer {
    pub fn new(base: f64, max: f64) -> Self {
        Self { base, max, inner: Mutex::new(PacerState { next_at: Instant::now(), interval: base, penalised_at: None }) }
    }

    pub async fn wait(&self, floor: f64) -> Duration {
        let delay = {
            let mut s = self.inner.lock().unwrap();
            let now = Instant::now();
            if let Some(p) = s.penalised_at {
                if now.duration_since(p).as_secs_f64() > 300.0 {
                    s.interval = (s.interval / 2.0).max(self.base);
                    s.penalised_at = if s.interval <= self.base { None } else { Some(now) };
                }
            }
            let interval = s.interval.max(floor);
            let delay = s.next_at.saturating_duration_since(now);
            s.next_at = now + delay + Duration::from_secs_f64(interval);
            delay
        };
        if !delay.is_zero() {
            tokio::time::sleep(delay).await;
        }
        delay
    }

    pub fn penalise(&self, reason: &str) {
        let mut s = self.inner.lock().unwrap();
        s.interval = (s.interval.max(self.base) * 4.0).min(self.max);
        s.penalised_at = Some(Instant::now());
        tracing::warn!("yt-dlp launch spacing raised to {:.1}s after {reason}", s.interval);
    }

    pub fn interval(&self) -> f64 {
        self.inner.lock().unwrap().interval
    }
}

pub struct Output {
    pub status: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[derive(Debug)]
pub enum RunError {
    Timeout,
    Spawn(std::io::Error),
}

impl std::fmt::Display for RunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RunError::Timeout => write!(f, "timed out"),
            RunError::Spawn(e) => write!(f, "spawn failed: {e}"),
        }
    }
}

pub struct Ytdlp {
    pub cfg: Config,
    pub db: PgPool,
    pub limiter: AdaptiveLimiter,
    pub transcode: AdaptiveLimiter,
    pub pacer: LaunchPacer,
    network_args: Vec<String>,
    user_cookies: TtlCache<String, Option<String>>,
    account_age: TtlCache<String, Option<i64>>,
    cookie_pref: TtlCache<String, String>,
    written_cookie_hash: dashmap::DashMap<String, [u8; 32]>,
    global_copy: Mutex<Option<(std::time::SystemTime, u64)>>,
}

impl Ytdlp {
    pub fn network(&self) -> &[String] {
        &self.network_args
    }

    pub fn new(cfg: &Config, db: PgPool) -> Self {
        let mut network_args: Vec<String> = ["-4", "--socket-timeout", "10"].iter().map(|s| s.to_string()).collect();
        if let Some(pot) = &cfg.ytdlp_pot_provider_url {
            network_args.push("--extractor-args".into());
            network_args.push(format!("youtubepot-bgutilhttp:base_url={pot}"));
        }
        Self {
            limiter: AdaptiveLimiter::new(cfg.ytdlp_max, cfg.ytdlp_safe),
            transcode: AdaptiveLimiter::new(cfg.transcode_max, cfg.transcode_safe),
            pacer: LaunchPacer::new(cfg.launch_spacing, cfg.launch_spacing_max),
            network_args,
            user_cookies: TtlCache::new(COOKIE_CACHE_TTL, 10_000),
            account_age: TtlCache::new(COOKIE_CACHE_TTL, 10_000),
            cookie_pref: TtlCache::new(COOKIE_CACHE_TTL, 10_000),
            written_cookie_hash: dashmap::DashMap::new(),
            global_copy: Mutex::new(None),
            cfg: cfg.clone(),
            db,
        }
    }

    pub fn network_args(&self) -> &[String] {
        &self.network_args
    }

    pub fn cache_dir(&self) -> &str {
        &self.cfg.ytdlp_cache_dir
    }

    // ---- cookies ---------------------------------------------------------------------------

    fn global_available(&self) -> bool {
        std::fs::metadata(&self.cfg.ytdlp_cookies_file).map(|m| m.is_file() && m.len() > 0).unwrap_or(false)
    }

    /// yt-dlp rewrites its cookie jar on exit, and the shared jar is
    /// bind-mounted read-only, so yt-dlp gets a writable copy that is
    /// refreshed whenever the source changes.
    fn writable_global_cookies_path(&self) -> Option<String> {
        let src = Path::new(&self.cfg.ytdlp_cookies_file);
        let meta = std::fs::metadata(src).ok()?;
        if meta.len() == 0 {
            return None;
        }
        let cache_dir = Path::new(&self.cfg.ytdlp_cache_dir);
        let copy = cache_dir.join("global-cookies.txt");
        let stamp = cache_dir.join("global-cookies.source");
        let sig = (meta.modified().ok()?, meta.len());
        {
            let g = self.global_copy.lock().unwrap();
            if *g == Some(sig) && copy.exists() {
                return Some(copy.to_string_lossy().into_owned());
            }
        }
        let bytes = std::fs::read(src).ok()?;
        let hash = hex::encode(Sha256::digest(&bytes));
        let stale = std::fs::read_to_string(&stamp).map(|s| s.trim() != hash).unwrap_or(true) || !copy.exists();
        if stale {
            let r = std::fs::create_dir_all(cache_dir)
                .and_then(|_| std::fs::write(&copy, &bytes))
                .and_then(|_| std::fs::write(&stamp, &hash));
            match r {
                Ok(_) => tracing::info!("refreshed writable cookie copy from source ({} bytes)", bytes.len()),
                Err(e) => {
                    tracing::error!("failed to refresh writable global cookies copy: {e}");
                    return if copy.exists() { Some(self.cfg.ytdlp_cookies_file.clone()) } else { None };
                }
            }
        }
        *self.global_copy.lock().unwrap() = Some(sig);
        Some(copy.to_string_lossy().into_owned())
    }

    pub fn invalidate_user_cookies(&self, user_id: &str) {
        self.user_cookies.remove(&user_id.to_string());
        self.cookie_pref.remove(&user_id.to_string());
        self.written_cookie_hash.remove(user_id);
    }

    async fn user_cookies_text(&self, user_id: &str) -> Option<String> {
        let key = user_id.to_string();
        if let Some(v) = self.user_cookies.get(&key) {
            return v;
        }
        let text: Option<String> = sqlx::query_scalar("SELECT ytdlp_cookies FROM ios_user_settings WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(&self.db)
            .await
            .ok()
            .flatten()
            .flatten()
            .filter(|t: &String| !t.is_empty());
        self.user_cookies.set(key, text.clone());
        text
    }

    async fn user_cookies_file(&self, user_id: Option<&str>) -> Option<String> {
        let uid = user_id?;
        let text = self.user_cookies_text(uid).await?;
        let dir = PathBuf::from(&self.cfg.ytdlp_user_cookies_dir);
        let path = dir.join(format!("{uid}.txt"));
        let hash: [u8; 32] = Sha256::digest(text.as_bytes()).into();
        let unchanged = self.written_cookie_hash.get(uid).is_some_and(|h| *h == hash) && path.exists();
        if !unchanged {
            let _ = tokio::fs::create_dir_all(&dir).await;
            if tokio::fs::write(&path, text.as_bytes()).await.is_ok() {
                self.written_cookie_hash.insert(uid.to_string(), hash);
            }
        }
        Some(path.to_string_lossy().into_owned())
    }

    async fn account_age_days(&self, user_id: &str) -> Option<i64> {
        let key = user_id.to_string();
        if let Some(v) = self.account_age.get(&key) {
            return v;
        }
        let created: Option<chrono::NaiveDateTime> =
            sqlx::query_scalar("SELECT created_at FROM ios_users WHERE id = $1")
                .bind(user_id)
                .fetch_optional(&self.db)
                .await
                .ok()
                .flatten()
                .flatten();
        let age = created.map(|c| (chrono::Utc::now().naive_utc() - c).num_days());
        self.account_age.set(key, age);
        age
    }

    pub async fn cookie_fallback_preference(&self, user_id: &str) -> String {
        let key = user_id.to_string();
        if let Some(v) = self.cookie_pref.get(&key) {
            return v;
        }
        let pref: Option<String> =
            sqlx::query_scalar("SELECT cookie_fallback_preference FROM ios_user_settings WHERE user_id = $1")
                .bind(user_id)
                .fetch_optional(&self.db)
                .await
                .ok()
                .flatten()
                .flatten();
        let pref = match pref.as_deref() {
            Some(p @ ("auto" | "own_only" | "global_only")) => p.to_string(),
            _ => "auto".to_string(),
        };
        self.cookie_pref.set(key, pref.clone());
        pref
    }

    async fn may_use_global_cookies(&self, user_id: Option<&str>) -> bool {
        let Some(uid) = user_id else { return true };
        match self.account_age_days(uid).await {
            Some(d) if d >= MIN_ACCOUNT_AGE_DAYS_FOR_GLOBAL_COOKIES => {}
            _ => return false,
        }
        self.cookie_fallback_preference(uid).await != "own_only"
    }

    /// Cookie arguments for a request on behalf of `user_id`: the user's own
    /// uploaded jar, else the shared one (accounts 15+ days old that allow it).
    pub async fn cookie_args(&self, user_id: Option<&str>, force_global: bool) -> Vec<String> {
        let mut args = vec!["--extractor-args".to_string(), "youtubetab:skip=webpage".to_string()];
        let eligible = self.global_available() && self.may_use_global_cookies(user_id).await;
        let path = if force_global && eligible {
            self.writable_global_cookies_path()
        } else {
            let own = self.user_cookies_file(user_id).await;
            let pref = match user_id {
                Some(u) if eligible => self.cookie_fallback_preference(u).await,
                _ => "auto".to_string(),
            };
            if eligible && pref == "global_only" {
                self.writable_global_cookies_path()
            } else if own.is_some() {
                own
            } else if eligible {
                self.writable_global_cookies_path()
            } else {
                None
            }
        };
        if let Some(p) = path {
            args.push("--cookies".into());
            args.push(p);
        }
        args
    }

    pub async fn listing_args(&self, target: &str, source: &str, user_id: Option<&str>) -> Vec<String> {
        if source == "soundcloud" {
            return vec![target.into(), "--dump-json".into(), "--no-playlist".into()];
        }
        let mut a: Vec<String> = vec![
            target.into(),
            "--dump-json".into(),
            "--flat-playlist".into(),
            "--no-playlist".into(),
            "--cache-dir".into(),
            self.cfg.ytdlp_cache_dir.clone(),
        ];
        a.extend(self.cookie_args(user_id, false).await);
        a
    }

    // ---- process control -------------------------------------------------------------------

    /// Spawn with retries when the kernel refuses a new process (EAGAIN
    /// under thread/process pressure), widening the launch pacer each time.
    pub async fn spawn(&self, program: &str, args: &[String]) -> Result<tokio::process::Child, std::io::Error> {
        let delays = [0.5, 2.0, 5.0];
        let mut last = None;
        for (i, delay) in delays.iter().map(Some).chain(std::iter::once(None)).enumerate() {
            match Command::new(program)
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true)
                .spawn()
            {
                Ok(c) => return Ok(c),
                Err(e) if e.raw_os_error() == Some(11) => {
                    let Some(d) = delay else {
                        last = Some(e);
                        break;
                    };
                    if program == "yt-dlp" {
                        self.pacer.penalise(&format!("spawn refused with EAGAIN (attempt {}/4)", i + 1));
                    }
                    tracing::warn!("spawn of {program} refused with EAGAIN; retrying in {d:.1}s");
                    tokio::time::sleep(Duration::from_secs_f64(*d)).await;
                    last = Some(e);
                }
                Err(e) => return Err(e),
            }
        }
        tracing::error!("spawn of {program} still refused with EAGAIN after 4 attempts; giving up");
        Err(last.unwrap_or_else(|| std::io::Error::other("spawn failed")))
    }

    /// Run a command to completion, killing it on timeout.
    pub async fn run(&self, program: &str, args: &[String], timeout: Duration) -> Result<Output, RunError> {
        let child = self.spawn(program, args).await.map_err(RunError::Spawn)?;
        match tokio::time::timeout(timeout, child.wait_with_output()).await {
            Ok(Ok(o)) => Ok(Output { status: o.status.code(), stdout: o.stdout, stderr: o.stderr }),
            Ok(Err(e)) => Err(RunError::Spawn(e)),
            // Dropping the future drops the child, and kill_on_drop reaps it.
            Err(_) => Err(RunError::Timeout),
        }
    }

    /// `_run_ytdlp`: yt-dlp with the network args, under the limiter; one JSON
    /// object per stdout line.
    pub async fn run_json(&self, args: &[String], timeout: Duration) -> Result<Vec<Value>, RunError> {
        let mut full: Vec<String> = self.network_args.clone();
        full.extend_from_slice(args);
        tracing::info!("Running: yt-dlp {}", redact(&full));
        let out = {
            let _slot = self.limiter.slot().await;
            self.run("yt-dlp", &full, timeout).await?
        };
        if !out.stderr.is_empty() {
            self.flag_cookies_stale_if_needed(&out.stderr);
        }
        Ok(out
            .stdout
            .split(|b| *b == b'\n')
            .filter_map(|l| {
                let l = l.trim_ascii();
                if l.is_empty() { None } else { serde_json::from_slice(l).ok() }
            })
            .collect())
    }

    // ---- stderr classification -------------------------------------------------------------

    pub fn flag_cookies_stale_if_needed(&self, stderr: &[u8]) {
        let t = String::from_utf8_lossy(stderr).to_lowercase();
        if !t.contains("no longer valid") || !t.contains("cookie") {
            return;
        }
        let p = Path::new(&self.cfg.ytdlp_cache_dir).join(".cookies_stale");
        let _ = std::fs::create_dir_all(Path::new(&self.cfg.ytdlp_cache_dir));
        if let Err(e) = std::fs::write(&p, chrono::Utc::now().to_rfc3339()) {
            tracing::warn!("failed to write cookies-stale sentinel: {e}");
        }
    }

    pub fn penalise_if_rate_limited(&self, stderr: &[u8]) -> bool {
        let t = String::from_utf8_lossy(stderr).to_lowercase();
        for m in RATE_LIMIT_MARKERS {
            if t.contains(m) {
                self.pacer.penalise(&format!("yt-dlp reported: {m:?}"));
                return true;
            }
        }
        false
    }

    pub fn auth_failure_reason(&self, stderr: &[u8]) -> Option<String> {
        self.flag_cookies_stale_if_needed(stderr);
        let t = String::from_utf8_lossy(stderr).to_lowercase();
        let r = if t.contains("sign in to confirm") || t.contains("not a bot") {
            "YouTube is requiring sign-in to verify this isn't a bot. Upload your YouTube cookies in Settings to fix this."
        } else if t.contains("age-restricted") || (t.contains("age") && t.contains("restrict")) {
            "This video is age-restricted. Upload YouTube cookies from a logged-in, age-verified account in Settings to play it."
        } else if t.contains("private video") {
            "This video is private."
        } else if t.contains("sign in") && t.contains("login") {
            "This video requires you to be signed in. Upload your YouTube cookies in Settings."
        } else if t.contains("requested format is not available") || t.contains("no video formats found") {
            "YouTube didn't expose a compatible audio stream for this track right now. This is usually temporary — try again in a bit."
        } else {
            return None;
        };
        Some(r.to_string())
    }

    // ---- stream URL resolution -------------------------------------------------------------

    /// Direct media URL for `target_url`. One yt-dlp run with the preferred
    /// format and its fallbacks chained (`a/b/c`), instead of one run per
    /// format; a second run only if the first produced nothing for a
    /// non-permanent reason.
    pub async fn raw_url(&self, target_url: &str, format_flag: &str, user_id: Option<&str>) -> Result<(Option<String>, Option<String>), RunError> {
        let mut chain: Vec<&str> = Vec::new();
        for f in format_flag.split('/').chain(["bestaudio", "best"]) {
            if !chain.contains(&f) {
                chain.push(f);
            }
        }
        let selector = chain.join("/");
        let cookies = self.cookie_args(user_id, false).await;
        let start = Instant::now();
        let mut last_stderr = Vec::new();
        for attempt in 1..=2 {
            let mut args: Vec<String> = self.network_args.clone();
            args.extend(STREAM_CLIENT_ARGS.iter().map(|s| s.to_string()));
            args.extend(["-f".into(), selector.clone(), "--get-url".into(), "--no-playlist".into()]);
            args.extend(cookies.iter().cloned());
            args.push(target_url.into());
            tracing::info!("Running (raw): yt-dlp {}", redact(&args));
            let out = {
                let _slot = self.limiter.slot().await;
                match self.run("yt-dlp", &args, Duration::from_secs(15)).await {
                    Err(RunError::Timeout) => {
                        tracing::warn!("raw_url: yt-dlp --get-url timed out after {:.1}s for {target_url}", start.elapsed().as_secs_f64());
                        return Err(RunError::Timeout);
                    }
                    r => r?,
                }
            };
            if let Some(url) = String::from_utf8_lossy(&out.stdout).lines().map(str::trim).find(|l| l.starts_with("http")) {
                tracing::info!("raw_url: resolved in {:.2}s (attempt {attempt}) for {target_url}", start.elapsed().as_secs_f64());
                return Ok((Some(url.to_string()), None));
            }
            last_stderr = out.stderr;
            if is_permanent_failure(&last_stderr) || self.auth_failure_reason(&last_stderr).is_some() {
                break;
            }
        }
        tracing::error!(
            "raw_url: no stream URL for {target_url} in {:.2}s — stderr: {}",
            start.elapsed().as_secs_f64(),
            tail(&String::from_utf8_lossy(&last_stderr), 500)
        );
        let reason = self.auth_failure_reason(&last_stderr).or_else(|| is_permanent_failure(&last_stderr).then(|| generic_failure_summary(&last_stderr)));
        Ok((None, reason))
    }
}

pub fn is_permanent_failure(stderr: &[u8]) -> bool {
    let t = String::from_utf8_lossy(stderr).to_lowercase();
    if t.contains("sign in to confirm") || t.contains("not a bot") {
        return false;
    }
    PERMANENT_FAILURE_MARKERS.iter().any(|m| t.contains(m))
}

pub fn generic_failure_summary(stderr: &[u8]) -> String {
    let text = String::from_utf8_lossy(stderr);
    let text = text.trim();
    if text.is_empty() {
        return "Could not download track".into();
    }
    let errors: Vec<&str> = text.lines().map(str::trim).filter(|l| l.starts_with("ERROR:")).collect();
    let summary = errors.last().copied().unwrap_or_else(|| text.lines().last().unwrap_or("").trim());
    let summary = summary.strip_prefix("ERROR:").map(str::trim).unwrap_or(summary);
    if summary.is_empty() { "Could not download track".into() } else { summary.chars().take(300).collect() }
}

pub fn tail(s: &str, n: usize) -> String {
    let c: Vec<char> = s.chars().collect();
    c[c.len().saturating_sub(n)..].iter().collect()
}

/// Command line for logs, with cookie paths left in (they are not secret)
/// but nothing else changed.
fn redact(args: &[String]) -> String {
    args.join(" ")
}

pub fn format_flag(format: &str) -> &'static str {
    match format {
        "mp3" | "flac" | "wav" | "best" => "bestaudio/best",
        "opus" => "bestaudio[ext=webm]/bestaudio/best",
        _ => "bestaudio[ext=m4a]/bestaudio/best",
    }
}

/// yt-dlp args + expected extension for a download format.
pub fn download_format_args(format: &str) -> (Vec<&'static str>, &'static str) {
    match format {
        "mp3" => (vec!["-f", "bestaudio", "-x", "--audio-format", "mp3", "--audio-quality", "0"], "mp3"),
        "flac" => (vec!["-f", "bestaudio", "-x", "--audio-format", "flac", "--audio-quality", "0"], "flac"),
        "opus" => (vec!["-f", "bestaudio[ext=webm]/bestaudio", "-x", "--audio-format", "opus", "--audio-quality", "0"], "opus"),
        "wav" => (vec!["-f", "bestaudio", "-x", "--audio-format", "wav", "--audio-quality", "0"], "wav"),
        "best" => (vec!["-f", "bestaudio/best", "-x"], "m4a"),
        _ => (vec!["-f", "bestaudio[ext=m4a]/bestaudio/best"], "m4a"),
    }
}

pub fn source_from_url(url: &str) -> &'static str {
    if url.contains("soundcloud.com") {
        "soundcloud"
    } else if url.contains("bandcamp.com") {
        "bandcamp"
    } else {
        "youtube"
    }
}

// ---- track parsing ---------------------------------------------------------------------------

const TOPIC_SUFFIX: &str = " - Topic";

pub fn strip_topic_suffix(name: &str) -> String {
    let n = name.trim();
    n.strip_suffix(TOPIC_SUFFIX).map(|s| s.trim().to_string()).unwrap_or_else(|| n.to_string())
}

fn gs<'a>(e: &'a Map<String, Value>, k: &str) -> Option<&'a str> {
    e.get(k).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn truthy(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64() != Some(0.0),
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::Object(o)) => !o.is_empty(),
    }
}

fn pick_youtube_thumbnail(e: &Map<String, Value>, track_id: &str) -> String {
    let thumbs: Vec<&Map<String, Value>> =
        e.get("thumbnails").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_object).collect()).unwrap_or_default();
    let best = thumbs
        .iter()
        .filter(|t| gs(t, "url").is_some() && truthy(t.get("width")))
        .max_by(|a, b| {
            let key = |t: &Map<String, Value>| {
                (t.get("width").and_then(Value::as_f64).unwrap_or(0.0), t.get("preference").and_then(Value::as_f64).unwrap_or(0.0))
            };
            key(a).partial_cmp(&key(b)).unwrap_or(std::cmp::Ordering::Equal)
        });
    if let Some(b) = best {
        return gs(b, "url").unwrap_or_default().to_string();
    }
    if let Some(t) = gs(e, "thumbnail") {
        return t.to_string();
    }
    if let Some(last) = thumbs.last() {
        if let Some(u) = gs(last, "url") {
            return u.to_string();
        }
    }
    if !track_id.is_empty() {
        return format!("https://i.ytimg.com/vi/{track_id}/hqdefault.jpg");
    }
    String::new()
}

/// Split "Artist - Title" (also en/em dash) the way the Python regex
/// `^\s*(.+?)\s*[-–—]\s*(.+?)\s*$` did: shortest artist before the first dash.
fn split_artist_title(title: &str) -> Option<(String, String)> {
    let t = title.trim();
    for (i, ch) in t.char_indices() {
        if i == 0 {
            continue;
        }
        if matches!(ch, '-' | '–' | '—') {
            let a = t[..i].trim();
            let b = t[i + ch.len_utf8()..].trim();
            if !a.is_empty() && !b.is_empty() {
                return Some((a.to_string(), b.to_string()));
            }
        }
    }
    None
}

/// `_parse_track`: a yt-dlp (or Data API shaped) entry -> client track JSON.
pub fn parse_track(entry: &Value, source: &str) -> Value {
    let empty = Map::new();
    let e = entry.as_object().unwrap_or(&empty);
    let track_id = gs(e, "id").or_else(|| gs(e, "webpage_url_basename")).unwrap_or("").to_string();
    let title = gs(e, "track").or_else(|| gs(e, "title")).or_else(|| gs(e, "fulltitle")).unwrap_or("Unknown Title").to_string();
    let raw_channel = gs(e, "channel").or_else(|| gs(e, "uploader")).unwrap_or("");
    let is_topic = raw_channel.trim().ends_with(TOPIC_SUFFIX);
    let mut artist = gs(e, "artist")
        .or_else(|| gs(e, "uploader"))
        .or_else(|| gs(e, "uploader_id"))
        .or_else(|| gs(e, "channel"))
        .or_else(|| gs(e, "creator"))
        .unwrap_or("Unknown Artist")
        .to_string();
    if is_topic {
        artist = strip_topic_suffix(&artist);
    } else if gs(e, "artist").is_none() {
        if let Some((a, t)) = split_artist_title(&title) {
            if a.chars().count() <= 60 && t.chars().count() >= 2 {
                artist = a;
            }
        }
    }
    let duration = match e.get("duration") {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0) as i64,
        Some(Value::String(s)) => s.trim().parse::<f64>().map(|f| f as i64).unwrap_or(0),
        _ => 0,
    };
    let thumbnail = if source == "youtube" {
        pick_youtube_thumbnail(e, &track_id)
    } else {
        gs(e, "thumbnail")
            .map(str::to_string)
            .or_else(|| {
                e.get("thumbnails")
                    .and_then(Value::as_array)
                    .and_then(|a| a.last())
                    .and_then(|t| t.get("url"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_default()
    };
    let youtube_url = gs(e, "webpage_url")
        .or_else(|| gs(e, "original_url"))
        .map(str::to_string)
        .unwrap_or_else(|| if source == "youtube" { format!("https://youtube.com/watch?v={track_id}") } else { String::new() });
    json!({
        "id": track_id,
        "title": title,
        "artist": artist,
        "duration_seconds": duration,
        "thumbnail_url": thumbnail,
        "source": source,
        "youtube_url": youtube_url,
        "is_topic_channel": is_topic,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_artist_title() {
        let t = parse_track(&json!({"id": "x", "title": "Daft Punk - One More Time", "channel": "DaftPunkVEVO"}), "youtube");
        assert_eq!(t["artist"], "Daft Punk");
        let t = parse_track(&json!({"id": "x", "title": "Song", "channel": "Band - Topic"}), "youtube");
        assert_eq!(t["artist"], "Band");
        assert_eq!(t["is_topic_channel"], true);
        assert_eq!(t["thumbnail_url"], "https://i.ytimg.com/vi/x/hqdefault.jpg");
    }

    #[test]
    fn chain_dedups() {
        assert_eq!(format_flag("m4a"), "bestaudio[ext=m4a]/bestaudio/best");
    }
}
