# Lumisound → Rust remake

Goal (user, 2026-10-31): rebuild every functional system in Rust. Swift keeps only SwiftUI views
and thin bindings. Downloads = Rust wrapper around the yt-dlp CLI. Audio = symphonia + cpal.
Postgres via sqlx. App ↔ Rust via UniFFI. Optimize as we go.

## Layout

```
rust/                      cargo workspace
  media/   lumisound-media   shared, no I/O runtime: LMSLOCK1 lock format, symphonia decode,
                             BPM / transition / spectral analysis, tag reading
  bridge/  lumisound-bridge  axum + sqlx server (replaces ios-bridge/*.py), yt-dlp wrapper
  core/    lumisound-core    UniFFI lib for iOS/tvOS/watchOS: API client, account/sync,
                             lock system, download manager, audio engine, library index
  rpc/     lumisound-rpc     Discord Rich Presence daemon (replaces discord-rpc/*.py)
```

## Migration method (bridge)

The Rust bridge listens on :8002. Any route not ported yet is reverse-proxied to the Python
bridge (moved to 127.0.0.1:8012, `LEGACY_URL`). Port one route group at a time, compare
responses against Python, then flip. When the list below is all checked, delete Python.

## Bridge route groups (main.py, 292 routes)

- [x] 0. Skeleton: config, sqlx pool, JWT auth, admin auth, rate limit, legacy proxy, /health, deploy
- [x] 1. Downloads + streaming: /api/search, /api/stream*, /api/download* (single, batch, relay,
        status/result/pending), /api/track, /api/resolve, /api/playlist/*, /api/spotify/resolve,
        /api/radio, /api/motion-artwork — yt-dlp wrapper (spawn, JSON parse, progress, cookies,
        PO token, adaptive limiter)
- [x] 2. Auth: /auth/* (register, login, 2FA, sessions, password, delete, me), Discord OAuth
- [x] 3. Library core: /user/playlists*, /user/favorites, /user/settings*, /user/sync, /user/backups,
        /user/folder-backups, /user/library/*, /user/history, /user/queue, /user/playback-state
- [x] 4. Cloud music + lock system: /user/music/* (upload, stream, artwork, waveform, metadata,
        delete), /api/library/server*, /user/storage/usage, locked_media.py (.lms), media backfill
        loop, artist image loop, duplicate scan loop
- [x] 5. Stats/discovery (stations, daily-pick, liner-notes moved to 8 — they call Gemini): /user/stats*, /user/on-this-day, recommendations, smart-playlists,
        weekly-mix, discover-mix, stations, daily-pick, achievements, liner-notes, /api/artist/*
- [x] 6. Social: /api/social/*, /social/*, /ws/live, rooms, device-sync, shared playlists,
        collaborators, comments, presence
- [x] 7. Integrations: subscriptions (YouTube), podcasts, scrobble (last.fm/libre.fm), Discord
        webhook + RPC config + verification, push tokens + APNs/FCM, notifications,
        announcements, webhooks, gif search, ytdlp-cookies, API keys
- [ ] 8. AI (Gemini over HTTP): intelligence/*, lyrics (+ transcribe), ai-dj, aria apis
- [ ] 9. Admin + logs: /admin*, /bug-report, /internal/logs, /api/log-event, janitors
- [ ] 10. Stem separation (spawn demucs CLI, same wrapper pattern as yt-dlp), fingerprint (fpcalc)
- [ ] 11. Delete Python; Dockerfile without Python app (keep yt-dlp + demucs CLIs)

## App core (Swift Services → rust/core)

- [ ] A. Crate + UniFFI + build-core.sh + CI xcframework step (copy SwarmPanel pattern)
- [ ] B. API client + auth/token store + all AccountService+* calls
- [ ] C. Lock system (AppLockService, LumisoundTrackVaultService, LMSLOCK1)
- [ ] D. Download manager (BackgroundDownloadManager, StreamingService+DownloadToLibrary, ledger)
- [ ] E. Audio engine: symphonia decode + cpal output, queue, gapless, crossfade, EQ/effects,
        A-B repeat, speed/pitch, ReplayGain, visualizer taps; Swift keeps AVAudioSession +
        NowPlaying/remote commands glue only
- [ ] F. Library index + analysis (BPM, beat grid, fingerprint, duplicates, corrupt files, tags)
- [ ] G. Remaining services (social, rooms, podcasts, stats, backups, cache, diagnostics…)
- [ ] H. Swift rewired, old Swift services deleted, tvOS/watchOS on the core, release tag
- [ ] I. Appearance system (user ask 2026-10-31): more styles besides Liquid Glass. Theme
        definitions/tokens + selection/persistence live in Rust core (`appearance` module:
        styles e.g. Liquid Glass, Solid, Midnight OLED, Paper/Light, Vapor/Neon, Minimal Mono,
        accent + density + corner + blur params); Swift only maps tokens -> SwiftUI modifiers.
        Picker in Settings, synced via user settings.
- [ ] J. Audit: every remaining Swift file is view/app-shell/UniFFI glue only (list exceptions
        that iOS strictly requires: AVAudioSession, MPNowPlaying/RemoteCommand, BGTask,
        URLSession background transfers, Keychain, WidgetKit/ActivityKit/AppIntents/CarPlay
        entry points, WatchConnectivity)

## Other

- [ ] discord-rpc daemon → rust/rpc
- [ ] README / docs updated

## Notes / decisions log

- 2026-10-31: Go-live (Rust on :8002, Python on 127.0.0.1:8012) is staged in
  ~/Projects/web-stack/docker-compose.yml but NOT deployed: the auto-mode
  classifier blocks production deploys, so the user has to run
  `cd ~/Projects/web-stack && docker compose up -d ios-bridge-legacy ios-bridge`.
  Compose backup: scratchpad compose.before-lumi-rust.yml.
- Test rig (isolated): network lumi-test (internal) + lumi-test-out; containers
  lumi_test_pg (tmpfs copy of discord_music_gws, webhooks/push tokens blanked),
  lumi_py_test, lumi_rs_test. Scripts in the session scratchpad harness/:
  restart.sh (recreate bridges), run.sh <cases.json> (diff py vs rs), dl.py.
  Test account: rusttest / operator session minted in the copy (tokens.json).
- Rust owns /ws/live. Python relays its live events to Rust via LIVE_PUSH_URL
  (POST /internal/live-push, X-Internal-Token = sha256(IOS_JWT_SECRET|live-push)).
- Fixed vs Python: purpose tokens (2FA-pending, OAuth state) no longer work as
  sessions. raw stream URL = one yt-dlp run with chained formats (was up to 3).
  Stream proxy prefetches the next 2 MB range. yt-dlp in the Rust image is
  unpinned/latest (Python pinned 2026.08.19, which no longer reads RD mixes).
- Push: rust/bridge/src/push.rs (APNs HTTP/2 ES256 token, FCM v1 service-account OAuth); still
  unconfigured on this host (no APNS_*/FCM_* env), so it no-ops like Python did.
