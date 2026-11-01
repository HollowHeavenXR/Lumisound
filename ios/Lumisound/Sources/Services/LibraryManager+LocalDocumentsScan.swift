import Foundation
import UIKit

extension LibraryManager {

    // MARK: - Local Documents Scan

    /// Scans the app's Documents directory (root + Imported Music subfolder) for audio
    /// files and adds any that aren't already tracked. Called automatically on init and
    /// can be triggered manually after the user drops files via the Files app.
    /// Recursively scans the app's entire Documents directory for audio files and
    /// adds any not already tracked. Picks up files placed via Finder, Files app,
    /// iTunes file sharing, or any subdirectory the user created inside the app folder.
    func scanLocalDocuments() {
        // A scan is already running — `performLocalDocumentsScan` would just
        // have this new call join it anyway (see its own coalescing), but
        // calling `beginScan()` here FIRST regardless meant every redundant
        // trigger (the foreground-return observer firing more than once in
        // a burst, several screens' `.onAppear`/`.task` each requesting
        // their own scan around the same event — see that function's doc
        // comment: "FIVE OR MORE of these firing back-to-back") still
        // flipped the `@Published isScanning`/`scanProgress` state of its
        // own accord. `@Published` fires `objectWillChange` on every
        // assignment regardless of whether the value actually changed, so
        // each of those redundant calls forced a full SwiftUI re-render
        // across every view observing `LibraryManager` — a real, compounding
        // main-actor cost stacked on top of, not instead of, the (already
        // deduplicated) scan work itself. This is what actually produced the
        // visible "freezes when the app comes back from background, and it
        // happens 4-5 times" reports — not the scan's own disk I/O, which
        // was already off-main and already coalesced.
        guard Self.inFlightScanTask == nil else {
            Task { await performLocalDocumentsScan() }
            return
        }
        // Throttled the same way `scanWatchedFolders` already is: LibraryView
        // calls this from `.onAppear`, which SwiftUI fires every time the
        // view reappears — not just on a real app-foreground event, but on
        // every NavigationStack pop back to it AND every TabView switch back
        // to the Library tab (e.g. from Now Playing). None of those actually
        // mean anything on disk changed, so without this a user bouncing
        // between Library and Now Playing paid for a full Documents-tree
        // walk + eviction check on every single return. `scanLocalDocuments
        // Async` (Download All, TrackedPlaylistStore, pending-download
        // reconciliation) deliberately does NOT get this throttle — those
        // callers need an up-to-date result to make correct dedup decisions,
        // not just an opportunistic background refresh.
        guard Date().timeIntervalSince(lastLocalDocumentsScanDate) >= 30 else { return }
        lastLocalDocumentsScanDate = Date()
        beginScan()
        Task {
            defer { endScan() }
            await performLocalDocumentsScan()
        }
    }

    /// Thorough re-scan used by the Library "Refresh" button: re-reads files
    /// whose on-disk `(mtime, size)` changed since they were imported (e.g.
    /// tags edited in place via the Files app or a desktop tool), not just
    /// brand-new files — the periodic/automatic scan keeps its faster
    /// new-files-only path. Also re-scans watched folders, and publishes a
    /// `lastScanResult` summary the UI can toast.
    func refreshAll(folderService: MusicFolderService) async {
        beginScan()
        defer { endScan() }
        let before = importedSongs.count
        await performLocalDocumentsScan(force: true)
        await scanWatchedFoldersAsync(using: folderService)
        let after = allSongs.count
        let delta = after - before
        lastScanResult = delta > 0
            ? "Refreshed — \(after) songs (\(delta) new/updated)"
            : "Refreshed — \(after) songs, library is up to date"
    }

