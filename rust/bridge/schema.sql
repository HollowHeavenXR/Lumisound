CREATE TABLE IF NOT EXISTS ios_users (
    id VARCHAR(36) PRIMARY KEY,
    username VARCHAR(255) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    display_name VARCHAR(255),
    avatar_url TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login TIMESTAMP NULL,
    is_active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS ios_user_sessions (
    token_id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    device_name VARCHAR(255),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_user_sessions_idx_user_id ON ios_user_sessions (user_id);

CREATE TABLE IF NOT EXISTS ios_user_playlists (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_user_playlists_idx_user_id ON ios_user_playlists (user_id);

CREATE TABLE IF NOT EXISTS ios_playlist_tracks (
    id VARCHAR(36) PRIMARY KEY,
    playlist_id VARCHAR(36) NOT NULL,
    track_url TEXT,
    local_song_id VARCHAR(255),
    title TEXT NOT NULL,
    artist TEXT,
    album TEXT,
    duration_seconds INT DEFAULT 0,
    position INT DEFAULT 0,
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (playlist_id) REFERENCES ios_user_playlists(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_playlist_tracks_idx_playlist ON ios_playlist_tracks (playlist_id);

CREATE TABLE IF NOT EXISTS ios_user_favorites (
    user_id VARCHAR(36) NOT NULL,
    song_id VARCHAR(255) NOT NULL,
    title TEXT,
    artist TEXT,
    album TEXT,
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, song_id),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ios_play_history (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    track_url TEXT,
    local_song_id VARCHAR(255),
    title TEXT NOT NULL,
    artist TEXT,
    played_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    listen_seconds INT DEFAULT 0,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_play_history_idx_user_played ON ios_play_history (user_id, played_at);

CREATE TABLE IF NOT EXISTS ios_user_settings (
    user_id VARCHAR(36) PRIMARY KEY,
    audio_settings_json TEXT,
    theme_color VARCHAR(7) DEFAULT '#EC4079',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Profile extensions: avatar and DOB (DOB immutable once set without admin)
ALTER TABLE ios_users ADD COLUMN IF NOT EXISTS date_of_birth DATE NULL;
ALTER TABLE ios_users ADD COLUMN IF NOT EXISTS avatar_data BYTEA NULL;

-- Per-track audio settings overrides, stored as a JSON map of song id -> AudioSettings.
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS track_audio_settings_json TEXT;

-- User library tracking: what songs the user has played/imported
CREATE TABLE IF NOT EXISTS ios_user_library (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    song_id VARCHAR(255) NOT NULL,
    title TEXT NOT NULL,
    artist TEXT,
    album TEXT,
    source VARCHAR(20) DEFAULT 'local',  -- 'local', 'youtube', 'soundcloud', 'apple_music'
    play_count INT DEFAULT 0,
    skip_count INT DEFAULT 0,
    last_played TIMESTAMP NULL,
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT user_song UNIQUE (user_id, song_id),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Expanded settings (audio + visual preferences)
CREATE TABLE IF NOT EXISTS ios_user_settings_expanded (
    user_id VARCHAR(36) PRIMARY KEY,
    audio_settings_json TEXT,
    theme_color VARCHAR(7) DEFAULT '#EC4079',
    vinyl_disc_enabled BOOLEAN DEFAULT TRUE,
    show_queue_preview BOOLEAN DEFAULT TRUE,
    songs_per_row INT DEFAULT 1,
    albums_per_row INT DEFAULT 2,
    bg_animation VARCHAR(20) DEFAULT 'fade',
    bg_opacity FLOAT DEFAULT 0.35,
    preferred_audio_format VARCHAR(10) DEFAULT 'm4a',
    download_path TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Per-user music upload audit log (actual files live on disk in USER_MUSIC_DIR)
CREATE TABLE IF NOT EXISTS ios_user_music_uploads (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    filename TEXT NOT NULL,
    folder VARCHAR(255) DEFAULT '',
    file_size_bytes INT DEFAULT 0,
    uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_user_music_uploads_idx_user_uploads ON ios_user_music_uploads (user_id, uploaded_at);

-- Rich metadata for uploaded user music files (keyed by SHA-256 of file content)
CREATE TABLE IF NOT EXISTS ios_user_music_metadata (
  id VARCHAR(64) PRIMARY KEY,
  user_id VARCHAR(36) NOT NULL,
  filename VARCHAR(255) NOT NULL,
  original_filename VARCHAR(255),
  title VARCHAR(255),
  artist VARCHAR(255),
  album VARCHAR(255),
  genre VARCHAR(100),
  year VARCHAR(10),
  duration_seconds FLOAT,
  file_size_bytes BIGINT,
  bitrate INT,
  sample_rate INT,
  mime_type VARCHAR(50),
  has_artwork BOOLEAN DEFAULT FALSE,
  uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_user_music_metadata_idx_user_id ON ios_user_music_metadata (user_id);

-- `filename` above is only ever the bare basename (see upload_user_music's
-- `safe_name`), but the actual on-disk location used by GET /user/music/stream
-- can include a subfolder (`folder` param at upload time) — the two only
-- coincide for root-level uploads. Any feature that needs to turn a
-- ios_user_music_metadata row back into a playable stream URL (e.g. the
-- weekly mix, 2026-07-19) needs the real relative path, not just the
-- filename. NULL for rows uploaded before this column existed; backfilled
-- automatically the next time that same file is (re-)uploaded.
ALTER TABLE ios_user_music_metadata ADD COLUMN IF NOT EXISTS relative_path VARCHAR(500) NULL;

-- Per-user gallery images (cloud-synced)
CREATE TABLE IF NOT EXISTS ios_user_gallery_images (
  id VARCHAR(36) PRIMARY KEY DEFAULT gen_random_uuid()::text,
  user_id VARCHAR(36) NOT NULL,
  filename VARCHAR(255) NOT NULL,
  display_order INT DEFAULT 0,
  uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_user_gallery_images_idx_user_id ON ios_user_gallery_images (user_id);

-- iOS client telemetry / background log ingestion
CREATE TABLE IF NOT EXISTS ios_app_logs (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    level VARCHAR(10),
    category VARCHAR(30),
    message TEXT,
    file VARCHAR(100),
    line INT,
    timestamp TIMESTAMP NULL,
    extra JSON,
    device_model VARCHAR(50) NULL,
    os_version VARCHAR(20) NULL,
    app_version VARCHAR(20) NULL,
    user_id VARCHAR(36) NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS ios_app_logs_idx_level ON ios_app_logs (level);
CREATE INDEX IF NOT EXISTS ios_app_logs_idx_created ON ios_app_logs (created_at);
CREATE INDEX IF NOT EXISTS ios_app_logs_idx_user ON ios_app_logs (user_id);
-- `timestamp` (the client's own capture-time, now millisecond-precision —
-- see AppLogger.preciseISO8601Now()) is what queries should actually sort/
-- filter by for a true causal reconstruction of events — `created_at` is
-- only WHEN the batch upload happened to land server-side (client batches
-- + flushes every 30s), which can trail the real event by up to that whole
-- window and collapses a burst of real events into one insert-time cluster.
-- Only `created_at` had an index before, silently steering every ad-hoc
-- debugging query onto the wrong column purely because it was the fast one.
CREATE INDEX IF NOT EXISTS ios_app_logs_idx_timestamp ON ios_app_logs (timestamp);
-- Feature: full-log admin audit browser (GET /admin/api/logs) — previously
-- only level='error' rows were ever queryable via the dashboard
-- (/admin/api/errors); auditing needs to filter by category too (e.g. "show
-- me every 'account'/'admin' event for this user"), which had no index.
CREATE INDEX IF NOT EXISTS ios_app_logs_idx_category ON ios_app_logs (category);
ALTER TABLE ios_app_logs ADD COLUMN IF NOT EXISTS device_model VARCHAR(50) NULL;
ALTER TABLE ios_app_logs ADD COLUMN IF NOT EXISTS os_version VARCHAR(20) NULL;
ALTER TABLE ios_app_logs ADD COLUMN IF NOT EXISTS app_version VARCHAR(20) NULL;
ALTER TABLE ios_app_logs ADD COLUMN IF NOT EXISTS user_id VARCHAR(36) NULL;

-- Feature: advanced usage/event logging (2026-08-16) — "timestamps, hour
-- stamps, and what day" as genuinely queryable dimensions, not just buried
-- inside the `timestamp` string.
--
-- REVERTED same day: a first attempt used two GENERATED ALWAYS ... STORED
-- columns (log_hour/log_day_of_week). Postgres has no "virtual" generated
-- column option (unlike MySQL) — STORED is the only kind available, and
-- adding one to an EXISTING table requires rewriting every row to backfill
-- its computed value. ios_app_logs is large enough (extensive logging,
-- short flush intervals) that this rewrite exceeded the bridge's DB query
-- timeout during startup migration, crash-looping the whole service.
-- log_hour/log_day_of_week are computed via plain EXTRACT() at query time
-- instead — e.g. "SELECT EXTRACT(HOUR FROM timestamp), EXTRACT(DOW FROM
-- timestamp) FROM ios_app_logs WHERE ..." — a small per-query cost instead
-- of a large one-time table rewrite risk. The existing `timestamp` index
-- (ios_app_logs_idx_timestamp, above) already makes range/bucket queries
-- against it fast without needing dedicated hour/day-of-week columns.

-- Collaborative playlist sharing (snapshot-based, bridge side)
CREATE TABLE IF NOT EXISTS ios_shared_playlists (
  id VARCHAR(36) PRIMARY KEY DEFAULT gen_random_uuid()::text,
  playlist_id VARCHAR(36) NOT NULL,
  owner_user_id VARCHAR(36) NOT NULL,
  share_token VARCHAR(36) UNIQUE NOT NULL,
  playlist_data JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  is_active BOOLEAN DEFAULT TRUE,
  FOREIGN KEY (owner_user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- In-app bug reports submitted from Settings → Help & Feature Guide → Report a Bug.
-- user_id is nullable since the app is usable without an account.
CREATE TABLE IF NOT EXISTS ios_bug_reports (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NULL,
    category VARCHAR(30) DEFAULT 'other',
    description TEXT NOT NULL,
    contact_email VARCHAR(255),
    app_version VARCHAR(20),
    device_info VARCHAR(255),
    recent_logs TEXT,
    status VARCHAR(20) DEFAULT 'open',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS ios_bug_reports_idx_status ON ios_bug_reports (status);
CREATE INDEX IF NOT EXISTS ios_bug_reports_idx_created ON ios_bug_reports (created_at);

-- Opt-in flag for the public listening activity / discovery feature.
-- When TRUE, this user's recent plays (song title/artist only — never file
-- contents or URLs) are visible to other signed-in users via GET /social/*.
ALTER TABLE ios_users ADD COLUMN IF NOT EXISTS share_listening_activity BOOLEAN DEFAULT FALSE;

-- Opt-in flag for AI-assisted suggestions (see ios-bridge/intelligence.py).
-- When TRUE, this user's track titles/artists/genres may be sent to
-- Anthropic's API to improve metadata/EQ/duplicate/mix decisions that
-- otherwise fall back to the existing rule-based heuristics. Off by default —
-- this is the first feature in the app that sends track data to a
-- third-party API.
ALTER TABLE ios_users ADD COLUMN IF NOT EXISTS ai_assisted_suggestions BOOLEAN DEFAULT FALSE;

-- Per-user snapshots of sync data (favorites, playlists, settings), taken
-- automatically before any operation that overwrites that data server-side
-- (notably POST /user/sync, which replaces all favorites/playlists in one
-- shot). Lets a user recover if a bad push from a buggy/offline client wipes
-- their server-side library. Pruned to the most recent N per user.
CREATE TABLE IF NOT EXISTS ios_user_backups (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    reason VARCHAR(30) NOT NULL,
    snapshot_json TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_user_backups_idx_user_created ON ios_user_backups (user_id, created_at);

-- Per-user audit log of sync activity (push/pull/restore), for diagnosing
-- "where did my data go" reports without digging through ios_app_logs.
CREATE TABLE IF NOT EXISTS ios_sync_log (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    action VARCHAR(20) NOT NULL,
    details VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_sync_log_idx_user_created ON ios_sync_log (user_id, created_at);

-- Fix playlist_id column type in ios_shared_playlists (was INT, must be VARCHAR for UUID strings).
-- Must run after the CREATE TABLE above — on a fresh database this ALTER previously executed
-- before the table existed, causing init_db() to throw "table doesn't exist", roll back
-- (a no-op since DDL auto-commits in MySQL), and crash the bridge on startup before
-- ios_app_logs/ios_shared_playlists were ever created.
ALTER TABLE ios_shared_playlists ALTER COLUMN playlist_id TYPE VARCHAR(36);
ALTER TABLE ios_shared_playlists ALTER COLUMN playlist_id SET DEFAULT '';
ALTER TABLE ios_shared_playlists ALTER COLUMN playlist_id SET NOT NULL;

-- ---------------------------------------------------------------------------
-- 10 new server-side features
-- ---------------------------------------------------------------------------

-- Feature: cross-device "continue listening" — last playback position per user
CREATE TABLE IF NOT EXISTS ios_playback_state (
    user_id VARCHAR(36) PRIMARY KEY,
    song_id VARCHAR(255),
    title TEXT,
    artist TEXT,
    track_url TEXT,
    source VARCHAR(20),
    position_seconds FLOAT DEFAULT 0,
    duration_seconds FLOAT DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: local Discord Rich Presence daemon needs to distinguish
-- playing vs. paused (a stale "now playing" row alone isn't enough).
ALTER TABLE ios_playback_state ADD COLUMN IF NOT EXISTS is_playing BOOLEAN DEFAULT TRUE;

-- Feature: surface the current track's BPM/tempo (from on-device analysis or
-- embedded tags) to other surfaces — widget "Continue Listening" and the local
-- Discord Rich Presence daemon, which can show it in the activity details line.
ALTER TABLE ios_playback_state ADD COLUMN IF NOT EXISTS bpm FLOAT NULL;

-- Feature: per-track artwork for the local Discord Rich Presence daemon's
-- large_image asset (see build_activity in lumisound_discord_rpc.py) — lets
-- the "Listening to X by Y" activity show the actual track thumbnail instead
-- of a single static image for every track.
ALTER TABLE ios_playback_state ADD COLUMN IF NOT EXISTS artwork_url TEXT NULL;

-- Feature: server-side loudness normalization (ReplayGain-style)
ALTER TABLE ios_user_music_metadata ADD COLUMN IF NOT EXISTS loudness_lufs FLOAT NULL;

-- Feature: scheduled playlist refresh — track a source URL per playlist so the
-- bridge can periodically re-resolve it and flag newly-added tracks.
ALTER TABLE ios_user_playlists ADD COLUMN IF NOT EXISTS source_url TEXT NULL;
ALTER TABLE ios_user_playlists ADD COLUMN IF NOT EXISTS source_checked_at TIMESTAMP NULL;
ALTER TABLE ios_user_playlists ADD COLUMN IF NOT EXISTS source_new_count INT DEFAULT 0;

-- Feature: shared listening rooms — host broadcasts current track/position,
-- guests poll for state.
CREATE TABLE IF NOT EXISTS ios_listen_rooms (
    id VARCHAR(36) PRIMARY KEY,
    host_user_id VARCHAR(36) NOT NULL,
    room_code VARCHAR(8) UNIQUE NOT NULL,
    track_url TEXT,
    title TEXT,
    artist TEXT,
    position_seconds FLOAT DEFAULT 0,
    is_playing BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (host_user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: Sync My Devices — reuses the Shared Listening Room mechanism
-- (same table, same /rooms/{code} GET/PUT, same drift-corrected position
-- sync) for a single account's own devices rather than SharePlay (which
-- needs an active FaceTime/Messages call, wrong fit for "my iPad in
-- another room"). Flags a room as self-only so other devices on the same
-- account can auto-discover and silently auto-join it (see
-- /user/device-sync/active) without a room code ever being shown.
ALTER TABLE ios_listen_rooms ADD COLUMN IF NOT EXISTS is_device_sync BOOLEAN DEFAULT FALSE;

-- ---------------------------------------------------------------------------
-- 10 more server-side features + Discord webhook integration
-- ---------------------------------------------------------------------------

-- Feature: artist/channel subscriptions — bridge periodically re-resolves
-- channel_url and compares against last_video_id to detect new uploads.
CREATE TABLE IF NOT EXISTS ios_artist_subscriptions (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    channel_url TEXT NOT NULL,
    channel_name VARCHAR(255),
    last_video_id VARCHAR(64),
    last_checked_at TIMESTAMP NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_artist_subscriptions_idx_user ON ios_artist_subscriptions (user_id);

-- ---------------------------------------------------------------------------
-- Subscriptions expansion (Feature: subscriptions-expansion) — additive
-- columns/tables on top of ios_artist_subscriptions above. Adds: per-
-- subscription auto-download (+ destination folder) mirroring tracked
-- playlists' own auto-download, per-subscription notification muting,
-- free-text categories for grouping, a persisted cross-subscription "New
-- Releases" feed (so it survives across sessions and captures uploads found
-- by the background polling loop too, not just on-demand "Check"), and an
-- upload-history log used to derive an "uploads ~weekly" style insight and
-- flag inactive/stale subscriptions.
-- ---------------------------------------------------------------------------

ALTER TABLE ios_artist_subscriptions ADD COLUMN IF NOT EXISTS auto_download BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE ios_artist_subscriptions ADD COLUMN IF NOT EXISTS destination_folder VARCHAR(255) NULL;
ALTER TABLE ios_artist_subscriptions ADD COLUMN IF NOT EXISTS notifications_muted BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE ios_artist_subscriptions ADD COLUMN IF NOT EXISTS category VARCHAR(64) NULL;

-- Every new upload discovered for any subscription (on-demand "Check" AND
-- the periodic background polling loop) gets a row here, giving the client
-- an aggregated "New Releases" feed across all followed channels in one
-- list instead of checking each channel individually.
CREATE TABLE IF NOT EXISTS ios_subscription_feed (
    id VARCHAR(36) PRIMARY KEY,
    subscription_id VARCHAR(36) NOT NULL,
    user_id VARCHAR(36) NOT NULL,
    track_json TEXT NOT NULL,
    discovered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_read BOOLEAN NOT NULL DEFAULT FALSE,
    FOREIGN KEY (subscription_id) REFERENCES ios_artist_subscriptions(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_subscription_feed_idx_user_discovered ON ios_subscription_feed (user_id, discovered_at);
CREATE INDEX IF NOT EXISTS ios_subscription_feed_idx_subscription ON ios_subscription_feed (subscription_id);

-- One row per newly-discovered video, kept even after the feed row above
-- might be dismissed/pruned — used to compute an average inter-upload gap
-- ("uploads ~weekly") and to detect subscriptions that have gone quiet.
CREATE TABLE IF NOT EXISTS ios_subscription_upload_history (
    id VARCHAR(36) PRIMARY KEY,
    subscription_id VARCHAR(36) NOT NULL,
    video_id VARCHAR(64) NOT NULL,
    discovered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (subscription_id) REFERENCES ios_artist_subscriptions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_subscription_upload_history_idx_subscription_discovered ON ios_subscription_upload_history (subscription_id, discovered_at);

-- Feature: collaborative playlists — additional users granted editor/viewer
-- access to a playlist they don't own.
CREATE TABLE IF NOT EXISTS ios_playlist_collaborators (
    playlist_id VARCHAR(36) NOT NULL,
    user_id VARCHAR(36) NOT NULL,
    role VARCHAR(10) NOT NULL DEFAULT 'editor',
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (playlist_id, user_id),
    FOREIGN KEY (playlist_id) REFERENCES ios_user_playlists(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: persistent server-side "up next" queue, independent of
-- ios_playback_state (which only tracks the current track/position).
CREATE TABLE IF NOT EXISTS ios_user_queue (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    position INT NOT NULL DEFAULT 0,
    local_song_id VARCHAR(255),
    track_url TEXT,
    title TEXT NOT NULL,
    artist TEXT,
    album TEXT,
    duration_seconds INT DEFAULT 0,
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_user_queue_idx_user_position ON ios_user_queue (user_id, position);

-- Feature: scrobbling to Last.fm / ListenBrainz
CREATE TABLE IF NOT EXISTS ios_scrobble_links (
    user_id VARCHAR(36) PRIMARY KEY,
    lastfm_session_key VARCHAR(64) NULL,
    lastfm_username VARCHAR(255) NULL,
    listenbrainz_token VARCHAR(64) NULL,
    enabled BOOLEAN DEFAULT TRUE,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: BPM analysis alongside the existing loudness pass
ALTER TABLE ios_user_music_metadata ADD COLUMN IF NOT EXISTS bpm FLOAT NULL;

-- Feature: search autocomplete / trending searches
CREATE TABLE IF NOT EXISTS ios_search_log (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    user_id VARCHAR(36) NULL,
    query VARCHAR(255) NOT NULL,
    source VARCHAR(20) DEFAULT 'youtube',
    searched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS ios_search_log_idx_query ON ios_search_log (query);
CREATE INDEX IF NOT EXISTS ios_search_log_idx_searched ON ios_search_log (searched_at);

-- Feature: playlist folders/tags for organization
ALTER TABLE ios_user_playlists ADD COLUMN IF NOT EXISTS folder VARCHAR(255) NULL;
ALTER TABLE ios_user_playlists ADD COLUMN IF NOT EXISTS tags_json TEXT NULL;

-- Feature: push notifications — registered device tokens + an in-app
-- notification feed (room invites, subscription uploads, collaborator adds).
CREATE TABLE IF NOT EXISTS ios_push_tokens (
    user_id VARCHAR(36) NOT NULL,
    device_token VARCHAR(255) NOT NULL,
    platform VARCHAR(10) DEFAULT 'ios',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, device_token),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ios_notifications (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    type VARCHAR(30) NOT NULL,
    title VARCHAR(255) NOT NULL,
    body TEXT,
    data_json TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    read_at TIMESTAMP NULL,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_notifications_idx_user_created ON ios_notifications (user_id, created_at);

-- Per-user YouTube Data API v3 key, used by /api/resolve to enumerate full
-- YouTube playlists via playlistItems.list (bypassing yt-dlp's ~205-entry
-- flat-playlist cap). Falls back to the server-wide YOUTUBE_API_KEY env var
-- when a user hasn't set their own.
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS youtube_api_key VARCHAR(128) NULL;

-- Per-user AcoustID API key (free registration at acoustid.org), used by
-- POST /api/fingerprint/identify to look up a Chromaprint fingerprint against
-- the AcoustID/MusicBrainz database for tracks with wrong or missing tags.
-- No server-wide fallback -- AcoustID client keys identify an application
-- registration, not a shared service credential, so each user brings their own.
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS acoustid_api_key VARCHAR(128) NULL;

-- Per-user yt-dlp cookies (Netscape cookies.txt format), used to authenticate
-- yt-dlp extraction (search/stream/resolve/download) as that user's YouTube
-- session — required for age-restricted content and avoids YouTube's
-- anonymous-request bot-detection blocks. Never echoed back to clients (see
-- the /user/ytdlp-cookies status + /user/ytdlp-cookies/validate endpoints).
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS ytdlp_cookies TEXT NULL;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS ytdlp_cookies_updated_at TIMESTAMP NULL;

-- Governs whether/when a user's yt-dlp calls may fall back to the
-- server-wide shared cookie file (YTDLP_COOKIES_FILE — the operator's own
-- YouTube session) instead of failing when the user has no cookies of
-- their own configured, or their own have gone stale. See
-- _may_use_global_cookies in main.py: accounts under 15 days old are
-- never eligible regardless of this value (a new/throwaway account
-- riding on the operator's personal session is exactly the abuse case
-- this age gate exists to prevent) — this column only takes effect once
-- an account clears that bar.
--   'auto'       (default) — prefer the user's own cookies; fall back to
--                 the global ones only when the user has none configured
--                 or their own fail with a cookie-rotation error.
--   'own_only'   — never fall back to global, even once eligible by age.
--   'global_only'— always prefer the global session over the user's own
--                 (e.g. a user whose own account keeps getting flagged).
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS cookie_fallback_preference VARCHAR(20) DEFAULT 'auto';

-- Feature: Discord "now playing" webhook integration. True per-user Discord
-- Rich Presence ("Listening to ...") requires the Discord desktop client and
-- a local IPC connection, which an iOS app cannot establish on a user's
-- behalf — so instead each user can point a Discord webhook (e.g. at a
-- channel in their own server) and the bridge posts a "Now Playing" embed.
CREATE TABLE IF NOT EXISTS ios_discord_webhooks (
    user_id VARCHAR(36) PRIMARY KEY,
    webhook_url TEXT NOT NULL,
    enabled BOOLEAN DEFAULT TRUE,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: Discord Rich Presence registration. Rich Presence itself is still
-- set by a local daemon talking to the Discord desktop client over IPC (no
-- server-side API exists for this), but the daemon's per-user configuration
-- (Discord Application client ID + optional Rich Presence art asset name) is
-- registered here once via the app, so the daemon only needs the per-user
-- RPC token (see /user/rpc-token) and fetches the rest from the server.
CREATE TABLE IF NOT EXISTS ios_discord_rpc_config (
    user_id VARCHAR(36) PRIMARY KEY,
    discord_client_id VARCHAR(64) NOT NULL,
    large_image VARCHAR(255),
    enabled BOOLEAN DEFAULT TRUE,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: enhanced Discord Rich Presence — small "play/pause" status icon
-- asset and an optional "Listen on <source>" button linking to the track.
ALTER TABLE ios_discord_rpc_config ADD COLUMN IF NOT EXISTS small_image VARCHAR(255);
ALTER TABLE ios_discord_rpc_config ADD COLUMN IF NOT EXISTS show_buttons BOOLEAN DEFAULT TRUE;

-- Feature: shared Discord app for Rich Presence (2026-08-16) — a NULL
-- discord_client_id now means "use Lumisound's own shared Discord
-- application" (DISCORD_RPC_DEFAULT_CLIENT_ID in main.py) instead of being
-- disallowed, so a user can enable Rich Presence with nothing but a
-- verified Discord account — no Discord Developer Application of their own
-- required. A non-NULL value is still a real per-user override for anyone
-- who wants their own branding.
ALTER TABLE ios_discord_rpc_config ALTER COLUMN discord_client_id DROP NOT NULL;

-- Feature: musical key estimation (Krumhansl-Schmuckler chroma analysis)
-- alongside BPM/loudness, for harmonic-mixing-aware automixing/crossfade.
ALTER TABLE ios_user_music_metadata ADD COLUMN IF NOT EXISTS musical_key VARCHAR(16) NULL;

-- Feature: trending-by-energy — records each played track's BPM (from
-- on-device analysis or embedded tags) so /social/trending-by-energy can
-- rank trending tracks by average tempo, not just play count.
ALTER TABLE ios_play_history ADD COLUMN IF NOT EXISTS bpm FLOAT NULL;

-- Per-folder backup of the user's "watched folders" (MusicFolderService) tree
-- structure: which relative path under Documents each watched folder lived
-- at, and which tracks (by source track ID / title+artist+duration, since
-- on-device file paths aren't portable across installs) it contained. Pushed
-- alongside /user/sync so a reinstall can recreate the same folder layout and
-- prompt the user to redownload tracks back into their original folders.
-- Replaced wholesale on each push (one row per folder), like
-- ios_user_playlists/ios_playlist_tracks.
CREATE TABLE IF NOT EXISTS ios_user_folder_backups (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    folder_path VARCHAR(1024) NOT NULL,
    track_filenames_json TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_user_folder_backups_idx_user_id ON ios_user_folder_backups (user_id);

-- Feature: Libre.fm scrobbling (Last.fm-API-compatible, different base URL).
-- Stored separately from the lastfm_* columns since a user may link both
-- independently.
ALTER TABLE ios_scrobble_links ADD COLUMN IF NOT EXISTS librefm_session_key VARCHAR(64) NULL;

-- Expanded per-user sync settings: visual/layout preferences that previously
-- lived only in ios_user_settings_expanded (unused by /user/sync) are now
-- also mirrored onto ios_user_settings so they round-trip through the normal
-- 8-minute auto-sync / manual sync (GET+POST /user/sync).
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS vinyl_disc_enabled BOOLEAN DEFAULT TRUE;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS show_queue_preview BOOLEAN DEFAULT TRUE;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS songs_per_row INT DEFAULT 1;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS albums_per_row INT DEFAULT 2;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS bg_animation VARCHAR(20) DEFAULT 'fade';
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS bg_opacity FLOAT DEFAULT 0.35;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS preferred_audio_format VARCHAR(10) DEFAULT 'm4a';
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS download_path TEXT NULL;

-- New sync fields (Feature: expanded sync payload).
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS car_mode_enabled BOOLEAN DEFAULT FALSE;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS library_artists_columns INT DEFAULT 2;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS now_playing_artwork_style VARCHAR(32) NULL;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS now_playing_seeker_style VARCHAR(32) NULL;
-- now_playing_artwork_style holds EITHER a built-in style's short rawValue OR
-- a user-created CustomNowPlayingStyle's UUID id (NowPlayingView.swift's
-- selectStyle) — a UUID string is 36 chars, which doesn't fit VARCHAR(32) and
-- 500s the whole settings sync for anyone using a custom style. Widen to
-- match channel_id's VARCHAR(64) below. Plain MODIFY is idempotent (a no-op
-- once already widened), unlike ADD COLUMN IF NOT EXISTS.
ALTER TABLE ios_user_settings ALTER COLUMN now_playing_artwork_style TYPE VARCHAR(64);
ALTER TABLE ios_user_settings ALTER COLUMN now_playing_artwork_style DROP NOT NULL;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS earned_badges_json TEXT NULL;
-- Generic JSON bag of additional UserDefaults-backed preferences included in
-- the per-user auto backup (notifications toggle, card style, auto-radio,
-- Liquid Glass customization, etc.). A single extensible column so new
-- settings can be backed up without per-field schema migrations.
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS extra_settings_json TEXT NULL;

-- The client (AccountService+Sync.swift) has built and sent bg_enabled/
-- bg_blur_radius/bg_shuffle_interval in every sync push since the gallery
-- background feature shipped, but no column ever existed for them here —
-- Pydantic's SyncPushRequest silently dropped the extra JSON keys, so a
-- fresh install never restored whether the gallery background was on, its
-- blur radius, or its shuffle interval. Filling that gap now.
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS bg_enabled BOOLEAN DEFAULT TRUE;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS bg_blur_radius FLOAT NULL;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS bg_shuffle_interval FLOAT NULL;

-- Previously device-local-only stores, now included in the per-user auto
-- backup — see SyncData's Swift-side doc comments (AccountModels.swift) for
-- why each of these was a real gap (Smart Playlists, tracked/auto-download
-- playlists, play history/stats, track bookmarks, and per-track BPM keyed
-- portably by sourceTrackID rather than the on-device-only path/mtime/size
-- key BPMAnalyzerService's own cache uses).
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS play_history_json TEXT NULL;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS smart_playlists_json TEXT NULL;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS tracked_playlists_json TEXT NULL;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS bookmarks_json TEXT NULL;
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS bpm_by_source_track_id_json TEXT NULL;

-- Feature: Discover subscriptions — resolve a user-entered channel
-- URL/handle/search term to a real YouTube channel_id + thumbnail at
-- subscribe time, so the subscription list can show real channel art
-- instead of just the raw URL the user typed.
ALTER TABLE ios_artist_subscriptions ADD COLUMN IF NOT EXISTS channel_id VARCHAR(64) NULL;
ALTER TABLE ios_artist_subscriptions ADD COLUMN IF NOT EXISTS channel_thumbnail TEXT NULL;
ALTER TABLE ios_scrobble_links ADD COLUMN IF NOT EXISTS librefm_username VARCHAR(255) NULL;

-- Records every track a user has successfully downloaded via /api/download
-- (regardless of whether they later delete/lose the local file). Powers:
--   - "My Library" search (find tracks the user has ever had, even if the
--     on-device library doesn't currently have them)
--   - "Previously downloaded" restore list after reinstall/corruption-delete
--   - Listening/download stats (most-downloaded artists, totals, etc.)
CREATE TABLE IF NOT EXISTS ios_download_history (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    source VARCHAR(20) NOT NULL,
    source_id VARCHAR(255) NOT NULL,
    title TEXT NOT NULL,
    artist TEXT,
    thumbnail_url TEXT,
    duration_seconds INT DEFAULT 0,
    format VARCHAR(10) DEFAULT 'm4a',
    download_count INT DEFAULT 1,
    first_downloaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_downloaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT user_track UNIQUE (user_id, source, source_id),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_download_history_idx_user_history ON ios_download_history (user_id, last_downloaded_at);

-- Durable record of a finished /api/download job whose file hasn't been
-- fetched by the client yet. Previously a finished job's file lived only in
-- an ephemeral temp dir and was deleted 15 minutes after creation regardless
-- of whether the client had fetched it — if the app was closed/backgrounded
-- while a job was still running (or briefly after), the finished download
-- was silently lost with no way to recover it. Rows here persist (bounded by
-- a long-term sweep, see _sweep_stale_pending_downloads) until the client
-- fetches the file via /api/download/result, so a job started from any
-- session/device state can always be picked up later by
-- GET /api/download/pending — on next app launch, next foreground, the next
-- BGAppRefreshTask run, or immediately via a silent push (see
-- _send_push_best_effort's content_available parameter).
CREATE TABLE IF NOT EXISTS ios_pending_downloads (
    job_id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    source_track_id VARCHAR(280) NOT NULL,
    title TEXT,
    artist TEXT,
    file_path TEXT NOT NULL,
    media_type VARCHAR(50) NOT NULL,
    filename TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_pending_downloads_idx_pending_user ON ios_pending_downloads (user_id, created_at);

-- Per-user snapshot of the source ids CURRENTLY in the user's on-device library
-- (Song.sourceTrackID values + download-ledger ids), uploaded periodically by
-- the app. yt-dlp/the bridge can never see the device's folders, so this is how
-- the server knows what the user already has: the resolve + single-download
-- dedup consult it so re-downloading a playlist skips owned tracks even when the
-- per-request existing_ids manifest is incomplete or too large for a URL. Unlike
-- ios_download_history (append-only "ever downloaded"), this is replaced on each
-- sync, so deleting a track on-device lets it be downloaded again.
CREATE TABLE IF NOT EXISTS ios_user_library_inventory (
    user_id VARCHAR(36) NOT NULL,
    source_id VARCHAR(255) NOT NULL,
    PRIMARY KEY (user_id, source_id),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------------
-- 10 more server-side features (2026-07-04)
-- ---------------------------------------------------------------------------

-- Feature: full-text search over the user's own uploaded music library.
-- /user/music's `search` param scans the whole filesystem + runs ffprobe on
-- every file on every request — slow for big libraries and no typo
-- tolerance. This FULLTEXT index lets /user/music/search query the
-- already-populated metadata table directly instead.
CREATE INDEX IF NOT EXISTS ft_search ON ios_user_music_metadata USING GIN (to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(artist, '') || ' ' || COALESCE(album, '')));

-- Feature: per-user storage quota override. NULL/0 means "use the server
-- default" (USER_MUSIC_QUOTA_BYTES env var, itself unlimited unless the
-- admin sets it) — this column exists only so a specific user's quota can
-- be raised/lowered without changing the server-wide default.
ALTER TABLE ios_user_settings ADD COLUMN IF NOT EXISTS storage_quota_bytes BIGINT NULL;

-- Feature: server-side lyrics cache. /api/lyrics previously re-fetched from
-- lrclib.net on every single request, even for the same song looked up
-- repeatedly (every time Now Playing opens). Cached indefinitely since
-- lyrics for a given track essentially never change; a user-submitted
-- correction (is_user_submitted) overwrites the lrclib result and is never
-- evicted by a later automatic re-fetch.
CREATE TABLE IF NOT EXISTS ios_lyrics_cache (
    id VARCHAR(64) PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    artist VARCHAR(255) NOT NULL,
    synced_lyrics TEXT NULL,
    plain_lyrics TEXT NULL,
    found BOOLEAN NOT NULL DEFAULT FALSE,
    is_user_submitted BOOLEAN NOT NULL DEFAULT FALSE,
    submitted_by_user_id VARCHAR(36) NULL,
    cached_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS ios_lyrics_cache_idx_title_artist ON ios_lyrics_cache (title, artist);

-- Cache of GET /api/artist/bio results (MusicBrainz facts + Wikipedia bio
-- text/photo — see main.py). artist_name is the lowercased/trimmed lookup
-- key. `found = FALSE` rows are real cache entries too (a typo'd/obscure
-- name that matched nothing), so a bad lookup isn't re-queried against
-- MusicBrainz/Wikipedia on every visit to that artist's page. Refreshed on
-- a 30-day TTL (checked in the endpoint itself via `cached_at`), not
-- indefinitely — unlike lyrics, a bio can meaningfully change over time.
CREATE TABLE IF NOT EXISTS ios_artist_bio_cache (
    artist_name VARCHAR(255) PRIMARY KEY,
    bio_json TEXT NULL,
    found BOOLEAN NOT NULL DEFAULT FALSE,
    cached_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Cache of Claude "intelligence" task results (see ios-bridge/intelligence.py),
-- keyed by task + a hash of the normalized input. Results here are stable
-- decisions (e.g. "which metadata candidate is correct for this filename"),
-- so they're cached indefinitely rather than on a TTL.
CREATE TABLE IF NOT EXISTS ios_intelligence_cache (
    task VARCHAR(32) NOT NULL,
    cache_key VARCHAR(64) NOT NULL,
    result_json TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (task, cache_key)
);

-- Aria Lumi's memory (see ios-bridge/intelligence.py): one row per suggestion
-- she makes, updated with correction_json whenever the user's actual choice
-- differs from her pick. Recent corrections (correction_json IS NOT NULL) are
-- fed back into her next prompt for that task as few-shot examples, so her
-- judgment concretely improves from real usage instead of resetting on every
-- request. Kept separate from ios_intelligence_cache (which caches a stable
-- decision for reuse) since this table's purpose is a learning signal, not
-- a cache — it's read in small recent-N slices, never looked up by key.
CREATE TABLE IF NOT EXISTS ios_aria_memory (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    task VARCHAR(32) NOT NULL,
    input_json TEXT NOT NULL,
    ai_result_json TEXT NOT NULL,
    correction_json TEXT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS ios_aria_memory_idx_task_created ON ios_aria_memory (task, created_at);

-- Aria Lumi's action log: unlike ios_aria_memory (one row per SUGGESTION,
-- best_index/confidence only), this is one row per real ACTION she took on
-- an existing track — currently just auto-removing a confidently-identified
-- duplicate, gated to confidence == "high" on the client (see
-- DuplicateFinderService.refineGroupsWithAria). Carries full before/after
-- state (not just an index) specifically so a client-side revert has
-- everything it needs to undo the action without a second round-trip, and so
-- this table is a genuinely readable audit trail on its own — "what did she
-- touch and why" — rather than requiring a join back through
-- ios_intelligence_cache. reverted_at is set by the client after a
-- successful local revert (see POST /user/intelligence/actions/{id}/revert);
-- the server never reverses the action itself, since the actual file/tag
-- state she changed only exists on the user's device.
CREATE TABLE IF NOT EXISTS ios_aria_actions (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    action_type VARCHAR(32) NOT NULL,
    title VARCHAR(512) NOT NULL,
    artist VARCHAR(512),
    detail TEXT,
    before_json TEXT,
    after_json TEXT,
    confidence VARCHAR(16),
    memory_id BIGINT REFERENCES ios_aria_memory(id),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    reverted_at TIMESTAMP NULL
);
CREATE INDEX IF NOT EXISTS ios_aria_actions_idx_user_created ON ios_aria_actions (user_id, created_at);

-- Feature: server-side waveform peak-data precomputation, alongside the
-- existing loudness/BPM/key analysis at upload time — saves the client from
-- decoding the whole file locally just to draw a scrubber waveform. Stored
-- as a JSON array of ~200 normalized (0.0-1.0) peak values.
ALTER TABLE ios_user_music_metadata ADD COLUMN IF NOT EXISTS waveform_json TEXT NULL;

-- Feature: cached acoustic-duplicate scan results, computed by a periodic
-- background job (see _duplicate_scan_loop) instead of live on every
-- GET /user/library/acoustic-duplicates request, which was slow for large
-- libraries (re-fingerprinting everything on demand).
CREATE TABLE IF NOT EXISTS ios_duplicate_scan_cache (
    user_id VARCHAR(36) PRIMARY KEY,
    groups_json TEXT NOT NULL,
    scanned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: generalized outbound webhooks (beyond the existing Discord-only
-- ios_discord_webhooks). One row per (user, event type) so a user can point
-- different events at different URLs — e.g. downloads to one Zapier hook,
-- subscription-alerts to a Home Assistant endpoint.
CREATE TABLE IF NOT EXISTS ios_user_webhooks (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    event_type VARCHAR(40) NOT NULL,
    webhook_url TEXT NOT NULL,
    enabled BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_user_webhooks_idx_user_event ON ios_user_webhooks (user_id, event_type);

-- Feature: persistent listening-room chat/history — ios_listen_rooms only
-- tracks the host's current track/position; this records track changes and
-- chat messages so guests joining late (or reopening the room) see history.
CREATE TABLE IF NOT EXISTS ios_room_events (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    room_id VARCHAR(36) NOT NULL,
    user_id VARCHAR(36) NULL,
    event_type VARCHAR(20) NOT NULL,
    title TEXT NULL,
    artist TEXT NULL,
    message TEXT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (room_id) REFERENCES ios_listen_rooms(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS ios_room_events_idx_room_created ON ios_room_events (room_id, created_at);

-- Feature: collaborative room queue — members can add/vote on tracks for a
-- shared listening room's "up next" order, independent of the host's own
-- device queue.
CREATE TABLE IF NOT EXISTS ios_room_queue (
    id VARCHAR(36) PRIMARY KEY,
    room_id VARCHAR(36) NOT NULL,
    added_by_user_id VARCHAR(36) NULL,
    track_url TEXT,
    title TEXT NOT NULL,
    artist TEXT,
    votes INT DEFAULT 0,
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (room_id) REFERENCES ios_listen_rooms(id) ON DELETE CASCADE,
    FOREIGN KEY (added_by_user_id) REFERENCES ios_users(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS ios_room_queue_idx_room_votes ON ios_room_queue (room_id, votes);

-- One vote per person per queue item.
--
-- `ios_room_queue.votes` was incremented with a bare `votes = votes + 1` and
-- nothing recorded WHO voted, so a single member could hold the vote button and
-- push any track to the top without limit. In a feature whose entire point is
-- that the group decides the order, an unbounded vote is not a small gap — it
-- makes the ordering meaningless. The primary key is what enforces it; the
-- counter on ios_room_queue is kept as a denormalised total so the queue can
-- still be ordered without a join per row.
CREATE TABLE IF NOT EXISTS ios_room_queue_votes (
    item_id VARCHAR(36) NOT NULL,
    user_id VARCHAR(36) NOT NULL,
    voted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (item_id, user_id),
    FOREIGN KEY (item_id) REFERENCES ios_room_queue(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Who is currently in a listening room.
--
-- The room tables tracked the host's playback and the shared queue but never
-- membership, so there was no way to answer "who is listening with me" — and no
-- way for the server to know who to push a room update TO. Presence is by
-- heartbeat (`last_seen_at`) rather than an explicit leave, because a phone that
-- loses signal or is force-quit never sends one; a timestamp degrades correctly
-- where a boolean would leave ghosts in the room forever.
CREATE TABLE IF NOT EXISTS ios_room_participants (
    room_id VARCHAR(36) NOT NULL,
    user_id VARCHAR(36) NOT NULL,
    joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (room_id, user_id),
    FOREIGN KEY (room_id) REFERENCES ios_listen_rooms(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_room_participants_idx_seen ON ios_room_participants (room_id, last_seen_at);

-- Feature: personalized history-based weekly mix (distinct from the existing
-- static tempo-bucket ios_user_music_metadata-derived smart-playlists) —
-- caches the generated track-id list per user, regenerated weekly by
-- _weekly_mix_loop rather than computed per-request.
CREATE TABLE IF NOT EXISTS ios_weekly_mix_cache (
    user_id VARCHAR(36) PRIMARY KEY,
    track_ids_json TEXT NOT NULL,
    generated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------------
-- 3 more server-side features (2026-07-11)
-- ---------------------------------------------------------------------------

-- Feature: search my library by lyrics (see /api/lyrics/search,
-- /user/lyrics/prefetch in main.py). MATCH()'s column list must exactly match
-- a FULLTEXT index's columns, hence (title, artist, plain_lyrics) here rather
-- than plain_lyrics alone — lets a query also hit on title/artist words.
CREATE INDEX IF NOT EXISTS ft_lyrics_search ON ios_lyrics_cache USING GIN (to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(artist, '') || ' ' || COALESCE(plain_lyrics, '')));

-- Feature: TOTP two-factor authentication (see /auth/2fa/* in main.py).
-- totp_secret is only meaningful once totp_enabled is TRUE (set by
-- /auth/2fa/verify after the user proves they scanned the QR code correctly —
-- /auth/2fa/setup alone does not turn 2FA on, so a half-finished setup can't
-- lock anyone out).
ALTER TABLE ios_users ADD COLUMN IF NOT EXISTS totp_secret VARCHAR(64) NULL;
ALTER TABLE ios_users ADD COLUMN IF NOT EXISTS totp_enabled BOOLEAN NOT NULL DEFAULT FALSE;

-- Feature: /social/similar-listeners collaborative-filtering recommendations.
-- No new tables — reuses ios_play_history and the existing
-- share_listening_activity opt-in (see the /social/* section in main.py).

-- ---------------------------------------------------------------------------
-- General-purpose DB event logging sweep
-- ---------------------------------------------------------------------------

-- Structured cross-system event log (auth, sync, backup, metadata/
-- intelligence, etc.) — see db.log_event() and POST /api/log-event in
-- main.py. Distinct from ios_app_logs (raw client debug-log-line ingestion
-- from AppLogger's local buffer) and the narrower ios_sync_log/
-- ios_search_log tables: this one is a single reusable sink for "something
-- happened" events from both the bridge itself (source='bridge') and the
-- iOS client (source='ios_client'), with an optional structured JSON detail
-- blob. user_id is nullable since some events (e.g. a failed login attempt
-- for an unknown username) have no known user yet.
CREATE TABLE IF NOT EXISTS ios_app_event_log (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    source VARCHAR(20) NOT NULL DEFAULT 'bridge',
    user_id VARCHAR(36) NULL,
    category VARCHAR(30) NOT NULL,
    event VARCHAR(60) NOT NULL,
    level VARCHAR(10) NOT NULL DEFAULT 'info',
    message TEXT,
    detail JSONB NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS ios_app_event_log_idx_category_created ON ios_app_event_log (category, created_at);
CREATE INDEX IF NOT EXISTS ios_app_event_log_idx_user_created ON ios_app_event_log (user_id, created_at);
CREATE INDEX IF NOT EXISTS ios_app_event_log_idx_level ON ios_app_event_log (level);

-- ---------------------------------------------------------------------------
-- Download/streaming attempt logging (2026-07-18)
-- ---------------------------------------------------------------------------

-- Append-only log of every /api/download job attempt (start-to-finish, not
-- per internal yt-dlp retry) — start, success, or failure with a reason —
-- keyed loosely by (source, source_id) rather than a unique constraint since
-- the same track can be legitimately re-downloaded/re-attempted many times.
-- Distinct from ios_download_history (which only upserts successful,
-- account-linked downloads for "My Library"/stats): this is a plain diagnostic
-- trail that also covers anonymous downloads (user_id NULL) and failures, so
-- "why did my download fail" can be answered without grepping raw app logs.
-- user_id uses ON DELETE SET NULL (not CASCADE, unlike most other per-user
-- tables here) so a deleted account's download history stays available for
-- aggregate/ops diagnostics instead of disappearing with the account.
CREATE TABLE IF NOT EXISTS ios_download_log (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    user_id VARCHAR(36) NULL,
    source VARCHAR(20) NOT NULL,
    source_id VARCHAR(280) NOT NULL,
    title TEXT NULL,
    status VARCHAR(20) NOT NULL,
    error_message TEXT NULL,
    duration_ms INT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP NULL,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS ios_download_log_idx_user_created ON ios_download_log (user_id, created_at);
CREATE INDEX IF NOT EXISTS ios_download_log_idx_source_id ON ios_download_log (source, source_id);

-- Streaming-side counterpart to ios_download_log: one row per
-- streaming-URL-resolution attempt (/api/stream, /api/stream/proxy) — a
-- track being played, not downloaded, so "status"/"error_message" describe
-- whether yt-dlp/the extractor produced a playable URL, not a downloaded file.
CREATE TABLE IF NOT EXISTS ios_stream_log (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    user_id VARCHAR(36) NULL,
    source VARCHAR(20) NOT NULL,
    source_id VARCHAR(280) NOT NULL,
    title TEXT NULL,
    status VARCHAR(20) NOT NULL,
    error_message TEXT NULL,
    duration_ms INT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP NULL,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS ios_stream_log_idx_user_created ON ios_stream_log (user_id, created_at);
CREATE INDEX IF NOT EXISTS ios_stream_log_idx_source_id ON ios_stream_log (source, source_id);

-- ---------------------------------------------------------------------------
-- Social Ecosystem: profiles, friends, presence (2026-07-18)
--
-- Everything below is additive and namespaced ios_social_ / ios_presence_ so
-- it can never collide with another workstream's tables. All new endpoints
-- live under the /api/social/* prefix in main.py (deliberately distinct from
-- the pre-existing global, non-friend-scoped /social/* activity/discover
-- feed above, which is a different feature this doesn't replace).
-- ---------------------------------------------------------------------------

-- One row per user with a customized profile (created lazily on first save —
-- a user who never visits their profile screen simply has no row here, and
-- GET /api/social/profile/{id} falls back to defaults). main_accent_hex /
-- sub_accent_hex are validated server-side against a curated palette (see
-- AccentColorPickerView.swift) rather than accepting arbitrary hex strings
-- from the client, so a malformed value can never make a profile unreadable.
-- share_now_playing is the privacy hook requested for presence: when FALSE,
-- this user's now_playing_* fields are withheld from both the presence
-- endpoints and the friend activity feed (online/offline still shows).
CREATE TABLE IF NOT EXISTS ios_social_profiles (
    user_id VARCHAR(36) PRIMARY KEY,
    bio VARCHAR(280) NULL,
    main_accent_hex VARCHAR(7) NULL,
    sub_accent_hex VARCHAR(7) NULL,
    share_now_playing BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Profile banner image (2026-07-19) — same JPEG/GIF-sniffed-bytes pattern
-- as ios_users.avatar_data (see POST/GET /user/avatar), just scoped to the
-- social profile instead of the core account. NULL means "no banner set";
-- the profile header falls back to a plain main/sub accent gradient.
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS banner_data BYTEA NULL;

-- Profile customization additions (Feature: profile-customization-2,
-- 2026-07-21): pronouns/status say a little more about a person than just
-- an accent pair + bio; avatar_frame is a purely cosmetic, client-rendered
-- ring style around the avatar (validated server-side against a curated set
-- — see _valid_avatar_frame — same "malformed value must never make a
-- profile broken" reasoning as main/sub_accent_hex above). show_top_genres
-- is an opt-in privacy toggle, mirroring share_now_playing exactly, gating
-- the new "Top Genres"/"Top Artists" showcase card built from the same
-- get_user_taste_profile signal already used for /api/social/compatibility.
-- show_guestbook lets an owner turn off new guestbook posts entirely without
-- deleting messages already left — see post_profile_comment's check.
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS pronouns VARCHAR(30) NULL;
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS status_emoji VARCHAR(8) NULL;
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS status_text VARCHAR(60) NULL;
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS avatar_frame VARCHAR(20) NOT NULL DEFAULT 'none';
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS show_top_genres BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS show_guestbook BOOLEAN NOT NULL DEFAULT TRUE;

-- Up to 5 user-pinned "favorite songs" shown on the profile, ordered by
-- `position` (0-4). Saved as a full replace (delete-then-insert in one
-- transaction) from PUT /api/social/profile/pinned-tracks rather than
-- incremental add/remove endpoints — simplest correct way to let the user
-- freely reorder/swap a small fixed-size list. Denormalized title/artist/
-- album (like ios_user_favorites and ios_playlist_tracks already do) so a
-- pin still displays something sensible even if source_track_id is null
-- (a purely local import) or the source later disappears.
CREATE TABLE IF NOT EXISTS ios_social_pinned_tracks (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    position INT NOT NULL DEFAULT 0,
    source_track_id VARCHAR(255) NULL,
    track_url TEXT NULL,
    title TEXT NOT NULL,
    artist TEXT NULL,
    album TEXT NULL,
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_social_pinned_tracks_idx_pinned_user ON ios_social_pinned_tracks (user_id);

-- Friend requests. `status` moves pending -> accepted/declined/cancelled and
-- is never deleted (keeps a simple audit trail / prevents immediate re-spam
-- after a decline within the app's own request-throttling logic). Accepting
-- a request writes the symmetric pair into ios_social_friends below rather
-- than this table being queried for "are we friends" at read time.
CREATE TABLE IF NOT EXISTS ios_social_friend_requests (
    id VARCHAR(36) PRIMARY KEY,
    from_user_id VARCHAR(36) NOT NULL,
    to_user_id VARCHAR(36) NOT NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    responded_at TIMESTAMP NULL,
    FOREIGN KEY (from_user_id) REFERENCES ios_users(id) ON DELETE CASCADE,
    FOREIGN KEY (to_user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_social_friend_requests_idx_freq_to ON ios_social_friend_requests (to_user_id, status);
CREATE INDEX IF NOT EXISTS ios_social_friend_requests_idx_freq_from ON ios_social_friend_requests (from_user_id, status);

-- Friendships, stored as a symmetric pair of rows (A,B) + (B,A) on accept —
-- a small denormalization that keeps every "who are my friends" /
-- "am I friends with X" query a single indexed lookup on `user_id` alone,
-- instead of an OR'd two-column match on every read. Both rows are deleted
-- together on unfriend or on either side blocking the other.
CREATE TABLE IF NOT EXISTS ios_social_friends (
    user_id VARCHAR(36) NOT NULL,
    friend_id VARCHAR(36) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, friend_id),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE,
    FOREIGN KEY (friend_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_social_friends_idx_friends_friend ON ios_social_friends (friend_id);

-- Basic abuse handling for the friends feature: a block is one-directional
-- (user_id blocked blocked_id) but enforced both ways at query time (neither
-- side can friend-request, view the other's profile, or see them in
-- presence/activity once either has blocked the other). Blocking also tears
-- down any existing friendship/pending request between the two (see
-- POST /api/social/block/{user_id}).
CREATE TABLE IF NOT EXISTS ios_social_blocks (
    user_id VARCHAR(36) NOT NULL,
    blocked_id VARCHAR(36) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, blocked_id),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE,
    FOREIGN KEY (blocked_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- One row per user, upserted on every POST /api/social/presence heartbeat
-- (client polls every 30-60s while foregrounded — see PresenceService.swift).
-- "Online" is derived, not stored as a trusted-forever flag: callers should
-- treat a user as online only when is_online = TRUE *and* last_seen_at is
-- recent (main.py uses a 90s freshness window — 1.5x the client's slowest
-- polling cadence — so a force-quit/crashed app without the best-effort
-- "going offline" beacon still reads as offline shortly after, not forever
-- online). now_playing_title/artist are always stored as reported (same
-- "store raw, gate on read" convention the pre-existing global
-- share_listening_activity feed above already uses for ios_play_history) —
-- every /api/social/presence/* read filters them out whenever the owning
-- profile has share_now_playing = FALSE, so they are never returned by the
-- API to anyone while the toggle is off, and toggling it doesn't require
-- rewriting this row.
CREATE TABLE IF NOT EXISTS ios_presence_state (
    user_id VARCHAR(36) PRIMARY KEY,
    is_online BOOLEAN NOT NULL DEFAULT FALSE,
    is_playing BOOLEAN NOT NULL DEFAULT FALSE,
    now_playing_title VARCHAR(500) NULL,
    now_playing_artist VARCHAR(500) NULL,
    now_playing_artwork_url VARCHAR(500) NULL,
    last_seen_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Profile guestbook (Feature: profile-comments, 2026-07-21) — short messages
-- friends can leave on each other's profiles, Discord/MySpace-style. Posting
-- requires an existing friendship (this app has no moderation tooling, so
-- the anti-spam/harassment guard is simply "only people you've already
-- accepted can write on your wall"); reading follows the same visibility as
-- the profile itself (GET /api/social/profile/{user_id} — anyone not
-- blocked, not friends-only). Deletable by either the author (retract your
-- own comment) or the profile owner (moderate your own wall) — see
-- DELETE /api/social/profile/comments/{comment_id}.
CREATE TABLE IF NOT EXISTS ios_social_profile_comments (
    id VARCHAR(36) PRIMARY KEY,
    profile_user_id VARCHAR(36) NOT NULL,
    author_user_id VARCHAR(36) NOT NULL,
    body VARCHAR(280) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (profile_user_id) REFERENCES ios_users(id) ON DELETE CASCADE,
    FOREIGN KEY (author_user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_social_profile_comments_idx_comments_profile ON ios_social_profile_comments (profile_user_id, created_at);

-- ---------------------------------------------------------------------------
-- Friends tab expansion (Feature: friends-tab-expansion, 2026-07-21) — new
-- storage for two of the five features woven into the redesigned Friends
-- tab: private nicknames and custom friend tags/groups. The other three new
-- features (weekly activity leaderboard, "listening together", friendiversary
-- callouts) are all derived at read time from tables that already exist
-- above (ios_play_history, ios_presence_state, ios_social_friends.created_at)
-- and need no new storage of their own.
-- ---------------------------------------------------------------------------

-- A friend nickname is private to whoever set it (Discord-style "server
-- nickname" but scoped to the friendship, not a server) — the friend being
-- nicknamed never sees it and it never appears on their public profile.
-- Server-synced (not just UserDefaults) so it follows the user across
-- devices/reinstalls, same reasoning as every other Social Ecosystem table
-- being bridge-backed rather than local-only. One row max per (owner,
-- friend) pair; deleting the nickname is a DELETE, not an empty-string UPDATE
-- (see set_friend_nickname), so "never customized" and "cleared" both read
-- back identically as no row.
CREATE TABLE IF NOT EXISTS ios_social_friend_nicknames (
    user_id VARCHAR(36) NOT NULL,
    friend_id VARCHAR(36) NOT NULL,
    nickname VARCHAR(60) NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, friend_id),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE,
    FOREIGN KEY (friend_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Custom friend tags/groups ("Close Friends", "Music Buddies", ...) power
-- the filter chips above the redesigned friends list. Free-form per-user
-- strings, not shared/global objects, so one row per (owner, friend, tag)
-- is enough storage — nothing to normalize into a separate tag-definitions
-- table. Distinct rows per tag_name let a single friend carry multiple tags.
CREATE TABLE IF NOT EXISTS ios_social_friend_tags (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    friend_id VARCHAR(36) NOT NULL,
    tag_name VARCHAR(40) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_friend_tag UNIQUE (user_id, friend_id, tag_name),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE,
    FOREIGN KEY (friend_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_social_friend_tags_idx_friend_tags_user ON ios_social_friend_tags (user_id, tag_name);

-- ---------------------------------------------------------------------------
-- Profile customization additions (Feature: profile-customization-3,
-- 2026-07-21) — five more profile/social-profile features layered on top of
-- the Social Ecosystem above: profile visitor stats, a listening streak
-- stat, milestone badges, a featured/spotlight playlist, and a friends-only
-- "recently played together" overlap card. See main.py's SOCIAL ECOSYSTEM
-- section (search for "profile-customization-3") for the endpoints.
-- ---------------------------------------------------------------------------

-- show_visitor_stats: opt-out toggle (default TRUE, matching
-- share_now_playing's "on by default, some people will want to turn it
-- off" precedent) gating both the visitor_count and recent_visitors fields
-- on GET /api/social/profile/{user_id} — when FALSE, no view is recorded
-- for this user at all and both fields are withheld entirely, same
-- "toggle off = withhold, don't just hide client-side" convention as
-- show_top_genres. show_listening_stats: opt-in toggle (default FALSE,
-- matching show_top_genres's precedent) gating the listening_streak field.
-- featured_playlist_id: an owner-chosen spotlight from their own
-- ios_user_playlists, shown on the public profile if set. Deliberately no
-- FK constraint here (no existing table in this schema adds one via a
-- later ALTER — every FK elsewhere is declared inline on CREATE TABLE, and
-- ALTER ... ADD CONSTRAINT ... FOREIGN KEY has no "IF NOT EXISTS" form, so
-- it wouldn't be safely re-runnable like every other statement in this
-- file); PUT /api/social/profile/featured-playlist validates ownership at
-- write time, and the read path (_featured_playlist_payload) already
-- treats a since-deleted playlist id as "nothing featured" rather than
-- erroring, so a dangling id is harmless either way.
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS show_visitor_stats BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS show_listening_stats BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS featured_playlist_id VARCHAR(36) NULL;

-- Feature: profile-customization-4 — how strongly the profile's main/sub
-- accent colors wash across the whole profile background client-side
-- (ProfileAccentBackgroundGlow), independent of the accent colors
-- themselves. One of 'subtle'/'normal'/'vivid'/'off', validated server-side
-- via _valid_glow_intensity's allowlist (same "allowlist, not free text"
-- precedent as avatar_frame) rather than trusted as arbitrary client input.
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS accent_glow_intensity VARCHAR(10) NOT NULL DEFAULT 'normal';

-- Feature: profile-customization-5 (2026-08-16) — Discord-style "Avatar
-- Decoration" (a small looping animation overlaid ON TOP of the avatar
-- image itself, distinct from avatar_frame's ring which sits AROUND it —
-- see AvatarDecorationStyle.swift) and "Profile Effect" (a looping
-- animation overlaid across the banner, see ProfileEffectStyle.swift).
-- Both purely cosmetic and purely client-rendered — no image/Lottie
-- assets, no server-stored pixels — validated server-side against a
-- curated allowlist, same "malformed value must never make a profile
-- broken" precedent as avatar_frame/accent_glow_intensity above.
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS avatar_decoration VARCHAR(20) NOT NULL DEFAULT 'none';
ALTER TABLE ios_social_profiles ADD COLUMN IF NOT EXISTS profile_effect VARCHAR(20) NOT NULL DEFAULT 'none';

-- Profile view log backing the visitor-stats feature. One row per (viewer,
-- profile) visit, debounced server-side to at most one row per 30 minutes
-- per pair (see main.py's _record_profile_view) so repeatedly reopening a
-- profile doesn't inflate the count like a naive page-refresh counter.
-- visitor_count is a simple COUNT(*) over this table; recent_visitors is
-- restricted to the profile owner's own friends (see _profile_visitor_stats)
-- — a stranger's view still counts toward the total, but their identity is
-- never exposed the way a friend's is, matching the guestbook/compatibility
-- precedent of gating anything identity-revealing behind friendship.
CREATE TABLE IF NOT EXISTS ios_social_profile_views (
    id VARCHAR(36) PRIMARY KEY,
    profile_user_id VARCHAR(36) NOT NULL,
    viewer_user_id VARCHAR(36) NOT NULL,
    viewed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (profile_user_id) REFERENCES ios_users(id) ON DELETE CASCADE,
    FOREIGN KEY (viewer_user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_social_profile_views_idx_profile_views_profile ON ios_social_profile_views (profile_user_id, viewed_at);
CREATE INDEX IF NOT EXISTS ios_social_profile_views_idx_profile_views_pair ON ios_social_profile_views (profile_user_id, viewer_user_id, viewed_at);

-- Feature: pending-download folder routing (2026-07-19). The job that
-- created a pending download already knows which local folder it's destined
-- for (e.g. a tracked playlist's own destination folder — see
-- TrackedPlaylist.destinationFolder client-side), but ios_pending_downloads
-- had nowhere to remember that once the job outlived the request that
-- started it. Without this, recovering a download after the app was closed
-- always fell back to the default folder, silently ignoring the playlist's
-- chosen destination. NULL means "use the default download folder", same
-- convention TrackedPlaylist.destinationFolder itself already uses.
ALTER TABLE ios_pending_downloads ADD COLUMN IF NOT EXISTS destination_folder VARCHAR(255) NULL;

-- Presence "Listening To" artwork (Feature: presence-artwork, 2026-08) — the
-- friends/public-profile "Listening To" card previously only had
-- title/artist for a friend's presence (no artwork at all), so it always
-- fell back to a generic placeholder icon even though the owner's own
-- device knows a real thumbnail URL for most tracks (YouTube's CDN). NULL
-- for purely-local imports with no derivable remote thumbnail, same as
-- now_playing_title/artist are NULL while nothing is playing.
ALTER TABLE ios_presence_state ADD COLUMN IF NOT EXISTS now_playing_artwork_url VARCHAR(500) NULL;

-- ---------------------------------------------------------------------------
-- MySQL -> PostgreSQL migration (2026-07): "ON UPDATE CURRENT_TIMESTAMP"
-- replacement triggers
-- ---------------------------------------------------------------------------
--
-- MySQL auto-touches a column declared "... ON UPDATE CURRENT_TIMESTAMP" on
-- every UPDATE to the row, with no equivalent column-level clause in
-- PostgreSQL. Rather than auditing every UPDATE/upsert call site in main.py
-- to see whether it already sets the timestamp itself, one small trigger per
-- distinct column name reproduces the original MySQL behavior exactly for
-- every table that used the clause (grouped below by column name):
--   updated_at:          ios_user_playlists, ios_user_settings,
--                        ios_user_settings_expanded, ios_playback_state,
--                        ios_listen_rooms, ios_scrobble_links,
--                        ios_discord_webhooks, ios_discord_rpc_config,
--                        ios_user_folder_backups, ios_social_profiles,
--                        ios_presence_state, ios_social_friend_nicknames
--   last_downloaded_at:  ios_download_history
--   cached_at:           ios_lyrics_cache, ios_artist_bio_cache
--   scanned_at:          ios_duplicate_scan_cache
--   generated_at:        ios_weekly_mix_cache
-- CREATE OR REPLACE + a DROP TRIGGER IF EXISTS before each CREATE TRIGGER
-- keeps this whole block idempotent/re-runnable, same as every CREATE TABLE
-- IF NOT EXISTS / ADD COLUMN IF NOT EXISTS statement above.

CREATE OR REPLACE FUNCTION ios_touch_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ios_touch_last_downloaded_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.last_downloaded_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ios_touch_cached_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.cached_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ios_touch_scanned_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.scanned_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ios_touch_generated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.generated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_user_playlists;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_user_playlists FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_user_settings;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_user_settings FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_user_settings_expanded;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_user_settings_expanded FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_playback_state;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_playback_state FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_listen_rooms;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_listen_rooms FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_scrobble_links;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_scrobble_links FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_discord_webhooks;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_discord_webhooks FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_discord_rpc_config;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_discord_rpc_config FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_user_folder_backups;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_user_folder_backups FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_social_profiles;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_social_profiles FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_presence_state;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_presence_state FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_updated_at ON ios_social_friend_nicknames;
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON ios_social_friend_nicknames FOR EACH ROW EXECUTE FUNCTION ios_touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_last_downloaded_at ON ios_download_history;
CREATE TRIGGER trg_touch_last_downloaded_at BEFORE UPDATE ON ios_download_history FOR EACH ROW EXECUTE FUNCTION ios_touch_last_downloaded_at();

DROP TRIGGER IF EXISTS trg_touch_cached_at ON ios_lyrics_cache;
CREATE TRIGGER trg_touch_cached_at BEFORE UPDATE ON ios_lyrics_cache FOR EACH ROW EXECUTE FUNCTION ios_touch_cached_at();

DROP TRIGGER IF EXISTS trg_touch_cached_at ON ios_artist_bio_cache;
CREATE TRIGGER trg_touch_cached_at BEFORE UPDATE ON ios_artist_bio_cache FOR EACH ROW EXECUTE FUNCTION ios_touch_cached_at();

DROP TRIGGER IF EXISTS trg_touch_scanned_at ON ios_duplicate_scan_cache;
CREATE TRIGGER trg_touch_scanned_at BEFORE UPDATE ON ios_duplicate_scan_cache FOR EACH ROW EXECUTE FUNCTION ios_touch_scanned_at();

DROP TRIGGER IF EXISTS trg_touch_generated_at ON ios_weekly_mix_cache;
CREATE TRIGGER trg_touch_generated_at BEFORE UPDATE ON ios_weekly_mix_cache FOR EACH ROW EXECUTE FUNCTION ios_touch_generated_at();

-- Cross-device playback handoff (Feature: playback-transfer): needs a
-- human-readable device list to pick a transfer target from, and a rough
-- "last seen" so a stale/uninstalled device doesn't show up forever.
-- ios_push_tokens already uniquely identifies a device (one row per
-- user+device_token) -- this just adds display metadata to rows that
-- already exist, no new table needed.
ALTER TABLE ios_push_tokens ADD COLUMN IF NOT EXISTS device_name VARCHAR(100) NULL;
ALTER TABLE ios_push_tokens ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;

-- Podcast support (Feature: podcasts) -- a genuinely new content type, not
-- covered by any existing table. Episodes are NOT cached/mirrored here --
-- /user/podcasts/episodes fetches and parses the RSS feed live on every
-- call, since podcast feeds are small and this avoids a whole sync/
-- staleness story for something the source already serves fresh. Only
-- subscriptions (which feed to follow) and per-episode resume position
-- need to persist.
CREATE TABLE IF NOT EXISTS ios_podcast_subscriptions (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    feed_url TEXT NOT NULL,
    title TEXT,
    artwork_url TEXT,
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ios_podcast_subscriptions_user_feed UNIQUE (user_id, feed_url),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_podcast_subscriptions_idx_user ON ios_podcast_subscriptions (user_id);
ALTER TABLE ios_podcast_subscriptions ADD COLUMN IF NOT EXISTS last_episode_guid TEXT;
ALTER TABLE ios_podcast_subscriptions ADD COLUMN IF NOT EXISTS last_checked_at TIMESTAMP NULL;
ALTER TABLE ios_podcast_subscriptions ADD COLUMN IF NOT EXISTS notifications_muted BOOLEAN DEFAULT FALSE;

-- guid is the RSS <guid> (or the enclosure URL when a feed omits guid) --
-- stable per episode even though episodes aren't stored anywhere else here.
CREATE TABLE IF NOT EXISTS ios_podcast_episode_progress (
    user_id VARCHAR(36) NOT NULL,
    feed_url TEXT NOT NULL,
    episode_guid VARCHAR(500) NOT NULL,
    title TEXT,
    position_seconds DOUBLE PRECISION DEFAULT 0,
    duration_seconds DOUBLE PRECISION DEFAULT 0,
    completed BOOLEAN DEFAULT FALSE,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, feed_url, episode_guid),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: real Discord account verification (OAuth2 "identify" scope) — a
-- "Discord Verified" badge next to the user's profile icon, distinct from
-- the pre-existing ios_discord_webhooks (Now Playing webhook) and
-- ios_discord_rpc_config (local Rich Presence daemon config) tables above,
-- neither of which actually confirms the user owns a specific Discord
-- account. Populated by /api/discord/oauth/callback after a real OAuth2
-- authorization-code exchange with Discord (see main.py). discord_user_id
-- is Discord's own snowflake ID for the linked account — kept even though
-- only discord_username is shown in the badge, since it's the stable
-- identity to re-check against if Discord username changes need refreshing
-- later, and it's what a future "unlink if this Discord account gets banned"
-- admin tool would key off of.
CREATE TABLE IF NOT EXISTS ios_discord_verifications (
    user_id VARCHAR(36) PRIMARY KEY,
    discord_user_id VARCHAR(32) NOT NULL,
    discord_username VARCHAR(64) NOT NULL,
    discord_avatar_hash VARCHAR(64) NULL,
    verified_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
-- A given Discord account should back at most one Lumisound "Verified"
-- badge — without this, the same Discord account could OAuth-link to many
-- Lumisound accounts and light up "Discord Verified" on all of them.
CREATE UNIQUE INDEX IF NOT EXISTS ios_discord_verifications_idx_discord_user
    ON ios_discord_verifications (discord_user_id);

-- Feature: profile bio — a short free-text tagline shown on the user's
-- profile (AccountView), alongside their display name. Deliberately its own
-- tiny table rather than another column crammed into ios_users or the
-- already-fragile ios_user_settings upsert (that one's CASE-WHEN-per-column
-- PUT handler is easy to get subtly wrong when adding a field by hand) — a
-- single-column table needs no positional-column juggling at all.
CREATE TABLE IF NOT EXISTS ios_user_profile_bio (
    user_id VARCHAR(36) PRIMARY KEY,
    bio VARCHAR(280) NOT NULL DEFAULT '',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: Aria announcements — a short in-app toast, spoken in Aria's voice,
-- broadcast to a time-boxed audience.
--
-- Deliberately NOT ios_notifications rows. That table is per-user and
-- pre-inserted, which cannot express "everyone, for the next three days":
-- an account that registers on day two would never get a row, and an account
-- that never opens the app would keep one forever. A broadcast is a window in
-- time that clients ask about, so the window is what's stored, and membership
-- is evaluated at read time. It's also a different delivery surface —
-- ios_notifications feeds the inbox and an APNs push, whereas this is an
-- in-app toast that needs no notification permission and no inbox entry.
--
-- `exclude_user_ids` is a comma-separated id list rather than a join table
-- because the only real use for it is holding back the operator from their own
-- announcement, which is one id.
CREATE TABLE IF NOT EXISTS ios_announcements (
    id VARCHAR(36) PRIMARY KEY,
    message VARCHAR(280) NOT NULL,
    -- Rendered as Aria speaking (her mark + italic voice) rather than as app
    -- chrome. False is an ordinary system toast.
    from_aria BOOLEAN NOT NULL DEFAULT TRUE,
    -- Maps to the client's ToastCategory: success/error/warning/info/download.
    category VARCHAR(20) NOT NULL DEFAULT 'info',
    starts_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ends_at TIMESTAMP NOT NULL,
    exclude_user_ids TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS ios_announcements_idx_window ON ios_announcements (ends_at, starts_at);

-- One row per (user, announcement) once that user has actually been shown it.
-- This is what stops a three-day announcement becoming a toast on every single
-- launch for three days — the window governs who is still eligible to see it,
-- this governs who already has.
--
-- No FK to ios_announcements: a row here outliving a deleted announcement is
-- harmless (it can only suppress something that no longer exists), whereas ON
-- DELETE CASCADE would silently re-show an announcement to everyone if one were
-- ever deleted and re-created with the same id.
CREATE TABLE IF NOT EXISTS ios_announcement_views (
    announcement_id VARCHAR(36) NOT NULL,
    user_id VARCHAR(36) NOT NULL,
    seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (announcement_id, user_id),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: recommended people — being offered to other users as someone with
-- similar taste.
--
-- Separate from `share_listening_activity`, and deliberately so. That flag
-- governs whether other people can see WHAT you listen to (your recent plays,
-- via /social/activity and /social/discover) and defaults to off. This one
-- governs only whether you can be SUGGESTED to someone as a similar listener,
-- which reveals no track, artist or play of yours — just that a resemblance
-- exists, plus the profile fields that /api/social/users/search already makes
-- findable by anyone who types your name.
--
-- Defaulting to TRUE is therefore not a widening of what is visible: a profile
-- is already searchable, and this exposes strictly less than the search that
-- finds it. Gating it off by default would instead make the feature empty for
-- everyone — 59 of 60 accounts have never turned on the activity flag — which
-- is the exact failure the mutual-friends suggestions already have.
--
-- Where the line actually sits: a recommendation may say "82% match" and "you
-- both lean fast and bright", because those are aggregate and name nothing. It
-- may NOT name a shared artist unless that user has turned on
-- share_listening_activity, because an artist name is a specific thing they
-- listen to. See _recommendation_reasons in main.py.
ALTER TABLE ios_users ADD COLUMN IF NOT EXISTS discoverable_in_recommendations BOOLEAN DEFAULT TRUE;

-- Feature: account security — per-account brute-force protection.
--
-- The existing throttle is per-IP (10 attempts a minute, see _check_auth_rate),
-- which stops one machine hammering the login endpoint and does nothing about
-- the attack that actually matters: the same account tried from many addresses.
-- Credential stuffing is distributed by nature, so a per-IP counter never sees
-- more than a handful of attempts from any single source while an account is
-- being worked through thousands of leaked passwords.
--
-- Tracked on the account rather than in memory so a bridge restart cannot clear
-- an attack in progress, and so the lock survives the process that observed it.
CREATE TABLE IF NOT EXISTS ios_login_failures (
    user_id VARCHAR(36) PRIMARY KEY,
    failure_count INTEGER NOT NULL DEFAULT 0,
    first_failure_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_failure_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- NULL when not locked. A lock is always temporary: a permanent one hands
    -- an attacker a denial-of-service against any account whose username they
    -- know, which is a worse outcome than the guessing it prevents.
    locked_until TIMESTAMP NULL,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_login_failures_idx_locked ON ios_login_failures (locked_until);

-- Feature: account security — which devices have signed in.
--
-- Exists so a sign-in from somewhere new can be recognised as new. Without any
-- record of what "usual" looks like there is nothing to compare a fresh login
-- against, and the account's owner is the only person able to say whether a
-- session is theirs — so they have to be told it happened.
--
-- Deliberately stores a HASH of the device descriptor, never the descriptor
-- itself: its only job is equality ("have we seen this before"), which a hash
-- answers exactly as well, and a table of device names and OS versions is worth
-- something to an attacker who reaches the database while a table of digests is
-- not.
CREATE TABLE IF NOT EXISTS ios_known_devices (
    user_id VARCHAR(36) NOT NULL,
    device_hash VARCHAR(64) NOT NULL,
    first_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, device_hash),
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);

-- Feature: artist images (see main.py GET /api/artist/image +
-- _artist_image_loop). One row per distinct artist name — global and
-- lowercased, same key convention as ios_artist_bio_cache above — rather
-- than per-user, since a real artist's photo/channel icon isn't something
-- each user resolves separately. There is no dedicated "artists" table in
-- this schema (artist is a free-text column on ios_user_music_metadata /
-- ios_play_history / etc.), so this cache is keyed loosely by that same
-- free-text name rather than a foreign key.
--
-- Populated two ways: lazily by GET /api/artist/image the first time any
-- client asks about a name nobody has looked up yet, and proactively by the
-- _artist_image_loop background job, which walks real artist names out of
-- the user's own library/history so the cache fills in even for names no
-- client has requested yet. Resolution order (see _resolve_artist_image):
-- Deezer artist search -> Wikipedia artist photo -> the artist's own
-- YouTube channel icon (via the existing YouTube Data API key) as the
-- fallback for artists who only really exist as a YouTube channel.
--
-- `found = FALSE` is a real cache entry too, so an obscure/YouTube-only
-- name isn't re-queried against three APIs on every tick — see
-- _ARTIST_IMAGE_NOTFOUND_RECHECK_DAYS. Once `found = TRUE`, last_checked_at
-- gates a re-VALIDATION (does image_url still resolve?), not a blind
-- re-fetch: the background loop only touches image_url again if that
-- validation finds the stored URL has actually broken. This is the "don't
-- constantly redownload/reset once correctly set" behavior the feature was
-- asked for — a correct image is left alone indefinitely unless it
-- actually goes stale.
CREATE TABLE IF NOT EXISTS ios_artist_image_cache (
    artist_name VARCHAR(255) PRIMARY KEY,
    image_url TEXT NULL,
    image_source VARCHAR(16) NULL,  -- 'deezer', 'wikipedia', or 'youtube'
    found BOOLEAN NOT NULL DEFAULT FALSE,
    last_checked_at TIMESTAMP NULL,
    resolved_at TIMESTAMP NULL
);

-- Feature: default 10GB per-user storage quota, admin-exempt (2026-10-22).
--
-- storage_quota_bytes (added above, in the "per-user storage quota override"
-- feature) started life as a pure OVERRIDE: NULL/0 meant "use the server-wide
-- USER_MUSIC_QUOTA_BYTES default", itself unlimited unless an operator opted
-- a specific user into a cap. Product decision now is a flat 10GB quota for
-- every account BY DEFAULT, with the single admin/operator account
-- (OPERATOR_USER_ID in main.py, 'ca8a4c53-5603-472e-9287-5fb879f28090')
-- exempt.
--
-- `ALTER COLUMN ... SET DEFAULT` only changes what NEW rows get going
-- forward -- both /auth/register and the Discord auto-register path INSERT
-- INTO ios_user_settings (user_id) with no storage_quota_bytes, so new
-- signups pick this default up for free. It does nothing for rows that
-- already exist with storage_quota_bytes NULL (or some other value), hence
-- the one-time-per-deploy UPDATE below, which backfills every CURRENT
-- non-admin account to the same 10GB figure. (main.py's
-- _storage_quota_default_janitor repeats this same UPDATE on a daily loop
-- so the invariant holds on an ongoing basis too -- e.g. after an admin
-- override via PUT /admin/api/users/{id}/quota -- not just at migration
-- time; this statement here just means a brand-new deploy doesn't have to
-- wait for that loop's first tick.)
--
-- 10GB here is binary (10 * 1024^3 = 10737418240), matching every other
-- byte-size constant in this codebase (_MAX_GALLERY_IMAGE_BYTES, the 100MB
-- upload cap, etc. are all `n * 1024 * 1024[ * 1024]`, never a decimal
-- 10**9-style GB) -- see main.py's _DEFAULT_USER_STORAGE_QUOTA_BYTES.
--
-- The operator account is deliberately excluded from both statements below,
-- so it stays NULL -> falls through to USER_MUSIC_QUOTA_BYTES (0/unlimited),
-- exactly as before this feature existed.
ALTER TABLE ios_user_settings ALTER COLUMN storage_quota_bytes SET DEFAULT 10737418240;
UPDATE ios_user_settings SET storage_quota_bytes = 10737418240
    WHERE user_id <> 'ca8a4c53-5603-472e-9287-5fb879f28090'
      AND (storage_quota_bytes IS NULL OR storage_quota_bytes <> 10737418240);

-- Feature: rate-limit username changes to twice per rolling 30 days
-- (2026-10-22).
--
-- There was previously no way at all to change a username after
-- registration -- the only two places that ever INSERT one are
-- /auth/register and the Discord auto-register path. PUT /auth/me now
-- accepts a `username` field; this table is the audit trail that endpoint's
-- rate limit is built on (see _check_username_change_rate_limit in
-- main.py): one row per successful change, so "how many times in the last
-- 30 days" is a plain COUNT/SELECT over a rolling window keyed off each
-- change's own timestamp, not a calendar-month counter that resets on the
-- 1st regardless of when the changes actually happened.
CREATE TABLE IF NOT EXISTS ios_username_change_log (
    id SERIAL PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    old_username VARCHAR(255) NOT NULL,
    new_username VARCHAR(255) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES ios_users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ios_username_change_log_idx_user_time ON ios_username_change_log (user_id, changed_at);
