# ios — to do

Full history and decisions: [`../RUST-PORT.md`](../RUST-PORT.md). Swift is views + app shell only.

## Done (2026-11-07)
- Library Health > Listening > Often Skipped (`Views/OftenSkippedView.swift`).
- Skip history sync on start / every 20 min / backgrounding (`Services/AccountService+SkipSync.swift`).

## Done (2026-11-08)
- `Services/MusicHapticsService.swift`: Core Haptics player for the core's haptic score; Settings feel picker.
- `Services/SilenceTrimAnalyzer.swift` / `SilenceTrimService.swift`: core intro detector, engine opens tracks at the music.
- `LumisoundTV/Sources/TVAudioSettings.swift`: TVSilenceTrim on the core detector.

## Open
- Phase H: delete superseded Swift (AVAudioEngine graph etc.).
- tvOS/watchOS: show Often Skipped / use Smart Shuffle there too.
- Verify Music Haptics feel and timing on device (AirPods vs speaker latency).

## Done (2026-11-09)
- `Services/RadioService.swift`: Lumisound Radio sessions (start/refill/feedback), mode picker on Auto-Radio long-press.
- `Services/HapticsBrainService.swift`: background observation of every track + global model sync.
- Smart Crossfade on the core Blend planner (`queueRustBlendNext`).
- `Views/Components/PanningArtwork.swift`: thumbnail slide no longer freezes.
- Aria lyrics poll deadline 15 min (server-side engine).

## Done (2026-11-11)
- Strata interface: `Views/Strata/` (StrataStore, StrataRenderer, StrataRootView, StrataNowView) on core `strata.rs`.

## Done (2026-11-12)
- Strata: Library crash fixed (rows play long lists by reference); playlists (create/rename/delete/add/remove),
  Library sorting, player Now/Lyrics/Queue tabs, Settings (8 pages), Account and Cloud composed in Rust
  (`StrataSettings.swift` adapter, `StrataLyrics.swift`).
- Interface picker: cards share the screen width equally; previews no longer set the width (page was wider than the phone).
- Sideload widgets: unsigned release IPAs are now ad-hoc signed with only the App Group (group.com.lumisound.ios) so SideStore/AltStore register it and widgets can read app data. PixelBoost and SwarmPanel IPAs have the same gap (no embedded App Group).

## Open
- Strata: verify on device; rare advanced settings (API keys, app lock, notifications) still open the classic Settings.
- tvOS has no Strata.

## Done (2026-11-11, widgets + Live Activity revamp)
- `Shared/NowPlaying/NowPlayingSnapshot.swift`: one atomic now-playing record (title, art file, timing, speed,
  tint, engine line) read by the widgets and carried as the Live Activity's ContentState.
- `Services/WidgetDataService.swift`: per-track artwork files (no more old art beside a new title), trailing
  reload throttle (bursts used to drop the last reload), per-tick resync re-anchors on drift > 1 s, duration,
  speed or play-state changes; 1 s grace after a track change while the engine loads.
- `Services/LiveActivityManager.swift`: publishes the snapshot with a stale date at track end.
- `LumisoundWidget/Sources/`: new `NowPlayingViews.swift`; widgets and Live Activity redesigned — live system
  progress bars (the widget bar used to be frozen), 16:9 art shown wide, artwork-tinted backdrop, engine/BPM
  line, speed-aware time labels, Watch Smart Stack / CarPlay (`.small`) layout.
- `engineSummary` ("Rust engine · LMS OPUS · 48 kHz") sent with playback state for Discord Rich Presence.

## Done (2026-11-11, widget fix in 2.0.0.25)
- Widgets were stuck on "Nothing Playing" after 2.0.0.24: `WidgetDataService.publish` only saved when the App
  Group *folder* was reachable, but on the sideloaded install only the shared *defaults* work (the old code
  saved to defaults unconditionally). Now always saves to defaults; artwork falls back to small JPEGs in the
  defaults (`now_playing_art.<file>`, current + previous track) when there is no folder.
