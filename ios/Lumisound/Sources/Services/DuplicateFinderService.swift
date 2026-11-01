import Foundation
import UIKit

// MARK: - DuplicateFinderService

@MainActor
final class DuplicateFinderService: ObservableObject {

    // MARK: Singleton

    static let shared = DuplicateFinderService()
    private init() {}

    // MARK: - Periodic Auto-Scan
    //
    // Aria Lumi Primary: same cadence/lifecycle contract as
    // CorruptFileFinderService.startPeriodicScanning — call once on app
    // launch, runs when stale then every six hours for the life of the
    // process (skipped while backgrounded). Same-title/same-duration text
    // matching alone was never reliable enough on its own (see the ask this
    // exists to satisfy), so this scan's actual duplicate decisions are made
    // acoustically by AudioFingerprintService/refineGroupsWithAria's Aria
    // call, not by the timer — the timer just keeps her listening
    // continuously instead of only when the user happens to open Duplicate
    // Finder.
    private var periodicTimer: Timer?
    private static let periodicScanInterval: TimeInterval = 6 * 60 * 60

    func startPeriodicScanning() {
        guard periodicTimer == nil else { return }

        if lastScanDate.map({ Date().timeIntervalSince($0) >= Self.periodicScanInterval }) ?? true {
            runPeriodicScan()
        }

        let interval = Self.periodicScanInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard UIApplication.shared.applicationState == .active else { return }
                self?.runPeriodicScan()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }

    func stopPeriodicScanning() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    private func runPeriodicScan() {
        guard let library = LibraryManager.shared else { return }
        Task { await runScan(songs: library.allSongs) }
    }

    // MARK: Published State

    @Published private(set) var isScanning = false
    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published private(set) var lastScanDate: Date? = {
        let ts = UserDefaults.standard.double(forKey: "duplicateFinder_lastScanTimestamp")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }()

    /// Aria Lumi's refined "keep this one" pick per group (group.id -> the
    /// song ID to keep), filled in progressively AFTER a scan completes —
    /// see `refineGroupsWithAria`. `allDuplicatesToRemove` prefers an entry
    /// here over its own duration-only heuristic whenever one exists, since
    /// Aria has access to signal (format/bitrate quality, favorited status,
    /// embedded-metadata health) duration alone can't see.
    @Published private(set) var ariaKeeperOverrides: [UUID: String] = [:]

    // MARK: - Cloud library check (acoustic fingerprint, server-side)
    //
    // Separate from the on-device scan above: this calls the bridge's
    // /user/library/acoustic-duplicates, which fingerprints (fpcalc/Chromaprint)
    // every file in the user's CLOUD-backed library and groups ones that are
    // acoustically the same recording — catches copies the title/artist match
    // above misses (differently-tagged re-encodes, etc.). Deliberately NOT
    // merged into `duplicateGroups`: correlating a cloud filename back to a
    // specific local `Song` isn't reliable (backup filenames aren't guaranteed
    // to match 1:1), so results are shown as their own informational list —
    // scoped to what the server actually told us, no risk of mis-attributing
    // a match to the wrong local file.

    @Published private(set) var isCheckingCloud = false
    @Published private(set) var cloudDuplicateGroups: [[CloudDuplicateFile]] = []
    @Published private(set) var cloudCheckError: String?

    struct CloudDuplicateFile: Identifiable {
        let id = UUID()
        let filename: String
        let duration: TimeInterval
    }

