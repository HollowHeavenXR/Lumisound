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
