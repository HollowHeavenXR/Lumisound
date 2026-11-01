import Foundation
import MediaPlayer
import UIKit

extension LibraryManager {

    // MARK: - Library Snapshot (instant-on-launch cache)

    private struct LibrarySnapshot: Codable {
        let songs: [Song]
        let artists: [String]
        let albums: [String]
        let genres: [String]
        /// The locally-imported subset, persisted separately from `songs`.
        ///
        /// `songs` is the COMBINED list (media library + imported) that the UI
        /// renders, and restoring it was enough to make the library appear
        /// instantly — which is why the gap here went unnoticed. But
        /// `performLocalDocumentsScan` diffs against `importedSongs`, not
        /// `allSongs`, so leaving this unrestored meant `existingURLs` was empty
        /// on every launch and the scan's entire "only process files we haven't
        /// seen before" optimisation never engaged: all ~3,500 files were treated
        /// as new, every launch, and the full main-actor merge plus index rebuild
        /// ran each time. Field telemetry showed it plainly — `librarySize: 0`
        /// alongside `newSongs: 3546` on every single scan.
        ///
        /// Optional so a snapshot written by an older build still decodes; those
        /// simply fall back to the previous behaviour for one launch, until the
        /// next persist writes the field.
        let importedSongs: [Song]?
    }

    private static let snapshotURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("library_snapshot_v1.json")
    }()

    /// Reads the last-persisted library state so `allSongs` (and the derived
    /// facet lists) are populated moments after `LibraryManager` is
    /// constructed — before any scan has run. For a 1,100-song library the
    /// real scan can take many seconds; without this, the launch/library
    /// screens sit empty that whole time even though the user had a perfectly
    /// good library a moment ago. `scanMediaLibrary`/`scanLocalDocuments`/etc.
    /// always run after `init` and silently replace these values with fresh
    /// results once they complete (see `persistSnapshotIfSettled`).
    ///
    /// The file read + JSON decode — real work for a several-thousand-song
    /// library — run off the main actor in a `Task.detached`; only the final
    /// `@Published` assignment touches the main actor. This USED to run
    /// fully synchronously and get called directly from `init()`, which
    /// SwiftUI invokes (via `@StateObject`) before the very first frame can
    /// render — for a big library, that synchronous decode was slow enough
    /// to visibly freeze the launch screen's supposedly-continuous
    /// animations for its duration, the opposite of the "instant" library
    /// this feature exists to provide. Callers should fire this from a
    /// `Task`, not await it inline where a blocked launch screen would
    /// matter.
    func loadPersistedSnapshot() async {
        let path = Self.snapshotURL.path
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL.path ?? ""
        // Read, re-anchor to the current container and group in the Rust
        // core; only the Song view models are decoded here.
        let restored: (snapshot: LibrarySnapshot,
                       byID: [String: Song],
                       byArtist: [String: [Song]],
                       byAlbum: [String: [Song]],
                       byGenre: [String: [Song]])? = await Task.detached(priority: .userInitiated) {
            guard let load = librarySnapshotLoad(path: path, documentsDir: docs),
                  let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: load.snapshotJson),
                  !snapshot.songs.isEmpty
            else { return nil }
            let byID = Dictionary(snapshot.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            func dict(_ groups: [SongGroup]) -> [String: [Song]] {
                Dictionary(groups.map { ($0.key, $0.songIds.compactMap { byID[$0] }) }, uniquingKeysWith: { a, b in a + b })
            }
            return (snapshot: snapshot, byID: byID,
                    byArtist: dict(load.byArtist), byAlbum: dict(load.byAlbum), byGenre: dict(load.byGenre))
        }.value
        guard let restored else { return }
        let snapshot = restored.snapshot
        songsByID = restored.byID
        songsByArtist = restored.byArtist
        songsByAlbum = restored.byAlbum
        songsByGenre = restored.byGenre
        allSongs = snapshot.songs
        artists = snapshot.artists
        albums = snapshot.albums
        genres = snapshot.genres
        if let imported = snapshot.importedSongs, importedSongs.isEmpty {
            importedSongs = imported
            appLog("Restored \(imported.count) imported song(s) from snapshot — scan will diff against these rather than treating every file as new",
                   category: "library")
        }
        appLog("Loaded cached library snapshot: \(snapshot.songs.count) song(s)", category: "library")
    }

    func persistSnapshotIfSettled() {
        guard !isScanning else { return }
        pendingSnapshotPersistTask?.cancel()
        Self.snapshotWritePending = true
        let sinceLastWrite = Self.lastSnapshotWriteAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(2, Self.minimumSnapshotInterval - sinceLastWrite)
        pendingSnapshotPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isScanning else { return }
            await self.writeSnapshot()
        }
    }

    /// Writes a pending snapshot now instead of waiting out the rate limit.
    /// Called when the app leaves the foreground, where a delayed write may
    /// never get to run.
    func flushPendingSnapshot() {
        guard Self.snapshotWritePending, !isScanning else { return }
        pendingSnapshotPersistTask?.cancel()
        let assertion = BackgroundTaskToken(name: "LumisoundSnapshotFlush")
        pendingSnapshotPersistTask = Task { [weak self] in
            await self?.writeSnapshot()
            assertion.end()
        }
    }

    private static let minimumSnapshotInterval: TimeInterval = 60
    private static var lastSnapshotWriteAt: Date?
    private static var snapshotWritePending = false

    private func writeSnapshot() async {
        let snapshot = LibrarySnapshot(
            songs: allSongs,
            artists: artists,
            albums: albums,
            genres: genres,
            importedSongs: importedSongs
        )
        Self.snapshotWritePending = false
        Self.lastSnapshotWriteAt = Date()
        let destination = Self.snapshotURL
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            _ = librarySnapshotSave(path: destination.path, json: data)
        }.value
    }
}
