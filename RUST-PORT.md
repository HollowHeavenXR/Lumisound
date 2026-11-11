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
- [x] B. API client + auth/token store + all AccountService+* calls
      [x] _makeRequest -> Rust ApiClient (retries, FastAPI errors, 401)
      [x] every URLSession.shared.data/upload/download in the iOS app -> Core.data/upload/download (Rust http_send / http_download_file)
      [x] sync payload/pull merge plan (sync.rs), inventory ids/unchanged-skip/retried replace,
          retry policy; token stays in the Keychain (Security framework, Swift-only), debounce is a Swift Task
      [x] LiveUpdateService socket -> Rust live.rs (typed events, backoff)
- [x] C. Lock system
      [x] LMSLOCK1 lock/unlock (streamed, atomic), playable cache, vault (AES-GCM), xattr tag
      [x] convert pipeline (lms_convert: lock, round-trip verify, adopt/replace) + in-place relock
      [x] AppLock state machine (applock.rs; LocalAuthentication prompt itself stays Swift)
- [x] D. Download manager (BackgroundDownloadManager, StreamingService+DownloadToLibrary,
      DownloadLedgerStore, DownloadFailureStore, AudioTagWriter -> lofty)
      [x] core store.rs (Application Support/LumisoundCore JSON docs) + downloads.rs
          (ledger, in-flight claims, failure cool-offs, dest naming, formats)
      [x] bridge job flow (start/poll/stream result) -> core bridge_download_job
      [x] tag writing/reading (lofty; MP4 freeform, ID3 TXXX, Vorbis) — verified with ffprobe
      [x] direct/relay transports (bridge_direct_fetch / bridge_relay_download), finalize
          (downloads_finalize_file), ledger-aware destination; lock via lms_convert
- [x] E. Audio engine — rust/core/src/engine/ (deck threads: symphonia + rubato -> rtrb
        rings; realtime mixer: gapless, crossfade cmd, RBJ 10-band EQ, Freeverb, mono,
        night-mode compressor, de-click/pause fades, per-track gain, peaks; cpal output on
        iOS/macOS; offline-render tests). CI green 2026-11-01.
      [x] Local files play through it (AudioPlayerManager+RustEngine.swift; Settings >
          Playback "Lumisound Audio Engine" toggle, key rust_audio_engine, default on;
          decode failure -> automatic AVAudioEngine fallback)
      [x] crossfade via engine.crossfade_to (equal-power/linear, smart plan length)
      [x] speed/pitch (WSOLA time-stretch + pitch resample), 8D rotation, tremolo, visualizer tap,
          spectrum FFT in Rust
      [x] vibrato (modulated delay), spatial audio + head tracking (binaural: Woodworth ITD + Brown–Duda head shadow)
      [x] beat-matched smart crossfade (per-deck tempo ramp, exact position tracking, beatmatch_ratio)
      [x] ReplayGain/normalization applied in-engine (set_track_gain)
      [x] streams play on the engine once downloaded; Opus via its transcoded AAC copy
      [x] music haptics (fed through the visualizer tap)
      [x] AVAudioEngine/AVPlayer remain only as fallback (Apple Music ipod-library:// items can only be read by
          AVFoundation; decode failures; Settings toggle off)
- [x] F. Library index + analysis (BPM, beat grid, fingerprint, duplicates, corrupt files,
      silence trim, spectral EQ, pitch contour, normalization)
      [x] media::decode (symphonia) + media::analysis (DSP shared with bridge);
          core analysis.rs: decode_mono, bpm (cached), key, waveform, transition, spectral
      [x] BPMAnalyzerService on the core (AVAssetReader only for Opus/WebM)
      [x] Opus/WebM decode in Rust (pure-Rust opus-decoder as a symphonia codec; vendored fix)
      [x] NormalizationService -> core normalization_gain (BS.1770, = ffmpeg ebur128 on test)
      [x] beat grid, acoustic fingerprint (+similarity), silence trim, pitch contour/hum match
      [x] corrupt/truncated check (core validate_audio; AVAudioFile only for Opus)
      [x] duplicate grouping + text normalisation (core duplicates.rs)
      [x] scan-time tag/property reading (core scan_read_track, lofty)
