import Foundation

// MARK: - Favorites, tied to the account
//
// Favorites were stored ONLY in UserDefaults (`PersistenceService.saveFavorites`)
// and `/user/favorites` was never called from this app at all — the endpoint
// existed and the tvOS port had been using it, so the server already held rows
// this app could not see. That is why favorites vanished on uninstall, did not
// survive a reinstall, and did not follow the account onto another device: they
// had never left the device they were made on.
//
// Local storage stays as the source of truth for immediate reads — every row in
// the library asks `isFavorite` while rendering, and that has to be synchronous.
// The server is treated as the durable copy behind it: writes are mirrored up
// here one at a time, and `pullSync` merges the account's set back in (a
// three-way merge in the Rust core, so removals made elsewhere arrive too).
//
// There used to be a second, union-only pull here (`mergeFavoritesFromServer`)
// that also re-uploaded every local favorite the server lacked — which put
// back anything another device had just removed. `pullSync` replaces it.
extension AccountService {

    /// Mirrors a single favorite change to the account. Fire-and-forget: the
    /// local write has already happened and the UI has already updated, so a
    /// failure here must never block or reverse that.
    func pushFavorite(songID: String, isFavorite: Bool, title: String?, artist: String?, album: String?) {
        guard token != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                if isFavorite {
                    struct Body: Encodable {
                        let song_id: String
                        let title: String?
                        let artist: String?
                        let album: String?
                    }
                    _ = try await self.makeRequest(
                        "/user/favorites", method: "POST",
                        body: Body(song_id: songID, title: title, artist: artist, album: album)
                    )
                } else {
                    let encoded = songID.addingPercentEncoding(
                        withAllowedCharacters: .urlPathAllowed) ?? songID
                    _ = try await self.makeRequest("/user/favorites/\(encoded)", method: "DELETE")
                }
                // The server announces the change to every device of this
                // account, this one included; that echo needs no pull.
                self.lastPushCompletedAt = Date()
            } catch {
                appWarn("pushFavorite(\(songID), \(isFavorite)) failed: \(error.localizedDescription)",
                        category: "network")
            }
        }
    }
}

// MARK: - Lyrics

extension AccountService {
    /// Stores lyrics against the account so every device can see them.
    ///
    /// Posts to `/user/lyrics`, not the service-key-gated submit path — this
    /// carries the user's own token. Returns whether it was accepted, so a
    /// bulk migration can retry a failure on the next launch rather than
    /// marking it done.
    func submitLyrics(title: String, artist: String, syncedLyrics: String) async -> Bool {
        guard token != nil else { return false }
        struct Body: Encodable {
            let title: String
            let artist: String
            let synced_lyrics: String
        }
        do {
            _ = try await makeRequest(
                "/user/lyrics", method: "POST",
                body: Body(title: title, artist: artist, synced_lyrics: syncedLyrics)
            )
            return true
        } catch {
            appWarn("submitLyrics(\(title)) failed: \(error.localizedDescription)", category: "network")
            return false
        }
    }
}
