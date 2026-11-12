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

## Open (widgets)
- If iOS still shows a bare system player while audio plays, the remaining lever is the audio session's
  `.mixWithOthers` option (then Lumisound no longer pauses other apps' audio).
- Live Activity showed the music-note placeholder instead of artwork for a wide (YouTube) track on 2.0.0.26
  while the tint was set, so the thumb was written; check whether the thumb loads in the Live Activity.
- Confirm 2.0.0.26 on device: medium + large in the gallery show the song, Live Activity appears on the Lock Screen.
- Find out why `containerURL(forSecurityApplicationGroupIdentifier:)` is nil on the SideStore install while the
  shared defaults work (check Settings > About warning, and the suffixed group ID SideStore registered).
- Verify on device: widget sizes, Dynamic Island layout, Smart Stack, tinted/clear Home Screen modes.
