import Foundation
import SwiftUI
import UIKit

extension AccountService {

    // MARK: - Sync

    /// Call schedulePush instead of this directly — it debounces rapid mutations.
    ///
    /// Payload shape and the push gate are the Rust core's (`sync.rs`); this
    /// gathers the device state it needs: favourites, playlists resolved
    /// against the library, the synced UserDefaults keys and store blobs.
    func pushSync(
        library: LibraryManager,
        audioSettings: AudioSettings? = nil,
        trackAudioSettings: [String: AudioSettings]? = nil
    ) async {
        guard isLoggedIn else { return }
        // The server REPLACES favourites and playlist tracks with what a push
        // carries, and playlists resolve against the loaded library — so an
        // early push would wipe them server-side.
        guard syncShouldPush(libraryLoaded: !library.allSongs.isEmpty,
                             favoriteCount: UInt32(library.favoriteSongIDs.count),
                             hasNonemptyPlaylist: library.playlists.contains { !$0.songIDs.isEmpty }) else {
            appLog("Push sync skipped — library not loaded yet", category: "account")
            return
        }
        appLog("Push sync started (favorites: \(library.favoriteSongIDs.count), playlists: \(library.playlists.count))", category: "account")
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }

        // Every favourite id, loaded or not (a favourite for a moved/renamed
        // file left out of the push was deleted server-side, then re-added on
        // every launch), plus filename-matched favourites under the library id.
        var favorites = library.favoriteSongIDs.map { id -> SyncFavoriteRec in
            let song = library.songsByID[id]
            return SyncFavoriteRec(songId: id, title: song?.title, artist: song?.artistName, album: song?.albumName)
        }
        favorites += library.favoriteSongs.map {
            SyncFavoriteRec(songId: $0.id, title: $0.title, artist: $0.artistName, album: $0.albumName)
        }
        let playlists = library.playlists.map { playlist -> SyncPlaylistRec in
            SyncPlaylistRec(
                id: playlist.id.uuidString, name: playlist.name, folder: playlist.folder, tags: playlist.tags,
                tracks: playlist.songIDs.enumerated().map { idx, id in
                    guard let song = library.songsByID[id] else {
                        // Not in the library right now (file missing, folder
                        // not scanned yet): still an entry of this playlist.
                        // Leaving it out told the server it had been removed.
                        let name = (LibraryManager.favoriteKey(for: id) as NSString).deletingPathExtension
                        return SyncTrackRec(localSongId: id, trackUrl: nil, title: name.isEmpty ? id : name,
                                            artist: nil, album: nil, durationSeconds: nil, position: Int64(idx))
                    }
                    return SyncTrackRec(localSongId: song.id, trackUrl: song.url?.absoluteString, title: song.title,
                                        artist: song.artist.isEmpty ? nil : song.artist,
                                        album: song.album.isEmpty ? nil : song.album,
                                        durationSeconds: Int64(song.duration), position: Int64(idx))
                })
        }
        func json<T: Encodable>(_ v: T?) -> String? {
            v.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        }
        let themeHex: String? = {
            guard let data = UserDefaults.standard.data(forKey: "accent_color_data"),
                  let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data)
            else { return nil }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
        }()
        let history = PlayHistoryStore.shared.entries
        let smart = SmartPlaylistStore.shared.playlists
        let tracked = TrackedPlaylistStore.shared.playlists
        let bookmarks = BookmarkStore.shared.bookmarksBySong
        let blobs = SyncBlobs(
            audioSettingsJson: json(audioSettings),
            trackAudioSettingsJson: json(trackAudioSettings),
            playHistoryJson: history.isEmpty ? nil : json(history),
            smartPlaylistsJson: smart.isEmpty ? nil : json(smart),
            trackedPlaylistsJson: tracked.isEmpty ? nil : json(tracked),
            bookmarksJson: bookmarks.isEmpty ? nil : json(bookmarks))
        let bpm = library.allSongs.compactMap { song -> BpmEntry? in
            guard let id = song.sourceTrackID, let bpm = song.bpm else { return nil }
            return BpmEntry(sourceTrackId: id, bpm: bpm)
        }
        // Merge mode: the server upserts what is sent and deletes only what
        // this device removed since its last sync (the core works that out
        // from the state it last agreed on with the server).
        let payload = syncBuildMergePayload(local: SyncLocal(
            favorites: favorites, playlists: playlists, prefs: Self.readSyncedPrefs(),
            themeHex: themeHex, earnedBadges: Array(Self.earnedBadges()), blobs: blobs, bpmBySource: bpm),
            account: currentUser?.id ?? "")

        do {
            // Retried, because the push is an idempotent upsert — the server
            // REPLACES this account's favourites and playlists with what is sent,
            // so sending it twice is indistinguishable from sending it once.
            //
            // Previously a single timeout abandoned the push entirely. Nothing was
            // permanently lost (a 20-minute safety-net timer re-pushes) but the
            // account stayed stale on every other device until it fired, and the
            // payload is tiny — 140 favourites and one playlist for the largest
            // account here — so these were ordinary network blips, not requests too
            // big to finish. Three attempts with backoff cover a blip in seconds
            // instead of twenty minutes.
            _ = try await _makeRequest("/user/sync", method: "POST", bodyData: payload, maxAttempts: 3)
            syncPushCommitted()
            lastSyncDate = Date()
            // The server broadcasts a "sync_changed" live event to every one
            // of this account's active connections after a successful push —
            // including this same device's own /ws/live socket. Without this
            // timestamp, that echo would trigger an immediate, redundant
            // pullSync of the data this device just uploaded. See
            // `handleLiveSyncChanged`.
            lastPushCompletedAt = Date()
            appLog("Push sync complete", category: "account")
        } catch let err as AccountError {
            appError("Push sync failed [\(err.statusCode)]: \(err.message)", category: "account")
            errorMessage = err.message
        } catch {
            // `schedulePush` cancels the *previous* debounce task whenever
            // called again before it fires — a URLSession request already
            // in flight from that superseded call surfaces here as
            // `URLError.cancelled`, not a real failure (the next debounced
            // call already covers it). Logging that as an error and
            // surfacing "cancelled" as errorMessage was pure noise: this one
            // pattern alone produced 500+ false-positive error-log entries
            // in a single day with nothing actually wrong. Log it quietly
            // and leave errorMessage untouched instead.
            if (error as? URLError)?.code == .cancelled {
                appLog("Push sync superseded by a newer sync (expected)", category: "account")
                return
            }
            // A transport failure that survived the retries above is reported but
            // NOT surfaced to the user. `errorMessage` has visible homes in the UI,
            // and telling someone their account failed to sync over a dropped
            // connection — which the safety-net timer will quietly fix, and which
            // they can do nothing about — is alarming without being useful. A real
            // server rejection still surfaces: that is the `AccountError` branch
            // above, where the status code means something actionable.
            let isTransport = error is URLError
            appError("Push sync error: \(error.localizedDescription)"
                     + (isTransport ? " (transient, will retry on the next sync)" : ""),
                     category: "account")
            if !isTransport {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Synced preferences (key list and types come from the core)

    /// Current values of every synced UserDefaults key that is set.
    static func readSyncedPrefs() -> [PrefEntry] {
        let d = UserDefaults.standard
        return syncPrefKeys().compactMap { k in
            guard d.object(forKey: k.key) != nil else { return nil }
            let value: PrefValue
            switch k.kind {
            case .bool: value = .bool(v: d.bool(forKey: k.key))
            case .int: value = .int(v: Int64(d.integer(forKey: k.key)))
            case .double: value = .double(v: d.double(forKey: k.key))
            case .str:
                guard let s = d.string(forKey: k.key) else { return nil }
                value = .str(v: s)
            }
            return PrefEntry(key: k.key, value: value)
        }
    }

    static func writePref(_ p: PrefEntry) {
        let d = UserDefaults.standard
        switch p.value {
        case .bool(let v): d.set(v, forKey: p.key)
        case .int(let v): d.set(Int(v), forKey: p.key)
        case .double(let v): d.set(v, forKey: p.key)
        case .str(let v): d.set(v, forKey: p.key)
        }
    }

    static func earnedBadges() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "earnedBadges"),
              let set = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
        return set
    }

    func pullSync(library: LibraryManager, player: AudioPlayerManager? = nil) async {
        guard isLoggedIn else { return }
        appLog("Pull sync started", category: "account")
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }

        do {
            let data = try await makeRequest("/user/sync")
            let defaults = UserDefaults.standard
            // Settings rules (Rust core sync.rs): only restored into unset
            // keys, badges unioned.
            let plan = try syncPullPlan(remote: data, local: SyncPullLocal(
                favoriteIds: Array(library.favoriteSongIDs),
                playlistNames: library.playlists.map(\.name),
                setKeys: syncPrefKeys().map(\.key).filter { defaults.object(forKey: $0) != nil },
                hasAudioSettings: PersistenceService.shared.loadAudioSettings() != nil,
                hasTrackAudioSettings: !PersistenceService.shared.loadTrackAudioSettings().isEmpty,
                hasAccentColor: defaults.data(forKey: "accent_color_data") != nil,
                earnedBadges: Array(Self.earnedBadges())))

            // Favourites and playlists: a three-way merge against the state
            // this device last agreed on with the server (core syncmerge.rs),
            // so a removal made on another device is a removal here too, and
            // playlist rows written by another device (under its own ids for
            // the songs) land on this library's songs. Matching runs off the
            // main thread: it indexes the whole library.
            let catalog = library.allSongs.map { song in
                CatalogTrack(id: song.id, title: song.title, artist: song.artist,
                             filename: song.url?.lastPathComponent ?? LibraryManager.favoriteKey(for: song.id),
                             trackUrl: song.sourceTrackID, durationSeconds: song.duration > 0 ? song.duration : nil)
            }
            let mergeLocal = MergeLocal(
                account: currentUser?.id ?? "",
                favoriteIds: Array(library.favoriteSongIDs),
                playlists: library.playlists.map { MergeLocalPlaylist(id: $0.id.uuidString, name: $0.name, songIds: $0.songIDs) },
                libraryLoaded: !catalog.isEmpty)
            let merge = try await Task.detached(priority: .utility) {
                try syncMergePlan(remote: data, local: mergeLocal, resolver: TrackResolver(catalog: catalog))
            }.value
            library.applySyncedFavorites(add: Set(merge.favoritesToAdd), remove: Set(merge.favoritesToRemove))
            library.applySyncedPlaylists(create: merge.playlistsToCreate, update: merge.playlistsToUpdate,
                                         removeLocalIDs: merge.playlistsToRemove)
            if merge.removalRefused {
                appWarn("Pull sync: the account lost most of its favourites; kept this device's and will push them back", category: "account")
            }
            if let json = plan.audioSettingsJson, let d = json.data(using: .utf8),
               let restored = try? JSONDecoder().decode(AudioSettings.self, from: d) {
                PersistenceService.shared.saveAudioSettings(restored)
            }
            if let json = plan.trackAudioSettingsJson, let d = json.data(using: .utf8),
               let restored = try? JSONDecoder().decode([String: AudioSettings].self, from: d), !restored.isEmpty {
                if let player { player.restorePerTrackAudioSettings(restored) }
                else { PersistenceService.shared.saveTrackAudioSettings(restored) }
            }
            if let c = plan.accent {
                AppTheme.saveAccentColor(Color(red: c.r, green: c.g, blue: c.b))
            }
            plan.prefsToSet.forEach(Self.writePref)
            if let badges = plan.mergedBadges, let encoded = try? JSONEncoder().encode(Set(badges)) {
                defaults.set(encoded, forKey: "earnedBadges")
            }
            // Re-apply gallery background settings to the live instance, or its
            // next didSet would push the stale in-memory values back up.
            BackgroundService.shared?.loadSettings()

            // Store-owned blobs: each store merges with its own policy.
            func decode<T: Decodable>(_ json: String?, as: T.Type) -> T? {
                json?.data(using: .utf8).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
            }
            if let r = decode(plan.blobs.playHistoryJson, as: [String: PlayHistoryEntry].self) { PlayHistoryStore.shared.mergeFromSync(r) }
            if let r = decode(plan.blobs.smartPlaylistsJson, as: [SmartPlaylist].self) { SmartPlaylistStore.shared.mergeFromSync(r) }
            if let r = decode(plan.blobs.trackedPlaylistsJson, as: [TrackedPlaylist].self) { TrackedPlaylistStore.shared.mergeFromSync(r) }
            if let r = decode(plan.blobs.bookmarksJson, as: [String: [TrackBookmark]].self) { BookmarkStore.shared.mergeFromSync(r) }
            if !plan.bpmBySource.isEmpty {
                let remote = Dictionary(plan.bpmBySource.map { ($0.sourceTrackId, $0.bpm) }, uniquingKeysWith: { a, _ in a })
                for song in library.allSongs {
                    guard song.bpm == nil, let id = song.sourceTrackID, let bpm = remote[id] else { continue }
                    library.storeBPM(bpm, for: song.id)
                }
            }

            lastSyncDate = Date()
            appLog("Pull sync complete (favorites: \(plan.remoteFavoriteCount), playlists: \(plan.remotePlaylistCount))", category: "account")
        } catch let err as AccountError {
            appError("Pull sync failed [\(err.statusCode)]: \(err.message)", category: "account")
            errorMessage = err.message
        } catch {
            appError("Pull sync error: \(error.localizedDescription)", category: "account")
            errorMessage = error.localizedDescription
        }
    }
}
