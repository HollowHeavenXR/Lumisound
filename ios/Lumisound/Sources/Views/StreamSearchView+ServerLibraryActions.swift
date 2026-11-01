import SwiftUI
import UniformTypeIdentifiers

extension StreamSearchView {

    // MARK: — Server Library Actions

    func handleServerPlay(track: ServerTrack) {
        let song = streaming.toSong(serverTrack: track)
        player.play(song: song, in: [song])
    }

    func handleServerDownload(track: ServerTrack) {
        guard !downloadingServerTrackIDs.contains(track.id),
              let streamURL = streaming.serverStreamURL(for: track) else { return }
        downloadingServerTrackIDs.insert(track.id)

        Task {
            // Same duplicate guard as `handleDownload`/`runDownloadPipeline`: rescan
            // first (picks up subfolder-imported files), then skip the download
            // entirely if a matching track is already in the library.
            await library.scanLocalDocumentsAsync()
            if library.isAlreadyImported(title: track.title, artist: track.artist, duration: track.duration) {
                downloadedServerTrackIDs.insert(track.id)
                downloadingServerTrackIDs.remove(track.id)
                ToastCenter.shared.show("\"\(track.title)\" is already in your library", category: .info, icon: "checkmark.circle")
                return
            }

            do {
                let importDir = streaming.downloadDirectory
                try? FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)

                let safeName = String(
                    track.title
                        .replacingOccurrences(of: "/", with: "-")
                        .replacingOccurrences(of: ":", with: "-")
                        .prefix(100)
                )
                let ext = track.ext.isEmpty ? "m4a" : track.ext
                let destURL = importDir.appendingPathComponent("\(safeName).\(ext)")

                if FileManager.default.fileExists(atPath: destURL.path) {
                    downloadedServerTrackIDs.insert(track.id)
                    downloadingServerTrackIDs.remove(track.id)
                    return
                }

                var request = URLRequest(url: streamURL)
                request.httpMethod = "GET"
                if !streaming.apiKey.isEmpty {
                    request.setValue("Bearer \(streaming.apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.timeoutInterval = 120

                // Retry a few times on incomplete/corrupt transfers, same as
                // StreamingService.downloadToLibrary, before giving up.
                let maxAttempts = 3
                var lastError: Error = StreamingError.corruptDownload

                for attempt in 1...maxAttempts {
                    do {
                        let (tmpURL, response) = try await Core.download(for: request)
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            throw StreamingError.httpError(http.statusCode)
                        }

                        // Verify the download is complete before adopting it — a truncated
                        // file would otherwise sit in the library showing "0:00" forever.
                        let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: tmpURL.path))?[.size] as? Int64 ?? 0
                        let expectedSize = (response as? HTTPURLResponse)?.expectedContentLength ?? -1
                        if downloadedSize <= 0 || (expectedSize > 0 && downloadedSize != expectedSize) {
                            try? FileManager.default.removeItem(at: tmpURL)
                            throw StreamingError.incompleteDownload
                        }

                        try? FileManager.default.removeItem(at: destURL)
                        try FileManager.default.moveItem(at: tmpURL, to: destURL)

                        guard CorruptFileFinderService.isValidAudioFile(at: destURL) else {
                            try? FileManager.default.removeItem(at: destURL)
                            throw StreamingError.corruptDownload
                        }

                        library.scanLocalDocuments()
                        downloadedServerTrackIDs.insert(track.id)
                        lastError = StreamingError.corruptDownload
                        break
                    } catch let error as StreamingError {
                        switch error {
                        case .incompleteDownload, .corruptDownload:
                            lastError = error
                            if attempt == maxAttempts { throw error }
                            continue
                        default:
                            throw error
                        }
                    }
                }
            } catch {
                streaming.errorMessage = "Download failed: \(error.localizedDescription)"
            }
            downloadingServerTrackIDs.remove(track.id)
        }
    }
}
