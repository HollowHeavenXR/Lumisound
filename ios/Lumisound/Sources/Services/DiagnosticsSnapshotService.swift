import Darwin
import Foundation
import UIKit

// MARK: - DiagnosticsSnapshotService
//
// Periodic structured snapshot of live app state — playback, profile, the
// social system, and which settings are actually on AND having a visible
// effect — sent to the bridge's event log every `interval`. This exists
// specifically because there's no Xcode/device debugger available in this
// project's dev environment: every prior investigation (the gallery
// background stuck-icon bug, the Library reload freeze, the media scan
// stutter) started from either a lucky log line or an ad-hoc one-off dump
// added mid-investigation. This is the standing version of that same idea —
// a routine, always-on "what does a real session actually look like right
// now" readout, so the next investigation starts with data already in hand
// instead of needing its own round of diagnostic builds first.
//
// Always-on, no settings toggle — matches PerformanceMonitorService's own
// "just always runs" precedent for infrastructure-level diagnostics (that
// one covers CPU/GPU; this one covers app-level state). Skips entirely
// while backgrounded (nothing meaningful changes for a user who isn't
// looking at the app, and there's no reason to spend the network/battery).
@MainActor
enum DiagnosticsSnapshotService {
    /// "A set easy interval" — 5 minutes. Frequent enough to catch a
    /// session's real state without turning this into its own source of
    /// background chatter; every RemoteLogger call here is fire-and-forget
    /// and best-effort, so a missed tick costs nothing.
    private static let interval: TimeInterval = 5 * 60
    private static var timer: Timer?

    /// When `send` last actually delivered a snapshot (not merely been
    /// called — calls skipped by the `.active` guard don't count). Drives
    /// `noteDidBecomeActive`'s catch-up below.
    private static var lastSentAt: Date?