- Snapshot numbers are sanitized before saving (NaN/inf made JSON encoding fail silently).

- 2.0.0.26: medium/large widgets and the Live Activity crashed (SIGTRAP, 6 MetricKit reports at 21:17 while
  browsing the widget gallery; small rendered fine). Only those used `Text(timerInterval:countsDown: true)` for
  the remaining time; replaced with `Text(endDate, style: .timer)`. BPM / time formatting guard Int conversions.

- 2.0.0.27: system media player turned off (`AudioPlayerManager.showsSystemNowPlaying = false`): no
  MPNowPlayingInfo, no remote command targets, so the Live Activity is the only Lock Screen card. Trade-off
  accepted by the user: AirPods/headphone buttons, car Bluetooth, CarPlay, Siri media commands, Control Center
  and the Watch's Now Playing no longer control Lumisound.

- Live Activity stuck on the previous track after auto-advance/crossfade (widgets were right). Each update was
  its own `Task`, so updates could land out of order, and steady playback sends no more. Now one serial sender
  (newest last) plus `LiveActivityManager.verify()` each tick: resends when the activity's actual
  `content.state` shows another track or play state.

- Button lag (Live Activity pause/like): intents returned before the Live Activity update landed, and iOS
  redraws when the intent returns, so the old state stayed until a later redraw. Intents now await
  `LiveActivityManager.flush()` (via `LumisoundPlaybackCommandRouter.settle`); play/pause and favourite reload
  widgets immediately instead of through the 1 s reload spacing.

- Stale username on Account/home/profile screens: `refreshMe()` (GET /auth/me) was never called, so the
  user saved at sign-in was shown forever. Now `refreshMeIfStale()` runs on launch and on returning to the
  app (max once a minute) and refetches the social profile when the name changed.
- New Shortcut/Siri action "Download Saved Playlists" (`DownloadSavedPlaylistsIntent`, 10th and last
  AppShortcut slot): runs the tracked-playlist auto-downloader now, ignoring the 5-minute spacing.
- Background refresh was reported "denied" in the 2026-11-12 diagnostics: BGTaskScheduler never runs then,
  so saved playlists only download while the app is open (Settings > General > Background App Refresh).

