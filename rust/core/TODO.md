# rust/core — to do

Full history and decisions: [`RUST-PORT.md`](../../RUST-PORT.md).

## Done (2026-11-07)
- Engine: 60 ms start head-start before a deck's first frame (`mixer.rs` `start_prefill_samples`).
- Engine: decode threads at user-interactive QoS on Apple platforms (`deck.rs` `raise_decode_priority`).
- Engine tests: decoder-paced `pump` (debug builds no longer starve decks); `engine_quality`
  skips itself in debug builds (run it with `--release`).
- Skips: fading (60-day half-life), `skip_top`, `skip_clear_all`, cross-device sync
  (`skip_sync_batch` / `skip_sync_apply` / `skip_sync_reset`) in `stores.rs`.

## Done (2026-11-08)
- `haptics.rs`: custom Music Haptics analysis + scheduler (3 cloud passes, tests/haptics_cloud.rs).
- `intro.rs`: custom Skip Silent Intros detector (3 cloud passes over all tracks, tests/intro_cloud.rs).
- `engine::queue_next_at` (gapless start offset); decoder picks the audio track in video containers.

## Open
- Engine: join the CoreAudio audio workgroup for deck threads (os_workgroup) instead of plain QoS.
- Skips: count a song played to the end after earlier skips as forgiveness (decrement).
- Haptics: downbeat emphasis from the beat grid (bar-level accents).
- Haptics: tune on a real phone (feel can't be measured on a desktop); strength presets may need adjusting.
- Intros: optional "skip silent outros" (end the track at its last sound for crossfades).

## Done (2026-11-12)
- `dupes.rs`: Duplicate Engine — LumiPrint acoustic prints (33-band energy-gradient bits, 3 probes, offset
  search, on-disk cache), evidence graph, variant guard, keeper scoring, ignore list, merge plan, undo journal.
  Real-track check: MP3 re-encode shifted 1.3 s matches 3/3 probes at BER 0.19; another track 0/3 at 0.48
  (`cargo test --release -p lumisound-core --lib dupes::real -- --ignored` with LUMI_DUPE_DIR).
- `engine/eq.rs`: LumiEQ (proportional Q, 60 ms glide, true-peak headroom, loudness match) + preset catalogue,
  legacy-name resolver, Auto EQ rules, response curve export. Replaces `Eq10`.
- `engine/boost.rs`: LumiBoost — 3-band LR4 split, per-band ceilings, route profiles, harmonic bass on the
  speaker, soft saturation; meter via `boost_reduction()`.
- `engine/space.rs`: LumiSpace — stereo virtual speakers (4 ITD + head-shadow paths), pinna cue, early
  reflections per room, bass bypass, crossfeed mode, mode cross-fades. Replaces `binaural.rs`.

## Done (2026-11-13)
- `search.rs` LibrarySearch: library-wide search (songs / artists / albums / playlists / lyrics) with folding,
  typo tolerance, highlights and LRC times; 9 tests incl. a 20k-song speed bound.
- `engine/deck.rs`: gapless trim + decoder output rate (HE-AAC), deck gapless test.
- `together.rs` TogetherSync: Listen Together clock offset + follow decisions (load/seek/play/pause/tempo nudge), 6 tests incl. a convergence simulation.

## Open (2026-11-12)
- engine_quality: "hits speed 1.25x / 0.8x pre-echo" limits fail (also before this pass; stretch.rs).
- LumiPrint: probes only within ±4 s duration clusters; a version with a long extra intro isn't matched.

## Done (2026-11-14)
- `engine/boost.rs`: LumiBoost v2. The per-band *peak* ceilings gave an already-loud master ~1 dB whatever the
  slider said (peaks sit at 0 dBFS, so nothing "fit"). Now each band is held under a *loudness* (RMS) ceiling
  and its own soft shoulder rounds the peaks; never quieter than the input. Real tracks at +1/+2/+3.5/+6/+9/+12:
  loud masters (−9…−11.6 dBFS RMS) gain 0.5–0.8 / 1.0–1.6 / 1.6–2.8 / 2.1–4.2 / 2.2–4.6 / 2.2–4.6 dB,
  mid-level tracks up to 6.8 dB, quiet tracks the full amount.
  Measure: `LUMI_BOOST_DIR=<dir> cargo test --release -p lumisound-core --lib boost::tests::real_tracks -- --ignored --nocapture`.
- `engine/mixer.rs` + `deck.rs`: start latency counts from when the mixer first wants a deck's audio
  (`wanted_at`), not from when it was opened. Queued gapless / blend decks and tracks loaded while paused were
  being reported as 100–700 s "slow starts" (every `slow_start` in telemetry with phase `crossfade`).
- `engine/mod.rs`: `start_output` waits at most 3 s for CoreAudio (it is called on the main thread).
- `store.rs`: `load_shared` — parsed documents are shared until the next save; `load` parses from the cached
  value without copying it. Per-song lookups (tempo, intro offset, normalization, beat grid, download ledger,
  failures, skips, resume points) were a full copy + parse of a one-entry-per-song map on every call.
- `engine/chain.rs` `SoundChain`: the mixer's master section (LumiEQ → FX → reverb → night mode → mono →
  LumiSpace → 8D → tremolo → volume → LumiBoost → limiter) for audio the engine doesn't decode (Android).
