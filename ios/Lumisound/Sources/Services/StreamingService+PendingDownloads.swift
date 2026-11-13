import Foundation

// MARK: - Pending Downloads (background-completed downloads reconciliation)
//
// The job-based /api/download flow (see StreamingService+DownloadToLibrary.swift)
// already runs entirely server-side once started — yt-dlp keeps going even if
// the app is backgrounded or killed mid-poll. What this file adds is the other
// half: recovering a finished download the app never got to fetch, because the
// bridge now durably holds it (GET /api/download/pending) instead of deleting
// it after 15 minutes. Reconciliation is called from several trigger points
// (app launch, app-foreground, each BGAppRefreshTask run, and immediately on a
// "download_ready" silent push — see AppDelegate and BackgroundRefreshService)
// so a download that finishes while the app isn't open still lands in the
// library on its own, without the user needing to notice anything.
//
// Those trigger points genuinely overlap in practice — a normal "reopen the
// app" fires BOTH the launch `.task` AND the scenePhase == .active handler
// close together, and each independently lists /api/download/pending and
// tries to fetch the same job_id. /api/download/result deletes its durable
// copy after being served once, so whichever call wins gets 200 and the
// other gets 404 — confirmed in production logs as repeated 200-then-404
// pairs for the same job_id. That race was harmless on its own (the winner
// still imports correctly) but wasteful and, combined with zero logging on
// that specific failure branch, impossible to diagnose from the field. The
// gate below collapses concurrent calls into a single in-flight fetch so
// there's only ever one claimant per reconciliation pass.
private actor PendingDownloadsReconcileGate {
    private var inFlight: Task<Int, Never>?

    func run(_ work: @escaping () async -> Int) async -> Int {
        if let inFlight {
            appLog("reconcilePendingDownloads: already in flight, joining existing call instead of racing it", category: "network")
            return await inFlight.value
        }
        let task = Task { await work() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}

private let pendingDownloadsReconcileGate = PendingDownloadsReconcileGate()

extension StreamingService {

    struct PendingDownloadInfo: Decodable {
        let job_id: String
        let source_track_id: String?
        let title: String?
        let artist: String?
        let media_type: String?
        let filename: String
        let created_at: String?
        /// The local subfolder this job was destined for (e.g. a tracked
        /// playlist's own destination folder), carried through from the
        /// original `/api/download` request — see `destination_folder` on
        /// `downloadToLibrary`. nil/empty means the default folder.
        let destination_folder: String?
    }

    private struct PendingDownloadsResponse: Decodable {
        let pending: [PendingDownloadInfo]
    }

    /// Lists every finished-but-unfetched download job for the current
    /// account. Empty (not throwing) if logged out or the request fails —
    /// callers treat "nothing to reconcile" and "couldn't check" the same way.
    func fetchPendingDownloads() async -> [PendingDownloadInfo] {
        guard let accountToken = AccountService.shared?.token, !accountToken.isEmpty else { return [] }
        guard var request = makeRequest("/api/download/pending") else { return [] }
        request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await Core.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return try JSONDecoder().decode(PendingDownloadsResponse.self, from: data).pending
        } catch {
            appWarn("fetchPendingDownloads: request failed: \(error.localizedDescription)", category: "network")
            return []
        }
    }

    /// Fetches and imports every pending (finished-but-unfetched) download for
    /// the current account, exactly like the job-based path's own finishing
    /// steps (move into place, ledger record, integrity check) — then does a
    /// single library rescan at the end. Safe to call opportunistically and
    /// often: an empty pending list is a fast no-op (one GET request), and
    /// re-running after a partial success only reprocesses what's left,
    /// since each successfully-imported job is deleted server-side as it's
    /// fetched (see /api/download/result's pending-download branch).
    private static let lastDownloadActivityKey = "downloads.lastActivity"

    /// Downloads were started in the last 24 h, so finished jobs may be waiting.
    static var hasRecentDownloadActivity: Bool {
        guard let d = UserDefaults.standard.object(forKey: lastDownloadActivityKey) as? Date else { return false }
        return Date().timeIntervalSince(d) < 24 * 3600
    }

    static func noteDownloadActivity() {
        UserDefaults.standard.set(Date(), forKey: lastDownloadActivityKey)
    }

    @discardableResult
    func reconcilePendingDownloads() async -> Int {
        await pendingDownloadsReconcileGate.run { [self] in
            await performReconcilePendingDownloads()
        }
    }

    private func performReconcilePendingDownloads() async -> Int {
        let pending = await fetchPendingDownloads()
        appLog("reconcilePendingDownloads: \(pending.count) pending job(s) found", category: "network")
        guard !pending.isEmpty else { return 0 }

        var imported = 0
        for (index, entry) in pending.enumerated() {
            if Task.isCancelled { break }
            guard await importPendingDownload(entry) else { continue }
            imported += 1
            if (index + 1) % 10 == 0 {
                await Task.yield()
            }
        }

        appLog("reconcilePendingDownloads: imported \(imported)/\(pending.count) pending job(s)", category: "network")
        if imported > 0 {
            await LibraryManager.shared?.scanLocalDocumentsAsync(userInitiated: false)
            let label = imported == 1 ? "1 download" : "\(imported) downloads"
            ToastCenter.shared.show("\(label) finished in the background", category: .download)
        }
        return imported
    }

    /// Imports one pending job — used both by the batch `reconcilePendingDownloads`
    /// pass (no override, uses `entry.destination_folder` as recorded on the
    /// job) and by `PendingImportsView`'s per-row "Import Now" (passes the
    /// user's picker choice as `folderOverride` when they changed it from
    /// the pre-filled default before importing).
    @discardableResult
    func importPendingDownload(_ entry: PendingDownloadInfo, folderOverride: String? = nil) async -> Bool {
        // Resolved per entry (not once for the whole batch) — different
        // pending jobs can be destined for different tracked playlists'
        // folders. Previously this was a single `destinationDir` the caller
        // passed in, which every call site left `nil`, so a track auto-
        // downloaded from a playlist with its own folder always came back
        // into the plain default folder after a crash/close recovery.
        let resolvedFolder = folderOverride ?? entry.destination_folder
        let importDir = StreamingService.downloadDirectory(forFolderName: resolvedFolder) ?? downloadDirectory
        try? FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)

        guard let base = makeRequest("/api/download"),
              let resultURL = jobPollURL(from: base, path: "/api/download/result", jobID: entry.job_id) else {
            return false
        }
        var request = base
        request.url = resultURL
        if let accountToken = AccountService.shared?.token {
            request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }
        request.timeoutInterval = 120

        let downloadedURL: URL
        let response: URLResponse
        do {
            (downloadedURL, response) = try await Core.download(for: request)
        } catch {
            appWarn("reconcilePendingDownloads: fetch failed for job \(entry.job_id): \(error.localizedDescription)", category: "network")
            return false
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // 404 here almost always means another concurrent reconcile call
            // (or the original foreground download flow, if it was still
            // polling when the app resumed) already claimed and deleted this
            // job's durable copy first — expected under the race described
            // above, not a real failure. Anything else IS worth flagging.
            if status == 404 {
                appLog("reconcilePendingDownloads: job \(entry.job_id) already claimed elsewhere (404) — skipping", category: "network")
            } else {
                appWarn("reconcilePendingDownloads: unexpected HTTP \(status) fetching job \(entry.job_id)", category: "network")
            }
            try? FileManager.default.removeItem(at: downloadedURL)
            return false
        }

        let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: downloadedURL.path))?[.size] as? Int64 ?? 0
        let expectedSize = http.expectedContentLength
        if downloadedSize <= 0 || (expectedSize > 0 && downloadedSize != expectedSize) {
            try? FileManager.default.removeItem(at: downloadedURL)
            appWarn("reconcilePendingDownloads: incomplete file for job \(entry.job_id)", category: "network")
            return false
        }

        let ext = extensionForContentType(http.value(forHTTPHeaderField: "Content-Type"))
            ?? (entry.filename as NSString).pathExtension
        let rawName = entry.title ?? (entry.filename as NSString).deletingPathExtension
        let safeName = String(
            rawName.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(100)
        )
        let sourceTrackID = entry.source_track_id ?? entry.job_id
        var (destURL, alreadyComplete) = await resolveDownloadDestination(
            preferred: importDir.appendingPathComponent("\(safeName).\(ext)"),
            sourceTrackID: sourceTrackID
        )

        if alreadyComplete {
            try? FileManager.default.removeItem(at: downloadedURL)
        } else {
            do {
                try FileManager.default.moveItem(at: downloadedURL, to: destURL)
            } catch {
                appError("reconcilePendingDownloads: move failed for job \(entry.job_id): \(error)", category: "network")
                try? FileManager.default.removeItem(at: downloadedURL)
                return false
            }
            guard CorruptFileFinderService.isValidAudioFile(at: destURL) else {
                try? FileManager.default.removeItem(at: destURL)
                appWarn("reconcilePendingDownloads: corrupt/unreadable file for job \(entry.job_id) — discarding", category: "network")
                return false
            }

            // This reconciliation path (a download that finished while the
            // app wasn't around to fetch it in the foreground) never used to
            // run the Lumisound-exclusive lock at all — only the foreground
            // `attemptDownload`/`finalizeRelayedFile` paths called
            // `finalizeAndLockDownload`. A track imported here sat as a
            // plain, unlocked file until SOME LATER background pass
            // (`LumisoundTrackVaultService.runExtensionConversionPass`)
            // happened to run — which, on a device that's mostly backgrounded
            // between app opens, could be a long wait or never happen before
            // the user noticed. That was the "some downloads still seep
            // through to the user's device un-converted" report. Best-effort,
            // same as the foreground path: on any failure this just leaves
            // `destURL` as the plain file, which is fully playable and still
            // picked up by the next background pass.
            LumisoundTrackVaultService.tagNewDownload(fileURL: destURL, trackID: sourceTrackID, sourceURL: "")
            if let lockedURL = await LumisoundExclusiveExtensionService.convert(fileURL: destURL) {
                LumisoundTrackTagger.tag(fileURL: lockedURL, trackID: sourceTrackID, sourceURL: "")
                appLog("reconcilePendingDownloads: locked job \(entry.job_id) synchronously -> \(lockedURL.lastPathComponent)", category: "network")
                destURL = lockedURL
            } else {
                appWarn("reconcilePendingDownloads: synchronous lock failed for job \(entry.job_id) — will retry on next background conversion pass", category: "network")
            }
        }

        DownloadLedgerStore.shared.record(sourceTrackID: sourceTrackID, filename: destURL.lastPathComponent)
        recordRecentImport(title: rawName, artist: entry.artist, destinationFolder: resolvedFolder)

        // Unlike the foreground download path (attemptDownload /
        // finalizeRelayedFile, both of which call prefetchArtworkWithFallback
        // right after a successful download), this reconciliation path never
        // seeds ArtworkService's cache — a track imported here relies
        // entirely on ArtworkService.loadArtwork's fallback chain (embedded-
        // metadata read -> LUMISOUND_THUMBNAIL tag recovery -> iTunes Search)
        // the first time its artwork is actually displayed. That chain can
        // genuinely come up empty rather than just slow: AVFoundation's
        // metadata parsing for Ogg/Opus's vorbis-comment picture blocks is
        // far less reliable than for MP4/ID3 tags, and iTunes Search has no
        // fan remix/game-rip upload in its commercial catalog to match — the
        // exact combination this app's own yt-dlp pipeline routinely
        // produces. `PendingDownloadInfo` doesn't carry the original
        // thumbnail URL (the bridge's /api/download/pending response never
        // included one), but YouTube's hqdefault.jpg is deterministic from
        // the video ID alone and virtually always exists — the same
        // guaranteed fallback prefetchArtworkWithFallback itself reaches for
        // when a track's *actual* thumbnail URL 404s. prefetchRemoteImage is
        // a cheap no-op if artwork is already cached under this filename
        // (e.g. the `alreadyComplete` branch above, which already has real
        // artwork from its original download), so this is safe to always try.
        if sourceTrackID.hasPrefix("youtube:") {
            let videoID = String(sourceTrackID.dropFirst("youtube:".count))
            if let thumbnailURL = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg") {
                await ArtworkService.shared.prefetchRemoteImage(url: thumbnailURL, forKey: destURL.lastPathComponent)
            }
        }

        appLog("reconcilePendingDownloads: imported job \(entry.job_id) -> \(destURL.lastPathComponent)", category: "network")
        return true
    }
}