## Open (widgets)
- If iOS still shows a bare system player while audio plays, the remaining lever is the audio session's
  `.mixWithOthers` option (then Lumisound no longer pauses other apps' audio).
- 2.0.0.28: Live Activity never showed artwork (every song). Cause: `AppGroup.id` used a keychain probe for the
  team-suffixed group, and the keychain is unreadable while locked (Lock Screen rendering) → wrong group.
  Now reads the group from embedded.mobileprovision, caches it per process, keychain last. Confirm on device;
  this may also be why the app reported the App Group folder as unavailable.
- Confirm 2.0.0.26 on device: medium + large in the gallery show the song, Live Activity appears on the Lock Screen.
- Find out why `containerURL(forSecurityApplicationGroupIdentifier:)` is nil on the SideStore install while the
  shared defaults work (check Settings > About warning, and the suffixed group ID SideStore registered).
- Verify on device: widget sizes, Dynamic Island layout, Smart Stack, tinted/clear Home Screen modes.

## Done (2026-11-12, six-part Lumisound pass)
- Live Activity stuck on old tracks (crossfade, or pause → skip/rewind, worst in the background), all three
  presentations (Lock Screen, Dynamic Island, Watch/CarPlay small): `LiveActivityManager` now updates every
  live activity (ends duplicates left by crashes — the one updated wasn't always the one on screen), coalesces
  bursts, sends under a background-task assertion (a paused app was suspended before iOS got the update),
  confirms delivery by snapshot `revision` and resends, and runs its own 12 s watchdog after each change (the
  player timer stops while paused). The Live Activity view also reads the App Group snapshot and shows it when
  its revision is newer than the activity state, so the redraw after a button tap is right even if ActivityKit
  dropped the update.
- Duplicate Finder rebuilt on the Rust Duplicate Engine (`rust/core/src/dupes.rs`): exact-file / same-source /
  same-recording (LumiPrint) / likely evidence, variant guard (Live, Remix, Sped Up… are never duplicates),
  keeper scoring with reasons, "Not duplicates", safe one-tap clean-up, merge of favorites + playlist places,
  Recently Deleted + undo journal (`Views/DuplicateFilesView.swift`, `FolderDuplicatesSheet.swift`,
  `Services/LibraryManager+DuplicateResolution.swift`). Aria auto-removal and the server fpcalc check are gone
  from this screen (the engine decides on-device).
- Classic Account screen: `Views/ClassicAccountView.swift` (listener pass, sync strip, Profile / Listening /
  Connections / Security decks). Lumen and Strata keep `AccountView`'s standard body.
- LumiBoost (volume > 100 %): `applyRustVolume` keeps the master at unity and sends the boost + output route
  profile to the engine; Now Playing shows the profile and a live hold-back meter.
- LumiEQ: `EQPreset` is now an id into the engine catalogue (18 presets in 4 categories, legacy names migrate);
  Now Playing panel with the engine's real response curve, preset cards, loudness match toggle.
- LumiSpace: Spatial Audio rooms (Studio / Wide Stage / Concert Hall / Crossfeed) picker in Settings.

## Open (2026-11-12 pass)
- Verify on device: Live Activity after pause → skip in the background; crossfade with the phone locked.
- Tune LumiBoost / LumiSpace by ear on AirPods and the phone speaker (levels were set by measurement).
- Duplicate clean-up does not merge play counts (history lives server-side); the plan reports them only.
- tvOS: no LumiEQ/LumiBoost/LumiSpace UI (tvOS uses its own audio path).

## Live Activity in the background (2026-11-12, after 2.0.0.32)
- Root cause (from device telemetry): every automatic track change while backgrounded logged "activity showed
  <old>, resending <new>" — iOS silently drops local `Activity.update` calls from an app playing audio with the
  `.playback` session in the background (Apple forums 716458 / 724483; open since iOS 16). APNs push updates
  are the only supported background path and this sideloaded build has no aps-environment ("APNs registration
  failed"). So:
  - Transport intents are also `LiveActivityIntent` (updates from inside an intent are allowed).
  - staleDate = end of track + 0.75 s: the system redraws then and the view reads the newer App Group snapshot,
    so the first automatic advance/crossfade after the last update shows without opening the app.
  - Background resend loop removed (it could never succeed).
  - Settings > Playback > Lock Screen Player: Live Activity / System Player / Both (system player always follows).
- Open: a second automatic advance in a row while backgrounded still waits for the app/a button (no redraw trigger).

## Settings family redesign (2026-11-12, branch settings-redesign → main)
- `Views/Kit/LumiKit.swift`: shared kit (LKPage/LKHero, LKCard/LKSection, LKRow/LKLink/LKToggle/LKControlRow,
  LKTile/LKGrid, LKStat, LKChip/LKPill/LKSegmented, LKField, LKBanner, LKEmpty, LKPrimaryButton, LKScroll,
  LKRowLinkStyle). Colours from AppTheme, so it follows the edition, accent and Liquid Glass.
- Settings (Classic + Strata): `SettingsView+Home.swift` — control-room home (search over every setting,
  account card, quick switches, nine room tiles with live details) and pages: Sound, Library, Downloads,
  Look & Feel, Notifications, Sleep & Wake, Lock Screen & Car, Privacy & Security, Help & About.
  Lumen keeps its own settings pages (old section vars, untouched).
- Own layouts: Notifications, Subscriptions & Tracked Playlists (dashboard + smart add + channel cards +
  playlist grid), Profile editor (live header, Identity/Style/Showcase/Privacy tabs, unsaved-changes bar),
  Library Health (grade gauge + issue tiles), Storage (usage bar), Duplicate Finder, Corrupt Files, Backup &
  Restore, Backup History (timeline), Compare Playlists (Venn), Listening Stats (podium), Liquid Glass (lab),
  Appearance (four shelves), Gallery Background (source cards), Deleted Playlists (countdown rings),
  Sessions (device cards), Wake-Up Alarm (clock face), Change Password (strength meter), Delete Account,
  Listening Goal, 2FA, YouTube API Key (credential card), Cookies (health checklist), Discord Webhook
  (message mock), Channel Settings sheet.
- Converted onto kit sections: Lua Themes, Help & Guide, Bug Report, Discover, Admin, Scrobbling, Rich
  Presence, Podcasts, Achievements, Time Capsules, Constellation, Inbox, Scripted Visualizer. Swipe actions
  there became long-press context menus (no List to swipe in).
- Kept as-is (already bespoke): Interface picker, Rewind, Needle Drop; Heatmap and Hearing Health got the hero.
- Open: verify on device (dark/light, Liquid Glass on/off, Dynamic Type), Lumen settings pages still old style.

## Done in 2.0.0.35 (2026-11-13) — batch requested 2026-11-12
1. Background downloader: no run on every launch/foreground. Manual "Start" button in Settings (one pass),
   still runs on the iOS daily background task, plus an in-app timer every 15 h. Resume only an interrupted pass.
2. Find out why YouTube API key quotas run out so fast (bridge usage, per-call unit costs, repeat resolves) and
   optimize (caching, fewer list calls, ETag/If-None-Match, batching, skip unchanged playlists).
3. Audio effects remade for the Lumisound engine (custom catalogue in Rust).
4. Now Playing artwork styles and seeker styles: redesign every one with its own idea.
5. All app animations remade as custom Lumisound motion, every animation capped at 60 fps.
6. Loading (launch) screen remade.

- Batch shipped in 2.0.0.35. Quota root cause: Spotify playlist matching spent 100 units (a Data API search) per
  track, so one 100-song import used a whole day; plus 100-unit interactive searches and tracked playlists
  re-resolved every 5 min with durations refetched each time. Fixed in the bridge (deployed): see commit 9dd0a453.
- Open: verify on device — artwork styles/seekers look and feel, launch dial, LumiFX character effects by ear.

## Task list (requested 2026-11-12 22:26) — auto-continue armed for 01:25
- [x] 1. Auto EQ fully on LumiEQ (catalogue presets, eqAutoPreset, spectral matcher + analyzer correction).
- [x] 2. New app identity: "sound eclipse" icon (waveform corona round a dark disc, pulse line, spark) for iOS, in-app display, tvOS parallax layers + Top Shelf, and a new watch AppIcon catalogue. Source: ios/Branding (make_icon.py + render.sh regenerate every size). Widgets use the host app icon.
- [x] 3. README: only what users need (what it is, install via AltStore/SideStore source, features). No build internals.
- [x] 4. Fix the same track appearing twice in Favorites.
- [x] 5. Subscriptions: channels are compact ~56pt rows in one grouped card (avatar with auto-download badge, meta line, mute/check/menu icons). TrackedPlaylistDetailView rebuilt: blurred-art hero, downloaded vs missing split bar, Missing / In Library / All filter + search, lazy track card, Tracking settings card.
- [x] 6. Audit of Apple-system features: ios/SWIFT-AUDIT.md section 5. Replaced DSWaveformImage with Rust waveform peaks (RustWaveformView), library search, engine format gaps and the engine toggle; remaining Apple uses listed with reasons (system integrations, mic, TTS, video export; SharePlay is task 12).
- [x] 7. Engine format coverage: rust/media tests/format_matrix.rs encodes every importable format with ffmpeg and checks rate, channels, exact length and tones (plain + locked .lms). Fixed: ALAC in CAF (atom-wrapped cookie, media/src/alac.rs), MP1/MP2 and MKA added, gapless trimming (media/src/gapless.rs: MP4 iTunSMPB / edit list for AAC, WAV fact for ADPCM, Ogg Opus end trim). New AAC path (media/src/aac.rs, pure-Rust syom) for HE-AAC v1/v2, 5.1/7.1 folded to stereo, 960-sample and implicit-SBR streams (tests/aac_profiles.rs). Engine toggle removed: always on, system engine only as automatic fallback. Not importable (no decoder): AC-3, E-AC-3, WMA, WavPack.
       wav/ogg/webm/alac...); custom decoders where missing; then hide the "Lumisound Audio Engine" toggle.
- [x] 8. Library redesign: LibraryHeader (big title, live songs/artists/albums/hours counts over an accent glow, Shuffle All + Add Music) and LibraryTabBar as an icon strip where the chosen section opens to icon+label with a gliding highlight (all 11 sections in ~one width, auto-scrolls to the selection); unified Rust search screen replaces tab content while searching (task 11). Tabs themselves (Artists shelf/letter headers/grid modes, Albums, Songs card styles, Hub) were already redesigned earlier and keep their layouts.
- [x] 9. tvOS overhaul: playback on the Lumisound engine (TVLumisoundEngine: pull render via engineRenderInto → AVAudioSourceNode; TVTrackFiles cache, locked files decoded in place; engine gapless + crossfade; AVPlayer pair, unlock cache and stall watchdog removed); Settings → Sound and a Now Playing Sound panel (LumiEQ presets from the core, Night Mode, Room); Listen Together on TV (TVListenTogether: join by code, follows the host with the Rust TogetherSync, reactions; Account → Listen Together); new icon. Screens keep the existing TV design system (neon/glass, redesigned in earlier rounds); everything new already exists on iOS.
       must be ported to iOS too.
- [x] 10. Tests + release: rust/media (format matrix, AAC profiles incl. HE-AAC/5.1, gapless, ALAC cookie, blur) and rust/core (138 unit tests incl. search, TogetherSync, pull render, deck gapless) pass; engine_cloud + dupes::real pass on real tracks; only the old engine_quality pre-echo-at-speed failure remains. Released 2.0.0.36 → 2.0.0.40; every IPA downloaded and checked: app + widget signed with group.com.lumisound.ios, SharePlay entitlement gone, AltStore source at 2.0.0.40. tvOS compiles in CI.
- [x] 11. Library search engine in Rust (rust/core/src/search.rs, LibrarySearch): songs, artists (credits split on feat/&/,/x), albums, playlists and lyrics (Lyrics folder, LRC times kept); accent/case folding, prefix-as-you-type, OSA typo tolerance, every-word AND, phrase/exact/plays/favourite boosts, UTF-16 highlight ranges; ~7 ms on 20k songs (prefilter + parallel ranking). UI: LibrarySearchView (top result, songs, artist/album ribbons, playlists, lyric cards that play from the line, scope chips) replaces tab content while searching. LibrarySearchService reindexes on library changes and re-reads lyrics when the folder changes.
- [x] 12. Listen Together without GroupActivities: SharePlayCoordinator/ListenTogetherActivity and the group-session entitlement removed. Rooms (bridge /rooms + /ws/live) do everything: Rust TogetherSync (rust/core/src/together.rs) does NTP-style clock offset from heartbeat round trips and decides load / seek / play / pause / ±5% tempo nudge (pitch kept, AudioPlayerManager.togetherRate) — simulated follower converges within 40 ms. Track identity = together_track_key (source id or folded title|artist), resolved to the library copy or the stream. Host republishes on track / play-state / seek (1 s watch). Live reactions (new POST /rooms/{code}/react, bridge deployed), queue suggestions/votes in QueueView, Follow-the-host toggle + sync status in the room.
- [x] 13. Cloud-track tests (2026-11-13): engine_cloud on 13 real tracks (Opus, AAC M4A, FLAC; locked .lms decoded in place) — every effect, speed, pitch, spatial and gapless check passes. The spatial check was fixed to measure against the dry render with GCC-PHAT (yaw 0: 0.00 ms on all tracks) and the >3 kHz head-shadow ILD (yaw 60: −15 to −16 dB). dupes::real passes (re-encode matched, other track rejected). Full 101-track set takes ~9 h at ~18 renders per track; the subset covers every format in the library.
- [x] 14. Responsiveness: telemetry-led (MetricKit showed daily GPU time up ~20× between 2.0.0.6 and 2.0.0.35 on the same account; no hang reports). Gallery background stills now come pre-blurred from the core (gallery_blurred_still: 720 px + fast_blur, blur kept as a share of the screen) so the Ken Burns pan moves a plain image instead of re-blurring a full-screen photo every frame behind every screen. Smart Crossfade no longer holds the analyzer (2048-pt FFT + SwiftUI publish at 23 Hz) for the whole of every track: armed 20 s before the fade only. Re-upload storm seen in telemetry was a one-time first backup (recent builds upload ~1–2 files/day).
- [x] 15. Owner/admin email voxellickinetix@icloud.com: SwarmPanel .env SWARM_PANEL_SITE_OWNER_EMAIL (new first, old kept) + container recreated; Nyxframe SITE_OWNER_EMAILS list (pushed, redeployed); Lumisound admin is the operator account (id ca8a4c53…), its email set to voxellickinetix@icloud.com.
- [x] 16. Git: global identity VoxeliseStudios <voxellickinetix@icloud.com>; remotes moved to github.com/VoxeliseStudios.

## Done (2026-11-14, engine pass: boost + stalls)
- Volume boost: LumiBoost v2 in the core (see `rust/core/TODO.md`) — every step above 100 % is audible on
  loud masters now. No Swift change; the hold-back meter keeps its meaning.
- Stalls: device telemetry (2.0.0.40) shows a healthy audio thread (0 underruns, load ≤ 11 %) but main-thread
  hangs of 6–50 s, with no way to see where. `Services/MainThreadBacktrace.swift` samples the main thread's
  stack while it is stuck (1.5 s and 6 s into a hang); `main_thread_hang` events carry it as `mainStack`
  ("Image 0xoffset symbol", innermost first).
- Core-side causes removed in the same pass: per-song cache lookups no longer copy + parse whole documents,
  output start is bounded to 3 s, `slow_start` telemetry no longer counts queued decks.

## Open (2026-11-14)
- Read `mainStack` from the next `main_thread_hang` reports (table `ios_app_event_log`) and fix what it names.
- Tune LumiBoost v2 by ear on AirPods and the phone speaker.

## Done (2026-11-14, sync: removals reach every device)
- Favorites and playlists are a three-way merge now (core `syncmerge.rs`, bridge merge-mode push). A favorite
  or playlist removed on one device is removed on the others; a playlist made on Android opens with this
  library's songs (rows resolved through `TrackResolver`); playlist entries follow adds and removes both ways.
  A playlist deleted on another device lands in Recently Deleted here.
- `pullSync` computes the merge off the main thread and applies it in one write (`LibraryManager+SyncMerge`).
  `pushSync` sends `"merge": true` with what this device removed; songs not in the library right now stay in
  the pushed playlist instead of being dropped (which told the server they were removed).
- `mergeFavoritesFromServer` (union-only pull that also re-uploaded every local favorite the server lacked,
  which put back anything removed elsewhere) is gone; `pullSync` covers it.
- `toggleFavorite` removes every id that makes the song a favorite (its own and other devices'): a favorite
  made on the Apple TV / Android could not be removed here before.
- A burst of live `sync_changed` events is one pull (1.5 s debounce).

## Done (2026-11-14, hang reports that can be read)
- `main_thread_hang` now carries `probeTicks` (how many of the monitor's own 250 ms timer ticks fired during
  the stall) and `mainThreadCPUSeconds`. A "stall" during which the monitor's timer barely fired was the whole
  process being suspended, not a hang: it is logged as `process_suspended_gap` (info) instead. A real stall
  with near-zero main-thread CPU was waiting (lock, synchronous call, disk); CPU close to the stall length
  was computing. Together with `mainStack` the next reports say what and where.

## Open (2026-11-14)
- Playlist order is not merged across devices.
- The first sync after this update is a union (no base yet): something removed elsewhere before the update
  can come back once.