    func checkCloudDuplicates() async {
        guard !isCheckingCloud else { return }
        guard let account = AccountService.shared, account.isLoggedIn, let token = account.token else {
            cloudCheckError = "Sign in to check your cloud library."
            return
        }
        isCheckingCloud = true
        cloudCheckError = nil
        defer { isCheckingCloud = false }

        let base = account.bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/user/library/acoustic-duplicates") else {
            cloudCheckError = "Invalid bridge URL"
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // fpcalc-scanning up to 300 cloud files can genuinely take a while —
        // well past the ~20s timeout used for quick lookups elsewhere.
        request.timeoutInterval = 90

        do {
            let (data, response) = try await Core.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                cloudCheckError = "Server error (HTTP \(http.statusCode))"
                return
            }
            let decoded = try JSONDecoder().decode(AcousticDuplicatesResponse.self, from: data)
            cloudDuplicateGroups = decoded.duplicateGroups.map { group in
                group.map { CloudDuplicateFile(filename: $0.file, duration: $0.duration) }
            }
        } catch {
            cloudCheckError = error.localizedDescription
        }
    }

    private struct AcousticDuplicatesResponse: Decodable {
        let duplicateGroups: [[AcousticDuplicateEntry]]

        enum CodingKeys: String, CodingKey {
            case duplicateGroups = "duplicate_groups"
        }
    }

    private struct AcousticDuplicateEntry: Decodable {
        let file: String
        let duration: Double
    }

    // MARK: - Scan

    /// Tolerance (in seconds) used when comparing two songs' `duration` for the
    /// "same title & artist" secondary match. Re-encodes/re-downloads of the same
    /// source track can differ by a fraction of a second due to container overhead
    /// or trimming, so an exact match is too strict.
    static let durationTolerance: TimeInterval = 2.0

    /// Groups `songs` into sets of likely duplicates, in three passes (see
    /// `findDuplicates`):
    ///  1. Same non-empty `sourceTrackID` (e.g. both downloaded from the same
    ///     YouTube/SoundCloud track, tagged with the `LUMISOUND_ID` metadata
    ///     tag) — the "definite duplicate" case, regardless of duration.
    ///  2. For everything else, candidates are first narrowed by duration
    ///     (`durationTolerance`), then CONFIRMED by actually comparing how
    ///     the audio sounds throughout the track — `AudioFingerprintService
    ///     .sequenceSimilarity` compares per-time-segment spectral profiles,
    ///     not a single blended average, so two different songs that merely
    ///     share overall mastering/EQ balance don't get waved through — for
    ///     any song whose file is locally readable. This is what catches
    ///     duplicates re-titled or re-tagged differently across sources,
    ///     which text matching alone can't.
    ///  3. Songs a duration cluster couldn't fingerprint (Apple Music items,
    ///     unreadable files) or that didn't acoustically match anything fall
    ///     back to the old normalized title + artist check within that same
    ///     duration cluster.
    func runScan(songs: [Song]) async {
        guard !isScanning else { return }
        isScanning = true
        appLog("DuplicateFinderService: scan started (\(songs.count) songs)", category: "audio")

        // Routed through the public wrapper (not the private worker
        // directly) so this actually gets the Task.detached off-main-actor
        // guarantee documented on `findDuplicateGroups`.
        let groups = await DuplicateFinderService.findDuplicateGroups(among: songs)

        appLog(
            "DuplicateFinderService: scan finished — \(groups.count) group(s), reasons: "
                + Dictionary(grouping: groups, by: { $0.reason.label })
                    .map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: ", "),
            category: "audio"
        )
        duplicateGroups = groups
        ariaKeeperOverrides = [:]
        let now = Date()
        lastScanDate = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "duplicateFinder_lastScanTimestamp")
        isScanning = false

        // Fire-and-forget, not awaited — the scan itself is already done and
        // its results are visible; Aria's refinement fills in
        // `ariaKeeperOverrides` progressively afterward, same "enrich after
        // the fact" pattern as artwork/BPM prewarming elsewhere. A logged-out
        // user (or any failure) just leaves the plain duration heuristic in
        // place, exactly as before this existed.
        Task { await refineGroupsWithAria() }
    }

    /// Refines each duplicate group's "which copy to keep" decision using
    /// Aria Lumi (`/user/intelligence/duplicate-resolve`) instead of the
    /// duration-only heuristic alone — she sees format/bitrate/sample rate,
    /// whether each copy's embedded custom metadata tag survived, and
    /// whether the user has favorited that specific copy, none of which
    /// `allDuplicatesToRemove`'s own sort considers. Populates
    /// `ariaKeeperOverrides` group-by-group as each call resolves; never
    /// throws, never blocks the scan, and any group she's unavailable or
    /// unconfident for simply keeps using the existing heuristic untouched.
    /// A small concurrency cap (not full parallelism) keeps a large library
    /// with many groups from firing dozens of simultaneous requests at once.
    private func refineGroupsWithAria() async {
        guard let account = AccountService.shared, account.isLoggedIn else { return }
        let groups = duplicateGroups
        guard !groups.isEmpty else { return }
        guard let library = LibraryManager.shared else { return }

        struct GroupResult {
            let groupID: UUID
            let removable: [Song]
            let resolution: DuplicateResolution
        }

        let maxConcurrent = 3
        await withTaskGroup(of: GroupResult?.self) { taskGroup in
            var iterator = groups.makeIterator()
            func launchNext() {
                guard let group = iterator.next() else { return }
                taskGroup.addTask { [weak self] in
                    guard let self else { return nil }
                    guard let (removable, resolution) = await self.resolveKeeper(for: group, account: account) else { return nil }
                    return GroupResult(groupID: group.id, removable: removable, resolution: resolution)
                }
            }
            for _ in 0..<maxConcurrent { launchNext() }
            for await result in taskGroup {
                if let result {
                    let keeper = result.removable[result.resolution.keepIndex]
                    if result.resolution.confidence == "high" {
                        // High confidence: act now rather than just suggesting —
                        // see AriaActivityLog for the revert path this enables.
                        // Anything less than "high" still only sets the override
                        // below, same as before this existed — the user reviews
                        // and confirms it themselves via "Delete All Duplicates".
                        autoRemoveLosers(
                            group: groups.first { $0.id == result.groupID },
                            removable: result.removable, keeper: keeper,
                            resolution: result.resolution, library: library
                        )
                    } else {
                        ariaKeeperOverrides[result.groupID] = keeper.id
                    }
                }
                launchNext()
            }
        }
    }

    /// One group's Aria call — builds the candidate payload from real
    /// on-disk/metadata signal (not just duration) and returns which
    /// removable copy she picked to keep plus her full resolution
    /// (including confidence), or `nil` if she's unavailable/unconfident/the
    /// group isn't eligible (fewer than 2 removable copies, e.g. one copy
    /// is an Apple Music item that can't be deleted from here anyway).
    private func resolveKeeper(for group: DuplicateGroup, account: AccountService) async -> (removable: [Song], resolution: DuplicateResolution)? {
        let removable = group.songs.filter { $0.persistentID == nil && $0.url != nil }
        guard removable.count > 1 else { return nil }

        var candidates: [DuplicateResolveCandidate] = []
        candidates.reserveCapacity(removable.count)
        for song in removable {
            guard let url = song.url else { return nil }
            let format = LumisoundExclusiveExtensionService.effectiveExtension(for: url)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            let hasMetadata = await LumisoundExclusiveExtensionService.hasEmbeddedSourceTag(fileURL: url)
            let isFavorite = LibraryManager.shared?.isFavorite(songID: song.id) ?? false
            candidates.append(DuplicateResolveCandidate(
                format: format,
                bitrate_kbps: song.bitrate > 0 ? song.bitrate : nil,
                sample_rate: song.sampleRate > 0 ? song.sampleRate : nil,
                duration_seconds: song.duration,
                file_size_bytes: Int(fileSize),
                has_embedded_metadata: hasMetadata,
                is_favorite: isFavorite
            ))
        }
        guard candidates.count == removable.count else { return nil }

        let resolution = await account.resolveDuplicateKeeper(
            title: group.songs.first?.title ?? "",
            artist: group.songs.first?.artist ?? "",
            reason: group.reason.apiValue,
            candidates: candidates
        )
        guard let resolution, resolution.keepIndex < removable.count else { return nil }
        return (removable, resolution)
    }

    /// Actually removes every removable copy except `keeper` — called only
    /// for a "high" confidence resolution (see `refineGroupsWithAria`).
    /// Uses `ariaRemoveDuplicate`, never `removeImportedSong`: an
    /// autonomous action she takes has to stay revertible, so a copy that
    /// fails to trash is left alone rather than hard-deleted. Logs one
    /// combined action (not one per removed copy) via `AriaActivityLog`,
    /// which shows the attributed toast and enables "Revert Aria's Change"
    /// from the keeper's context menu.
    private func autoRemoveLosers(
        group: DuplicateGroup?, removable: [Song], keeper: Song,
        resolution: DuplicateResolution, library: LibraryManager
    ) {
        let losers = removable.filter { $0.id != keeper.id }
        guard !losers.isEmpty else { return }

        var removedAny = false
        var loggedOnce = false
        for loser in losers {
            guard library.ariaRemoveDuplicate(id: loser.id) else { continue }
            removedAny = true
            removeSongFromGroups(songID: loser.id)
            // Only the FIRST successfully-removed loser's trash entry is
            // wired to the revert action — duplicate groups are overwhelmingly
            // pairs in practice, and the log entry already names the track,
            // not a specific copy, so this is the common case handled well
            // rather than every N-way group handled perfectly.
            guard !loggedOnce else { continue }
            loggedOnce = true
            AriaActivityLog.shared.recordDuplicateRemoved(
                survivingSongID: keeper.id, title: keeper.displayName, artist: keeper.artistName,
                removedEntryID: loser.id, confidence: resolution.confidence, memoryID: resolution.memoryID
            )
        }
        if let group, removedAny {
            ariaKeeperOverrides[group.id] = keeper.id
        }
    }

    /// Songs that "Delete All Duplicates" would remove: for each group, the
    /// longest removable (downloaded, not Apple Music) copy is kept and every
    /// other removable copy is queued for deletion. Apple Music copies are
    /// never included since they can't be removed from here.
    var allDuplicatesToRemove: [Song] {
        duplicateGroups.flatMap { group -> [Song] in
            let removable = group.songs.filter { $0.persistentID == nil && $0.url != nil }
            guard removable.count > 1 else { return [] }

            // Prefer Aria Lumi's refined pick (format/bitrate quality,
            // favorited status, embedded-metadata health — see
            // `refineGroupsWithAria`) when one has resolved for this group.
            // Falls straight through to the plain duration heuristic below
            // whenever she has no pick yet (still resolving, unavailable, or
            // genuinely unconfident) or her picked ID isn't actually in this
            // removable set for some reason — always a safe, defined
            // fallback, never a missing keeper.
            if let keeperID = ariaKeeperOverrides[group.id],
               removable.contains(where: { $0.id == keeperID }) {
                return removable.filter { $0.id != keeperID }
            }

            let sorted = removable.sorted { a, b in
                if abs(a.duration - b.duration) > 0.01 {
                    return a.duration > b.duration
                }
                // Tiebreaker for same-duration copies: prefer to keep the one
                // with a known BPM. A successful BPM analysis means the file
                // decoded cleanly end-to-end, while a copy that previously
                // failed analysis (nil bpm) may be truncated or corrupt.
                let aHasBPM = a.bpm != nil
                let bHasBPM = b.bpm != nil
                return aHasBPM && !bHasBPM
            }
            return Array(sorted.dropFirst())
        }
    }

    /// Removes a single song from `duplicateGroups` (e.g. after it's been
    /// deleted from the library), dropping any group that's left with fewer
    /// than two songs.
    func removeSongFromGroups(songID: String) {
        duplicateGroups = duplicateGroups.compactMap { group in
            var songs = group.songs
            songs.removeAll { $0.id == songID }
            guard songs.count > 1 else { return nil }
            return DuplicateGroup(id: group.id, songs: songs, reason: group.reason)
        }
    }

    // MARK: - Scoped, non-mutating scan (folder-level duplicate checks, etc.)

    /// Same three-pass matching logic as `runScan` (source-track ID ->
    /// acoustic fingerprint -> title+artist fallback), but for an arbitrary
    /// subset of songs and WITHOUT touching `duplicateGroups`/`lastScanDate`/
    /// `isScanning` — those are owned by the full-library Duplicate Finder
    /// screen (`DuplicateFilesView`), and a scoped scan (e.g. one triggered
    /// from a single local folder's detail screen) must never clobber them.
    /// Callers own their own result state; see `FolderDuplicatesSheet`.
    nonisolated static func findDuplicateGroups(among songs: [Song]) async -> [DuplicateGroup] {
        // `findDuplicates` being `nonisolated` doesn't by itself guarantee
        // this runs off whichever actor called `findDuplicateGroups` — a
        // plain `await` on a nonisolated async func with no suspension
        // points of its own can still execute its synchronous stretches on
        // the CALLER's executor. Both known callers (`runScan` here,
        // `FolderDuplicatesSheet`) are on `@MainActor` types, and this does
        // real O(n²) Levenshtein work over the whole scanned set — genuinely
        // capable of blocking the main thread on a large library, the same
        // class of bug fixed in LumisoundExclusiveExtensionService.convert.
        // `Task.detached` forces the actual work onto the cooperative pool
        // regardless of caller.
        await Task.detached(priority: .utility) {
            await findDuplicates(in: songs)
        }.value
    }

    // MARK: - Private Worker (nonisolated, runs off main actor)

    /// Hard cap on total fingerprints computed per scan — bounds worst-case
    /// scan time on a large library where many unrelated songs happen to
    /// share a close duration (a weak signal on its own; see the clustering
    /// step below). Cache hits (repeat scans) don't count against this.
    private static let maxFingerprintsPerScan = 150

    /// Duration clusters larger than this skip acoustic comparison entirely
    /// and fall straight back to the title+artist check — a cluster this
    /// size means duration alone isn't narrowing things down at all (e.g. a
    /// library with many similarly-timed tracks), so fingerprinting every
    /// pair would spend most of the budget on near-certain non-matches.
    private static let maxClusterSizeForAcoustic = 20

    /// Grouping runs in the Rust core (rust/core/src/duplicates.rs): source
    /// track id, then acoustic fingerprints inside 2 s duration clusters,
    /// then fuzzy title + artist. Source ids are resolved here first so old
    /// files whose tag only AVFoundation can read still group correctly.
    nonisolated private static func findDuplicates(in songs: [Song]) async -> [DuplicateGroup] {
        var input: [DupSong] = []
        input.reserveCapacity(songs.count)
        for song in songs {
            var sourceID = song.sourceTrackID
            if sourceID?.isEmpty ?? true, let url = song.url {
                sourceID = LumisoundTrackTagger.readTag(fileURL: url)?.trackID
                if sourceID?.isEmpty ?? true, FileManager.default.fileExists(atPath: url.path) {
                    sourceID = await LumisoundExclusiveExtensionService.embeddedSourceTrackID(fileURL: url)
                }
            }
            let path = song.url.flatMap { $0.isFileURL ? $0.path : nil }
            input.append(DupSong(id: song.id, title: song.title, artist: song.artist, duration: song.duration,
                                 path: path, sourceTrackId: sourceID))
        }
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = Lumisound.findDuplicates(songs: input, cacheDir: CoreAudio.unlockDir).compactMap { g -> DuplicateGroup? in
            let members = g.songIds.compactMap { byID[$0] }
            guard members.count > 1 else { return nil }
            let reason: DuplicateReason = switch g.reason {
            case .sameSourceTrack: .sameSourceTrack
            case .acousticMatch: .acousticMatch
            case .sameTitleAndArtist: .sameTitleAndArtist
            }
            return DuplicateGroup(id: UUID(), songs: members, reason: reason)
        }
        appLog("DuplicateFinderService: \(groups.count) duplicate group(s) among \(songs.count) song(s)", category: "audio")
        return groups
    }

    nonisolated static func extractFeatureName(from text: String) -> String? { dupFeatureName(text: text) }
    nonisolated static func normalize(_ text: String) -> String { dupNormalize(text: text) }
    nonisolated static func normalizeArtist(_ text: String) -> String { dupNormalizeArtist(text: text) }
}

struct DuplicateGroup: Identifiable {
    let id: UUID
    let songs: [Song]
    let reason: DuplicateReason

    /// Combined playtime of every copy in this group, e.g. "8:42 total" across
    /// 3 copies — shown alongside each copy's own duration so the user can
    /// judge which copy is more complete (longer = likely fewer cuts/ads).
    var totalDuration: TimeInterval {
        songs.reduce(0) { $0 + $1.duration }
    }
}

// MARK: - DuplicateReason

enum DuplicateReason {
    case sameSourceTrack
    case acousticMatch
    case sameTitleAndArtist

    var label: String {
        switch self {
        case .sameSourceTrack: return "Same source track"
        case .acousticMatch: return "Sounds identical"
        case .sameTitleAndArtist: return "Same title & artist"
        }
    }

    /// Raw identifier sent to the bridge's `/user/intelligence/duplicate-
    /// resolve` — matches `DuplicateResolveRequest.reason`'s expected
    /// literals server-side, distinct from `label` (human-facing UI text).
    var apiValue: String {
        switch self {
        case .sameSourceTrack: return "sameSourceTrack"
        case .acousticMatch: return "acousticMatch"
        case .sameTitleAndArtist: return "sameTitleAndArtist"
        }
    }
}
