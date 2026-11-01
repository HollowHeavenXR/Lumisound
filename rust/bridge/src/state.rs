use crate::auth::Keys;
use crate::cache::TtlCache;
use crate::config::Config;
use crate::notify::LiveHub;
use crate::probe::TagCache;
use crate::routes::media::{BatchJob, Job};
use crate::youtube::YouTube;
use crate::ytdlp::Ytdlp;
use dashmap::DashMap;
use serde_json::Value;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::{Duration, Instant};

#[derive(Clone)]
pub struct AppState(Arc<Inner>);

pub struct Inner {
    pub cfg: Config,
    pub db: PgPool,
    pub keys: Keys,
    /// token id -> session confirmed live until.
    pub session_cache: DashMap<String, Instant>,
    /// Shared outbound HTTP client (APIs, webhooks).
    pub http: reqwest::Client,
    /// Client for the legacy Python bridge: no redirects, no decompression.
    pub legacy: reqwest::Client,
    pub ytdlp_version: String,
    /// IPv4-only client for googlevideo (IPv6 egress gets 403s).
    pub cdn: reqwest::Client,
    pub ytdlp: Ytdlp,
    pub yt: YouTube,
    pub tags: TagCache,
    pub live: LiveHub,
    /// Shared secret for /internal/* calls from the legacy bridge.
    pub internal_token: String,
    pub search_cache: TtlCache<String, Value>,
    pub stream_urls: TtlCache<String, String>,
    pub stream_tickets: TtlCache<String, String>,
    pub inventory: TtlCache<String, Arc<HashSet<String>>>,
    pub download_jobs: DashMap<String, Job>,
    pub batch_jobs: DashMap<String, BatchJob>,
    pub download_push_at: DashMap<String, Instant>,
    pub last_pending_sweep: AtomicI64,
    pub motion_locks: DashMap<String, Arc<tokio::sync::Mutex<()>>>,
    pub motion_sem: tokio::sync::Semaphore,
    pub re_chosen_format: regex::Regex,
    pub auth_attempts: DashMap<String, Vec<Instant>>,
    pub release_cache: TtlCache<(), Value>,
    pub release_stale: std::sync::Mutex<Option<Value>>,
    /// Upload/backfill analysis runs (ffmpeg decodes) at once.
    pub analysis_sem: tokio::sync::Semaphore,
    pub storage_tier_sent: DashMap<String, f64>,
    pub taste_cache: TtlCache<String, Value>,
}

impl std::ops::Deref for AppState {
    type Target = Inner;
    fn deref(&self) -> &Inner {
        &self.0
    }
}

impl AppState {
    pub async fn new(cfg: Config) -> anyhow::Result<Self> {
        let db = crate::db::connect(&cfg).await?;
        if let Err(e) = crate::db::ensure_helpers(&db).await {
            tracing::error!("could not install SQL helpers: {e}");
        }
        let http = reqwest::Client::builder()
            .user_agent("Lumisound/2.0 (+https://github.com/HollowHeavenXR/Lumisound)")
            .connect_timeout(std::time::Duration::from_secs(10))
            .timeout(std::time::Duration::from_secs(30))
            .pool_idle_timeout(std::time::Duration::from_secs(90))
            .build()?;
        let legacy = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .pool_max_idle_per_host(64)
            .tcp_nodelay(true)
            .build()?;
        let ytdlp_version = tokio::process::Command::new("yt-dlp")
            .arg("--version")
            .output()
            .await
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_else(|| "unknown".into());
        let cdn = reqwest::Client::builder()
            .local_address(std::net::IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED))
            .connect_timeout(Duration::from_secs(10))
            .tcp_nodelay(true)
            .pool_max_idle_per_host(32)
            .build()?;
        let tags_path = match &cfg.server_music_dir {
            Some(d) => format!("{d}/.lumisound_ffprobe_cache.json"),
            None => std::env::temp_dir().join("lumisound_ffprobe_cache.json").to_string_lossy().into_owned(),
        };
        let internal_token = hex::encode(Sha256::digest(format!("{}|live-push", cfg.jwt_secret).as_bytes()));
        Ok(AppState(Arc::new(Inner {
            keys: Keys::new(&cfg.jwt_secret),
            ytdlp: Ytdlp::new(&cfg, db.clone()),
            yt: YouTube::new(http.clone()),
            tags: TagCache::load(tags_path),
            live: LiveHub::default(),
            internal_token,
            search_cache: TtlCache::new(Duration::from_secs(3600), 500),
            stream_urls: TtlCache::new(Duration::from_secs(5 * 3600), 20_000),
            stream_tickets: TtlCache::new(Duration::from_secs(6 * 3600), 5000),
            inventory: TtlCache::new(Duration::from_secs(30), 5000),
            download_jobs: DashMap::new(),
            batch_jobs: DashMap::new(),
            download_push_at: DashMap::new(),
            last_pending_sweep: AtomicI64::new(0),
            motion_locks: DashMap::new(),
            motion_sem: tokio::sync::Semaphore::new(2),
            re_chosen_format: regex::Regex::new(r"Downloading \d+ format\(s\): ([0-9+]+)").unwrap(),
            auth_attempts: DashMap::new(),
            release_cache: TtlCache::new(Duration::from_secs(300), 2),
            release_stale: std::sync::Mutex::new(None),
            analysis_sem: tokio::sync::Semaphore::new(3),
            storage_tier_sent: DashMap::new(),
            taste_cache: TtlCache::new(Duration::from_secs(3600), 5000),
            cdn,
            cfg,
            db,
            session_cache: DashMap::new(),
            http,
            legacy,
            ytdlp_version,
        })))
    }

    /// Background loops that are already ported. The legacy bridge still
    /// runs the rest until their route groups move over.
    pub fn spawn_background(&self) {
        crate::background::spawn_all(self);
        let st = self.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(300));
            loop {
                tick.tick().await;
                let now = Instant::now();
                st.session_cache.retain(|_, until| *until > now);
                st.stream_tickets.sweep();
                st.stream_urls.sweep();
                st.auth_attempts.retain(|_, v| v.iter().any(|t| now.duration_since(*t) < Duration::from_secs(60)));
            }
        });
    }
}
