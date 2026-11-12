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

## 2026-11-12: age-restricted downloads (403)
- YouTube now asks the cookie account to age-verify; `web_embedded` is UNPLAYABLE and the fallbacks
  (`web_creator`, `mweb`) hand out streams that 403 ("unable to download video data"). Cookies, PO token
  (bgutil 2.0.2) and yt-dlp 2026.10.26 were all fine.
- Fixed in config: `YTDLP_FALLBACK_CLIENT=tv` (web-stack docker-compose.yml). The `tv` client still serves
  these with the same cookies; output is .m4a. Verified on 4 previously failing videos.
- Open: detect "age-restricted ... age-verification" on attempt 1 and jump straight to the `tv` client
  (saves two failed attempts). "Music Premium members" only videos can't download without Premium cookies:
  fail fast with that message instead of retrying.
