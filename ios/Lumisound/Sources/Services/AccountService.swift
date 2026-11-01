import AuthenticationServices
import Foundation
import SwiftUI
import UIKit

// MARK: - AccountService

@MainActor
final class AccountService: ObservableObject {

    static let tokenKey       = "ios_account_token"
    static let userKey        = "ios_account_user"
    static let lastSyncKey    = "ios_account_last_sync"

    // MARK: Published state

    @Published var isLoggedIn: Bool = false
    @Published var currentUser: AppUser? = nil
    @Published var isSyncing: Bool = false
    @Published var errorMessage: String? = nil
    @Published var lastSyncDate: Date? = nil {
        didSet {
            if let d = lastSyncDate {
                UserDefaults.standard.set(d.timeIntervalSince1970, forKey: Self.lastSyncKey)
            }
        }
    }
    @Published var avatarImage: UIImage? = nil
    @Published var backups: [SyncBackup] = []
    @Published var socialActivity: [ActivityEntry] = []
    @Published var trendingTracks: [TrendingTrack] = []
    @Published var similarListenerTracks: [TrendingTrack] = []
    @Published var similarListenerCount: Int = 0
    @Published var ariaDailyPick: AriaDailyPick? = nil
    @Published var sessions: [AccountSession] = []
    @Published var stats: AccountStats? = nil
    @Published var achievements: AchievementsData? = nil
    @Published var yearInReview: YearInReview? = nil
    @Published var monthInReview: MonthInReview? = nil
    @Published var adminOverview: AdminOverview? = nil
    @Published var adminDownloadJobs: [AdminDownloadJob] = []
    @Published var adminErrors: [AdminErrorLogEntry] = []
    @Published var adminUsers: [AdminUser] = []
    @Published var hasDateOfBirth: Bool = false
    // Unread notification count for AccountView's badge — @Published (not
    // view-local @State) so it can be refreshed the instant a push arrives
    // while foregrounded (see AppDelegate's willPresent -> refreshUnreadNotificationCount),
    // not just when the view re-appears. Previously this only ever refreshed
    // on `.task` (view first-appear), so a push banner could visibly show
    // while the app was open without the in-app badge count changing until
    // the user navigated away and back — the "needs a tab switch to refresh"
    // pattern.
    @Published var unreadNotificationCount: Int = 0
    // Two-factor auth (TOTP). `pendingTOTPToken` is set by `login()` when the
    // server responds `requires_2fa` instead of a session — LoginView shows a
    // code-entry step and calls `completeTOTPLogin(code:)` while this is set,
    // instead of treating that response as a login failure.
    @Published var pendingTOTPToken: String? = nil
    @Published var isTOTPEnabled: Bool = false

    // MARK: Persisted token
    //
    // Security hardening — moved from plain UserDefaults to the Keychain
    // (see KeychainTokenStore's doc comment for why). The getter migrates
    // any pre-existing UserDefaults-stored token into the Keychain on first
    // read and then scrubs it from UserDefaults, so an already-logged-in
    // user upgrading to this version stays logged in instead of silently
    // losing their session — the old plaintext copy doesn't linger
    // alongside the new Keychain one, which would defeat the point of
    // moving it at all.

    var token: String? {
        get {
            if let migrated = UserDefaults.standard.string(forKey: Self.tokenKey) {
                KeychainTokenStore.set(migrated, account: "auth_token")
                UserDefaults.standard.removeObject(forKey: Self.tokenKey)
                return migrated
            }
            return KeychainTokenStore.get(account: "auth_token")
        }
        set {
            if let newValue {
                KeychainTokenStore.set(newValue, account: "auth_token")
            } else {
                KeychainTokenStore.delete(account: "auth_token")
            }
            // Belt-and-suspenders: guarantees no plaintext copy survives in
            // UserDefaults even if some future code path ever writes
            // through this setter without going through the migration
            // above first.
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        }
    }

    // MARK: Debounce state

    var syncDebounceTask: Task<Void, Never>?

    /// The default audio settings as of the last push they caused, in the
    /// form `AudioSettings.syncComparable` gives. See the `audioSettings`
    /// `onChange` in LumisoundApp for why a change has to differ from this to
    /// be worth a push.
    var lastPushedAudioSettings: AudioSettings?

    // MARK: Auto-push timer

