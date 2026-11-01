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

    nonisolated private static func findDuplicates(in songs: [Song]) async -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        var consumed = Set<String>()

        // First pass: group by shared source track ID (most reliable signal —
        // same exact upstream track downloaded more than once). Falls back to
        // the encrypted LumisoundTrackVault xattr tag (see
        // LumisoundTrackTagger) when `sourceTrackID` itself is missing —
        // that field is populated from the plaintext `LUMISOUND_ID`
        // container-metadata tag at scan time, which for a handful of older
        // downloads/re-encodes/container types never got embedded (or got
        // stripped by an external tool that touched the file), whereas the
        // vault tag is a separate xattr independent of the audio container
        // and its format/extension (m4a/mp3/opus/webm/wav all carry it the
        // same way), so it can recover an identity match this pass would
        // otherwise silently miss entirely for that song.
        var bySourceID: [String: [Song]] = [:]
        for song in songs {
            var sourceID = song.sourceTrackID
            if sourceID == nil || sourceID?.isEmpty == true, let url = song.url {
                sourceID = LumisoundTrackTagger.readTag(fileURL: url)?.trackID
            }
            // Third fallback: the xattr vault tag doesn't survive every path
            // a file can take out of and back into the sandbox (AirDrop,
            // iCloud Drive, a Files app export/reimport all preserve bytes
            // but drop extended attributes) — the embedded LUMISOUND_ID tag
            // baked into the container itself does. Only reached when both
            // faster checks above came up empty, since reading embedded
            // asset metadata means actually parsing the file.
            if sourceID == nil || sourceID?.isEmpty == true, let url = song.url,
               FileManager.default.fileExists(atPath: url.path) {
                sourceID = await LumisoundExclusiveExtensionService.embeddedSourceTrackID(fileURL: url)
            }
            guard let sourceID, !sourceID.isEmpty else { continue }
            bySourceID[sourceID, default: []].append(song)
        }
        for (_, group) in bySourceID where group.count > 1 {
            groups.append(DuplicateGroup(id: UUID(), songs: group, reason: .sameSourceTrack))
            consumed.formUnion(group.map(\.id))
        }
        appLog("DuplicateFinderService: pass 1 (source track ID) — \(consumed.count) song(s) grouped", category: "audio")

        // Second pass: cluster whatever's left by duration alone (not
        // gated on title matching first, unlike before) — within each
        // cluster, prefer ACTUALLY LISTENING to confirm a match over
        // trusting text: songs with a locally-readable file are compared
        // acoustically via AudioFingerprintService (the offline counterpart
        // to the live Auto EQ/Smart Crossfade analyzer — see its doc
        // comment), and only songs that can't be fingerprinted (Apple Music
        // items, unreadable files) or that don't acoustically match anything
        // fall back to the old normalized-title+artist check.
        let remaining = songs.filter { !consumed.contains($0.id) }
        let clusters = clusterByDuration(remaining)
        var fingerprintsComputed = 0
        var acousticGroupCount = 0
        var fallbackGroupCount = 0

        for cluster in clusters where cluster.count > 1 {
            var clusterConsumed = Set<String>()

            let fingerprintable = cluster.filter { song in
                guard let url = song.url else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
            if fingerprintable.count > 1 && fingerprintable.count <= maxClusterSizeForAcoustic {
                var vectors: [String: [[Float]]] = [:]
                for song in fingerprintable {
                    guard let url = song.url else { continue }
                    if fingerprintsComputed >= maxFingerprintsPerScan {
                        appWarn("DuplicateFinderService: fingerprint budget (\(maxFingerprintsPerScan)) exhausted this scan — remaining candidates fall back to title matching", category: "audio")
                        break
                    }
                    if let vector = await AudioFingerprintService.shared.fingerprint(for: url) {
                        vectors[song.id] = vector
                        fingerprintsComputed += 1
                    }
                }

                // Union-find: group songs whose pairwise cosine similarity
                // clears the match threshold, so A-matches-B-matches-C all
                // land in one group even if A-vs-C alone were borderline.
                var parent: [String: String] = [:]
                func find(_ x: String) -> String {
                    var x = x
                    while let p = parent[x], p != x { x = p }
                    return x
                }
                func union(_ a: String, _ b: String) {
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[ra] = rb }
                }
                for id in vectors.keys { parent[id] = id }
                let ids = Array(vectors.keys)
                var comparisons = 0
                var matches = 0
                for i in 0..<ids.count {
                    for j in (i + 1)..<ids.count {
                        guard let va = vectors[ids[i]], let vb = vectors[ids[j]] else { continue }
                        let similarity = AudioFingerprintService.sequenceSimilarity(va, vb)
                        comparisons += 1
                        if similarity >= AudioFingerprintService.matchThreshold {
                            union(ids[i], ids[j])
                            matches += 1
                        }
                    }
                }
                if comparisons > 0 {
                    appLog(
                        "DuplicateFinderService: compared \(comparisons) acoustic pairs, \(matches) matched",
                        category: "audio"
                    )
                }
                var byRoot: [String: [Song]] = [:]
                for song in fingerprintable where vectors[song.id] != nil {
                    byRoot[find(song.id), default: []].append(song)
                }
                for (_, matched) in byRoot where matched.count > 1 {
                    groups.append(DuplicateGroup(id: UUID(), songs: matched, reason: .acousticMatch))
                    clusterConsumed.formUnion(matched.map(\.id))
                    acousticGroupCount += 1
                }
            }

            // Fallback for whatever the acoustic pass didn't account for
            // (non-fingerprintable songs, songs whose fingerprint didn't
            // match anything, or an oversized cluster that skipped
            // fingerprinting entirely) — same normalized title+artist
            // check as before, scoped to this duration cluster.
            let leftover = cluster.filter { !clusterConsumed.contains($0.id) }
            // Keyed on (normalized title, feat. name) rather than just the
            // normalized title — `normalize` strips any "(feat. X)" clause
            // entirely (see its doc comment: catches the same track tagged
            // inconsistently with/without a feature credit), which used to
            // silently collapse "Song (feat. A)" and "Song (feat. B)" into
            // ONE dictionary bucket the moment they were inserted, before
            // any near-match/union logic even ran — two genuinely different
            // songs (different featured artist) with a shared base title
            // were flattened into "the same track" purely because the
            // differentiating part of the title was thrown away. Keeping
            // the feat. name alongside the base title (nil when absent)
            // preserves the original "same track, tagged inconsistently"
            // coverage for the common case (no feat. tag vs. some feat.
            // tag) while `unionBaseKeys` below still refuses to merge two
            // buckets that both HAVE a feat. name and it's different.
            var byTitleArtist: [String: [Song]] = [:]
            var featNameByKey: [String: String?] = [:]
            for song in leftover {
                let baseTitle = normalize(song.title)
                let artist = normalizeArtist(song.artist)
                guard !baseTitle.isEmpty, !artist.isEmpty else { continue }
                let featName = extractFeatureName(from: song.title)
                let key = baseTitle + "|" + artist + "|" + (featName ?? "")
                byTitleArtist[key, default: []].append(song)
                featNameByKey[key] = featName
            }

            // Near-match merge: an exact normalized-key match already caught
            // the common case above, but a typo, an extra/missing word, or
            // punctuation `normalize` doesn't strip (e.g. "Song Title" vs.
            // "Song Titel", or "DJ Snake" vs. "DJ  Snake" surviving as
            // distinct keys) would otherwise sit in two separate singleton
            // groups and never surface as a duplicate at all. Union any two
            // keys whose titles are a close edit-distance match AND whose
            // artists match exactly — artist is still required verbatim so
            // this doesn't start pairing unrelated songs that merely have
            // similarly-spelled titles.
            let keys = Array(byTitleArtist.keys)
            var parent: [String: String] = [:]
            for key in keys { parent[key] = key }
            func find(_ x: String) -> String {
                var x = x
                while let p = parent[x], p != x { x = p }
                return x
            }
            func union(_ a: String, _ b: String) {
                let ra = find(a), rb = find(b)
                if ra != rb { parent[ra] = rb }
            }
            /// True unless both sides have a real, DIFFERENT feat. name —
            /// the guard described above, shared by both the exact-base-title
            /// union pass and the near-match pass below.
            func compatibleFeatNames(_ keyA: String, _ keyB: String) -> Bool {
                guard let featA = featNameByKey[keyA] ?? nil, let featB = featNameByKey[keyB] ?? nil else { return true }
                return featA == featB || isNearMatch(featA, featB)
            }
            // Two keys sharing the exact same base title (differing only by
            // feat. name, e.g. "" vs "madame m") represent the SAME
            // underlying track tagged inconsistently — union them (subject
            // to the feat.-name guard) so the "no feat. tag" upload and the
            // "with feat. tag" upload still land in one group like before
            // this fix, without also merging two DIFFERENT feat. names.
            for i in 0..<keys.count {
                let partsI = keys[i].split(separator: "|", maxSplits: 2)
                guard partsI.count >= 2 else { continue }
                for j in (i + 1)..<keys.count {
                    let partsJ = keys[j].split(separator: "|", maxSplits: 2)
                    guard partsJ.count >= 2, partsI[0] == partsJ[0], partsI[1] == partsJ[1] else { continue }
                    guard compatibleFeatNames(keys[i], keys[j]) else { continue }
                    union(keys[i], keys[j])
                }
            }
            for i in 0..<keys.count {
                let partsI = keys[i].split(separator: "|", maxSplits: 2)
                guard partsI.count >= 2 else { continue }
                for j in (i + 1)..<keys.count {
                    let partsJ = keys[j].split(separator: "|", maxSplits: 2)
                    guard partsJ.count >= 2, partsI[1] == partsJ[1] else { continue }
                    guard compatibleFeatNames(keys[i], keys[j]) else { continue }
                    if isNearMatch(String(partsI[0]), String(partsJ[0])) {
                        union(keys[i], keys[j])
                    }
                }
            }
            var byRootKey: [String: [Song]] = [:]
            for key in keys {
                byRootKey[find(key), default: []].append(contentsOf: byTitleArtist[key] ?? [])
            }
            // `cluster` only guarantees each song is within `durationTolerance`
            // of its NEIGHBOR in sorted order, not of every other song in the
            // cluster — a dense-enough chain of unrelated intermediate
            // durations (a real risk in a large library) can transitively
            // bridge a cluster across a much wider span. Two songs that
            // merely share a title/artist (e.g. an OST-rip channel that
            // titles every track in a playlist identically) but whose
            // durations actually differ by tens of seconds are clearly
            // DIFFERENT recordings, not re-encodes of the same one — re-check
            // the actual span of whatever this title+artist key matched
            // before trusting it, so Auto-Clean can't delete distinct songs.
            for (_, matched) in byRootKey where matched.count > 1 {
                let durations = matched.map(\.duration)
                guard let minDuration = durations.min(), let maxDuration = durations.max(),
                      maxDuration - minDuration <= durationTolerance else {
                    appWarn(
                        "DuplicateFinderService: discarded title+artist match spanning \(String(format: "%.1f", (durations.max() ?? 0) - (durations.min() ?? 0)))s (> \(durationTolerance)s tolerance) — likely a duration-cluster chain artifact, not real duplicates: \(matched.map(\.title))",
                        category: "audio"
                    )
                    continue
                }
                groups.append(DuplicateGroup(id: UUID(), songs: matched, reason: .sameTitleAndArtist))
                fallbackGroupCount += 1
            }
        }
        appLog(
            "DuplicateFinderService: pass 2 — \(fingerprintsComputed) fingerprint(s) computed, "
                + "\(acousticGroupCount) acoustic group(s), \(fallbackGroupCount) title-fallback group(s)",
            category: "audio"
        )

        return groups.sorted { $0.songs.count > $1.songs.count }
    }

    /// Splits `songs` into clusters where every pair of durations within a
    /// cluster is within `durationTolerance` of each other — the candidate
    /// pool for pass 2's acoustic/title-fallback check above (duration alone
    /// is a weak signal, which is exactly why that pass confirms a real
    /// match acoustically rather than trusting a duration cluster on its
    /// own). Sorts by duration first and then does a simple chain-grouping
    /// pass, so e.g. durations [120, 121, 122, 200, 201] with a 2s tolerance
    /// become two clusters: [120, 121, 122] and [200, 201].
    nonisolated private static func clusterByDuration(_ songs: [Song]) -> [[Song]] {
        let sorted = songs.sorted { $0.duration < $1.duration }
        var clusters: [[Song]] = []
        var current: [Song] = []
        var previousDuration: TimeInterval?

        // Compares each song to the PREVIOUS song in sorted order, not a
        // fixed cluster-start — a fixed start under-clusters any gradually
        // drifting chain of durations. E.g. with tolerance 2s: 120, 121.9,
        // 123.8 are each within tolerance of their neighbor, but 123.8 is
        // 3.8s from 120, so comparing against a fixed start would wrongly
        // split this into [120, 121.9] and [123.8] — two clusters that
        // never get compared to each other — even though 121.9 and 123.8
        // are themselves within tolerance and could be the same track
        // trimmed slightly differently. A sliding comparison keeps the
        // whole drifting chain in one cluster.
        for song in sorted {
            if let previous = previousDuration, song.duration - previous > durationTolerance {
                clusters.append(current)
                current = []
            }
            current.append(song)
            previousDuration = song.duration
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// Bracketed/parenthetical terms YouTube/SoundCloud uploaders routinely tack
    /// onto a title that do NOT represent a genuinely different recording —
    /// stripped before comparison so e.g. "Song Name" and "Song Name (Official
    /// Music Video)" match. Deliberately excludes real edition markers (Radio
    /// Edit, Extended Mix, Remix, Acoustic, Live, Instrumental, Cover, ...) so
    /// those stay distinct rather than being merged with the original.
    private static let titleNoiseTerms: Set<String> = [
        "official video", "official music video", "official audio",
        "official lyric video", "official lyrics video", "lyric video", "lyrics",
        "audio", "video", "hd", "hq", "4k", "music video", "visualizer", "mv",
        "full video", "with lyrics", "explicit", "clean", "clean version",
        "monstercat release", "audio only",
    ]

    /// Matches a `feat./ft./featuring <name>` clause, optionally wrapped in
    /// parens/brackets or introduced by a hyphen/comma — stripped from both
    /// titles and artists since the same track is tagged inconsistently
    /// with/without a feature credit across different uploads/sources.
    private static let featureClauseRegex = try? NSRegularExpression(
        pattern: #"(?i)[\(\[]?\s*(feat\.?|ft\.?|featuring)\s+([^()\[\],]+)[\)\]]?"#
    )

    /// Extracts and normalizes just the featured-artist name from a title's
    /// `feat./ft./featuring` clause, e.g. "Song (feat. Madame M)" -> "madame
    /// m", or `nil` if the title has no such clause at all. Used to make
    /// sure two titles that both HAVE a feat. clause, but name a different
    /// artist, are never treated as the same underlying track just because
    /// `normalize`/`featureClauseRegex` strip that clause out entirely for
    /// the base-title comparison — see the duplicate-grouping code's own
    /// comment for the false-positive this fixes ("gomotion (feat. A)" vs
    /// "gomotion (feat. B)" being merged as if identical).
    nonisolated static func extractFeatureName(from text: String) -> String? {
        guard let featureClauseRegex,
              let match = featureClauseRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 2,
              let nameRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let normalized = normalize(String(text[nameRange]))
        return normalized.isEmpty ? nil : normalized
    }

    /// Lowercases, strips diacritics/punctuation, drops noise tags and feature
    /// credits, and collapses whitespace so e.g. "Daft Punk - One More Time
    /// (Official Audio)" and "daft punk one more time" match, while "(Radio
    /// Edit)" vs "(Extended Mix)" of the same title stay distinct.
    nonisolated static func normalize(_ text: String) -> String {
        var working = text
        if let featureClauseRegex {
            working = featureClauseRegex.stringByReplacingMatches(
                in: working, range: NSRange(working.startIndex..., in: working), withTemplate: ""
            )
        }
        working = stripNoiseTags(from: working)

        let folded = working.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let alphanumeric = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(alphanumeric))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Removes only the `(...)`/`[...]` groups whose contents are a known
    /// noise term (see `titleNoiseTerms`) — groups containing a real edition
    /// marker (e.g. "(Remix)") are left in place.
    nonisolated private static func stripNoiseTags(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[\(\[]([^()\[\]]+)[\)\]]"#) else { return text }
        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let groupRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let inner = result[groupRange].lowercased().trimmingCharacters(in: .whitespaces)
            if titleNoiseTerms.contains(inner) {
                result.removeSubrange(fullRange)
            }
        }
        return result
    }

    /// Matches a trailing "- Topic" (any dash style) — YouTube's
    /// auto-generated "Topic" channel naming convention for official
    /// Content-ID audio (e.g. "WoodenToaster - Topic"). Stripped so the same
    /// track imported once via a Topic-channel download and once from a
    /// plain-artist source (Apple Music, a manual import, a different
    /// extractor version) still compares equal instead of silently evading
    /// both the pre-download dedupe check and the Duplicate Scanner.
    private static let topicChannelSuffixRegex = try? NSRegularExpression(
        pattern: #"(?i)\s*[-–—]\s*Topic\s*$"#
    )

    /// Like `normalize`, but additionally strips a trailing "- Topic" channel
    /// suffix, splits on common multi-artist separators (",", "&", "/", " x ",
    /// " vs ", "with") and sorts the parts — so "Artist A & Artist B" and
    /// "Artist B, Artist A" (or the same pairing tagged with a different
    /// separator across sources) compare equal.
    nonisolated static func normalizeArtist(_ text: String) -> String {
        var working = text
        if let topicChannelSuffixRegex {
            working = topicChannelSuffixRegex.stringByReplacingMatches(
                in: working, range: NSRange(working.startIndex..., in: working), withTemplate: ""
            )
        }
        if let featureClauseRegex {
            working = featureClauseRegex.stringByReplacingMatches(
                in: working, range: NSRange(working.startIndex..., in: working), withTemplate: ""
            )
        }
        guard let separatorRegex = try? NSRegularExpression(pattern: #"(?i)\s*(,|&|/| x | vs\.?\s| with )\s*"#) else {
            return normalize(working)
        }
        let unified = separatorRegex.stringByReplacingMatches(
            in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "|"
        )
        let parts = unified.components(separatedBy: "|")
            .map { normalize($0) }
            .filter { !$0.isEmpty }
            .sorted()
        return parts.joined(separator: " ")
    }

    /// True if `a` and `b` are close enough (Levenshtein edit distance,
    /// scaled to length so short and long titles use proportionally
    /// different tolerances) to be the same title with a typo or minor
    /// formatting difference `normalize` didn't already collapse — used only
    /// as a secondary merge on top of the exact-match fallback pass, and
    /// only ever applied within a duration cluster that ALSO requires an
    /// exact artist match, so it can't by itself pair two unrelated songs.
    nonisolated private static func isNearMatch(_ a: String, _ b: String) -> Bool {
        guard a != b else { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        // A different TRAILING NUMBER is never a typo — it's almost always a
        // sequel/episode/part/volume indicator ("Guild Hall 1" vs "Guild
        // Hall 3", "Ending 5", "Title 1" vs "Title 2"). Levenshtein distance
        // alone treats a single changed digit exactly like a single changed
        // letter, which is why a fuzzy-typo check was merging genuinely
        // different, sequentially-numbered tracks into one "duplicate"
        // group. Reject outright whenever both titles end in a digit run
        // and those digit runs differ, before ever computing edit distance.
        let aTrailingDigits = trailingDigitRun(a)
        let bTrailingDigits = trailingDigitRun(b)
        if let aTrailingDigits, let bTrailingDigits, aTrailingDigits != bTrailingDigits {
            return false
        }
        // Cheap reject before paying for the O(n*m) distance computation:
        // titles whose lengths differ by more than the max tolerance we'd
        // ever allow can't possibly pass.
        let maxLen = max(a.count, b.count)
        guard abs(a.count - b.count) <= 3 else { return false }
        let distance = levenshteinDistance(a, b)
        // Scaled threshold: ~15% of the longer title's length, floored at 1
        // (so single-character titles still require an exact match) and
        // capped at 3 (so two genuinely different long titles that happen
        // to share most characters don't get merged).
        let threshold = min(3, max(1, Int(Double(maxLen) * 0.15)))
        return distance <= threshold
    }

    /// Returns the run of ASCII digits at the very end of `text` (e.g. "guild
    /// hall 3" -> "3", "ending 15" -> "15"), or `nil` if `text` doesn't end
    /// in a digit at all. Used by `isNearMatch` to distinguish a real typo
    /// from a different sequel/episode/part number.
    nonisolated private static func trailingDigitRun(_ text: String) -> String? {
        var digits = ""
        for char in text.reversed() {
            guard char.isASCII, char.isNumber else { break }
            digits.append(char)
        }
        return digits.isEmpty ? nil : String(digits.reversed())
    }

    nonisolated private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                if aChars[i - 1] == bChars[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = 1 + min(previous[j - 1], previous[j], current[j - 1])
                }
            }
            previous = current
        }
        return previous[bChars.count]
    }
}

// MARK: - DuplicateGroup

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
