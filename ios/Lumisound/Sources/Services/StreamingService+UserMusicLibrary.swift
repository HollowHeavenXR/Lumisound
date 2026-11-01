import Foundation
import UIKit

extension StreamingService {

    // MARK: - User Music Library (personal per-user server storage)

    /// Returns the stream URL for a user music track (requires JWT token).
    func userMusicStreamURL(for track: UserMusicTrack, token: String) -> URL? {
        guard let encoded = track.serverPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let base = bridgeURL.trimmingCharacters(in: .init(charactersIn: "/"))
        return URL(string: "\(base)/user/music/stream?path=\(encoded)")
    }

    /// Returns the artwork URL for a user music track (requires JWT token).
    func userMusicArtworkURL(for track: UserMusicTrack) -> URL? {
        guard track.hasArtwork,
              let encoded = track.serverPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let base = bridgeURL.trimmingCharacters(in: .init(charactersIn: "/"))
        return URL(string: "\(base)/user/music/artwork?path=\(encoded)")
    }

    /// Wraps a `UserMusicTrack` in a `Song` for playback.
    ///
    /// NOTE: for a Lumisound-locked track (`userMusicTrack.isLocked`) this
    /// hands back the raw (still-masked, not decodable) stream URL as-is —
    /// use `toPlayableSong(userMusicTrack:token:)` instead for anything
    /// that's actually about to play immediately. This synchronous version
    /// stays cheap/instant specifically so it's still safe to `.map` over an
    /// entire cloud library (e.g. building an up-next queue) without an
    /// eager download-and-unlock pass per locked track. KNOWN GAP: skipping
    /// forward/backward through a queue built this way will fail to decode
    /// when it lands on a locked track — only the track actually handed to
    /// `toPlayableSong` at play-time is guaranteed playable. Fixing that
    /// fully means teaching `AudioPlayerManager`'s queue-advance path itself
    /// to resolve locked cloud tracks JIT (the same pattern
    /// `LumisoundExclusiveExtensionService.prewarmPlayableURL` already uses
    /// for local files) — deferred; out of scope for the single-track fix.
    func toSong(userMusicTrack: UserMusicTrack, token: String) -> Song {
        let streamURL = userMusicStreamURL(for: userMusicTrack, token: token)
        let artworkKey = userMusicArtworkURL(for: userMusicTrack)?.absoluteString
        return Song(
            id: userMusicTrack.id,
            title: userMusicTrack.title,
            artist: userMusicTrack.artist,
            album: userMusicTrack.album,
            duration: userMusicTrack.duration,
            url: streamURL,
            persistentID: nil,
            artworkCacheKey: artworkKey,
            trackNumber: Int(userMusicTrack.trackNumber) ?? 0,
            year: "",
            genre: userMusicTrack.genre,
            bitrate: 0,
            sampleRate: 0,
            httpHeaders: ["Authorization": "Bearer \(token)"],
            bpm: userMusicTrack.bpm,
            transitionProfile: userMusicTrack.transitionProfile,
            spectralProfile: userMusicTrack.spectralProfile
        )
    }

    /// Same as `toSong(userMusicTrack:token:)`, except a locked track is
    /// downloaded and unlocked to a local temp file FIRST (see
    /// `LumisoundLockFormat`'s header comment for why: its on-server bytes
    /// are XOR-masked and not a decodable audio container to AVFoundation
    /// until reversed — exactly like a local `.lms` file, which this app
    /// only ever plays via `LumisoundExclusiveExtensionService.playableURL`,
    /// never the raw locked bytes directly). Use this for the track that's
    /// actually about to start playing; use the cheap synchronous version
    /// for building a queue/list.
    func toPlayableSong(userMusicTrack: UserMusicTrack, token: String) async -> Song {
        guard userMusicTrack.isLocked,
              let localURL = await resolveLockedUserMusicURL(for: userMusicTrack, token: token)
        else {
            return toSong(userMusicTrack: userMusicTrack, token: token)
        }
        let artworkKey = userMusicArtworkURL(for: userMusicTrack)?.absoluteString
        return Song(
            id: userMusicTrack.id,
            title: userMusicTrack.title,
            artist: userMusicTrack.artist,
            album: userMusicTrack.album,
            duration: userMusicTrack.duration,
            url: localURL,
            persistentID: nil,
            artworkCacheKey: artworkKey,
            trackNumber: Int(userMusicTrack.trackNumber) ?? 0,
            year: "",
            genre: userMusicTrack.genre,
            bitrate: 0,
            sampleRate: 0,
            httpHeaders: [:],   // local file — no auth header needed
            bpm: userMusicTrack.bpm,
            transitionProfile: userMusicTrack.transitionProfile,
            spectralProfile: userMusicTrack.spectralProfile
        )
    }