    var autoPushTimer: Timer?
    /// Set by `pushSync` on success — see `handleLiveSyncChanged`'s doc
    /// comment for why this exists (echo suppression for the live
    /// "sync_changed" event this same push triggers).
    var lastPushCompletedAt: Date?
    // ASWebAuthenticationSession must be retained until its completion
    // handler runs. Keeping it here also gives cancellation/deallocation a
    // deterministic owner instead of relying on the local variable in the
    // async Discord-login helper.
    var discordAuthSession: ASWebAuthenticationSession?

    func startAutoPushTimer(library: LibraryManager) {
        stopAutoPushTimer()
        startAppearanceSync()

        // Pull the account's favorites once at start-up. This is the half that
        // actually restores them after a reinstall or on a new device — writes
        // have been mirrored up since `toggleFavorite`, but nothing ever read
        // them back, so the server's copy was write-only.
        Task { @MainActor [weak self, weak library] in
            guard let self, let library, self.isLoggedIn else { return }
            await self.mergeFavoritesFromServer(into: library)
            // One-time catch-up for lyrics Aria generated before they were
            // persisted server-side — see LyricsMigrationService.
            LyricsMigrationService.shared.migrateIfNeeded(library: library, account: self)
        }
        // Widened from 8 to 20 min now that it's a safety net rather than
        // the primary mechanism — LiveUpdateService's "sync_changed" push
        // (see below) tells this device the moment there's actually
        // something new to pull, instead of this timer blindly re-uploading
        // the whole library on a fixed schedule regardless of whether
        // anything changed. This timer still exists purely to catch up
        // after a dropped/reconnecting socket.
        autoPushTimer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isLoggedIn else { return }
                await self.pushSync(library: library)
                await self.syncLibraryInventory(library: library)
            }
        }
        // Lets iOS batch this wake-up with others (battery).
        autoPushTimer?.tolerance = (20 * 60) * 0.1

        guard let token else { return }
        let live = LiveUpdateService.shared
        live.onSyncChangedEvent = { [weak self, weak library] in
            guard let self, let library else { return }
            self.handleLiveSyncChanged(library: library)
        }
        live.onNotificationEvent = { [weak self] in
            guard let self else { return }
            Task { @MainActor in _ = await self.refreshUnreadNotificationCount() }
        }
        live.onPresenceEvent = { presence in
            PresenceService.shared.applyLivePresence(presence)
        }
        live.start(bridgeURL: bridgeURL, token: token)
    }

    func stopAutoPushTimer() {
        autoPushTimer?.invalidate()
        autoPushTimer = nil
        LiveUpdateService.shared.stop()
    }

    /// Handles a live "sync_changed" push — see `LiveUpdateService`'s file
    /// header and `lastPushCompletedAt`'s doc comment for why this exists
    /// and why it's debounced. `library` comes from whichever call site is
    /// still holding the `LibraryManager` it started the timer with.
    private func handleLiveSyncChanged(library: LibraryManager) {
        guard isLoggedIn else { return }
        // Suppress the echo of this device's own just-completed push —
        // anything within a generous window is assumed to be that, not a
        // genuinely different change from elsewhere.
        if let lastPushCompletedAt, Date().timeIntervalSince(lastPushCompletedAt) < 10 {
            return
        }
        Task { @MainActor [weak self, weak library] in
            guard let self, let library else { return }
            await self.pullSync(library: library)
        }
    }

    /// Schedules a push sync that fires 2 seconds after the last call.
    /// Rapid successive mutations only trigger one server write.
    func schedulePush(
        library: LibraryManager,
        audioSettings: AudioSettings? = nil,
        trackAudioSettings: [String: AudioSettings]? = nil
    ) {
        guard isLoggedIn else { return }
        syncDebounceTask?.cancel()
        syncDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard let self, !Task.isCancelled, self.isLoggedIn else { return }
            await self.pushSync(library: library, audioSettings: audioSettings, trackAudioSettings: trackAudioSettings)
            await self.syncLibraryInventory(library: library)
        }
    }

    /// Uploads the set of source ids currently in the on-device library
    /// (Song.sourceTrackID + download-ledger ids whose files are still present)
    /// to the bridge, so server-side dedup (playlist resolve / downloads) knows
    /// what the user already has even though yt-dlp can never see the device's
    /// folders. Replaces the stored snapshot, so deletions are reflected. Cheap
    /// and debounced via the schedulePush path that calls it.
    func syncLibraryInventory(library: LibraryManager) async {
        guard isLoggedIn else { return }
        // Id gathering, the not-loaded / unchanged skips and the retried
        // replace live in the Rust core (sync.rs).
        let ids = syncInventoryIds(songSourceIds: library.allSongs.compactMap(\.sourceTrackID),
                                   presentFilenames: library.allSongs.compactMap { $0.url?.lastPathComponent })
        Core.prepare(baseURL: bridgeURL, token: token)
        do {
            switch try await syncInventoryUpload(client: Core.api, ids: ids, libraryLoaded: !library.allSongs.isEmpty) {
            case .notLoaded:
                appLog("syncLibraryInventory skipped — library not loaded yet", category: "account")
            case .unchanged:
                break
            case .uploaded(let count):
                appLog("syncLibraryInventory: uploaded \(count) source id(s)", category: "account")
                RemoteLogger.log(category: "sync", event: "library_inventory_synced", detail: ["count": Int(count)])
            }
        } catch {
            if Task.isCancelled {
                appLog("syncLibraryInventory superseded by a newer sync (expected)", category: "account")
                return
            }
            appWarn("syncLibraryInventory failed: \(error.localizedDescription)", category: "account")
            // The id count travels with the failure: this endpoint's cost is
            // a function of exactly that number.
            RemoteLogger.logError(category: "sync", event: "library_inventory_sync_failed",
                                   message: error.localizedDescription,
                                   detail: ["sourceIDCount": ids.count])
        }
    }

    // MARK: Bridge URL — defaults to public baked-in URL, overridable in Settings

    var bridgeURL: String {
        UserDefaults.standard.string(forKey: StreamingService.bridgeURLKey)
            ?? StreamingService.defaultBridgeURL
    }

    // MARK: Init / Deinit

    deinit {
        syncDebounceTask?.cancel()
        autoPushTimer?.invalidate()
        discordAuthSession?.cancel()
    }

    /// Ambient reference to the app's single AccountService instance, so
    /// services without direct access to the SwiftUI environment (e.g.
    /// AudioPlayerManager) can push playback state. Set once at init.
    static weak var shared: AccountService?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.userKey),
           let user = try? JSONDecoder().decode(AppUser.self, from: data) {
            currentUser = user
            // Deliberately NOT gated on `token != nil` here. `currentUser`
            // and the Keychain-backed token are always cleared together --
            // handleUnauthorized()/clearSession() both wipe userKey and the
            // token in the same call, so restoring a cached user from
            // UserDefaults already proves this session was valid as of the
            // last write. Re-checking the Keychain read on every launch
            // (including headless background launches while the device is
            // locked -- see KeychainTokenStore's doc comment) risks a false
            // "no token" read flipping isLoggedIn to false even though the
            // real Keychain item and the server-side session are both still
            // intact, which then persists in this long-lived @StateObject
            // until the next real 401 or explicit logout corrects it -- the
            // exact "randomly logged out on open" bug this fixes. A
            // genuinely revoked/expired session is still caught correctly
            // by the normal 401 handling in
            // AccountService+PrivateHelpers.swift the next time an
            // authenticated request actually goes out.
            isLoggedIn = true
            hasDateOfBirth = user.dateOfBirth != nil
            // Show the cached avatar immediately so the launch screen never
            // flashes the placeholder initial circle for a returning user —
            // `loadAvatar(forceRefresh: true)` (called later, post-pullSync)
            // skips the cache and hits the network, which is too slow for
            // the launch screen's first frame.
            avatarImage = loadAvatarLocally()
        }
        let ts = UserDefaults.standard.double(forKey: Self.lastSyncKey)
        if ts > 0 {
            // Bypass didSet to avoid re-writing the same value on init
            _lastSyncDate = Published(initialValue: Date(timeIntervalSince1970: ts))
        }
        Self.shared = self
    }


    // MARK: Cross-extension stored state (extensions in AccountService+*.swift
    // cannot hold stored properties, so anything they need across calls lives here)

    /// Debounce task mirroring `schedulePush` — folder-structure pushes ride
    /// along on the same 2-second debounce window as the main sync push, since
    /// both are triggered by the same kinds of changes (library rescans/imports).
    var folderBackupDebounceTask: Task<Void, Never>?
    var playbackStatePushTask: Task<Void, Never>?

}

// MARK: - Error types

struct AccountError: LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? { message }
}

struct APIErrorBody: Decodable {
    let detail: String
}
