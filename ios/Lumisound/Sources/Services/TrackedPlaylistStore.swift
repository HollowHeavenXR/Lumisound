import Foundation
import Combine

// MARK: - TrackedPlaylist

/// A YouTube/SoundCloud playlist the user is tracking for on-demand downloads.
/// Distinct from `ArtistSubscription` (channel following): tracked playlists are
/// stored locally on the device and resolved to their tracks on demand via the
/// bridge's `/api/resolve`, so each item can be downloaded into the local
/// library (with duplicate detection) without a backend schema change.
struct TrackedPlaylist: Identifiable, Codable, Equatable {
    let id: String          // stable UUID string
    var url: String
    var name: String
    var thumbnailURL: String
    var dateAdded: Date
    /// Track count seen on the last successful resolve — lets the list show a
    /// hint ("32 tracks") without re-resolving every appearance.
    var lastTrackCount: Int
    /// When true, the app auto-downloads newly-added tracks from this playlist in
    /// the background. Optional so older persisted entries decode (missing = off).
    var autoDownload: Bool?
    /// Last time the auto-downloader checked this playlist (throttles checks).
    var lastAutoCheck: Date?
    /// Optional per-playlist destination subfolder under "Imported Music" (see
    /// `DownloadFolderPicker`) — lets this playlist's downloads land somewhere
    /// dedicated instead of the global Settings → yt-dlp → Download Folder.
    /// nil/empty falls back to that global setting. Optional so older persisted
    /// entries decode (missing = use the global default).
    var destinationFolder: String?

    var isAutoDownload: Bool { autoDownload ?? false }

    init(id: String = UUID().uuidString,
         url: String,
         name: String,
         thumbnailURL: String = "",
         dateAdded: Date = Date(),
         lastTrackCount: Int = 0,
         autoDownload: Bool? = nil,
         lastAutoCheck: Date? = nil,
         destinationFolder: String? = nil) {
        self.id = id
        self.url = url
        self.name = name
        self.thumbnailURL = thumbnailURL
        self.dateAdded = dateAdded
        self.lastTrackCount = lastTrackCount
        self.autoDownload = autoDownload
        self.lastAutoCheck = lastAutoCheck
        self.destinationFolder = destinationFolder
    }
}

// MARK: - TrackedPlaylistStore

/// Local, on-device persistence for tracked playlists (UserDefaults-backed).
/// Kept separate from the server-side channel subscriptions so it needs no DB
/// migration; the trade-off is that tracked playlists don't sync across devices.
@MainActor
final class TrackedPlaylistStore: ObservableObject {
    static let shared = TrackedPlaylistStore()

    @Published private(set) var playlists: [TrackedPlaylist] = []

