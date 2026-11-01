import SwiftUI
import UniformTypeIdentifiers

extension StreamSearchView {

    // MARK: — Streaming Actions

    func handlePlay(track: StreamTrack) {
        guard loadingTrackID == nil else { return }
        loadingTrackID = track.id
        appBreadcrumb("Tapped Play (preview) on \"\(track.title)\" [\(track.source)]")
        Task {
            defer { loadingTrackID = nil }
            do {
                let url = try await streaming.streamURL(for: track)
                let song = streaming.toSong(track: track, streamURL: url)
                player.play(song: song, in: [song])
            } catch {
                streaming.errorMessage = error.localizedDescription
            }
        }
    }

    func handleAddToQueue(track: StreamTrack) {
        guard loadingTrackID == nil else { return }
        loadingTrackID = track.id
        Task {
            defer { loadingTrackID = nil }
            do {
                let url = try await streaming.streamURL(for: track)
                let song = streaming.toSong(track: track, streamURL: url)
                player.appendToQueue(song: song)
            } catch {
                streaming.errorMessage = error.localizedDescription
            }
        }
    }

    func handlePlayNext(track: StreamTrack) {
        guard loadingTrackID == nil else { return }
        loadingTrackID = track.id
        Task {
            defer { loadingTrackID = nil }
            do {
                let url = try await streaming.streamURL(for: track)
                let song = streaming.toSong(track: track, streamURL: url)
                player.insertNext(song: song)
            } catch {
                streaming.errorMessage = error.localizedDescription
            }
        }
    }

    /// Re-derives `downloadedTrackIDs`/`downloadedServerTrackIDs` from the
    /// current `library.allSongs` (which includes everything found by recursive
    /// subfolder scans, not just top-level "Imported Music"). Previously these
    /// sets were ONLY mutated as a side effect of an in-session download, so
    /// tracks that were already on disk (in a subfolder, restored from backup,
    /// imported manually, etc.) permanently showed the "not downloaded" icon
    /// and could be re-downloaded as duplicates.
    func refreshDownloadedStatus() {
        guard !library.allSongs.isEmpty else { return }
        // Built ONCE (O(library)), then each result is O(1) — per-result
        // library scans on a 1000-track playlist tripped the watchdog.
        let index = library.metadataCopyIndex()

        // Collected locally and assigned once: inserting into the @State
        // sets per match invalidated the view once per track, which on a
        // resolved 1000-track playlist meant hundreds of state writes.
        var downloaded = downloadedTrackIDs
        for track in streaming.searchResults where !downloaded.contains(track.id) {
            if index.contains(candidate: track.remoteCandidate) {
                downloaded.insert(track.id)
            }
        }
        if downloaded != downloadedTrackIDs { downloadedTrackIDs = downloaded }

        var downloadedServer = downloadedServerTrackIDs
        for track in streaming.serverTracks where !downloadedServer.contains(track.id) {
            if index.contains(candidate: RemoteCandidate(sourceTrackId: "", title: track.title,
                                                         artist: track.artist, duration: track.duration)) {
                downloadedServer.insert(track.id)
            }
        }
        if downloadedServer != downloadedServerTrackIDs { downloadedServerTrackIDs = downloadedServer }
    }