    /// Awaitable variant of `scanLocalDocuments()` — used by callers (e.g.
    /// "Download All") that need `allSongs` to reflect every locally-imported
    /// file, including any sitting in subfolders the user created or moved
    /// files into, *before* deciding what still needs to be downloaded.
    /// `userInitiated: false` runs the scan without raising the visible
    /// scanning state — see `LibraryManager.visibleScanCount`. Automatic callers
    /// (the auto-download check, pending-download reconciliation, the
    /// return-to-foreground refresh) pass false: nobody asked for these, and a
    /// scan nobody asked for should not hold the launch screen or spin a tab.
    func scanLocalDocumentsAsync(userInitiated: Bool = true) async {
        // Same reasoning as scanLocalDocuments()'s guard above — several
        // callers (Download All, TrackedPlaylistStore auto-downloads,
        // pending-download reconciliation) can legitimately call this around
        // the same moment scanLocalDocuments()'s own trigger fires; join the
        // existing scan's isScanning state instead of also flipping it.
        guard Self.inFlightScanTask == nil else {
            await performLocalDocumentsScan()
            return
        }
        beginScan(visible: userInitiated)
        defer { endScan(visible: userInitiated) }
        await performLocalDocumentsScan()
    }

    /// Every completed download, missing-file self-heal, and several
    /// `.onAppear`/`.task` view modifiers each trigger their own local scan
    /// independently — under a burst of activity (a big batch download,
    /// dozens of tracks completing within milliseconds of each other) field
    /// logs showed FIVE OR MORE of these firing back-to-back in the same
    /// batch, each doing a full detached filesystem walk plus per-file
    /// metadata reads. `beginScan`/`endScan` only ever tracked a COUNT of
    /// concurrent scans for the UI spinner — it never actually prevented
    /// them from piling up. That's real, wasted concurrent work stacking up
    /// exactly when the device is already under the most load, and lines up
    /// with "the app freezes a lot with background downloads going on."
    /// Coalesce concurrent NON-forced scans into a single shared execution
    /// (the common case — every trigger above passes `force: false`);
    /// `force: true` (the explicit Library "Refresh" button) always runs
    /// its own fresh pass since that's a deliberate user action expecting
    /// an immediate re-read, not a share of whatever else is in flight.
    private static var inFlightScanTask: Task<Void, Never>?

    /// Set when a scan was skipped for being in the background, so the next
    /// foreground transition can run the scan that was deferred instead of
    /// silently dropping whatever change triggered it.
    private static var scanDeferredWhileBackgrounded = false

    /// Whether a deferred background scan is waiting to run on next activation.
    static var hasDeferredBackgroundScan: Bool { scanDeferredWhileBackgrounded }

    static func clearDeferredBackgroundScan() { scanDeferredWhileBackgrounded = false }

