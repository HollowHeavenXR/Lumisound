# rust/core — to do

Full history and decisions: [`RUST-PORT.md`](../../RUST-PORT.md).

## Done (2026-11-07)
- Engine: 60 ms start head-start before a deck's first frame (`mixer.rs` `start_prefill_samples`).
- Engine: decode threads at user-interactive QoS on Apple platforms (`deck.rs` `raise_decode_priority`).
- Engine tests: decoder-paced `pump` (debug builds no longer starve decks); `engine_quality`
  skips itself in debug builds (run it with `--release`).
- Skips: fading (60-day half-life), `skip_top`, `skip_clear_all`, cross-device sync
  (`skip_sync_batch` / `skip_sync_apply` / `skip_sync_reset`) in `stores.rs`.

## Open
- Engine: join the CoreAudio audio workgroup for deck threads (os_workgroup) instead of plain QoS.
- Skips: count a song played to the end after earlier skips as forgiveness (decrement).
