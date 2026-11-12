import Foundation

/// Applies Duplicate Engine clean-ups to the library. The engine plans the
/// merge (`dupeMergePlan`: favorites and playlist places move to the kept
/// copy) and keeps the undo journal; this moves files to Recently Deleted
/// and updates the library's own records.
extension LibraryManager {

    private func dupePlaylists() -> [DupePlaylist] {
        playlists.map { DupePlaylist(id: $0.id.uuidString, songIds: $0.songIDs) }
    }

    private func applyDupePlaylists(_ changed: [DupePlaylist]) {
        guard !changed.isEmpty else { return }
        for p in changed {
            guard let i = playlists.firstIndex(where: { $0.id.uuidString == p.id }) else { continue }
            playlists[i].songIDs = p.songIds
        }
        persistence.savePlaylists(playlists)
    }

    /// Moves `removeIDs` to Recently Deleted and folds them into `keeperID`.
    /// Copies that are playing or queued are skipped. Returns the journal
    /// entry (nil when nothing could be moved).
    @discardableResult
    func resolveDuplicates(keeperID: String, removeIDs: [String]) -> DupeResolution? {
        guard let keeper = allSongs.first(where: { $0.id == keeperID }) else { return nil }
        let player = AudioPlayerManager.shared
        var trashed: [Song] = []
        var bytes: UInt64 = 0
        for id in removeIDs where id != keeperID {
            // Checked fresh per copy: playback may have moved on since the scan.
            if player?.currentSong?.id == id || (player?.isInActiveQueue(songID: id) ?? false) { continue }
            guard let song = importedSongs.first(where: { $0.id == id }), let url = song.url else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            guard RecentlyDeletedService.shared?.trash(song: song) ?? false else { continue }
            trashed.append(song)
            bytes += size
        }
        guard !trashed.isEmpty else { return nil }

        let stats = { (s: Song) in
            DupeCopyStats(songId: s.id, isFavorite: self.isFavorite(songID: s.id), playCount: UInt32(max(0, self.playCount(for: s.id))))
        }
        let keeperWasFavorite = isFavorite(songID: keeper.id)
        let plan = dupeMergePlan(keeper: stats(keeper), losers: trashed.map(stats), playlists: dupePlaylists())

        let gone = Set(trashed.map(\.id))
        importedSongs.removeAll { gone.contains($0.id) }
        var favorites = favoriteSongIDs.subtracting(gone)
        if plan.keeperFavorite { favorites.insert(keeper.id) }
        favoriteSongIDs = favorites
        persistence.saveFavorites(favoriteSongIDs)
        applyDupePlaylists(plan.playlists)
        rebuildAllSongs()

        let entry = dupeJournalRecord(keeperId: keeper.id, keeperTitle: keeper.displayName, keeperWasFavorite: keeperWasFavorite,
                                      extraPlays: plan.extraPlays, removed: plan.removed, bytes: bytes)
        appLog("Duplicates: kept \"\(keeper.displayName)\", moved \(trashed.count) cop\(trashed.count == 1 ? "y" : "ies") to Recently Deleted", category: "library")
        return entry
    }

    /// Restores a clean-up's copies from Recently Deleted and puts them back
    /// in their playlists and favorites. Returns how many came back.
    func undoDuplicateResolution(_ r: DupeResolution) -> Int {
        var restored: [String] = []
        var favorites = favoriteSongIDs
        for removed in r.removed {
            guard let song = RecentlyDeletedService.shared?.restore(entryID: removed.songId) else { continue }
            readdRestoredSong(song)
            restored.append(song.id)
            if removed.wasFavorite { favorites.insert(song.id) }
        }
        guard !restored.isEmpty else {
            dupeJournalRemove(id: r.id)
            return 0
        }
        // The keeper only became a favorite through the merge: undo that too.
        if !r.keeperWasFavorite, restored.count == r.removed.count { favorites.remove(r.keeperId) }
        favoriteSongIDs = favorites
        persistence.saveFavorites(favoriteSongIDs)
        applyDupePlaylists(dupeUndoPlaylists(resolution: r, restored: restored, playlists: dupePlaylists()))
        rebuildAllSongs()
        dupeJournalRemove(id: r.id)
        appLog("Duplicates: undid clean-up of \"\(r.keeperTitle)\" (\(restored.count) restored)", category: "library")
        return restored.count
    }
}
