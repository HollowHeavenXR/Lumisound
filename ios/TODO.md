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

## Open (widgets)
- Verify on device: widget sizes, Dynamic Island layout, Smart Stack, tinted/clear Home Screen modes.