- [x] G. Remaining services (social, rooms, podcasts, stats, backups, cache, diagnostics,
      stores: PlayHistory/Bookmark/TimeCapsule/LongTrackResume/RecentlyDeleted, Lua engines)
      [x] library snapshot load/re-anchor/group/save (core library.rs)
      [x] PlayHistory, Bookmark, LongTrackResume stores (core stores.rs)
      [x] TimeCapsule, DeletedPlaylists, RecentlyDeleted, ListeningGoal, IntelligenceSuggestionCache
      [x] TrackedPlaylist store, ScanCache (batch partition)
      [x] Lua engines on a Rust Lua 5.4 runtime (mlua, sandboxed, json module); LuaSwift removed
      [x] sync payload/merge, tracked-playlist pass rules + LocalCopyIndex pre-download gate
      [x] metadata lookup chain, artwork processing, artist photos, smart playlists, moods (metadata.rs, smart.rs, mood.rs)
      [x] AI DJ session (aidj.rs), cache housekeeping (cache.rs), logging + events (logger.rs, iOS + tvOS),
          document import + Documents scan orchestration (import.rs)
- [ ] H. Swift rewired, old Swift services deleted, tvOS/watchOS on the core, release tag
      [x] tvOS app links the core (all HTTP via Core.data); universal iOS simulator slice
      [x] watchOS app links the core (arm64_32/arm64 device + universal simulator) — CI green
      [ ] delete superseded Swift (AV graph etc.); release tag
- [x] I. Appearance system: 7 styles (Liquid Glass, Frosted, Solid, Midnight OLED, Neon,
      Aurora, Minimal Mono) + density, tokens in rust/core/src/appearance.rs, picker in
      Settings > Appearance, synced via /user/appearance. (No light style yet: ~180 views
      hard-code white; needs a view sweep first.)
- [ ] J. Audit (ios/SWIFT-AUDIT.md written: wrappers / Apple-required / still-Swift lists): every remaining Swift file is view/app-shell/UniFFI glue only (list exceptions
        that iOS strictly requires: AVAudioSession, MPNowPlaying/RemoteCommand, BGTask,
        URLSession background transfers, Keychain, WidgetKit/ActivityKit/AppIntents/CarPlay
        entry points, WatchConnectivity, LocalAuthentication)

## Other

- [x] discord-rpc daemon → rust/rpc (binary lumisound-discord-rpc + `login`; installers updated;
      release-rpc.yml builds Linux/macOS/Windows on rpc/v* tags — runs once merged to main)
- [x] README / docs updated (root README, ios/README, ios-bridge/README, discord-rpc/README)

## Notes / decisions log

- 2026-11-01: Rust bridge live in production (single `ios-bridge` service in
  ~/Projects/web-stack, :8002 behind cloudflared). The Python bridge, its
  images, the parity harness and the rollback compose backup were removed.
- 2026-11-01 (user): go live with the Rust bridge ONLY after the Rust-core app
  is verified and released on GitHub. After all phases, tag one big release
  (app functionally all-Rust). App work happens on branch `rust-app-core`
  (CI dispatch builds there never tag); merging to main cuts the release.
- Test rig (isolated): network lumi-test (internal) + lumi-test-out; containers
  lumi_test_pg (tmpfs copy of discord_music_gws, webhooks/push tokens blanked),
  lumi_py_test, lumi_rs_test, driven by a py-vs-rs diff harness (removed with the
  Python bridge after go-live 2026-11-01).
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
- Final regression (every Python GET route x 2 users):
  only validation-ordering (Python validates query before API key; both are errors),
  random OAuth state, newer yt-dlp thumbnails and the documented shadowing fixes differ.