    func handleDownload(track: StreamTrack) {
        guard !downloadingTrackIDs.contains(track.id) else { return }
        downloadingTrackIDs.insert(track.id)
        appBreadcrumb("Tapped Download on \"\(track.title)\" [\(track.source)]")
        Task {
            do {
                // Rescan the full Documents tree (including subfolders the user has
                // created or moved files into) so `isAlreadyImported` reflects reality
                // before we decide whether to download — without this, a track sitting
                // in a subfolder of "Imported Music" would pass the sourceTrackID-only
                // check inside `downloadToLibrary` (which only looks at the top-level
                // download directory) and get re-downloaded as a duplicate.
                await library.scanLocalDocumentsAsync()
                if library.isAlreadyImported(title: track.title, artist: track.artist, duration: track.duration) {
                    downloadedTrackIDs.insert(track.id)
                    failedTrackIDs.remove(track.id)
                    downloadingTrackIDs.remove(track.id)
                    ToastCenter.shared.show("\"\(track.title)\" is already in your library", category: .info, icon: "checkmark.circle")
                    return
                }
                let localURL = try await streaming.downloadToLibrary(track: track, existingSongs: library.allSongs)
                library.scanLocalDocuments()
                downloadedTrackIDs.insert(track.id)
                failedTrackIDs.remove(track.id)
                appLog("Download succeeded: \"\(track.title)\"", category: "download",
                       extra: ["title": track.title, "artist": track.artist, "source": track.source, "trackId": track.id])
                ToastCenter.shared.show("Downloaded \"\(track.title)\"", category: .download, icon: "checkmark.circle.fill")
                NotificationService.shared.notify(
                    title: "Download Complete",
                    body: "\"\(track.title)\" is ready in your library.",
                    identifier: "download-\(track.id)"
                )
                if autoCloudBackup, account.isLoggedIn, let token = account.token {
                    Task {
                        let hasArtwork = await LumisoundExclusiveExtensionService.hasEmbeddedThumbnailTag(fileURL: localURL)
                        try? await streaming.uploadTrack(
                            fileURL: localURL, token: token,
                            metadata: TrackMetadata(title: track.title, artist: track.artist, durationSeconds: track.duration, hasArtwork: hasArtwork)
                        )
                    }
                }
            } catch let error as StreamingError {
                failedTrackIDs.insert(track.id)
                appWarn("Download failed: \"\(track.title)\": \(error.localizedDescription)", category: "download",
                        extra: ["title": track.title, "artist": track.artist, "source": track.source, "trackId": track.id, "error": error.localizedDescription])
                if case .serverDetail(let detail) = error {
                    // A specific, actionable reason from the bridge (e.g. an
                    // auto-generated Topic-channel track blocked from extraction) —
                    // show it directly instead of a generic "failed to download".
                    streaming.errorMessage = detail
                    ToastCenter.shared.show(detail, category: .error)
                } else {
                    streaming.errorMessage = "Download failed: \(error.localizedDescription)"
                    ToastCenter.shared.show("Failed to download \"\(track.title)\"", category: .error)
                }
            } catch {
                streaming.errorMessage = "Download failed: \(error.localizedDescription)"
                failedTrackIDs.insert(track.id)
                appWarn("Download failed: \"\(track.title)\": \(error.localizedDescription)", category: "download",
                        extra: ["title": track.title, "artist": track.artist, "source": track.source, "trackId": track.id, "error": error.localizedDescription])
                ToastCenter.shared.show("Failed to download \"\(track.title)\"", category: .error)
            }
            downloadingTrackIDs.remove(track.id)
        }
    }

    func handleDownloadAll() {
        guard !isDownloadingAll else { return }
        failedTrackIDs.removeAll()
        let url = searchText.trimmingCharacters(in: .whitespaces)
        let looksLikePlaylist = url.contains("list=") || url.contains("/playlist") || url.contains("/sets/")

        // For a playlist, re-run the resolver (the full per-item extractor) right
        // before downloading, so Download All always operates on EVERY item in
        // the current playlist — not a stale or partial result. The resolve also
        // sends the dedup manifest/inventory, so owned tracks are excluded.
        if streaming.isPlaylistResult, looksLikePlaylist {
            Task { @MainActor in
                await streaming.resolvePlaylist(url: url, existingSongs: library.allSongs)
                let tracks = streaming.searchResults
                guard !tracks.isEmpty else { return }
                runDownloadPipeline(tracks: tracks)
            }
            return
        }

        let tracks = streaming.searchResults
        guard !tracks.isEmpty else { return }
        runDownloadPipeline(tracks: tracks)
    }

    /// Re-runs the download pipeline for only the tracks that failed last
    /// time (`failedTrackIDs`) — no call to `triggerSearch()`/`resolvePlaylist`,
    /// so `streaming.searchResults` and the rest of the list stay untouched
    /// and the UI doesn't refresh wholesale.
    func handleRetryFailedDownloads() {
        guard !isDownloadingAll else { return }
        let tracks = streaming.searchResults.filter { failedTrackIDs.contains($0.id) }
        guard !tracks.isEmpty else { return }
        failedTrackIDs.removeAll()
        runDownloadPipeline(tracks: tracks)
    }

