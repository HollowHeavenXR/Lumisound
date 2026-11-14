import Foundation
import MediaPlayer
import UIKit

extension LibraryManager {

    /// Reduces any favourite id to the part every device agrees on — the bare
    /// filename, with the "local:" scheme prefix and directory components
    /// stripped. Must stay in step with tvOS's `TVBridgeClient.favoriteKey`.
    static func favoriteKey(for songID: String) -> String {
        var s = songID
        if s.hasPrefix("local:") { s = String(s.dropFirst("local:".count)) }
        return s.split(separator: "/").last.map(String.init) ?? s
    }

    func isFavorite(songID: String) -> Bool {
        if favoriteSongIDs.contains(songID) { return true }
        // No favourites at all: skip building the filename key below, which
        // allocates — this runs for every song in `favoriteSongs` and per row.
        guard !favoriteKeyCache.isEmpty else { return false }
        // Cross-device fallback. This app ids a song by its own on-device path
        // ("local:Imported Music/<folder>/<file>"); the Apple TV sees the same
        // song as a cloud track keyed by a server-side content hash. Those are
        // never equal, so a favourite made on one device was invisible on the
        // other despite both reading the same account's list. The filename is
        // what they genuinely share — it is what this app uploads and what the
        // cloud library stores.
        let key = Self.favoriteKey(for: songID)
        guard !key.isEmpty else { return false }
        return favoriteKeyCache.contains(key)
    }

    func toggleFavorite(songID: String) {
        let nowFavorite: Bool
        if isFavorite(songID: songID) {
            // Every id that makes this song a favourite goes: its own, and
            // the ids other devices saved it under (matched by file name in
            // `isFavorite`). Removing only this device's id left a favourite
            // made on the Apple TV or an Android phone impossible to remove
            // here — the heart stayed filled, and tapping it again *added* a
            // second row.
            let key = Self.favoriteKey(for: songID)
            let same = favoriteSongIDs.filter { $0 == songID || (!key.isEmpty && Self.favoriteKey(for: $0) == key) }
            favoriteSongIDs.subtract(same)
            persistence.saveFavorites(favoriteSongIDs)
            ToastCenter.shared.show("Removed from Favorites", category: .info, icon: "heart")
            for id in same {
                AccountService.shared?.pushFavorite(songID: id, isFavorite: false, title: nil, artist: nil, album: nil)
            }
            return
        } else {
            favoriteSongIDs.insert(songID)
            nowFavorite = true
            ToastCenter.shared.show("Added to Favorites", category: .success, icon: "heart.fill")
        }
        persistence.saveFavorites(favoriteSongIDs)
        // Mirrored to the account so it survives a reinstall and reaches other
        // devices — see AccountService+Favorites. Local storage stays the
        // synchronous source of truth for rendering; this is the durable copy.
        let song = songsByID[songID]
        AccountService.shared?.pushFavorite(songID: songID, isFavorite: nowFavorite,
                                           title: song?.title, artist: song?.artist,
                                           album: song?.album)
    }

    /// Adds multiple songs to Favorites in a single persistence write/toast —
    /// used by bulk "Favorite" actions (e.g. LocalFolderDetailView's
    /// multi-select bar) instead of looping `toggleFavorite(songID:)`, which
    /// would both toast per item AND flip an already-favorited song back off
    /// (this only ever adds, never removes). Songs already favorited are
    /// silently skipped rather than counted again.
    func addFavorites(ids songIDs: Set<String>) {
        let toAdd = songIDs.subtracting(favoriteSongIDs)
        guard !toAdd.isEmpty else {
            ToastCenter.shared.show("Already in Favorites", category: .info, icon: "heart")
            return
        }
        favoriteSongIDs.formUnion(toAdd)
        persistence.saveFavorites(favoriteSongIDs)
        for songID in toAdd {
            let song = songsByID[songID]
            AccountService.shared?.pushFavorite(songID: songID, isFavorite: true,
                                               title: song?.title, artist: song?.artist,
                                               album: song?.album)
        }
        appLog("addFavorites: \(toAdd.count) song(s) added", category: "library")
        ToastCenter.shared.show(
            "Added \(toAdd.count) song\(toAdd.count == 1 ? "" : "s") to Favorites",
            category: .success, icon: "heart.fill"
        )
    }

    func songs(for playlist: Playlist) -> [Song] {
        playlist.songIDs.compactMap { songsByID[$0] }
    }

    func songs(byArtist artist: String) -> [Song] {
        songsByArtist[artist] ?? []
    }

    func songs(inAlbum album: String) -> [Song] {
        songsByAlbum[album] ?? []
    }

    func songs(inGenre genre: String) -> [Song] {
        songsByGenre[genre] ?? []
    }
}