    func performLocalDocumentsScan(force: Bool = false) async {
        // Never start an automatic scan while backgrounded.
        //
        // This is what the 0x8BADF00D crashes were. A scan costs 3-4 seconds in
        // the foreground; field telemetry measured the SAME scan over the same
        // ~3,500 files taking 27 and 77 seconds when the app was backgrounded
        // partway through, because iOS throttles background CPU hard. The
        // scene-update watchdog allows 10 seconds of wall clock, so a scan that
        // straddles backgrounding blows that budget and the OS kills the app —
        // reported as "scene-update watchdog transgression ... exhausted real
        // (wall clock) time allowance of 10.00 seconds", with ProcessVisibility
        // Background and ~10s of app CPU burned. It is not a thermal or memory
        // problem: thermal was nominal and resident memory ~120 MB.
        //
        // A `force` scan is exempt because it is a direct user action (the
        // Library Refresh button), which means the app is by definition
        // foreground and visible at the moment it is requested.
        //
        // Work inside an OS-granted background window is also exempt: a
        // BGAppRefreshTask importing a download that finished while the app was
        // away legitimately needs to scan, and iOS has explicitly granted it time
        // to do so. Blocking that would trade the crash for silently never
        // importing background-completed downloads — see
        // `BackgroundExecutionContext`.
        //
        // Deliberately a DEFER, not a drop: the trigger (a finished download, a
        // playlist sync) still represents a real change, so the work is
        // remembered and run on next activation — see `runDeferredScanIfNeeded`.
        if !force,
           UIApplication.shared.applicationState != .active,
           !BackgroundExecutionContext.shared.isGrantedBackgroundTime {
            Self.scanDeferredWhileBackgrounded = true
            appLog("performLocalDocumentsScan: app is not active — deferring scan to next foreground rather than risking a background watchdog kill",
                   category: "library")
            RemoteLogger.log(
                category: "library", event: "local_scan_deferred_background",
                message: "scan deferred until foreground"
            )
            return
        }

        if !force, let existing = Self.inFlightScanTask {
            appLog("performLocalDocumentsScan: already in flight, joining existing call instead of racing it", category: "library")
            await existing.value
            return
        }
        // A forced scan (the Library "Refresh" button) still shouldn't run
        // CONCURRENTLY with an already-in-flight regular one — both walk the
        // whole Documents tree and run `resolveSongs` over potentially
        // thousands of files, and a forced pass re-resolves EVERY candidate
        // rather than just new ones, so it's the heavier of the two. Caught
        // on screen: tapping Refresh right as an auto-download batch's own
        // scan was still wrapping up froze the UI for several seconds — two
        // full-library passes contending for the same CPU/IO budget at
        // once, not something either one's own off-main work alone
        // accounts for. Waiting here doesn't weaken the "always fresh"
        // guarantee `force` provides — this scan hasn't started reading
        // anything yet, so anything the other pass picks up is still
        // reflected once this one actually runs.
        if force, let existing = Self.inFlightScanTask {
            appLog("performLocalDocumentsScan(force): waiting for in-flight regular scan to finish first, rather than racing it", category: "library")
            await existing.value
        }
        // A scan that has already started must be allowed to FINISH even if the
        // user leaves the app mid-way. Without an assertion iOS suspends the
        // process partway through, the scan's wall clock keeps running while it
        // is throttled, and that is the other half of the watchdog story above.
        // A background task assertion buys real execution time instead, so the
        // scan completes in something close to its foreground cost.
        //
        // The expiration handler only ends the assertion; it deliberately does
        // NOT cancel the scan. A scan interrupted halfway leaves `importedSongs`
        // holding a partial library, and the next scan is what repairs that —
        // whereas ending the assertion twice, or leaking it, is a guaranteed
        // problem. UIKit terminates the app if an assertion is never ended.
        var assertionID: UIBackgroundTaskIdentifier = .invalid
        assertionID = UIApplication.shared.beginBackgroundTask(withName: "LumisoundLocalScan") {
            if assertionID != .invalid {
                UIApplication.shared.endBackgroundTask(assertionID)
                assertionID = .invalid
            }
        }

        let task = Task { await self.runLocalDocumentsScan(force: force) }
        if !force { Self.inFlightScanTask = task }
        await task.value
        if !force { Self.inFlightScanTask = nil }

        if assertionID != .invalid {
            UIApplication.shared.endBackgroundTask(assertionID)
            assertionID = .invalid
        }
    }

    /// Runs a scan that was deferred because the app was backgrounded when its
    /// trigger fired. Call on foreground activation.
    ///
    /// Without this, deferring would silently swallow the change that asked for
    /// the scan — a download that finished while the user was in another app
    /// would never appear until something else happened to trigger a scan.
    func runDeferredScanIfNeeded() async {
        guard Self.hasDeferredBackgroundScan else { return }
        Self.clearDeferredBackgroundScan()
        appLog("Running library scan deferred from background", category: "library")
        await performLocalDocumentsScan()
    }

