import Foundation
import UIKit

extension StreamingService {

    // MARK: - Auto-Backup Sync (catches songs that were imported/scanned, not just downloaded)

    // MARK: Permanent-failure guard
    //
    // A 4xx from `uploadTrack` (e.g. a file extension the server's
    // SUPPORTED_AUDIO_EXTS doesn't recognize) will never succeed no matter how
    // many times it's retried — but `pending` is recomputed from scratch on
    // EVERY scan (LibraryView's onAppear/refresh, folder-watch, foreground
    // return, ...), so without this a single permanently-unbackupable track
    // silently burned a real network request every single scan, forever.
    // Confirmed in production logs: one locally-imported track logged 1900+
    // "upload failed ... HTTP 400" retries in a week. Keyed by filename+size
    // (not just filename) so replacing the file with different content — the
    // one case where a retry could actually succeed — gets a fresh attempt.
    // Bumped v1 -> v2 to discard the memo built up against a server bug that
    // has since been fixed: `/user/music/upload` mangled any filename whose
    // base name ended with a period (a title like "Super Smash Bros." backs up
    // as "...Bros..opus.lms", whose ".." the server collapsed, destroying the
    // extension) and 400'd it. Those tracks are genuinely uploadable now, but
    // this guard had already recorded them as permanently failed — so without
    // resetting the key they'd stay skipped forever and silently never back
    // up, which is the exact failure this guard exists to bound, not cause.
    // Any entry still genuinely unbackupable just re-earns its 3 strikes.
    private static let permanentUploadFailureKey = "backUpLibraryIfNeeded.permanentFailures.v2"

    private struct UploadFailureRecord: Codable { let size: Int; let attempts: Int }

    private static func loadPermanentUploadFailures() -> [String: UploadFailureRecord] {
        guard let data = UserDefaults.standard.data(forKey: permanentUploadFailureKey),
              let decoded = try? JSONDecoder().decode([String: UploadFailureRecord].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func savePermanentUploadFailures(_ map: [String: UploadFailureRecord]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: permanentUploadFailureKey)
        }
    }

    /// True if `filename` (at its current `size`) has already failed with a
    /// non-retriable client error enough times to stop retrying automatically.
    private static func shouldSkipPermanentlyFailedUpload(filename: String, size: Int) -> Bool {
        guard let record = loadPermanentUploadFailures()[filename], record.size == size else { return false }
        return record.attempts >= 3
    }

    /// Records one non-retriable failure for `filename` at its current `size`
    /// — resets the attempt count first if the file's size changed since the
    /// last recorded failure (a different file at that path deserves a fresh
    /// try, not to inherit an unrelated file's failure count).
    private static func recordPermanentUploadFailure(filename: String, size: Int) {
        var map = loadPermanentUploadFailures()
        let previousAttempts = map[filename]?.size == size ? map[filename]?.attempts ?? 0 : 0
        map[filename] = UploadFailureRecord(size: size, attempts: previousAttempts + 1)
        savePermanentUploadFailures(map)
    }