- POST /user/history moved to Rust with scrobbling (Last.fm/ListenBrainz/Libre.fm) + Discord now-playing.
- Dates: apps parse `yyyy-MM-dd'T'HH:mm:ss.SSSSSS` (or no fraction). SQL uses
  `lumi_iso(ts)` (installed by the bridge at startup) and Rust `db::py_iso`
  to match Python isoformat() exactly. Don't use to_json(timestamp).
- Python's /user/playlists/{id} (declared first) shadowed /user/playlists/folders and
  /shared-with-me (both 404'd). axum prefers static segments, so folders now works;
  shared-with-me now served (group 6). Same shadowing fixed for /api/social/presence/listening-together.
- POST /user/history stays on Python (method fallback) until scrobbling (group 7).
- Sync push / restore / queue / inventory now run in one transaction (Python was autocommit).
- Group 4: uploads stream to disk while hashing (Python buffered 100 MB in RAM); upload
  analysis is ONE ffmpeg decode (asplit -> loudnorm + 11025 Hz + 5512 Hz) instead of four,
  results bit-identical to Python on test tracks. LMSLOCK1 unmask is a seekable XOR stream
  (rust/bridge/src/lock.rs); readable_copy handles gzip+lock together. Background loops
  media_backfill / duplicate_scan / storage_quota run in Rust (RUST_LOOPS), Python skips
  them via LEGACY_DISABLE_LOOPS (patched lifespan).
- serde_json preserve_order is on: JSON keys keep insertion order like Python dicts.
- Known schema quirk (unchanged): ios_user_music_metadata.id is the content hash alone, so
  two users uploading the same file share one row (second upload rewrites the first's).
