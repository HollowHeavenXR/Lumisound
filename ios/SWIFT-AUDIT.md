# Swift audit (Rust port, phase J)

Goal: Swift is only SwiftUI views, the app shell, UniFFI glue, and the Apple
system APIs that can only be reached from Swift. Everything functional runs in
`rust/core` (module `LumisoundCore`). This is the state on branch
`rust-app-core`; update it as files move.

## 1. Thin wrappers over the Rust core (done)

| Swift | Rust |
|---|---|
| `AccountService+PrivateHelpers._makeRequest`, every `Core.data(for:)` / `Core.upload` call (iOS, tvOS, watchOS) | `client.rs` (`ApiClient`, `http_send`, `http_upload_file`) |
| `LiveUpdateService` | `live.rs` |
| `LumisoundLockFormat`, `LumisoundTrackVault`, `LumisoundTrackTagger`, playable-URL cache in `LumisoundExclusiveExtensionService` | `lock.rs`, `media/lock.rs` |
| `DownloadLedgerStore`, `DownloadFailureStore`, bridge job flow in `attemptDownload` | `downloads.rs` |
| `AudioTagWriter`, source-id/thumbnail tag readers | `media/tags.rs` (lofty) |
| `BPMAnalyzerService`, `NormalizationService`, `SilenceTrimAnalyzer`, `BeatGridAnalyzerService`, `PitchContourService`, `AudioFingerprintService` | `analysis.rs`, `media/analysis.rs`, `media/decode.rs` |
| Local-file playback in `AudioPlayerManager` (`+RustEngine.swift`) | `engine/` |
| `LibraryManager+Snapshot`, `ScanCacheService` | `library.rs` |
| `PlayHistoryStore`, `BookmarkStore`, `LongTrackResumeStore`, `TimeCapsuleStore`, `DeletedPlaylistsStore`, `RecentlyDeletedService`, `ListeningGoalService`, `IntelligenceSuggestionCache`, `TrackedPlaylistStore` (store part) | `stores.rs` |
| `LuaJSONBridge`, `LuaThemeEngine` (+ effect/visualizer/smart-playlist/vault engines that call the bridge) | `lua.rs` |
| `Appearance` (interface styles) | `appearance.rs` |

## 2. Swift by necessity (Apple-only APIs)

These stay in Swift because the API exists only for Swift/Objective-C; the
logic around them is kept minimal and calls into the core.

| Area | Files | Why |
|---|---|---|
| Audio session, interruptions, routes | `AudioPlayerManager+EngineConfig` (session parts) | `AVAudioSession` |
| Now Playing + remote commands | `AudioPlayerManager+NowPlayingInfo` | `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter` |
| Apple Music library | `LibraryManager+WatchedFoldersAndMediaLibraryScan` (media-library part) | `MPMediaLibrary` / `ipod-library://` assets |
| Background work | `BackgroundRefreshService`, `LumisoundTrackVaultService` (scheduling), `BackgroundDownloadManager` | `BGTaskScheduler`, `UIApplication` background tasks |
| SharePlay | `SharePlayCoordinator*`, `ListenTogetherActivity` | GroupActivities |
| Widgets, Live Activity, intents, Focus filter | `WidgetDataService`, `LiveActivityManager`, `LumisoundAppIntents`, `LumisoundFocusFilter` | WidgetKit, ActivityKit, AppIntents |
| Watch link | `PhoneWatchSync` | WatchConnectivity |
| Sign-in sheets | `AccountService+DiscordLogin`, `DiscordVerificationService` | `ASWebAuthenticationSession` |
| Keychain | `KeychainTokenStore` | Security keychain items shared with the widget |
| App lock prompt | `AppLockService` | LocalAuthentication (Face ID / passcode) |
| Notifications | `NotificationService`, alarm/focus/time-capsule scheduling | UserNotifications |
| Sensors / health / haptics / Bluetooth | `PhysicalGesturesService`, `WorkoutModeService`, `HearingHealthService`, `AdaptiveSleepTimerService`, `MusicHapticsService`, `BluetoothBatteryMonitorService` | CoreMotion, HealthKit, CoreHaptics, CoreBluetooth |
| Metrics / reachability | `PerformanceMonitorService`, `NetworkPathMonitor`, `MainThreadHangMonitor` | MetricKit, Network.framework, run-loop observers |
| Media export/encode | `AudioEncoderService`, `ClipExportService`, `LyricVideoExportService`, `AIDJSessionExportService` | AVAssetWriter/AVAssetExportSession (AAC/H.264 encoding uses Apple's encoders; no Rust AAC encoder ships on iOS) |
| Photo picker | `BackgroundService` | PhotosUI |

## 3. Still Swift logic, to move next

- AVAudioEngine/AVPlayer path in `AudioPlayerManager` kept only as a fallback:
  Apple Music `ipod-library://` items (AVFoundation-only), decode failures, and
  the Settings toggle. Beat-matched tempo nudge during smart crossfade.
- Sync payload build/merge (`AccountService+Sync`) and the per-feature
  `AccountService+*` request/decode wrappers (transport is already Rust).
- Metadata enrichment and artwork (`MetadataFetchService`, `ArtworkService`,
  `ArtistImageService`); scan orchestration in `LibraryManager+*` (tag reading
  and the scan cache are Rust).
- Smart-playlist rule evaluation outside Lua, mood playlists, AI DJ scripting.
- `.lms` conversion pipeline (`LumisoundExclusiveExtensionService.convert`),
  tracked-playlist auto-download orchestration, direct/relay transports.
- `DocumentImportService`, `M3UImportService`, `CacheManagerService`,
  `DiagnosticsSnapshotService`, `AppLogger`/`RemoteLogger` formatting.
