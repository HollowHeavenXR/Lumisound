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

## Migration method (bridge) — DONE 2026-11-01

Python is deleted from the repo. Production still runs the last Python image
until go-live (see notes). Staged compose: ~/Projects/web-stack/docker-compose.yml
(single Rust `ios-bridge` service, 1536M for Demucs; previous file kept as
docker-compose.yml.bak-before-rust-only). Go-live command, once the app is
released: `cd ~/Projects/web-stack && docker compose up -d --build ios-bridge`.

Historical method:

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
- [x] 8. AI (Gemini over HTTP): intelligence/*, lyrics (+ transcribe), ai-dj, aria apis
- [x] 9. Admin + logs: /admin*, /bug-report, /internal/logs, /api/log-event, janitors
- [x] 10. Stem separation (spawn demucs CLI, same wrapper pattern as yt-dlp), fingerprint (fpcalc)
- [x] 11. Delete Python; Dockerfile without Python app (keep yt-dlp + demucs CLIs)

## App core (Swift Services → rust/core)

Branch `rust-app-core` (merge to main = release). Verify every step with
`gh workflow run build-ios.yml --ref rust-app-core -f configuration=Debug`
(branch builds never tag). Crates: rust/core (UniFFI, module LumisoundCore),
rust/media (shared with the bridge). Swift glue: ios/Shared/Core/Core.swift.
Swift models stay Codable view-data shapes; logic moves to Rust.

- [x] A. Crate + UniFFI + build-core.sh + CI step in all 6 workflows (CI build green 2026-11-01)
- [ ] B. API client + auth/token store + all AccountService+* calls
      [x] _makeRequest -> Rust ApiClient (retries, FastAPI errors, 401)
      [x] every URLSession.shared.data/upload in the iOS app -> Core.data(for:) (Rust http_send)
      [ ] token/session store, sync debounce + inventory diff logic
      [x] LiveUpdateService socket -> Rust live.rs (typed events, backoff)
- [ ] C. Lock system
      [x] LMSLOCK1 lock/unlock (streamed, atomic), playable cache, vault (AES-GCM), xattr tag
      [ ] LumisoundExclusiveExtensionService.convert pipeline + relock/integrity passes
      [ ] AppLockService state (LocalAuthentication prompt itself stays Swift)
- [ ] D. Download manager (BackgroundDownloadManager, StreamingService+DownloadToLibrary,
      DownloadLedgerStore, DownloadFailureStore, AudioTagWriter -> lofty)
      [x] core store.rs (Application Support/LumisoundCore JSON docs) + downloads.rs
          (ledger, in-flight claims, failure cool-offs, dest naming, formats)
      [ ] job flow (start/poll/relay/direct), finalize+lock, tagging
- [ ] E. Audio engine — rust/core/src/engine/ (deck threads: symphonia + rubato -> rtrb
        rings; realtime mixer: gapless, crossfade cmd, RBJ 10-band EQ, Freeverb, mono,
        night-mode compressor, de-click/pause fades, per-track gain, peaks; cpal output on
        iOS/macOS; offline-render tests). CI green 2026-11-01.
      [x] Local files play through it (AudioPlayerManager+RustEngine.swift; Settings >
          Playback "Lumisound Audio Engine" toggle, key rust_audio_engine, default on;
          decode failure -> automatic AVAudioEngine fallback)
      [x] crossfade via engine.crossfade_to (equal-power/linear, smart plan length)
      [ ] beat-match rate during smart crossfade; speed/pitch (time-stretch)
      [x] ReplayGain/normalization applied in-engine (set_track_gain)
      [x] streams play on the engine once downloaded; Opus via its transcoded AAC copy
      [ ] spatial/8D/special effects, visualizer FFT taps, music haptics feed
      [ ] then delete the AVAudioEngine graph (EngineConfig/SpatialAudio/Effects nodes)
- [ ] F. Library index + analysis (BPM, beat grid, fingerprint, duplicates, corrupt files,
      silence trim, spectral EQ, pitch contour, normalization)
      [x] media::decode (symphonia) + media::analysis (DSP shared with bridge);
          core analysis.rs: decode_mono, bpm (cached), key, waveform, transition, spectral
      [x] BPMAnalyzerService on the core (AVAssetReader only for Opus/WebM)
      [ ] Opus decode in Rust (symphonia has none; options: libopus static via audiopus_sys)
      [x] NormalizationService -> core normalization_gain (BS.1770, = ffmpeg ebur128 on test)
      [x] beat grid, acoustic fingerprint (+similarity), silence trim, pitch contour/hum match
      [ ] duplicate finder orchestration, corrupt finder (core is_valid_audio exists;
          CorruptFileFinder still AVAudioFile), library scan/index
- [ ] G. Remaining services (social, rooms, podcasts, stats, backups, cache, diagnostics,
      stores: PlayHistory/Bookmark/TimeCapsule/LongTrackResume/RecentlyDeleted, Lua engines)
- [ ] H. Swift rewired, old Swift services deleted, tvOS/watchOS on the core, release tag
- [x] I. Appearance system: 7 styles (Liquid Glass, Frosted, Solid, Midnight OLED, Neon,
      Aurora, Minimal Mono) + density, tokens in rust/core/src/appearance.rs, picker in
      Settings > Appearance, synced via /user/appearance. (No light style yet: ~180 views
      hard-code white; needs a view sweep first.)
- [ ] J. Audit: every remaining Swift file is view/app-shell/UniFFI glue only (list exceptions
        that iOS strictly requires: AVAudioSession, MPNowPlaying/RemoteCommand, BGTask,
        URLSession background transfers, Keychain, WidgetKit/ActivityKit/AppIntents/CarPlay
        entry points, WatchConnectivity, LocalAuthentication)

## Other

- [x] discord-rpc daemon → rust/rpc (binary lumisound-discord-rpc + `login`; installers updated;
      release-rpc.yml builds Linux/macOS/Windows on rpc/v* tags — runs once merged to main)
- [ ] README / docs updated

## Notes / decisions log

- 2026-10-31: Go-live (Rust on :8002, Python on 127.0.0.1:8012) is staged in
  ~/Projects/web-stack/docker-compose.yml but NOT deployed: the auto-mode
  classifier blocks production deploys, so the user has to run
  `cd ~/Projects/web-stack && docker compose up -d ios-bridge-legacy ios-bridge`.
  (The scratchpad compose backup was lost in a 2026-11-01 reboot; rollback =
  point `ios-bridge` back at `build: ../Lumisound/ios-bridge` on :8002 and drop
  `ios-bridge-legacy`. Prod still runs the old Python image until go-live.)
- 2026-11-01 (user): go live with the Rust bridge ONLY after the Rust-core app
  is verified and released on GitHub. After all phases, tag one big release
  (app functionally all-Rust). App work happens on branch `rust-app-core`
  (CI dispatch builds there never tag); merging to main cuts the release.
- Test rig (isolated): network lumi-test (internal) + lumi-test-out; containers
  lumi_test_pg (tmpfs copy of discord_music_gws, webhooks/push tokens blanked),
  lumi_py_test, lumi_rs_test. Harness lives in rust/tests/parity: setup.sh
  (whole rig from scratch), restart.sh (recreate bridges), run.sh <cases.json>
  (diff py vs rs), jobs.py (transcribe / stems / fingerprint end-to-end).
  Test accounts rusttest + rustmade1, operator session minted in the copy
  (tokens.json, gitignored).
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
- Groups 8-10: Gemini over REST (rust/bridge/src/gemini.rs; prompts/schemas extracted
  verbatim to prompts.json; cache keys = sha256 of Python-identical json.dumps so the
  Python and Rust bridges share ios_intelligence_cache). Lyrics transcription keeps
  whole-track-then-windowed-repair. Stems: Demucs htdemucs spawned as a CLI (torch 2.3.1
  + demucs 4.0.1 + baked weights in the Rust image), same pattern as yt-dlp.
- Fixed vs Python: request bodies were capped at axum's 2 MB default (Python had none) —
  now 256 MB globally. serde_json float_roundtrip on (exact decimals in jsonb passthrough).
- Remaining 422 diffs are only pydantic's extra `input`/`ctx`/`type` fields in
  validation errors; the apps read `detail` text only on 4xx.
- Final regression (rust/tests/parity/c_all_get.json, every Python GET route x 2 users):
  only validation-ordering (Python validates query before API key; both are errors),
  random OAuth state, newer yt-dlp thumbnails and the documented shadowing fixes differ.
- Known schema quirk (unchanged): ios_user_music_metadata.id is the content hash alone, so
  two users uploading the same file share one row (second upload rewrites the first's).