- Known schema quirk (unchanged): ios_user_music_metadata.id is the content hash alone, so
  two users uploading the same file share one row (second upload rewrites the first's).
- 2026-11-07 stream storm fix: AVURLAsset readers (artwork, ReplayGain, BPM) opened
  streamed songs over /api/stream/proxy and every range request ran yt-dlp (one song:
  342 runs in 48 h, 35-85 s each behind the limiter) -> streams timed out, skipped, app
  crashed once. Bridge: per-track singleflight resolve + failure memory (stream_failures)
  + shared 3 s googlevideo settle (stream_resolved_at). App: StreamCache.localURL (analysis
  reads the downloaded copy only); a failed stream download retries once then skips
  (never AVPlayer on the proxy URL); a superseded load's failure is ignored.

## 2026-11-07 upgrade + stability pass

Done:
- [x] Smart Shuffle (rust/core/src/shuffle.rs; Swift `SmartShuffle` / `[Song].smartShuffled()`):
      weighted random order (recently played and often-skipped songs later), artist/album
      spreading (24-song look-ahead; artist just played never repeats when avoidable), tempo
      smoothing (half/double time count as close). Used by the queue shuffle and every Shuffle
      button. Settings > Playback > Smart Shuffle (key `smartShuffleEnabled`, default on).
- [x] Skip learning: `userSkipToNext()` (buttons, swipes, remote, Siri, shake) records early
      skips (< 30 s, or < 40 % of a short song) in core `skip_history`; automatic advances
      (song ended, load failed) don't count. Plays offset skips.
- [x] Core store writes are background + coalesced (250 ms); `core_flush()` on app background.
      Every play/skip used to write a whole JSON file on the main thread.
- [x] Upload storm: the app re-downloaded the full cloud list (5.7k tracks) after every
      upload, up to 17x a minute during backups. The bridge now returns the stored row as
      `track` in the upload response; concurrent list fetches share one request; background
      passes reuse a list < 30 s old; JSON decode is off the main thread.
- [x] '+' in bridge query strings is sent as %2B (core client.rs). The bridge read it as a
      space, so "Goku + Vegeta.opus" was stored as "Goku   Vegeta.opus" and re-uploaded on
      every backup pass. A duplicate upload now heals the stored original_filename.

Open / ideas:
- [x] Engine test `beatmatched_crossfade_...` failing in debug: the test pump now waits for the
      decks to have each chunk buffered (decoder-paced), so it passes in debug and release.
- [x] "Often skipped" songs in Library Health with per-song Forget + Reset All (see below).
- [x] Sync skip history across devices (see below).
- [ ] Incremental `/user/music/metadata?since=`: deprioritised; the metadata table holds only
      ~25 rows in production (the heavy list is the file walk `/user/music`, now off the async
      workers). Revisit if libraries grow.
- [ ] H. delete superseded Swift (AV graph etc.) — still open from the port.

## 2026-11-07 (evening) upgrade + stability pass

Telemetry check first (ios_app_event_log, last 3 days): no crashes/hangs since 2.0.0.11;
stream_proxy_auth_rejected stopped after 2.0.0.11; the engine's "clipping" counts are samples
its look-ahead limiter caught (not audible clipping); remaining issue = 1-10 ms underruns in the
first 0.5 s of a track (phase "starting", Bluetooth, locked Opus).

Done:
- [x] Engine start head-start: a deck's first frame plays once 60 ms is buffered (or decoding
      finished) — mixer.rs `start_prefill_samples`. Fixes the start-of-track underruns.
      Quality suite (release) unchanged: start/seek click scores 1.07 / 5.26 (limit 8).
- [x] Deck decode threads run at QOS_CLASS_USER_INTERACTIVE on Apple platforms (deck.rs).
- [x] Skip learning v2 (core stores.rs): skips fade (half-life 60 days); `skip_top`,
      `skip_clear_all`; cleared songs kept as zero-count entries so the clear syncs.
      Smart Shuffle weighs faded skips (threshold 1.5).
