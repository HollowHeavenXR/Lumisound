import Foundation

/// Applying an account sync (the plan comes from the Rust core's
/// `syncMergePlan`). Everything here is silent and writes once: it runs on
/// every launch, foreground and live "sync_changed" event, and nothing in it
/// is the user's own action on this device — so no toasts, and no per-item
/// requests back to the server (the next push carries the result).
extension LibraryManager {

    func applySyncedFavorites(add: Set<String>, remove: Set<String>) {
        var next = favoriteSongIDs
        next.formUnion(add)
        next.subtract(remove)
        guard next != favoriteSongIDs else { return }
        favoriteSongIDs = next
        persistence.saveFavorites(next)
        appLog("sync: favorites +\(add.count) -\(remove.count)", category: "library")
    }

    func applySyncedPlaylists(create: [MergePlaylist], update: [MergePlaylist], removeLocalIDs: [String]) {
        guard !(create.isEmpty && update.isEmpty && removeLocalIDs.isEmpty) else { return }
        var next = playlists
        let gone = Set(removeLocalIDs.map { $0.uppercased() })
        if !gone.isEmpty {
            // Deleted on another device: into Recently Deleted here too, so
            // a deletion made by mistake elsewhere can still be undone.
            for playlist in next where gone.contains(playlist.id.uuidString.uppercased()) {
                DeletedPlaylistsStore.shared.trash(playlist)
            }
            next.removeAll { gone.contains($0.id.uuidString.uppercased()) }
        }
        for change in update {
            guard let index = next.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(change.localId) == .orderedSame }) else { continue }
            next[index].name = change.name
            next[index].songIDs = change.songIds
        }
        for made in create {
            let id = UUID(uuidString: made.localId) ?? UUID()
            guard !next.contains(where: { $0.id == id }) else { continue }
            next.append(Playlist(id: id, name: made.name, songIDs: made.songIds, createdAt: Date(),
                                 folder: made.folder, tags: made.tags))
        }
        playlists = next
        persistence.savePlaylists(next)
        appLog("sync: playlists +\(create.count) ~\(update.count) -\(removeLocalIDs.count)", category: "library")
    }
}
