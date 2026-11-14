# rust/bridge — to do

Full history and decisions: [`RUST-PORT.md`](../../RUST-PORT.md).

## Done (2026-11-12)
- `USER_MUSIC_EXTRA_DIRS`: user libraries can live on more drives (web-stack mounts the terabyte store at
  `/usermusic-terabyte`). A user's folder stays on the drive it's on; new users go to the emptiest drive.
- To do: moving an existing user's library between drives is manual (stop bridge, move folder, start).

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
- Done: a failed attempt whose output says age-restricted / age-verification switches the remaining attempts
  to `YTDLP_FALLBACK_CLIENT` (`ytdlp::needs_age_fallback`); "only available to Music Premium" is a permanent
  failure with its own message (no retries). Tested: Premium video stops after attempt 1. The age gate is
  intermittent: at 05:59 UTC every previously failing video downloaded on attempt 1, so the switch hasn't
  been seen live yet — look for "Age-restricted (...): retrying with the tv client" in the logs.
- Image build: the demucs model host's TLS cert expired (2026-11-12). The Dockerfile now copies the
  checkpoint from rust/models/demucs/hub/checkpoints/955717e8-8726e21a.th (git-ignored, 84 MB, sha256 starts
  8726e21a as its name says). On a fresh machine, extract it from a previous bridge image:
  `docker cp $(docker create <old image>):/app/cache/demucs/hub/checkpoints/955717e8-8726e21a.th rust/models/demucs/hub/checkpoints/`

## 2026-11-12: username changes
- Limit is now 3 per rolling 30 days (`MAX_USERNAME_CHANGES_PER_30_DAYS`, routes/account.rs).
- schema.sql: trigger `ios_users_username_changed` writes ios_username_change_log on every rename and
  rewrites each column registered in `username_sync_targets` (empty today: no table copies usernames).
  `resolve_username(name)` = current name, else a former name nobody holds now; used by friend requests
  and playlist collaborator adds. Login deliberately still needs the current name or email.
- Operator account renamed HeavenlyXenusVR -> Voxelise (Nyxframe user 8 HollowHeavenXR -> Voxelise too).

## 2026-11-14: merge-mode sync push
- `POST /user/sync` with `"merge": true` (routes/library.rs `merge_library`): favorites upserted,
  `removed_favorites` deleted; pushed playlists upserted, `removed_playlists` deleted, others untouched; a
  pushed playlist's rows become the pushed list followed by rows the device has not accounted for (`seen`,
  identities from `row_identity`, same function in core `syncmerge.rs`). Without the flag the push replaces
  the account as before (old app versions).
- Favorite and playlist endpoints now announce `sync_changed` on `/ws/live` (Android edits reach the iPhone at once).
- Playlist upserts never touch another account's playlist id (both push paths).
