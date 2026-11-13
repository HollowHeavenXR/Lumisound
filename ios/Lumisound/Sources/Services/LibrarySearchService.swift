import Foundation

/// The library search engine (rust/core/src/search.rs) kept in step with the
/// library. Indexing and every query run off the main thread; the index is
/// rebuilt (debounced) when songs, playlists or play counts change, and the
/// Lyrics folder is read once the songs are in.
@MainActor
final class LibrarySearchService: ObservableObject {
    static let shared = LibrarySearchService()

    nonisolated let engine = LibrarySearch()
    @Published private(set) var lyricsIndexed: Int = 0
    @Published private(set) var isIndexed = false

    private var indexedSignature = ""
    private var pending: Task<Void, Never>?
    private var lyricsLoaded = false

    private init() {}

    /// Reindexes when the library changed (cheap no-op otherwise).
    func refresh(from library: LibraryManager, immediately: Bool = false) {
        let songs = library.allSongs
        let playlists = library.playlists
        let signature = "\(songs.count)|\(songs.first?.id ?? "")|\(songs.last?.id ?? "")|\(playlists.count)|\(playlists.reduce(0) { $0 &+ $1.songIDs.count })"
        guard signature != indexedSignature else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            guard !Task.isCancelled, let self else { return }
            let history = PlayHistoryStore.shared.entries
            let favorites = Set(songs.lazy.filter { library.isFavorite(songID: $0.id) }.map(\.id))
            let inputs = songs.map { s in
                SearchSongInput(id: s.id, title: s.displayName, artist: s.artistName, album: s.albumName,
                                genre: s.genre, plays: UInt32(clamping: history[s.id]?.playCount ?? 0),
                                favorite: favorites.contains(s.id))
            }
            let lists = playlists.map { SearchPlaylistInput(id: $0.id.uuidString, name: $0.name, songIds: $0.songIDs) }
            let engine = self.engine
            let loadLyrics = !self.lyricsLoaded
            let lyricsDir = Self.lyricsDirectory.path
            let lyricCount: UInt32? = await Task.detached(priority: .utility) {
                engine.setLibrary(songs: inputs, playlists: lists)
                return loadLyrics ? engine.loadLyrics(dir: lyricsDir) : nil
            }.value
            guard !Task.isCancelled else { return }
            self.indexedSignature = signature
            self.isIndexed = true
            if let lyricCount {
                self.lyricsLoaded = true
                self.lyricsIndexed = Int(lyricCount)
                self.lyricsStamp = (try? Self.lyricsDirectory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            } else {
                self.reloadLyricsIfChanged()
            }
        }
    }

    private var lyricsStamp: Date?

    /// Re-reads the Lyrics folder when anything in it changed since the last
    /// read (saving a file renames it into the folder, which moves the
    /// folder's modification date). Lyrics are written from several places
    /// (fetch, import, editor, auto-sync), so this watches the folder
    /// rather than each writer.
    func reloadLyricsIfChanged() {
        guard isIndexed else { return }
        let dir = Self.lyricsDirectory
        let stamp = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard stamp != lyricsStamp else { return }
        lyricsStamp = stamp
        let engine = engine
        Task.detached(priority: .utility) {
            let n = engine.loadLyrics(dir: dir.path)
            await MainActor.run { self.lyricsIndexed = Int(n); self.lyricsLoaded = true }
        }
    }

    nonisolated func search(_ text: String, lyrics: Bool = true) async -> SearchResults {
        let engine = engine
        return await Task.detached(priority: .userInitiated) {
            engine.query(text: text, includeLyrics: lyrics)
        }.value
    }

    nonisolated static var lyricsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
    }
}