    /// Call once from `LumisoundApp`'s `.task` — deliberately NOT `init()`
    /// (unlike `PerformanceMonitorService`, which has nothing to read yet
    /// at that point): every `.shared` singleton this function reads is a
    /// `weak var` set by that service's own `init()`, and those services
    /// are `@StateObject`s constructed when `LumisoundApp`'s `body` first
    /// evaluates — after `init()`, but before `.task` fires.
    static func start() {
        guard timer == nil else { return }
        send(reason: "app_launch") // seed one immediately rather than waiting a full interval
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { send(reason: "periodic") }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Call from `LumisoundApp`'s `scenePhase == .active` handler.
    ///
    /// A repeating `Timer` on the main run loop doesn't fire while the app is
    /// suspended, and `send`'s `.active` guard drops any tick that lands
    /// while backgrounded — so with real usage (short foreground bursts, the
    /// app backgrounded in between) the periodic tick effectively never
    /// produced a row: across the first three real sessions after this
    /// service shipped, `ios_app_event_log` held only `app_launch` snapshots
    /// and not a single `periodic` one, including a session that stayed in
    /// use for ~6 minutes and so should have logged one. That made the
    /// standing "what does a live session look like" readout this service
    /// exists to provide amount to a single launch-time sample, which is
    /// exactly the gap it was built to close.
    ///
    /// Taking the overdue snapshot on foreground return fixes that without
    /// raising the tick rate: it only fires when a full `interval` has
    /// actually elapsed since the last delivered snapshot, so a user
    /// flicking in and out of the app doesn't generate a burst.
    static func noteDidBecomeActive() {
        guard timer != nil else { return } // not started yet; `start()` seeds its own
        // A nil `lastSentAt` means no snapshot has ever actually gone out —
        // `start()`'s seeding call is made from `.task`, which can run while
        // the scene is still `.inactive`, in which case `send`'s guard
        // dropped it. Treat that as overdue rather than as "just sent", or
        // that launch would produce no snapshot at all, ever.
        if let last = lastSentAt, Date().timeIntervalSince(last) < interval { return }
        send(reason: "foreground")
    }

    private static func send(reason: String) {
        guard UIApplication.shared.applicationState == .active else { return }
        lastSentAt = Date()

        let detail: [String: Any] = [
            "device": deviceSnapshot(),
            "playback": playbackSnapshot(),
            "profile": profileSnapshot(),
            "social": socialSnapshot(),
            "notifications": notificationsSnapshot(),
            "settings": settingsSnapshot(),
        ]
        RemoteLogger.log(category: "diagnostics", event: "snapshot", message: reason, detail: detail)
    }

    // MARK: - Notifications
    //
    // Split out from `settingsSnapshot` since it has its own two-layer
    // "is this actually working" question: `isEnabled` is this app's own
    // toggle, `isAuthorized` is whether iOS actually granted permission —
    // a user can have the in-app switch on while `isAuthorized` is false
    // (denied at the system prompt, or revoked later in iOS Settings),
    // which silently means zero notifications ever arrive despite every
    // in-app setting saying they should.

    private static func notificationsSnapshot() -> [String: Any] {
        let notifications = NotificationService.shared
        return [
            "enabledInApp": notifications.isEnabled,
            "authorizedByOS": notifications.isAuthorized,
            "actuallyWorking": notifications.isEnabled && notifications.isAuthorized,
            "topicsEnabledCount": notifications.topicPreferences.values.filter { $0 }.count,
            "hasAuthorizationError": notifications.lastAuthorizationError != nil,
        ]
    }

    // MARK: - Device (perf correlation)
    //
    // `PerformanceMonitorService` already logs system-wide CPU load every
    // 60s independently of this — this section exists to put THIS app's own
    // memory footprint and the device's thermal state right next to
    // playback/settings state in the SAME event, so "device gets hot/laggy
    // after N minutes"-style reports can be correlated against what was
    // actually running at the time without manually joining two separate
    // log streams by timestamp.

    private static func deviceSnapshot() -> [String: Any] {
        let info = Bundle.main.infoDictionary
        var result: [String: Any] = [
            // Which build produced this snapshot. `ios_app_logs` records an
            // app_version per row but these snapshots land in
            // `ios_app_event_log`, which does not — so there was no way to
            // tell whether a snapshot (or an error logged beside it) came
            // from a build that already contains a given fix. That directly
            // blocked an investigation into repeated backup failures, where
            // the whole question was "is the device even running the build
            // with the fix in it".
            "appVersion": info?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildNumber": info?["CFBundleVersion"] as? String ?? "unknown",
            "osVersion": UIDevice.current.systemVersion,
            "thermalState": ProcessInfo.processInfo.thermalState.diagnosticsDescription,
            "lowPowerModeEnabled": ProcessInfo.processInfo.isLowPowerModeEnabled,
            // The system-level gate every background feature in this app
            // depends on (BackgroundRefreshService's subscription/tracked-
            // playlist checks, LumisoundTrackVaultService's conversion
            // sweep, PodcastAutoDownloadService) — if this isn't
            // `.available`, every one of those is silently inert regardless
            // of what's toggled on in-app, which is exactly the "setting is
            // on but doing nothing" shape this whole service exists to
            // surface. Set by the user in iOS Settings, not by this app.
            "backgroundRefreshStatus": UIApplication.shared.backgroundRefreshStatus.diagnosticsDescription,
        ]
        // -1 means monitoring isn't enabled yet (it's opt-in, off by
        // default) rather than "no battery" — every real device has one, so
        // just turning monitoring on here is simpler than threading a
        // one-time enable call through app launch for this alone.
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel >= 0 {
            result["batteryLevel"] = batteryLevel
        }
        if let mb = residentMemoryMB() {
            result["residentMemoryMB"] = Int(mb.rounded())
        }
        // `NSNull()`, not bare `nil` — RemoteLogger's `detail` payload is
        // JSON-serialized, where `Optional<Bool>.none` boxed as `Any` is
        // not a value `JSONSerialization` recognizes, but `NSNull` is the
        // documented way to represent "checked, still unknown" (as opposed
        // to omitting the key, which would read as "never checked at all").
        result["bridge"] = [
            "reachable": BridgeHealthService.shared?.isHealthy.map { $0 as Any } ?? NSNull(),
            "apiKeyValid": BridgeHealthService.shared?.isAPIKeyValid.map { $0 as Any } ?? NSNull(),
        ]
        return result
    }

    /// This process's own resident memory footprint via the standard Mach
    /// `task_info` call — the same technique `PerformanceMonitorService`
    /// uses for CPU (`host_cpu_load_info`), just the per-process memory
    /// counterpart. Public API, no entitlement or private-symbol usage;
    /// widely used by performance-monitoring code for exactly this purpose.
    private static func residentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    // MARK: - Playback

    private static func playbackSnapshot() -> [String: Any] {
        guard let player = AudioPlayerManager.shared else { return ["available": false] }
        let s = player.audioSettings
        return [
            "available": true,
            "isPlaying": player.isPlaying,
            "hasCurrentSong": player.currentSong != nil,
            "queueCount": player.queue.count,
            "queueIndex": player.currentIndex,
            "positionSeconds": Int(player.position),
            "durationSeconds": Int(player.duration),
            "repeatMode": String(describing: player.repeatMode),
            "shuffleEnabled": player.shuffleEnabled,
            "autoRadioEnabled": player.autoRadioEnabled,
            "abRepeatEnabled": player.abRepeatEnabled,
            "isUsingTrackAudioSettings": player.isUsingTrackAudioSettings,
            // Whether each toggle is not just ON but actually doing
            // something right now — the distinction that matters most for
            // "is this feature working" style investigations.
            "effectsActive": [
                "8d": player.is8DActive,
                "tremolo": player.isTremoloActive,
                "vibrato": player.isVibratoActive,
                "crossfading": player.isCrossfading,
            ],
            "audioSettings": [
                "volume": s.volume,
                "speed": s.speed,
                "pitchSemitones": s.pitchSemitones,
                "equalizerEnabled": s.equalizerEnabled,
                "eqPreset": String(describing: s.eqPreset),
                "crossfadeEnabled": s.crossfadeEnabled,
                "crossfadeDuration": s.crossfadeDuration,
                "gaplessEnabled": s.gaplessEnabled,
                "replayGainEnabled": s.replayGainEnabled,
            ],
            "sleepTimer": [
                "enabledAndRunning": SleepTimerService.shared?.isActive ?? false,
                "remainingSeconds": Int(SleepTimerService.shared?.remainingSeconds ?? 0),
            ],
            "aiDJ": [
                "enabled": AIDJService.shared?.isEnabled ?? false,
                "currentlySpeaking": AIDJService.shared?.isSpeaking ?? false,
            ],
            "silenceTrimEnabled": SilenceTrimService.shared?.isEnabled ?? false,
            "engine": player.isUsingRustEngine ? "lumisound" : "avaudioengine",
            "lumisoundEngine": AudioPlayerManager.engineHealthSnapshot(),
        ]
    }

    // MARK: - Profile

    private static func profileSnapshot() -> [String: Any] {
        guard let account = AccountService.shared else { return ["available": false] }
        return [
            "available": true,
            "isLoggedIn": account.isLoggedIn,
            "hasAvatarImageLoaded": account.avatarImage != nil,
            "hasUnlockedAchievements": (account.achievements?.totalPlays ?? 0) > 0,
            "hasAriaDailyPick": account.ariaDailyPick != nil,
            "similarListenerTrackCount": account.similarListenerTracks.count,
            "discordVerified": DiscordVerificationService.shared.isVerified,
        ]
    }

    // MARK: - Social

    private static func socialSnapshot() -> [String: Any] {
        guard let social = SocialService.shared else { return ["available": false] }
        return [
            "available": true,
            "hasMyProfile": social.myProfile != nil,
            "friendCount": social.friends.count,
            "incomingRequestCount": social.incomingRequests.count,
            "outgoingRequestCount": social.outgoingRequests.count,
            "blockedCount": social.blockedUsers.count,
            "friendsActivityCount": social.friendsActivity.count,
            "listeningTogetherCount": social.listeningTogether.count,
        ]
    }

    // MARK: - Liquid Glass
    //
    // Added when Settings was converted to Liquid Glass. Glass is the one part
    // of the UI whose result genuinely cannot be verified from this dev
    // environment — there's no Mac, so CI proves it compiles and nothing
    // proves how it *looks*. These fields exist so a "the glass looks wrong"
    // report arrives with the configuration that produced it already attached,
    // rather than starting a round of guessing which knob the user had moved.
    //
    // `reduceTransparency` (recorded alongside this, at the top level of
    // `settingsSnapshot`) is the single most important correlate: iOS renders
    // Liquid Glass as a flat opaque fill when it's on, so a user with it
    // enabled sees none of this work and would reasonably report the glass as
    // "not doing anything". `renderingAsGlass` states that outright rather
    // than leaving the join to whoever reads the row.

    private static func glassSnapshot() -> [String: Any] {
        let glass = GlassSettings.shared
        let reduceTransparency = UIAccessibility.isReduceTransparencyEnabled
        return [
            "tintStrength": glass.tintStrength,
            "useAccentTint": glass.useAccentTint,
            // Only meaningful when `useAccentTint` is false; recorded either
            // way so a report can be reproduced exactly.
            "tintHue": glass.tintHue,
            "tintIsEffectivelyClear": glass.tintColor == .clear,
            // Whether the user is actually seeing Liquid Glass at all.
            "renderingAsGlass": !reduceTransparency,
            // `translucency` drives ONLY the pre-iOS-26 fallback branch in
            // GlassEffectCompat. This app's deployment target is iOS 26.0, so
            // that branch is unreachable and this slider cannot affect the app
            // — yet it is still live in GlassSettingsView, and its own local
            // preview swatch *does* respond to it, so dragging it visibly
            // changes the preview while nothing else moves. That is exactly
            // the "setting is on but doing nothing" shape this whole service
            // exists to surface, so it is reported as such rather than as a
            // plain value: a non-default reading here means a user spent time
            // on a control that does nothing.
            "translucency": glass.translucency,
            "translucencyHasNoEffect": true,
            "translucencyMovedFromDefault": abs(glass.translucency - 1.0) > 0.001,
        ]
    }

    // MARK: - Navbar
    //
    // The floating navbar is the glass surface Settings sits directly above,
    // and the one whose height Settings must reserve clearance for — its mode
    // decides whether that bar is a tab row or the mini player. Recorded here
    // so a layout complaint about either screen can be read against the
    // configuration that produced it.

    private static func navbarSnapshot() -> [String: Any] {
        let defaults = UserDefaults.standard
        let hiddenTabs = Set(
            (defaults.string(forKey: "navbarHiddenTabs") ?? "")
                .split(separator: ",")
                .compactMap { Int($0) }
        ).subtracting([6])  // Settings can never be hidden — see CustomTabBar.hiddenTabs
        return [
            "mode": defaults.string(forKey: "navbarDisplayMode") ?? NavbarDisplayMode.tabs.rawValue,
            "selectionStyle": defaults.string(forKey: "navbarSelectionStyle") ?? NavbarSelectionStyle.glassPill.rawValue,
            "showTabLabels": defaults.object(forKey: "navbarShowTabLabels") as? Bool ?? true,
            "hiddenTabCount": hiddenTabs.count,
        ]
    }

    // MARK: - Settings (and whether each is actually doing something)

    private static func settingsSnapshot() -> [String: Any] {
        var result: [String: Any] = [
            "reduceMotion": UserDefaults.standard.bool(forKey: "app_reduce_motion"),
            "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
        ]
        result["glass"] = glassSnapshot()
        result["navbar"] = navbarSnapshot()

        if let bg = BackgroundService.shared {
            result["galleryBackground"] = [
                "enabled": bg.isEnabled,
                "source": UserDefaults.standard.string(forKey: GalleryBackgroundSource.storageKey)
                    ?? GalleryBackgroundSource.photos.rawValue,
                "imageCount": bg.images.count,
                // The "is it actually doing something" signal: enabled with
                // images loaded but the shuffle timer not running means the
                // toggle is on and nothing is happening — exactly the shape
                // of bug this whole service exists to catch earlier.
                "actuallyShuffling": bg.isActive,
                "kenBurnsEnabled": bg.kenBurnsEnabled,
            ]
        }

        if let appLock = AppLockService.shared {
            result["appLock"] = [
                "enabled": appLock.isEnabled,
                "currentlyUnlocked": appLock.isUnlocked,
            ]
        }

        if let library = LibraryManager.shared {
            result["library"] = [
                "songCount": library.allSongs.count,
                "isScanning": library.isScanning,
                "playlistCount": library.playlists.count,
                "favoriteCount": library.favoriteSongIDs.count,
            ]
        }

        let trackedPlaylists = TrackedPlaylistStore.shared.playlists
        result["trackedPlaylists"] = [
            "count": trackedPlaylists.count,
            "autoDownloadEnabledCount": trackedPlaylists.filter(\.isAutoDownload).count,
        ]

        if let mood = MoodPlaylistService.shared {
            result["moodPlaylists"] = [
                "isAnalyzing": mood.isAnalyzing,
                // Non-zero bucket counts is the "is this feature actually
                // producing anything" signal — a user could have Moods
                // enabled/visible in the hub with every bucket empty if
                // classification never ran or never found a confident match.
                "hasClassifiedSongs": !mood.energeticSongs.isEmpty || !mood.chillSongs.isEmpty
                    || !mood.focusSongs.isEmpty || !mood.sleepSongs.isEmpty,
            ]
        }

        result["smartPlaylistCount"] = SmartPlaylistStore.shared.playlists.count
        result["watchedFolderCount"] = MusicFolderService.shared?.watchedFolders.count ?? 0
        result["recentlyDeletedCount"] = RecentlyDeletedService.shared?.entries.count ?? 0
        // Podcast auto-download has no dedicated service instance (it's a
        // plain enum with a UserDefaults-backed flag, checked directly by
        // its own periodic pass) — read the same flag it reads.
        result["podcastAutoDownloadEnabled"] = UserDefaults.standard.bool(forKey: PodcastAutoDownloadService.enabledKey)

        return result
    }
}

private extension ProcessInfo.ThermalState {
    var diagnosticsDescription: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

private extension UIBackgroundRefreshStatus {
    var diagnosticsDescription: String {
        switch self {
        case .available: return "available"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }
}