- `crossdevice.rs` `TrackResolver`: which of this device's tracks a favorite / playlist row written by another
  device means (id → source → file name → title + artist → unique title).
- Android: builds for `*-linux-android` (rustls instead of native-tls there; pull output like tvOS with
  `engine_set_pull_rate`; decode threads at audio priority). Kotlin bindings: `[bindings.kotlin]` in `uniffi.toml`.

## Done (2026-11-14, second pass)
- `syncmerge.rs`: three-way merge for favorites and playlists. Each device keeps the state it last agreed on
  with the server (`sync_base`); `sync_merge_plan` says what to add *and remove* locally after a pull (playlist
  rows resolved to this device's songs through `TrackResolver`), `sync_build_merge_payload` builds a push that
  lists what this device removed, `sync_push_committed` / `sync_base_reset`. A pull that would remove most of
  the favorites is refused (wiped account). 7 tests.
- `engine/dsp.rs` `Vibrato`: the mixer's delay-line vibrato as its own type, now also in `SoundChain`
  (`set_vibrato`).
- `engine/session.rs` `PlaySession`: queue playback on the engine (order, shuffle, repeat, gapless successor,
  crossfade timer, skipping unplayable files, queue edits). Files are asked for by key (`need_source` /
  `provide_source`). 5 tests that decode and render real audio. The Android player is a shell over it.
- Pull output (`engine_render_into`) is the output on every target that isn't iOS / macOS, so desktop builds
  (the Android app's unit tests) can drive a whole engine.
- Re-ran `engine_quality` (release): unchanged, only the two known `hits speed` pre-echo limits fail.
  `engine_cloud` over 8 library tracks: 92 checks pass, 3 fail, all `spatial (yaw …)` ITD / ILD measurements on
  wide or very quiet material (LumiSpace itself was not touched in this pass).

## Open (2026-11-14)
- `engine_cloud`: the `spatial (yaw 0 / 60)` limits fail on 3 of 8 tracks (ITD estimate 0.27 ms off at yaw 0
  on low-correlation masters; too little high-band ILD on a −30 dB intro). Decide whether the estimator or
  LumiSpace is off.
- iOS could run its queue on `PlaySession` (it still does this bookkeeping in Swift).
- `PlaySession`: Smart Crossfade (`queue_blend` with a `blend_plan`) and Skip Silent Intros offsets are not
  wired in; it does fixed-length crossfades and plain gapless.
- Playlist order is not merged (a reorder on one device stays local; additions append).
