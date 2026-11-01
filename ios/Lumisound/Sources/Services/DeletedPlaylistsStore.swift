import Foundation

/// A 30-day safety net for deleted playlists — same retention window and
/// general shape as `RecentlyDeletedService` (downloaded tracks), but much
/// simpler: a `Playlist` is just metadata (name, song ID references), not
/// a file on disk, so "trashing" one is just keeping a copy of the struct
/// around for a while rather than moving anything. `LibraryManager
/// .deletePlaylist` trashes here before removing from `playlists`.
struct DeletedPlaylistEntry: Codable, Identifiable {
    let id: UUID
    let playlist: Playlist
    let deletedAt: Date
}

@MainActor
final class DeletedPlaylistsStore: ObservableObject {
    static let shared = DeletedPlaylistsStore()

    private static let retentionDays: TimeInterval = 30
    private let key = "deletedPlaylists.v1"

    @Published private(set) var entries: [DeletedPlaylistEntry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key) { trashImportLegacy(json: data) }
        reload()
    }

    /// The trash and its 30-day retention live in the Rust core; this is a
    /// published mirror for the Recently Deleted screen.
    private func reload() {
        entries = trashEntries().compactMap { e in
            guard let id = UUID(uuidString: e.id), let data = e.playlistJson.data(using: .utf8),
                  let playlist = try? JSONDecoder().decode(Playlist.self, from: data) else { return nil }
            return DeletedPlaylistEntry(id: id, playlist: playlist, deletedAt: Date(timeIntervalSince1970: e.deletedAt))
        }
    }

    func trash(_ playlist: Playlist) {
        guard let data = try? JSONEncoder().encode(playlist), let json = String(data: data, encoding: .utf8) else { return }
        _ = trashAdd(playlistJson: json)
        reload()
    }

    func restore(entryID: DeletedPlaylistEntry.ID) -> Playlist? {
        let playlist = entries.first { $0.id == entryID }?.playlist
        _ = trashTake(entryId: entryID.uuidString)
        reload()
        return playlist
    }

    func purge(entryID: DeletedPlaylistEntry.ID) {
        _ = trashTake(entryId: entryID.uuidString)
        reload()
    }

    func purgeAll() {
        trashPurgeAll()
        reload()
    }

    func purgeExpired() { reload() }
}