    /// Downloads a Lumisound-locked cloud track's full bytes and unlocks them
    /// to a local temp file, returning its URL — or `nil` on any failure
    /// (network error, non-2xx response, or an unlock failure). Cached at a
    /// stable path keyed by the track's id, so repeat plays of the same
    /// track don't re-download+re-unlock every time — mirrors
    /// `LumisoundExclusiveExtensionService.playableURL`'s own caching
    /// strategy for local files. Full-file, not incremental streaming —
    /// same as how that function's own `LumisoundLockFormat.unlock` already
    /// works for local files (XOR needs the whole payload up front), so this
    /// isn't a new architectural tradeoff, just the same one over the network.
    func resolveLockedUserMusicURL(for track: UserMusicTrack, token: String) async -> URL? {
        guard track.isLocked, let remoteURL = userMusicStreamURL(for: track, token: token) else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumisound_cloud_lms_playable", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheName = track.id.isEmpty ? track.serverPath : track.id
        let realExt = track.ext.isEmpty ? "m4a" : track.ext
        let outURL = dir.appendingPathComponent(cacheName).appendingPathExtension(realExt)
        if fm.fileExists(atPath: outURL.path) {
            return outURL
        }

        var request = URLRequest(url: remoteURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let data: Data
        do {
            let (responseData, response) = try await Core.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                appWarn("resolveLockedUserMusicURL: bad response for \(track.filename)", category: "network")
                return nil
            }
            data = responseData
        } catch {
            appWarn("resolveLockedUserMusicURL: download failed for \(track.filename): \(error.localizedDescription)", category: "network")
            return nil
        }

        let lockedTempURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(LumisoundExclusiveExtensionService.marker)
        defer { try? fm.removeItem(at: lockedTempURL) }
        do {
            try data.write(to: lockedTempURL, options: .atomic)
        } catch {
            appWarn("resolveLockedUserMusicURL: write failed for \(track.filename): \(error.localizedDescription)", category: "network")
            return nil
        }
        guard LumisoundLockFormat.unlock(lockedURL: lockedTempURL, to: outURL) else {
            appWarn("resolveLockedUserMusicURL: unlock failed for \(track.filename)", category: "network")
            return nil
        }
        return outURL
    }

    /// Returns the stream URL for a weekly-mix track (requires JWT token) —
    /// same construction as `userMusicStreamURL(for:)`, just keyed off
    /// `relativePath` instead of `UserMusicTrack.serverPath` (the bridge's
    /// `/user/music/stream` endpoint takes the same kind of relative path
    /// either way, it just comes from a different source table).
    func weeklyMixStreamURL(for track: WeeklyMixTrack, token: String) -> URL? {
        guard let encoded = track.relativePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let base = bridgeURL.trimmingCharacters(in: .init(charactersIn: "/"))
        return URL(string: "\(base)/user/music/stream?path=\(encoded)")
    }

    /// Returns the artwork URL for a weekly-mix track (requires JWT token).
    func weeklyMixArtworkURL(for track: WeeklyMixTrack) -> URL? {
        guard track.hasArtwork,
              let encoded = track.relativePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let base = bridgeURL.trimmingCharacters(in: .init(charactersIn: "/"))
        return URL(string: "\(base)/user/music/artwork?path=\(encoded)")
    }

    /// Wraps a `WeeklyMixTrack` in a `Song` for playback.
    func toSong(weeklyMixTrack track: WeeklyMixTrack, token: String) -> Song {
        Song(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: 0,
            url: weeklyMixStreamURL(for: track, token: token),
            persistentID: nil,
            artworkCacheKey: weeklyMixArtworkURL(for: track)?.absoluteString,
            trackNumber: 0,
            year: "",
            genre: "",
            bitrate: 0,
            sampleRate: 0,
            httpHeaders: ["Authorization": "Bearer \(token)"],
            bpm: track.bpm
        )
    }