    private func runLocalDocumentsScan(force: Bool) async {
        // Let the snapshot restore land first, so the diff below has a library to
        // compare against instead of starting from empty. See
        // `LibraryManager.snapshotLoadTask`.
        if let snapshotLoad = Self.snapshotLoadTask {
            await snapshotLoad.value
            Self.snapshotLoadTask = nil
        }
        appLog("Scanning local documents directory (force: \(force))", category: "library")
        // Instrumented because this path was the cause of the visible freezing
        // and nothing recorded how often it ran or what it cost. The frequency
        // had to be reconstructed by counting log lines and re-deriving the rate
        // from client timestamps; a scan that reports its own interval and
        // duration makes that answerable directly, and makes a regression
        // obvious rather than something to be rediscovered from a video.
        let scanStartedAt = Date()
        let secondsSinceLastScan = Self.lastScanStartedAt.map { scanStartedAt.timeIntervalSince($0) }
        Self.lastScanStartedAt = scanStartedAt
        // Whether the app left the foreground at any point during this scan.
        //
        // The duration below is wall-clock, and wall-clock keeps running while
        // the process is suspended — so a scan interrupted by the user leaving
        // the app reported however long they were away. The first real samples
        // came back claiming a single scan took two and a half HOURS, which is
        // not a slow scan, it is a stopwatch left running. A measurement that
        // can be wrong by four orders of magnitude is worse than none, because
        // it will be believed.
        let wasActiveAtStart = UIApplication.shared.applicationState == .active
        guard FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first != nil else { return }

        // Walk (off the main actor: inline it blocked the UI on every scan),
        // vanished-file detection, deletion of pre-conversion leftovers whose
        // `.lms` twin exists, and the new-file diff all run in the Rust core.
        let existingPaths = importedSongs.compactMap { $0.url?.path }
        guard let docsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path else { return }
        let scan = await Task.detached(priority: .utility) {
            scanDocuments(docsDir: docsPath, libraryPaths: existingPaths)
        }.value
        let missingPaths = Set(scan.missing)

        let countBeforeEviction = importedSongs.count
        MainThreadActivity.measure("scan.evict") {
            importedSongs = importedSongs.filter { song in
                guard let path = song.url?.path else { return false }
                return !missingPaths.contains(path)
            }
        }
        let evicted = countBeforeEviction != importedSongs.count

        // Retroactive cleanup of pre-conversion/converted pairs that both got
        // imported before the leftover cleanup existed.
        let mergedDuplicates = await mergeExistingConversionDuplicates()
        let cleanedUpOrphans = Int(scan.orphansRemoved)
        if cleanedUpOrphans > 0 {
            appLog("Local scan: cleaned up \(cleanedUpOrphans) pre-conversion leftover file(s) that already had a converted .lms counterpart", category: "library")
        }
        let cleanedCandidates = scan.candidates.map { URL(fileURLWithPath: $0) }
        guard !cleanedCandidates.isEmpty else {
            if evicted || mergedDuplicates > 0 || cleanedUpOrphans > 0 { rebuildAllSongs() }
            return
        }

        if force {
            // Refresh-button path: re-resolve EVERY candidate. `resolveSongs`
            // returns cached songs unchanged (cheap stat + dict hit) for files
            // whose (mtime, size) still matches, and re-extracts metadata only
            // for files that actually changed on disk — so in-place tag edits
            // are finally picked up, which the new-files-only path below misses.
            let resolved = await resolveSongs(for: cleanedCandidates)
            // Deduplicated off the main actor: on the Refresh path this covers
            // the whole library, and URL standardisation plus a grouping
            // dictionary over thousands of songs was part of the multi-second
            // freeze on pull-to-refresh. Same first-wins result as before.
            importedSongs = Self.uniqueByPath(resolved)
            appLog("Local scan (force) complete: \(importedSongs.count) song(s)", category: "library")
            rebuildAllSongs()
            return
        }

        // Only process files we haven't seen before.
        //
        // BUGFIX (reported: scrolling/browsing hangs for a few seconds,
        // "like there's another reload process going on all the time" on a
        // large library): this ran synchronously on the main actor —
        // `standardizedFileURL` per candidate plus a Set lookup, over
        // `cleanedCandidates`, which is every audio file still found in
        // Documents, not just new ones. Every neighboring step in this same
        // function (the enumeration pass, eviction, orphan cleanup, the
        // `force`-path dedup) was already moved off the main actor for
        // exactly this reason; this one wasn't, and it runs on every regular
        // scan trigger — not just an explicit pull-to-refresh, but also
        // every background-download completion and foreground return — so
        // on a large library it fired this same multi-second main-thread
        // cost repeatedly during ordinary use, not just once.
        let newURLs = scan.newPaths.map { URL(fileURLWithPath: $0) }
        guard !newURLs.isEmpty else { return }

        let newSongs = await resolveSongs(for: newURLs)

        let scanDuration = Date().timeIntervalSince(scanStartedAt)
        appLog("Local scan complete: \(newSongs.count) song(s) in \(String(format: "%.2f", scanDuration))s"
               + (secondsSinceLastScan.map { String(format: " (%.1fs since the previous scan)", $0) } ?? ""),
               category: "library")
        // Reported as a structured event, not just a log line, so the rate and
        // cost are queryable across every account instead of needing a
        // hand-written pattern match over free text.
        //
        // `sinceLastScanSeconds` is the field that matters: a scan taking 300ms
        // is fine on its own and ruinous ten times a minute, and only the
        // interval separates those two. Flagged when scans arrive closer together
        // than the throttle that is supposed to be governing them.
        RemoteLogger.log(
            category: "library",
            event: "local_scan_completed",
            level: (secondsSinceLastScan.map { $0 < 10 } ?? false) ? "warning" : "info",
            message: "\(newSongs.count) new song(s) in \(String(format: "%.2f", scanDuration))s",
            detail: [
                "durationMs": Int(scanDuration * 1000),
                "newSongs": newSongs.count,
                "librarySize": importedSongs.count,
                "forced": force,
                "sinceLastScanSeconds": secondsSinceLastScan.map { Int($0) } ?? -1,
                // Consult this before trusting `durationMs`: false means the app
                // was backgrounded for part of the scan and the figure includes
                // however long it sat suspended.
                "foregroundThroughout": wasActiveAtStart
                    && UIApplication.shared.applicationState == .active,
            ]
        )
        // Nothing found and nothing removed means the library is byte-for-byte
        // what it already was, so there is nothing to merge and nothing to
        // rebuild. This ran unconditionally, and on a large library that is the
        // whole cost of an automatic scan: a dictionary keyed on every song —
        // each key holding its own array — followed by a full index rebuild,
        // both on the main actor, both to arrive back at the list already held.
        // For a three-thousand-song library that is thousands of allocations
        // several times over, every time anything asked for a scan, almost
        // always to discover that nothing had changed.
        guard !newSongs.isEmpty || evicted || mergedDuplicates > 0 || cleanedUpOrphans > 0 else {
            return
        }

        importedSongs = Self.uniqueByPath(importedSongs + newSongs)
        rebuildAllSongs()
    }

