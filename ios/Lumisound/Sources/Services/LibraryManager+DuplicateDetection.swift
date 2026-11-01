import Foundation

/// "Do we already have this track?" — the pre-download gate for tracked
/// playlists, subscriptions, search results and Download All. The matching
/// rules live in the Rust core's `LocalCopyIndex` (rust/core/src/duplicates.rs):
/// a source id ("<source>:<id>") whose file still exists (embedded tag, or the
/// vault xattr for untagged files), a download-ledger entry whose file is
/// present, or a normalized title + artist match within 2 s of duration.
///
/// Callers MUST `await scanLocalDocumentsAsync()` first so `allSongs` covers
/// every file under Imported Music and its subfolders. Build an index ONCE per
/// batch and query it per track (O(1)); per-track library scans over a big
/// playlist were the O(tracks × library) main-thread hang that tripped the
/// watchdog.
extension LibraryManager {

    private var copyIndexEntries: [LibraryEntry] {
        allSongs.compactMap { song in
            guard let url = song.url else { return nil }
            return LibraryEntry(path: url.path, sourceTrackId: song.sourceTrackID,
                                title: song.title, artist: song.artist, duration: song.duration)
        }
    }

    /// Full index (checks files on disk, reads vault tags and the download
    /// ledger), built off the main thread.
    func localCopyIndex() async -> LocalCopyIndex {
        let entries = copyIndexEntries
        return await Task.detached(priority: .utility) { LocalCopyIndex(library: entries) }.value
    }

    /// Metadata-only index (no disk access): the songs' own source ids plus
    /// title/artist/duration. Cheap enough for a synchronous view refresh.
    func metadataCopyIndex() -> LocalCopyIndex {
        LocalCopyIndex.withoutDisk(library: copyIndexEntries)
    }

    /// Normalized title/artist (+ duration) match against the library.
    func isAlreadyImported(title: String, artist: String, duration: TimeInterval? = nil) -> Bool {
        metadataCopyIndex().contains(candidate: RemoteCandidate(sourceTrackId: "", title: title, artist: artist,
                                                                duration: max(0, duration ?? 0)))
    }

    /// Single-track check. For many tracks build `localCopyIndex()` once.
    func hasLocalCopy(of track: StreamTrack) -> Bool {
        LocalCopyIndex(library: copyIndexEntries).contains(candidate: track.remoteCandidate)
    }
}

extension StreamTrack {
    var remoteCandidate: RemoteCandidate {
        RemoteCandidate(sourceTrackId: sourceTrackID, title: title, artist: artist,
                        duration: Double(max(0, durationSeconds)))
    }
}
