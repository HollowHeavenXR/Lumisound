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

## 3. Moved in phase J (were still Swift)

| Swift (now a wrapper) | Rust |
|---|---|
| Beat-matched tempo nudge in smart crossfade | `engine/` (`crossfade_to(tempo_match)`, `beatmatch_ratio`) |
| `AccountService+Sync` payload + pull merge, inventory upload, `NetworkRetry` policy | `sync.rs`, `retry.rs` |
| `MetadataFetchService`, `ArtworkService` processing, `ArtistImageService` lookup | `metadata.rs`, `media/artwork.rs` |
| Smart-playlist rules, `MoodPlaylistService` classification | `smart.rs`, `mood.rs` |
| `AIDJService` (announce decisions, duck plan, session log, transition request) | `aidj.rs` |
| `.lms` conversion (`LumisoundExclusiveExtensionService.convert`, relock) | `lock.rs` (`lms_convert`, `lms_relock_in_place`) |
| `TrackedPlaylistStore.runAutoDownloads` rules, `LibraryManager+DuplicateDetection` | `stores.rs` (`tracked_due`, `tracked_batch_verdict`), `duplicates.rs` (`LocalCopyIndex`) |
| Direct/relay download transports, finalize, destination resolution | `downloads.rs` |
| `DocumentImportService`, Documents scan orchestration, watched-folder leftover cleanup | `import.rs` |
| `CacheManagerService` | `cache.rs` |
| `AppLogger`, `RemoteLogger`, `TVAppLogger`, `TVRemoteLogger` | `logger.rs` |
| `AppLockService` state | `applock.rs` |
| Every `URLSession` data/upload/download call | `client.rs` (`Core.data/upload/download`) |

## 4. Intentionally still Swift

- AVAudioEngine/AVPlayer path in `AudioPlayerManager`: fallback only, for Apple
  Music `ipod-library://` items (readable only through AVFoundation), files the
  core can't decode, and the Settings toggle.
- AVFoundation tag reading in `DocumentImportService`: only for files lofty
  can't parse (rules applied are the core's), plus video first-frame thumbnails.
- Image caches (`CachedAsyncImage`, `TVAuthImage`): `URLCache`-backed UI caches.
- `DiagnosticsSnapshotService`: reads live SwiftUI-observable state and UIKit
  /Mach device info, then hands it to the core's `logger_event`.
- `PodcastDownloadManager` scheduling, `BackgroundDownloadManager`
  (`UIApplication` background tasks); transfers themselves are the core's.
- Debounce timers and `Task` orchestration that glue SwiftUI state to core calls.