    /// Uploads any locally-stored songs that aren't yet in the user's cloud
    /// library — covers files added via import/scan/folder-watch, not just the
    /// "download from search" path that originally drove auto-backup. Apple
    /// Music library items (no readable file URL) are skipped; they can't be
    /// read off disk directly.
    ///
    /// Runs at low priority and pauses between uploads so a large library catch-up
    /// doesn't compete with foreground playback, streaming, or UI responsiveness —
    /// callers should fire-and-forget this from a scan/import completion handler
    /// when Auto-Backup is enabled.
    func backUpLibraryIfNeeded(songs: [Song], token: String) {
        guard !isSyncingLibraryBackup else { return }
        let localSongs = songs.filter { $0.url?.isFileURL == true }
        guard !localSongs.isEmpty else { return }

        isSyncingLibraryBackup = true
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            defer { self.isSyncingLibraryBackup = false }

            // Compare against what the server already has so re-runs (e.g. after
            // every scan) only ever upload genuinely new files.
            guard let existing = try? await self.fetchUserMusicMetadata(token: token, maxAge: 30) else { return }
            let existingByOriginalName = Dictionary(
                existing.compactMap { track -> (String, UserMusicMetadataTrack)? in
                    guard let name = track.originalFilename else { return nil }
                    return (name, track)
                },
                uniquingKeysWith: { first, _ in first }
            )

            let pending = localSongs.filter { song in
                guard let name = song.url?.lastPathComponent else { return false }
                return existingByOriginalName[name] == nil
            }

            // Retroactive fix, independent of `pending`: a Lumisound-locked
            // upload's has_artwork was hardcoded false server-side for a
            // while (the server can't ffprobe locked bytes to check itself —
            // see _locked_inner_ext's doc comment) — patch already-backed-up
            // tracks whose local copy actually has embedded art but whose
            // server record still says it doesn't, without re-uploading the
            // whole file. Best-effort and cheap (a metadata-only PATCH), so
            // this just runs alongside the real upload pass below rather
            // than needing its own opt-in.
            for song in localSongs {
                guard !Task.isCancelled, let url = song.url, let name = url.lastPathComponent as String?,
                      let record = existingByOriginalName[name], !record.hasArtwork,
                      FileManager.default.fileExists(atPath: url.path)
                else { continue }
                guard await LumisoundExclusiveExtensionService.hasEmbeddedThumbnailTag(fileURL: url) else { continue }
                do {
                    _ = try await self.patchArtworkFlag(filename: record.filename, hasArtwork: true, token: token)
                } catch {
                    appWarn("backUpLibraryIfNeeded: has_artwork patch failed for \"\(record.filename)\": \(error.localizedDescription)", category: "network")
                }
            }

            guard !pending.isEmpty else { return }
            appLog("backUpLibraryIfNeeded: backing up \(pending.count) local song(s)", category: "network")

            for song in pending {
                guard !Task.isCancelled, let url = song.url else { return }
                // `pending` is a one-time snapshot, but this loop can run for
                // a genuinely long time (1.5s/song × a several-thousand-song
                // backlog is over an hour) — long enough for the periodic
                // lock-conversion pass or a corrupt-file cleanup elsewhere in
                // the app to rename/remove a file this snapshot still points
                // at by the time we get to it. Without this check, that
                // showed up as a confusing "unlock failed"/"could not read"
                // warning pair for every such song (the file genuinely wasn't
                // there — "no such file", not a decode/corruption failure) —
                // skip quietly instead of burning a read attempt on a path
                // that's already gone; the next scan's fresh snapshot will
                // pick up wherever the file actually ended up now (e.g. under
                // its post-lock `.lms` name) on its own.
                guard FileManager.default.fileExists(atPath: url.path) else {
                    appLog("backUpLibraryIfNeeded: skipping \"\(song.displayName)\" — file no longer at its scanned path (likely renamed/removed since)", category: "network")
                    continue
                }
                let fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
                guard !Self.shouldSkipPermanentlyFailedUpload(filename: url.lastPathComponent, size: fileSize) else {
                    continue
                }
                let metadata = TrackMetadata(
                    title: song.title.isEmpty ? nil : song.title,
                    artist: song.artist.isEmpty ? nil : song.artist,
                    album: song.album.isEmpty ? nil : song.album,
                    genre: song.genre.isEmpty ? nil : song.genre,
                    year: song.year.isEmpty ? nil : song.year,
                    durationSeconds: song.duration > 0 ? song.duration : nil,
                    bitrate: song.bitrate > 0 ? song.bitrate : nil,
                    sampleRate: song.sampleRate > 0 ? song.sampleRate : nil,
                    hasArtwork: await LumisoundExclusiveExtensionService.hasEmbeddedThumbnailTag(fileURL: url)
                )
                do {
                    _ = try await self.uploadTrack(fileURL: url, token: token, metadata: metadata)
                } catch {
                    appWarn("backUpLibraryIfNeeded: upload failed for \"\(song.displayName)\": \(error.localizedDescription)", category: "network")
                    // 4xx means the server rejected THIS request as malformed
                    // (bad filename/extension, empty body, ...) — retrying the
                    // exact same bytes under the exact same name will never
                    // produce a different outcome, unlike a 5xx/timeout/network
                    // error, which genuinely might. See this file's
                    // permanent-failure-guard comment above for why this needs
                    // tracking at all.
                    //
                    // Two-step unwrap (not `if case .httpError(let code) =
                    // error as? StreamingError`) — matching a bare case
                    // pattern directly against an `as?` cast requires the
                    // pattern to be written `.httpError(let code)?` (or
                    // `.some(.httpError(let code))`); without that, Swift
                    // treats it as matching the non-optional `StreamingError`
                    // and fails to compile. Same two-step shape NetworkRetry
                    // already uses for this identical enum.
                    if let streamingError = error as? StreamingError,
                       case .httpError(let code) = streamingError,
                       (400..<500).contains(code) {
                        Self.recordPermanentUploadFailure(filename: url.lastPathComponent, size: fileSize)
                    }
                }
                // Throttle — keeps this from saturating the network/CPU during a
                // big catch-up so foreground playback and streaming stay smooth.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            appLog("backUpLibraryIfNeeded: finished", category: "network")
        }
    }
}
