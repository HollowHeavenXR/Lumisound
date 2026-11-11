# rust/bridge — to do

Full history and decisions: [`RUST-PORT.md`](../../RUST-PORT.md).

## Done (2026-11-07)
- `POST /user/skip-history` + table `ios_user_skip_history` (schema.sql): cross-device skip sync.
- `/user/music`: per-file filesystem work moved off the async workers.

## Open
- Incremental `/user/music/metadata?since=` (low priority: table is tiny today).
- Prune zero-count skip rows older than ~1 year.

## 2026-11-09
- [x] routes/radio.rs (Lumisound Radio), routes/haptics.rs (Haptics Brain), lyricsgen.rs (Aria Lyrics), realness.rs.
- [ ] Aria Lyrics: cache Demucs vocals per track hash (re-runs skip separation).

## 2026-11-11 (Rich Presence)
- [x] `GET /api/rp-art/yt/{id}.jpg`: YouTube thumbnail shaped for Discord's square slot (16:9 kept whole over a
      blurred fill), cached on disk under ytdlp_cache_dir/rp-art-yt.
- [x] `/user/rp-artwork-upload` shapes on upload; older unshaped files are shaped on first read.
- [x] `ios_playback_state.engine` column (schema.sql); playback handoff clears stale artwork/engine.
- [ ] Prune rp-art-yt / rp-artwork caches (unbounded today, ~40 KB per track).