- [x] Skip sync: bridge `POST /user/skip-history` (table ios_user_skip_history, `rev` cursor
      from a sequence; newer `updated` wins; the caller's own kept rows aren't echoed back).
      Core `skip_sync_batch` / `skip_sync_apply` / `skip_sync_reset` (per-entry dirty flag,
      oldest-first batches of 5000). App syncs on start, every 20 min, on backgrounding; the
      cursor resets on sign-out (AccountService+SkipSync.swift).
- [x] Often Skipped screen (Library Health > Listening): songs Smart Shuffle holds back, swipe
      to Forget, Reset All (OftenSkippedView.swift).
- [x] Bridge `/user/music`: per-file canonicalize/stat loop moved to spawn_blocking (it ran on
      the async workers), tokio canonicalize for tag reads, sort with cached lowercase keys.

## 2026-11-08 custom Music Haptics + Skip Silent Intros

Both rebuilt from scratch in the core; Swift only plays cues / applies offsets.

- [x] Music Haptics (rust/core/src/haptics.rs): 3-band onset analysis (low <150 Hz, mid
      180 Hz-1.8 kHz, high >3.5 kHz) with track-adaptive thresholds, cross-band leakage
      filter, merged co-hits, density caps (12/s total, 6/s hi-hats), dynamics scaling,
      continuous rumble with a 50 ms envelope for sustained bass. Long tracks analysed in
      300 s pieces off one front-to-back decode (decode::mono_pcm_blocks), so memory stays
      flat. Scores cached (blob cache "haptics_v1", compact binary). HapticScheduler times
      cues against engine position, output latency and speed, detects seeks.
      MusicHapticsService.swift rewritten (Core Haptics player, 0.15 s ticks, 0.45 s
      look-ahead, Subtle/Balanced/Intense); no longer runs the FFT visualizer tap.
- [x] Skip Silent Intros (rust/core/src/intro.rs): level relative to the track (p90),
      silence < -66 dBFS avg (~ -60 peak), sound must hold 80 ms (crackle ignored), steady
      hiss/hum (35 dB under, std < 3 dB) skipped to the music, quiet intros/fades kept,
      60 ms pre-roll. Engine opens tracks at the cached offset (load, gapless
      queue_next_at, crossfade); next track analysed ahead; first-play fallback seek only
      while still in the silence. tvOS TVSilenceTrim uses the same core detector. Old
      leading_silence removed.