    /// One song per file (normalized path; id when pathless), first wins.
    nonisolated static func uniqueByPath(_ songs: [Song]) -> [Song] {
        scanUniqueIndices(keys: songs.map { $0.url?.path ?? $0.id }).map { songs[Int($0)] }
    }

    /// Shared by every local-file scan path (Documents, watched folders,
    /// a specific directory): drops — and deletes on disk — any candidate
    /// that's a pre-conversion leftover, returning the cleaned candidate
    /// list plus how many were removed.
    ///
    /// A file whose exclusive-extension conversion target (`<name>.m4a.lms`)
    /// already exists — either already in the library (`existingURLs`), or
    /// right alongside it in this same scan batch — means
    /// `LumisoundExclusiveExtensionService.convert` re-encoded it
    /// successfully but failed to delete the original source afterward (a
    /// real, if rare, failure mode — see that function's doc comment).
    /// Every scan path used to import this leftover as if it were a
    /// genuinely separate file, which is exactly how "old file + .lms file,
    /// both showing up as separate library entries" duplicates happened.
    nonisolated static func cleanUpConversionOrphans(among candidates: [URL], existingURLs: Set<URL>) -> (candidates: [URL], cleanedUp: Int) {
        let r = scanCleanConversionOrphans(candidates: candidates.map(\.path), existing: existingURLs.map(\.path))
        if r.removed > 0 {
            appLog("Local scan: cleaned up \(r.removed) pre-conversion leftover file(s) that already had a converted .lms counterpart", category: "library")
        }
        return (r.remaining.map { URL(fileURLWithPath: $0) }, Int(r.removed))
    }