    private let key = "trackedPlaylists.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key) { trackedImportLegacy(json: data) }
        load()
    }

    // Store rules (URL de-dup, naming, merge) and persistence live in the
    // Rust core (rust/core/src/stores.rs); `playlists` mirrors it.

    @discardableResult
    func add(url: String, name: String, thumbnailURL: String = "") -> Bool {
        let ok = trackedAdd(url: url, name: name, thumbnailUrl: thumbnailURL)
        if ok { load() }
        return ok
    }

    func remove(id: String) {
        trackedRemove(id: id)
        load()
    }

    func mergeFromSync(_ remote: [TrackedPlaylist]) {
        trackedMerge(remote: remote.map(Self.record))
        load()
    }

    func updateMetadata(id: String, trackCount: Int? = nil, thumbnailURL: String? = nil, name: String? = nil) {
        trackedUpdateMetadata(id: id, trackCount: trackCount.map(Int64.init), thumbnailUrl: thumbnailURL, name: name)
        load()
    }

    func setAutoDownload(id: String, _ on: Bool) {
        trackedSetAutoDownload(id: id, on: on)
        load()
    }

    func setDestinationFolder(id: String, _ folder: String) {
        trackedSetDestination(id: id, folder: folder)
        load()
    }

    private func markAutoChecked(id: String) {
        trackedMarkChecked(id: id)
        load()
    }

    private static func record(_ p: TrackedPlaylist) -> TrackedPlaylistRecord {
        TrackedPlaylistRecord(id: p.id, url: p.url, name: p.name, thumbnailUrl: p.thumbnailURL,
                              dateAdded: p.dateAdded.timeIntervalSince1970, lastTrackCount: Int64(p.lastTrackCount),
                              autoDownload: p.autoDownload, lastAutoCheck: p.lastAutoCheck?.timeIntervalSince1970,
                              destinationFolder: p.destinationFolder)
    }

    private static let autoDownloadConcurrency = 4

    /// Guards against concurrent `runAutoDownloads` calls — it's triggered
    /// from two independent, uncoordinated sites (app launch/foreground in
    /// LumisoundApp.swift, and BackgroundRefreshService's BGAppRefreshTask
    /// handler), and `minInterval`/`lastAutoCheck` alone doesn't prevent
    /// overlap between them: `lastAutoCheck` is only updated (via
    /// `markAutoChecked`) after a playlist's full download batch completes,
    /// so two calls that start close together (e.g. app opened right as a
    /// background refresh fires) both see the same playlist as "due", both
    /// scan and compute their own `toGet` before either has downloaded
    /// anything, and both attempt the same "new" tracks in parallel. The
    /// per-download dedupe check in `downloadToLibrary` still catches and
    /// skips the actual write, but not before wasting a network round-trip
    /// and a yt-dlp job on the bridge for every track duplicated this way.
    private var isRunningAutoDownloads = false

    /// For each auto-download playlist not checked in the last `minInterval`,
    /// resolves it and downloads any tracks the user doesn't already have
    /// (deduped via `LibraryManager.hasLocalCopy`). Safe to call on launch /
    /// foreground; throttled so it doesn't re-resolve constantly.
    ///
    /// NOTE: lowering `minInterval` doesn't buy true "every N minutes in the
    /// background" behavior on its own — it only controls whether a check
    /// is SKIPPED once one actually runs. Whether a check runs at all while
    /// backgrounded is entirely up to `BackgroundRefreshService`/iOS's
    /// `BGAppRefreshTask` scheduling (see its doc comment), which iOS
    /// throttles independently of anything here and offers no cadence
    /// guarantee. This just makes checks that DO happen far less likely to be
    /// skipped by this throttle.
    ///
    /// ## Resuming an interrupted pass
    ///
    /// Being interrupted is the normal case, not the exception — a background
    /// task's budget expires, or iOS suspends the app mid-batch. Two things make
    /// that recoverable, and both matter:
    ///
    ///   * This function leaves `lastAutoCheck` UNTOUCHED when it is cancelled or
    ///     finds the bridge unreachable, so the playlist stays due and the next
    ///     trigger picks it straight back up rather than waiting out the throttle
    ///     window. It only stamps a playlist as checked on a pass that genuinely
    ///     ran to completion.
    ///   * `startForegroundResumeLoop` gives it a trigger that doesn't depend on
    ///     iOS's background scheduling at all, alongside the cold-launch and
    ///     foreground triggers in `LumisoundApp`.
    ///
    /// There is no separate persisted queue of "tracks I still owe": each pass
    /// re-resolves the playlist and diffs it against the library, so whatever is
    /// still missing IS the remaining work. That is self-healing across a crash,
    /// a force-quit, and an app update, none of which a queue file would survive
    /// as reliably.
    /// Returns true when every due playlist finished (false: interrupted —
    /// cancelled, bridge down — so the next trigger should resume).
    @discardableResult
    func runAutoDownloads(streaming: StreamingService,
                          library: LibraryManager,
                          minInterval: TimeInterval = 5 * 60) async -> Bool {
        guard !isRunningAutoDownloads else { return false }
        isRunningAutoDownloads = true
        defer { isRunningAutoDownloads = false }

        let dueIDs = Set(trackedDue(minIntervalSecs: minInterval).map(\.id))
        let due = playlists.filter { dueIDs.contains($0.id) }
        guard !due.isEmpty else { return true }

        // Scanned ONCE up front rather than once per playlist.
        //
        // This scan was inside the loop, so a pass over several tracked playlists
        // ran a full local-library scan for each of them. Measured from a real
        // session: scans every three to six seconds, and a single pass taking
        // thirty seconds to walk three playlists with a scan apiece. Each one
        // flips `@Published isScanning`, which forces a SwiftUI re-render across
        // every view observing LibraryManager — the documented cause of the
        // visible freezing, and why scrolling the library stuttered for roughly
        // two seconds out of every five.
        //
        // Correctness is unaffected because the scan exists to keep dedup
        // decisions honest, and the library can only change mid-pass if this pass
        // downloads something. Between playlists where nothing was downloaded,
        // `allSongs` is byte-for-byte what it already was, so re-scanning could not
        // change a single decision. Where something IS downloaded, the loop
        // re-scans before moving on (see the end of the loop).
        await library.scanLocalDocumentsAsync(userInitiated: false)

        for pl in due {
            // A pass gets interrupted far more often than it completes on a
            // phone: a BGAppRefreshTask's budget expires (its expirationHandler
            // cancels this task), or the app is suspended mid-batch. Stop
            // promptly when that happens, and — critically — WITHOUT marking
            // this playlist checked, so the next trigger resumes it straight
            // away instead of treating it as freshly done. See the
            // `markAutoChecked` call at the end of this loop.
            if Task.isCancelled {
                appLog("runAutoDownloads: cancelled before \"\(pl.name)\" — leaving it due so the next trigger resumes it", category: "network")
                return false
            }
            let tracks = await streaming.fetchPlaylistTracks(url: pl.url, existingSongs: [])

            // `fetchPlaylistTracks` returns [] for EVERY failure — a dead
            // bridge, a 500, a timeout, no network — which is the same value it
            // returns for a playlist that genuinely has nothing new. That
            // ambiguity is what made a server outage look like a successful
            // check: the pass did nothing, then marked the playlist checked
            // anyway, so a playlist mid-download would sit idle for the whole
            // throttle window on the strength of a request that never
            // succeeded. Probing health only when the resolve came back empty
            // keeps this off the normal path entirely.
            if tracks.isEmpty {
                let reachable = await streaming.checkHealth()
                if !reachable {
                    appWarn("runAutoDownloads: bridge unreachable — stopping this pass with \"\(pl.name)\" still due so it retries rather than waiting out the throttle", category: "network")
                    // Deliberately abandons the whole pass, not just this
                    // playlist: every remaining one resolves against the same
                    // bridge, and marching through them to fail identically
                    // would mark each of them checked in turn.
                    return false
                }
            }
            // One Rust-core index per playlist (O(1) per track): source id
            // with the file still present, ledger entry, or title/artist/
            // duration; repeated entries in the resolve collapse to one job.
            let index = await library.localCopyIndex()
            let toGet = index.missing(candidates: tracks.map(\.remoteCandidate)).map { tracks[Int($0)] }
            let destinationDir = StreamingService.downloadDirectory(forFolderName: pl.destinationFolder)
            let existingSongsSnapshot = library.allSongs
            // `got`/`blocked` and the per-track work itself run on
            // `StreamingService`'s own MainActor isolation regardless of how
            // many `group.addTask` closures call into it concurrently —
            // actor isolation only serializes the SYNCHRONOUS stretches
            // between awaits, not the awaited work itself, so the slow part
            // of each download (network round-trips, the bridge's own
            // yt-dlp job) genuinely overlaps across these tasks rather than
            // queuing behind each other on the client. Was previously a
            // plain sequential `for track in toGet { await ... }` — one
            // track at a time — which, at the ~15-30s a job-based download
            // actually takes end-to-end (see the bridge's own request logs),
            // turned a several-hundred-track playlist into well over an
            // hour of serialized waiting even though the bridge itself was
            // sitting mostly idle the whole time.
            var got = 0
            var blocked = 0
            // Counted so a mid-batch outage can be told apart from a batch of
            // individually-unavailable tracks — see the health probe after the
            // group. `blocked` and `alreadyDownloaded` are deliberately NOT
            // failures: both are settled answers about a specific track, and
            // neither says anything about whether the bridge is up.
            var failed = 0
            await withTaskGroup(of: (succeeded: Bool, wasBlocked: Bool, failed: Bool).self) { group in
                var nextIndex = 0
                func startNext() {
                    guard nextIndex < toGet.count else { return }
                    // Stop feeding the group once cancelled. Without this, an
                    // expired background task kept starting fresh downloads
                    // right up to the last track of the playlist, every one of
                    // them doomed — burning bridge capacity and, worse, making
                    // the pass look like it ran to completion.
                    guard !Task.isCancelled else { return }
                    let track = toGet[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            _ = try await streaming.downloadToLibrary(
                                track: track,
                                destinationDir: destinationDir,
                                existingSongs: existingSongsSnapshot,
                                destinationFolderName: pl.destinationFolder,
                                reportExistingAsSkipped: true
                            )
                            return (true, false, false)
                        } catch StreamingError.serverDetail {
                            // e.g. an auto-generated Topic-channel track
                            // blocked from extraction — tallied so the
                            // summary toast can explain why some tracks
                            // were skipped instead of silently dropping them.
                            return (false, true, false)
                        } catch StreamingError.alreadyDownloaded {
                            return (false, false, false)
                        } catch StreamingError.permanentlyUnavailable {
                            // Known-gone and still in cool-off, so no request was
                            // made — see DownloadFailureStore. Not a failure and
                            // deliberately not counted as one: a playlist full of
                            // dead videos must not look like a bridge outage to the
                            // health probe below.
                            return (false, false, false)
                        } catch StreamingError.alreadyInFlight {
                            // Another download of this exact track is already
                            // running, or WAS when the app died — the claim
                            // (DownloadLedgerStore.beginDownload) is backed by
                            // UserDefaults with a 5-minute TTL so it deliberately
                            // outlives a crash. That makes this the normal answer
                            // for the first resume attempt right after a crash,
                            // and it is emphatically not a failure: counting it as
                            // one would make a post-crash resume look like a
                            // bridge outage (got == 0, many "failures") and cost
                            // the pass its health probe and a throttle window.
                            // Left to the next cycle, by which point the claim has
                            // expired.
                            return (false, false, false)
                        } catch {
                            // Other failures (network, timeout, etc.) stay
                            // silent here — this is a background check, and
                            // the next scheduled run will simply retry them.
                            // Counted, though: a whole batch failing this way is
                            // how a bridge that died mid-pass presents itself.
                            return (false, false, true)
                        }
                    }
                }
                for _ in 0..<min(Self.autoDownloadConcurrency, toGet.count) { startNext() }
                for await result in group {
                    if result.succeeded { got += 1 }
                    if result.wasBlocked { blocked += 1 }
                    if result.failed { failed += 1 }
                    startNext()
                }
            }
            if got > 0 {
                // The library genuinely changed, so the next playlist's dedup needs
                // to see it. This is the only condition under which a mid-pass
                // re-scan can affect any decision.
                await library.scanLocalDocumentsAsync(userInitiated: false)
                ToastCenter.shared.show("Auto-downloaded \(got) new track\(got == 1 ? "" : "s") from \"\(pl.name)\"",
                                        category: .download)
            }
            if blocked > 0 {
                ToastCenter.shared.show(
                    "\(blocked) track\(blocked == 1 ? "" : "s") from \"\(pl.name)\" blocked by YouTube (auto-generated \"Topic\" channel)",
                    category: .warning
                )
            }
            // Said out loud, once per pass, because the old behaviour was for
            // these tracks to silently never appear while the app re-requested
            // them indefinitely. A count the user can see is what turns "this
            // playlist never finishes" into "these ones are gone from YouTube".
            let unavailable = DownloadFailureStore.shared.suppressedCount(
                among: toGet.map(\.sourceTrackID))
            if unavailable > 0 {
                appLog("runAutoDownloads: \(unavailable) track(s) from \"\(pl.name)\" skipped — no longer available on YouTube", category: "network")
                if got > 0 || blocked > 0 {
                    ToastCenter.shared.show(
                        "\(unavailable) track\(unavailable == 1 ? "" : "s") from \"\(pl.name)\" \(unavailable == 1 ? "is" : "are") no longer available on YouTube",
                        category: .info
                    )
                }
            }
            if !tracks.isEmpty { updateMetadata(id: pl.id, trackCount: tracks.count) }

            // Outcome rules (Rust core): interrupted, or nothing landed while
            // the bridge is down -> stay due and stop the pass; partial
            // failures are normal per-track misses and still count as checked.
            var verdict = trackedBatchVerdict(got: UInt32(got), failed: UInt32(failed), cancelled: Task.isCancelled, reachable: nil)
            if verdict == .probeHealth {
                let reachable = await streaming.checkHealth()
                verdict = trackedBatchVerdict(got: UInt32(got), failed: UInt32(failed), cancelled: Task.isCancelled, reachable: reachable)
                if reachable {
                    appWarn("runAutoDownloads: \(failed) track(s) from \"\(pl.name)\" failed but the bridge is reachable — treating as per-track failures, will retry on the next cycle", category: "network")
                }
            }
            if verdict == .stayDueAndStop {
                appLog("runAutoDownloads: \"\(pl.name)\" interrupted after \(got)/\(toGet.count) (\(failed) failed) — staying due so the next trigger picks up where this left off", category: "network")
                return false
            }
            markAutoChecked(id: pl.id)
        }
        return true
    }

    // MARK: Schedule — manual, iOS daily, in-app every 15 h

    /// The background downloader runs a full pass at most this often on its own.
    static let autoRunInterval: TimeInterval = 15 * 3600
    private static let lastRunKey = "autoDownloads.lastFullRun"
    private static let interruptedKey = "autoDownloads.interruptedPass"

    /// When the last pass finished (manual, background or timer).
    @Published private(set) var lastFullRun: Date? = UserDefaults.standard.object(forKey: "autoDownloads.lastFullRun") as? Date
    @Published private(set) var isPassRunning = false
    private var scheduleTimer: Task<Void, Never>?

    var nextScheduledRun: Date {
        (lastFullRun ?? .distantPast).addingTimeInterval(Self.autoRunInterval)
    }

    /// A pass stopped part-way (suspended, out of background time, bridge down).
    var hasInterruptedPass: Bool { UserDefaults.standard.bool(forKey: Self.interruptedKey) }

    /// One full downloader pass now: collect finished jobs, then every
    /// auto-download playlist regardless of throttle. Used by the Settings
    /// button, the iOS background tasks and the 15-hour timer.
    @discardableResult
    func runPass(streaming: StreamingService, library: LibraryManager, reason: String) async -> Bool {
        guard !isPassRunning else { return false }
        isPassRunning = true
        defer { isPassRunning = false }
        appLog("Background downloader: pass started (\(reason))", category: "network")
        await streaming.reconcilePendingDownloads()
        let completed = await runAutoDownloads(streaming: streaming, library: library, minInterval: 0)
        UserDefaults.standard.set(!completed, forKey: Self.interruptedKey)
        if completed {
            let now = Date()
            lastFullRun = now
            UserDefaults.standard.set(now, forKey: Self.lastRunKey)
        }
        appLog("Background downloader: pass \(completed ? "finished" : "interrupted — will resume once") (\(reason))", category: "network")
        return completed
    }

    /// Cheap check for launch / foreground: no network unless a pass is due
    /// (15 h since the last) or the last one was interrupted.
    func runIfDue(streaming: StreamingService, library: LibraryManager) {
        guard !isPassRunning, !playlists.filter(\.isAutoDownload).isEmpty else { return }
        if hasInterruptedPass {
            Task { await runPass(streaming: streaming, library: library, reason: "resume interrupted pass") }
        } else if Date() >= nextScheduledRun {
            Task { await runPass(streaming: streaming, library: library, reason: "15 h timer") }
        }
    }

    /// The in-app 15-hour timer: sleeps until the next scheduled pass while
    /// the app stays open (iOS's own background task runs it otherwise).
    func startScheduleTimer(streaming: StreamingService, library: LibraryManager) {
        scheduleTimer?.cancel()
        scheduleTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = max(60, self.nextScheduledRun.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.runIfDue(streaming: streaming, library: library)
            }
        }
    }

    // MARK: Helpers

    private func load() {
        playlists = trackedAll().map {
            TrackedPlaylist(id: $0.id, url: $0.url, name: $0.name, thumbnailURL: $0.thumbnailUrl,
                            dateAdded: Date(timeIntervalSince1970: $0.dateAdded), lastTrackCount: Int($0.lastTrackCount),
                            autoDownload: $0.autoDownload, lastAutoCheck: $0.lastAutoCheck.map { Date(timeIntervalSince1970: $0) },
                            destinationFolder: $0.destinationFolder)
        }
    }
}