    /// Fetches this user's personalized weekly mix from
    /// `GET /user/music/weekly-mix`, publishing it on `weeklyMix`. Silent
    /// no-op on failure, same "nice to have, not worth an error banner"
    /// reasoning as `fetchStorageUsage(token:)` — the Home hub just omits
    /// the Weekly Mix card entirely when this hasn't populated anything.
    func fetchWeeklyMix(token: String) async {
        guard var request = makeRequest("/user/music/weekly-mix") else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await Core.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                appWarn("fetchWeeklyMix: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)", category: "network")
                return
            }
            struct Response: Decodable { let tracks: [WeeklyMixTrack] }
            weeklyMix = try JSONDecoder().decode(Response.self, from: data).tracks
        } catch {
            appWarn("fetchWeeklyMix: \(error.localizedDescription)", category: "network")
        }
    }

    /// Fetches this account's Personal Cloud Library storage usage/quota from
    /// `GET /user/storage/usage`, publishing it on `storageUsage`. Silent no-op
    /// on failure (leaves whatever was previously loaded, if anything) — this
    /// is a "nice to have" stat, not worth an error banner over.
    func fetchStorageUsage(token: String) async {
        guard var request = makeRequest("/user/storage/usage") else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await Core.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                appWarn("fetchStorageUsage: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)", category: "network")
                return
            }
            storageUsage = try JSONDecoder().decode(StorageUsage.self, from: data)
        } catch {
            appWarn("fetchStorageUsage: \(error.localizedDescription)", category: "network")
        }
    }

    /// Fetches the user's personal music library from the server.
    func fetchUserMusic(token: String, search: String = "") async {
        appLog("fetchUserMusic: search=\"\(search)\"", category: "network")
        isLoadingUserMusic = true
        errorMessage = nil
        defer { isLoadingUserMusic = false }

        var components = URLComponents()
        components.path = "/user/music"
        components.queryItems = [
            // No 500-item cap on the user's cloud library (server allows up to 100k).
            URLQueryItem(name: "limit", value: "100000"),
        ]
        if !search.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "search", value: search))
        }

        guard var request = makeRequest(components.string ?? "/user/music") else {
            errorMessage = "Invalid bridge URL."
            return
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The first request after a library change has to ffprobe every
        // uncached file server-side before it can respond — with a large
        // personal library this routinely took longer than the old 20s
        // timeout, which made "My Library" appear to hang/fail forever even
        // though the server was still working (and would have served a fast,
        // cached response on the next try). 90s gives that cold pass room to
        // finish; subsequent calls hit the server's ffprobe cache and return
        // quickly regardless.
        request.timeoutInterval = 90

        do {
            let (data, response) = try await Core.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                appWarn("fetchUserMusic: HTTP \(httpResponse.statusCode)", category: "network")
                if httpResponse.statusCode == 401 {
                    errorMessage = "Your session has expired. Please log in again."
                } else {
                    errorMessage = "Streaming service error (HTTP \(httpResponse.statusCode)). Please try again later."
                }
                return
            }

            struct Response: Decodable {
                let tracks: [UserMusicTrack]
                let total: Int
                let configured: Bool
                /// Median tonal shape of the whole library — what Auto EQ
                /// corrects toward. Nil until enough tracks are analysed for a
                /// median to mean anything.
                let eq_target: [Double]?
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            if !decoded.configured {
                errorMessage = "User music storage is not configured on the server."
                userMusicTracks = []
            } else {
                userMusicTracks = decoded.tracks
                if let target = decoded.eq_target, target.count == 10 {
                    AudioSettings.libraryEQTarget = target
                }
                appLog("fetchUserMusic: \(decoded.tracks.count) tracks", category: "network")
            }
        } catch {
            appError("fetchUserMusic: \(error.localizedDescription)", category: "network")
            errorMessage = "Failed to load your library: \(error.localizedDescription)"
        }
    }

    /// Fetches the tracks this account has downloaded before (server-side
    /// history), optionally filtered by `search`. Used by "My Library" search
    /// to surface tracks the user has ever had — even ones no longer present
    /// on this device — and by the "previously downloaded" restore list.
    func fetchDownloadHistory(token: String, search: String = "") async {
        appLog("fetchDownloadHistory: search=\"\(search)\"", category: "network")
        isLoadingDownloadHistory = true
        defer { isLoadingDownloadHistory = false }

        var components = URLComponents()
        components.path = "/user/download-history"
        components.queryItems = [URLQueryItem(name: "limit", value: "200")]
        if !search.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "search", value: search))
        }

        guard var request = makeRequest(components.string ?? "/user/download-history") else {
            return
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await Core.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                appWarn("fetchDownloadHistory: HTTP \(httpResponse.statusCode)", category: "network")
                return
            }
            struct Response: Decodable {
                let tracks: [DownloadHistoryTrack]
                let total: Int
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            downloadHistory = decoded.tracks
            appLog("fetchDownloadHistory: \(decoded.tracks.count) tracks", category: "network")
        } catch {
            appError("fetchDownloadHistory: \(error.localizedDescription)", category: "network")
        }
    }

    /// Uploads a local audio file to the user's personal music library on the server.
    func uploadToUserLibrary(fileURL: URL, token: String, folder: String = "") async throws {
        appLog("uploadToUserLibrary: \(fileURL.lastPathComponent)", category: "network")
        isUploadingUserMusic = true
        uploadProgress = 0
        defer { isUploadingUserMusic = false; uploadProgress = 0 }

        let filename = fileURL.lastPathComponent
        var components = URLComponents()
        components.path = "/user/music/upload"
        components.queryItems = [
            URLQueryItem(name: "filename", value: filename),
        ]
        if !folder.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "folder", value: folder))
        }

        guard var request = makeRequest(components.string ?? "/user/music/upload") else {
            throw StreamingError.invalidURL
        }
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300   // 5 min for large files

        // Use URLSession.upload(for:fromFile:) instead of loading the whole file into memory.
        // This streams the file directly from disk, critical for large audio files.
        let (_, response) = try await Core.upload(for: request, fromFile: fileURL)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 413: throw StreamingError.httpError(413)
            default: throw StreamingError.httpError(http.statusCode)
            }
        }
        appLog("uploadToUserLibrary: uploaded \(filename)", category: "network")
    }

    /// Deletes a file from the user's personal music library on the server.
    func deleteUserMusic(path: String, token: String) async throws {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard var request = makeRequest("/user/music/\(encoded)") else {
            throw StreamingError.invalidURL
        }
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (_, response) = try await Core.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StreamingError.httpError(http.statusCode)
        }
        appLog("deleteUserMusic: deleted \(path)", category: "network")
    }
}