    /// Retroactive counterpart to `cleanUpConversionOrphans` — that one only
    /// stops a NEW duplicate pair from forming; this finds pairs that
    /// already both made it into `importedSongs` as separate entries before
    /// that fix existed (each import only ever compared a candidate file
    /// against other FILES on disk, never against an existing library
    /// entry that happens to be its own converted counterpart). For every
    /// such pair, re-keys favorites/playlists/play-history from the old
    /// (pre-conversion) entry's id to the surviving `.lms` entry's id —
    /// same migration `LibraryManager.convertToLumisoundExclusiveExtension`
    /// already does for a live conversion — then deletes the old file and
    /// drops it from the library. Skips the currently-playing song (same
    /// "don't replace a file out from under an open player" reasoning as
    /// everywhere else in this pipeline); it's picked up on a later scan
    /// once it's no longer playing. Returns how many pairs were merged.
    @discardableResult
    func mergeExistingConversionDuplicates() async -> Int {
        // Finding pairs is pure URL work over the whole library, and on the
        // main actor it cost 0.5-1s of every scan (the hang monitor's
        // `scan.mergeConversionDuplicates` label, in 3-4s launch freezes), to
        // find nothing almost every time. It runs detached on a snapshot; only
        // the rare pairs it finds are merged here, against live state.
        let entries = importedSongs.compactMap { song in song.url.map { LibraryPathEntry(id: song.id, path: $0.path) } }
        let found = await Task.detached(priority: .userInitiated) { scanConversionPairs(entries: entries) }.value
        let byID = Dictionary(importedSongs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pairs: [(song: Song, survivor: Song, url: URL, target: URL)] = found.compactMap { p in
            guard let song = byID[p.songId], let survivor = byID[p.survivorId] else { return nil }
            return (song, survivor, URL(fileURLWithPath: p.path), URL(fileURLWithPath: p.convertedPath))
        }
        guard !pairs.isEmpty else { return 0 }

        let currentlyPlayingID = AudioPlayerManager.shared?.currentSong?.id
        let queuedIDs = Set(AudioPlayerManager.shared?.queue.map(\.id) ?? [])
        var merged = 0

        for (song, survivor, url, target) in pairs {
            // Still present? Something may have changed it while the pairs
            // were being found.
            guard importedSongs.contains(where: { $0.id == song.id }) else { continue }
            // See AudioPlayerManager.isInActiveQueue's doc comment: the
            // survivor's target `.lms` file could be anywhere in the same
            // queue as `song`, not just the current index.
            guard song.id != currentlyPlayingID, !queuedIDs.contains(song.id) else { continue }

            if favoriteSongIDs.contains(song.id) {
                favoriteSongIDs.remove(song.id)
                favoriteSongIDs.insert(survivor.id)
                persistence.saveFavorites(favoriteSongIDs)
            }
            var playlistsChanged = false
            for i in playlists.indices {
                guard let pos = playlists[i].songIDs.firstIndex(of: song.id) else { continue }
                playlists[i].songIDs[pos] = survivor.id
                playlistsChanged = true
            }
            if playlistsChanged { persistence.savePlaylists(playlists) }
            PlayHistoryStore.shared.rekey(from: song.id, to: survivor.id)
            if let sourceTrackID = survivor.sourceTrackID, !sourceTrackID.isEmpty {
                DownloadLedgerStore.shared.record(sourceTrackID: sourceTrackID, filename: target.lastPathComponent)
            }

            try? FileManager.default.removeItem(at: url)
            importedSongs.removeAll { $0.id == song.id }
            merged += 1
        }

        if merged > 0 {
            appLog("Local scan: merged \(merged) existing pre-conversion/converted duplicate pair(s)", category: "library")
        }
        return merged
    }
}