- [x] Decoder: picks the audio track when an .m4a/.mp4 lists video first (one cloud track
      couldn't play/analyse in Rust before).
- Cloud tests (LUMI_CLOUD_DIR = copies of the cloud library, ~/lumisound/test-copies):
  - tests/haptics_cloud.rs — pass 1: beat recall 68%, 11 "silent" hits (a test indexing
    bug: 9.977 ms windows read as 10 ms). Pass 2 (sensitivity 2.5 dB, k 0.28, leakage +
    mix-relative floor): audible-beat recall 82%, 93% of haptics on onsets, 0 in silence,
    timing +5 ms vs beat grid. Pass 3 (different 61 tracks + 50-min DJ mix): 85% / 91%,
    chunked = whole within 0.4%, 190-600x real time on desktop.
  - tests/intro_cloud.rs (all 678 tracks, 288-306 checked against ffmpeg silencedetect) —
    pass 1: 27 later than ffmpeg (jumped over quiet sounds). Pass 2: start at first sound
    after silence: 13. Pass 3: silence level -66 dB avg + audio-track fix: green; the 7
    tracks starting later than ffmpeg only cross a floor 40 dB+ under the music.

## 2026-11-09 engine, Blend, Radio, Aria Lyrics, Haptics Brain, realness

Done:
- [x] Pitch "stutter dips" fixed (engine/stretch.rs): transient phase resets now only touch bins
      that jumped 6 dB+ (the whole-frame reset cancelled notes still ringing under each drum hit),
      and peak regions split at the quietest bin between peaks. Cloud tracks: 320 -> ~41 dips/min
      (Rubber Band scores 300 on the same metric); sustained bass under hits 4-8 dB dips -> <1.6 dB.
      tests/pitch_cloud.rs.
- [x] Pitch/speed changes are seamless: `set_speed_pitch` opens a retune deck 0.25 s ahead under the
      same deck id; the mixer swaps it in with a 30 ms crossfade at the exact track position
      (Cmd::Retune). It used to seek (silent gap). `load` now clears the queued next deck.
- [x] Lumisound Blend = new Smart Crossfade (core blend.rs): cached head/tail profile (music start/end,
      beat grid + downbeat, 3-band envelopes, outro/intro kind, key) -> plan (downbeat-aligned start,
      whole-bar length, incoming downbeat alignment, beat-match, bass swap / equal power / cut).
      Engine `queue_blend` starts the fade sample-accurately (cue error < 5 ms on cloud pairs).
      tests/blend_cloud.rs. iOS uses it (queueRustBlendNext); tvOS still uses TVAutoCrossfade
      (AVPlayer streaming, no Rust engine there).
- [x] Lumisound Radio (bridge routes/radio.rs + core radio.rs + RadioService.swift): session radio
      from YouTube Mix + global co-listen graph + the listener's library + search; scoring, skips and
      completions steer it, liked/finished songs expand the pool; artist spacing; modes
      balanced/familiar/discover (long-press Auto-Radio). /user/stations/auto answers from it.
      Operator check: `docker exec ios_bridge lumisound-bridge radio-probe <user> <artist> <title> [ytid]`.
- [x] Aria Lyrics (bridge lyricsgen.rs): Demucs vocals -> voice phrases -> whisper.cpp (whisper-rs,
      ggml-small-q5_1 baked into the image) -> alignment to known text (hint / LRCLIB plain) or lines
      from phrases; instrumental detection; hallucination filter. No Gemini.
      Probe: `lumisound-bridge lyrics-probe <audio> <title> <artist> [truth.lrc] [aligned|asr]`.
      ABC (asr mode): median line error 1.1 s, 54 lines, 8.7 min on 1.5 CPUs (bridge now 3 CPUs,
      app waits 15 min).
- [x] Haptics Brain (core haptic_brain.rs, bridge routes/haptics.rs, HapticsBrainService.swift):
      every played track observed in the background (haptics on or off): pulse fit, timing offset,
      drop/fill tuning; global model + per-track consensus aggregated on the bridge from all users.
- [x] Thumbnail slides that stopped: SwiftUIPanningArtwork is clock-driven (repeatForever froze on
      re-render); PanningImageView re-adds a missing pan on any update/foreground.
- [x] Account realness (bridge realness.rs): daily scan, score/verdict/reasons/frequency per account in
      ios_user_realness; GET /admin/api/realness; `lumisound-bridge realness-report`.

Open:
- [x] Strata (third interface): core/src/strata.rs composes every screen (Home rails, Library tabs
      paged + alphabet index, typo-tolerant search, album/artist/playlist/genre/queue/You) and the
      theme (OKLab palette tinted by artwork, WCAG-checked accent); Swift Views/Strata/ only renders.
- [ ] Aria Lyrics: test aligned mode on more songs; speed (Demucs dominates).
- [ ] tvOS Smart Crossfade on Blend (needs bridge-side profiles for streamed tracks).

## 2026-11-11 titles cut at a dash
- [x] core import.rs `tag_apply_fallbacks`: a title tag equal to the filename (every download) was
      split at its first " - " and only the right part kept, even with a known artist
      ("... (Dragon Ball - 2026)" -> "2026)"). Now: split only when no artist is known, never inside
      brackets; a leading repeat of the known artist is dropped.
- [x] core library.rs scan cache v2: every file's tags re-read once after the update.
- [x] bridge `split_artist_title` (search/stream results): spaced separator outside brackets only.
- [ ] Cloud metadata repair: `docker exec ios_bridge lumisound-bridge repair-titles apply`
      (dry run found 2,563 cut titles; restores each file's own title tag). Needs to be run by the owner.
