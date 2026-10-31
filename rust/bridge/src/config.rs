//! Environment configuration. Names and defaults match the Python bridge so
//! the same compose environment works for both.

use std::env;

fn s(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn opt(key: &str) -> Option<String> {
    env::var(key).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

fn flag(key: &str, default: bool) -> bool {
    match env::var(key) {
        Ok(v) => matches!(v.as_str(), "1" | "true" | "True" | "yes"),
        Err(_) => default,
    }
}

fn num<T: std::str::FromStr>(key: &str, default: T) -> T {
    env::var(key).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(default)
}

#[derive(Clone, Debug)]
pub struct Config {
    pub host: String,
    pub port: u16,
    /// Python bridge that serves every route not ported yet.
    pub legacy_url: Option<String>,

    pub db_host: String,
    pub db_port: u16,
    pub db_user: String,
    pub db_password: String,
    pub db_name: String,
    pub db_pool_max: u32,

    pub jwt_secret: String,
    pub api_key: String,
    pub admin_token: String,

    pub ytdlp_cache_dir: String,
    pub ytdlp_cookies_file: String,
    pub ytdlp_user_cookies_dir: String,
    pub ytdlp_pot_provider_url: Option<String>,
    pub ytdlp_fallback_client: String,
    pub ytdlp_max: usize,
    pub ytdlp_safe: usize,
    pub transcode_max: usize,
    pub transcode_safe: usize,
    pub launch_spacing: f64,
    pub launch_spacing_max: f64,

    pub pending_downloads_dir: String,
    pub server_music_dir: Option<String>,
    pub user_music_dir: Option<String>,
    pub user_music_compression: bool,
    pub user_music_quota_bytes: i64,

    pub youtube_api_key: Option<String>,
    pub spotify_client_id: Option<String>,
    pub spotify_client_secret: Option<String>,
    pub apns_key_base64: Option<String>,
    pub apns_key_id: Option<String>,
    pub apns_team_id: Option<String>,
    pub apns_topic: String,
    pub apns_use_sandbox: bool,
    pub fcm_service_account_json_base64: Option<String>,
    pub bug_report_webhook_url: Option<String>,
    pub discord_oauth_client_id: Option<String>,
    pub discord_oauth_client_secret: Option<String>,
    pub discord_oauth_redirect_uri: Option<String>,
    pub github_releases_token: Option<String>,
    pub discord_rpc_default_client_id: Option<String>,
    pub discord_rpc_default_large_image: Option<String>,
    pub discord_rpc_default_small_image: Option<String>,
    pub giphy_api_key: Option<String>,
    pub gemini_api_key: Option<String>,
}

impl Config {
    pub fn from_env() -> Self {
        let jwt_secret = opt("IOS_JWT_SECRET").unwrap_or_else(|| {
            // Same fallback as auth.py: a secret persisted next to the app.
            let path = std::path::Path::new("/app/.bridge_jwt_secret");
            std::fs::read_to_string(path).map(|s| s.trim().to_string()).unwrap_or_else(|_| {
                let s = hex::encode(rand::random::<[u8; 32]>());
                let _ = std::fs::write(path, &s);
                s
            })
        });
        Self {
            host: s("HOST", "0.0.0.0"),
            port: num("PORT", 8002),
            legacy_url: opt("LEGACY_URL"),
            db_host: s("DB_HOST", "127.0.0.1"),
            db_port: num("DB_PORT", 5432),
            db_user: s("DB_USER", "botuser"),
            db_password: s("DB_PASSWORD", "bot_logins"),
            db_name: s("DB_NAME", "discord_music_gws"),
            db_pool_max: num("DB_POOL_MAX_SIZE", 16),
            jwt_secret,
            api_key: s("IOS_BRIDGE_API_KEY", ""),
            admin_token: s("ADMIN_TOKEN", ""),
            ytdlp_cache_dir: s("YTDLP_CACHE_DIR", "/app/.cache/yt-dlp"),
            ytdlp_cookies_file: s("YTDLP_COOKIES_FILE", "/app/cookies.txt"),
            ytdlp_user_cookies_dir: s("YTDLP_USER_COOKIES_DIR", "/app/.cache/yt-dlp/user-cookies"),
            ytdlp_pot_provider_url: opt("YTDLP_POT_PROVIDER_URL"),
            ytdlp_fallback_client: s("YTDLP_FALLBACK_CLIENT", "mweb"),
            ytdlp_max: num("YTDLP_MAX_CONCURRENT", 4),
            ytdlp_safe: num("YTDLP_SAFE_CONCURRENT", 2),
            transcode_max: num("YTDLP_MAX_TRANSCODE_CONCURRENT", 3),
            transcode_safe: num("YTDLP_SAFE_TRANSCODE_CONCURRENT", 2),
            launch_spacing: num("YTDLP_LAUNCH_SPACING_SECONDS", 1.5),
            launch_spacing_max: num("YTDLP_LAUNCH_SPACING_MAX_SECONDS", 30.0),
            pending_downloads_dir: s("PENDING_DOWNLOADS_DIR", "/tmp/lumisound_pending_downloads"),
            server_music_dir: opt("SERVER_MUSIC_DIR"),
            user_music_dir: opt("USER_MUSIC_DIR"),
            user_music_compression: flag("USER_MUSIC_COMPRESSION", false),
            user_music_quota_bytes: num("USER_MUSIC_QUOTA_BYTES", 0),
            youtube_api_key: opt("YOUTUBE_API_KEY"),
            spotify_client_id: opt("SPOTIFY_CLIENT_ID"),
            spotify_client_secret: opt("SPOTIFY_CLIENT_SECRET"),
            apns_key_base64: opt("APNS_KEY_BASE64"),
            apns_key_id: opt("APNS_KEY_ID"),
            apns_team_id: opt("APNS_TEAM_ID"),
            apns_topic: s("APNS_TOPIC", "com.lumisound.ios"),
            apns_use_sandbox: flag("APNS_USE_SANDBOX", true),
            fcm_service_account_json_base64: opt("FCM_SERVICE_ACCOUNT_JSON_BASE64"),
            bug_report_webhook_url: opt("BUG_REPORT_WEBHOOK_URL"),
            discord_oauth_client_id: opt("DISCORD_OAUTH_CLIENT_ID"),
            discord_oauth_client_secret: opt("DISCORD_OAUTH_CLIENT_SECRET"),
            discord_oauth_redirect_uri: opt("DISCORD_OAUTH_REDIRECT_URI"),
            github_releases_token: opt("GITHUB_RELEASES_TOKEN"),
            discord_rpc_default_client_id: opt("DISCORD_RPC_DEFAULT_CLIENT_ID"),
            discord_rpc_default_large_image: opt("DISCORD_RPC_DEFAULT_LARGE_IMAGE"),
            discord_rpc_default_small_image: opt("DISCORD_RPC_DEFAULT_SMALL_IMAGE"),
            giphy_api_key: opt("GIPHY_API_KEY"),
            gemini_api_key: opt("GEMINI_API_KEY"),
        }
    }
}