    /// Bounded-concurrency download pipeline shared by "Download All" and
    /// "Retry Failed". Before downloading, refreshes the local library scan
    /// (recursively, including any subfolders) and skips any track that
    /// already matches a locally-imported song by title+artist — covering
    /// manually-imported files or ones from a different source that the
    /// `sourceTrackID`-based check inside `downloadToLibrary` wouldn't catch.
    func runDownloadPipeline(tracks: [StreamTrack]) {
        isDownloadingAll = true
        downloadAllDone = 0
        downloadAllTotal = tracks.count

        // Matches the bridge's yt-dlp process semaphore (_YTDLP_SEMAPHORE) so the
        // client keeps it saturated without piling up extra jobs that just sit
        // "pending" behind the semaphore (each holding its own /tmp/dl_* dir).
        // Dropped 4 -> 2 (2026-08) — see TrackedPlaylistStore.autoDownloadConcurrency.
        let maxConcurrent = 2

        Task { @MainActor in
            // Make sure `library.allSongs` reflects every file on disk — including
            // subfolders the user created or moved files into — before deciding
            // what's already imported.
            await library.scanLocalDocumentsAsync()

            // Build the fast-path lookups ONCE before checking every track —
            // hasLocalCopy(of:) alone is O(library) per call, so checking it
            // per track over a big "Download All" batch was an
            // O(tracks × library) main-thread hang long enough to trip the
            // watchdog (the same "opening a big playlist crashes" bug fixed
            // in TrackedPlaylistDetailView/TrackedPlaylistStore).
            let index = await library.localCopyIndex()

            var toDownload: [StreamTrack] = []
            var skipped = 0
            for track in tracks {
                if index.contains(candidate: track.remoteCandidate) {
                    skipped += 1
                    downloadedTrackIDs.insert(track.id)
                    downloadAllDone += 1
                } else {
                    toDownload.append(track)
                }
            }

            var failed: [String] = []
            var nextIndex = 0

            await withTaskGroup(of: (track: StreamTrack, localURL: URL?, errorDescription: String?).self) { group in
                func launchNext() {
                    guard nextIndex < toDownload.count else { return }
                    let track = toDownload[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            let localURL = try await streaming.downloadToLibrary(track: track, existingSongs: library.allSongs)
                            appLog("Download All: succeeded for \"\(track.title)\"", category: "download",
                                   extra: ["title": track.title, "artist": track.artist, "source": track.source, "trackId": track.id])
                            return (track, localURL, nil)
                        } catch {
                            appWarn("Download All: failed for \"\(track.title)\": \(error.localizedDescription)", category: "download",
                                    extra: ["title": track.title, "artist": track.artist, "source": track.source, "trackId": track.id, "error": error.localizedDescription])
                            return (track, nil, error.localizedDescription)
                        }
                    }
                }

                for _ in 0..<min(maxConcurrent, toDownload.count) {
                    launchNext()
                }

                for await result in group {
                    if let localURL = result.localURL {
                        downloadedTrackIDs.insert(result.track.id)
                        failedTrackIDs.remove(result.track.id)
                        if autoCloudBackup, account.isLoggedIn, let token = account.token {
                            Task {
                                let hasArtwork = await LumisoundExclusiveExtensionService.hasEmbeddedThumbnailTag(fileURL: localURL)
                                try? await streaming.uploadTrack(
                                    fileURL: localURL, token: token,
                                    metadata: TrackMetadata(title: result.track.title, artist: result.track.artist, durationSeconds: result.track.duration, hasArtwork: hasArtwork)
                                )
                            }
                        }
                    } else {
                        failed.append(result.track.title)
                        failedTrackIDs.insert(result.track.id)
                    }
                    downloadAllDone += 1
                    launchNext()
                }
            }

            library.scanLocalDocuments()
            isDownloadingAll = false
            let succeeded = toDownload.count - failed.count

            if failed.isEmpty {
                if skipped > 0 {
                    ToastCenter.shared.show("Downloaded \(succeeded), skipped \(skipped) already imported", category: .download)
                } else {
                    ToastCenter.shared.show("Downloaded \(succeeded) tracks", category: .download)
                }
            } else {
                streaming.errorMessage = "\(failed.count) track(s) failed to download."
                let skippedSuffix = skipped > 0 ? ", skipped \(skipped)" : ""
                ToastCenter.shared.show("Downloaded \(succeeded), \(failed.count) failed\(skippedSuffix)", category: .warning)
            }
        }
    }
}
