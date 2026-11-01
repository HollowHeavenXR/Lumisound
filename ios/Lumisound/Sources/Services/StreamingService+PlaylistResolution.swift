import Foundation
import UIKit

extension StreamingService {

    // MARK: - Playlist resolution

    /// Builds the comma-separated "source:id" manifest of tracks the user
    /// already has, from `songs` (typically `LibraryManager.allSongs`). Sent
    /// to `/api/resolve` and `/api/download` so the bridge can skip
    /// re-downloading/re-listing tracks the client already has. Only songs
    /// with a non-empty `sourceTrackID` (the `LUMISOUND_ID`-tagged downloads)
    /// can be matched this way — local-only imports have no such ID and are
    /// simply omitted from the manifest.
    ///
    /// Capped to `maxManifestBytes` (~4KB) — with a large library this string
    /// was going out uncapped as a single query param, and for libraries in
    /// the thousands of tracks it grew past Cloudflare's/the origin's request
    /// line limit, which sent back a 400 the app couldn't distinguish from
    /// any other bad request and killed EVERY download for that user, not
    /// just the dedupe check. This manifest is purely a "defense in depth"
    /// hint anyway (`/api/download` and `/api/resolve` already do the
    /// authoritative owned-track check server-side against the account's
    /// stored inventory), so silently truncating it here is safe — worst
    /// case a handful of already-owned tracks get redundantly
    /// re-checked/re-downloaded instead of the whole request failing.
    func existingTrackManifest(songs: [Song]) -> String {
        var ids = Set(songs.compactMap { song -> String? in
            guard let id = song.sourceTrackID, !id.isEmpty else { return nil }
            return id
        })
        // Also include ids from the download ledger whose files are still present.
        // This covers tracks whose embedded LUMISOUND_ID didn't round-trip (e.g.
        // older m4a downloads), so the server's playlist-resolve dedup filter
        // doesn't hand them back as "missing" and trigger duplicate downloads.
        let presentFilenames = Set(songs.compactMap { $0.url?.lastPathComponent })
        for id in DownloadLedgerStore.shared.presentSourceIDs(presentFilenames: presentFilenames) {
            ids.insert(id)
        }

        let maxManifestBytes = 4000
        var manifest = ""
        for id in ids {
            let candidate = manifest.isEmpty ? id : manifest + "," + id
            guard candidate.utf8.count <= maxManifestBytes else { break }
            manifest = candidate
        }
        return manifest
    }

    /// Resolves a YouTube (or SoundCloud) playlist URL to a list of tracks via
    /// the bridge's `/api/resolve` endpoint. Results are published on `searchResults`
    /// and `isPlaylistResult` is set to `true` so the UI can show the playlist banner.
    /// `existingSongs` (typically `LibraryManager.allSongs`) is sent as a dedupe
    /// manifest so tracks the user already has are excluded from the result —
    /// pass `[]` to disable this (e.g. callers without library access).
    func resolvePlaylist(url: String, existingSongs: [Song] = []) async {
        guard isConfigured else {
            errorMessage = "Streaming service is unavailable right now."
            return
        }
        appLog("Resolving playlist: \(url)", category: "network")
        isResolvingPlaylist = true
        isPlaylistResult = false
        errorMessage = nil
        defer { isResolvingPlaylist = false }

        var components = URLComponents()
        components.path = "/api/resolve"
        components.queryItems = [
            URLQueryItem(name: "url",   value: url),
            URLQueryItem(name: "limit", value: "1000"),
        ]
        let manifest = existingTrackManifest(songs: existingSongs)
        if !manifest.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "existing_ids", value: manifest))
        }

        guard var request = makeRequest(components.string ?? "/api/resolve") else {
            errorMessage = "Invalid bridge URL."
            return
        }
        request.timeoutInterval = 130  // slightly over server timeout
        // Lets the bridge use this account's personal YouTube Data API key
        // (Account -> ... ) for full playlist enumeration, if one is set.
        if let accountToken = AccountService.shared?.token {
            request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }

        do {
            let (data, response) = try await Core.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300: break
                case 408:
                    errorMessage = "Playlist resolve timed out. Try again."
                    searchResults = []
                    return
                default:
                    errorMessage = "Could not resolve playlist (HTTP \(http.statusCode))."
                    searchResults = []
                    return
                }
            }
            let tracks = StreamingService.dedupedByID(try JSONDecoder().decode([StreamTrack].self, from: data))
            if tracks.isEmpty {
                // Primary resolve returned nothing — fall back to the
                // playlist-to-individual-URLs expander (the export-style
                // workaround), which can succeed where full playlist resolution
                // doesn't for large/partially-unavailable playlists.
                let expanded = await expandPlaylistTracks(url: url, existingSongs: existingSongs)
                searchResults = expanded
                isPlaylistResult = !expanded.isEmpty
                appLog("Resolved playlist via expand fallback: \(expanded.count) track(s)", category: "network")
            } else {
                searchResults = tracks
                isPlaylistResult = true
                appLog("Resolved playlist: \(tracks.count) track(s)", category: "network")
            }
        } catch {
            appError("Playlist resolve failed: \(error.localizedDescription)", category: "network")
            // Last resort before giving up: try the individual-URL expander.
            let expanded = await expandPlaylistTracks(url: url, existingSongs: existingSongs)
            if !expanded.isEmpty {
                searchResults = expanded
                isPlaylistResult = true
                errorMessage = nil
                appLog("Playlist resolve recovered via expand fallback: \(expanded.count) track(s)", category: "network")
            } else {
                errorMessage = "Failed to resolve playlist: \(error.localizedDescription)"
                searchResults = []
            }
        }
    }

    /// De-duplicates tracks by `id`, keeping the first occurrence. YouTube
    /// playlists frequently repeat a video; duplicate ids in a SwiftUI
    /// `ForEach(id:)` corrupt the List and can CRASH the playlist screen — so
    /// every resolved/expanded playlist is deduped at the source. Also stops the
    /// same track being queued/downloaded twice by "Download All".
    static func dedupedByID(_ tracks: [StreamTrack]) -> [StreamTrack] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    /// Resolves a playlist URL to its tracks and RETURNS them, without touching
    /// the published `searchResults`/`isPlaylistResult` state. Used by the
    /// tracked-playlist screen so opening a tracked playlist doesn't clobber the
    /// user's current Stream-search results. Pass `existingSongs: []` to keep
    /// already-owned tracks in the result (the tracked-playlist UI wants to show
    /// them with an "In Library" badge rather than hide them). Returns `[]` on
    /// failure; `errorMessage` is left untouched.
    func fetchPlaylistTracks(url: String, existingSongs: [Song] = []) async -> [StreamTrack] {
        guard isConfigured else { return [] }
        var components = URLComponents()
        components.path = "/api/resolve"
        components.queryItems = [
            URLQueryItem(name: "url",   value: url),
            URLQueryItem(name: "limit", value: "1000"),
        ]
        let manifest = existingTrackManifest(songs: existingSongs)
        if !manifest.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "existing_ids", value: manifest))
        }
        guard var request = makeRequest(components.string ?? "/api/resolve") else { return [] }
        request.timeoutInterval = 130
        if let accountToken = AccountService.shared?.token {
            request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }
        do {
            let (data, response) = try await Core.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // Fall back to the individual-URL expander on any non-2xx.
                return await expandPlaylistTracks(url: url, existingSongs: existingSongs)
            }
            let tracks = StreamingService.dedupedByID(try JSONDecoder().decode([StreamTrack].self, from: data))
            if tracks.isEmpty {
                return await expandPlaylistTracks(url: url, existingSongs: existingSongs)
            }
            return tracks
        } catch {
            appWarn("fetchPlaylistTracks failed: \(error.localizedDescription)", category: "network")
            return await expandPlaylistTracks(url: url, existingSongs: existingSongs)
        }
    }

    /// Expands a playlist URL into individual track entries via the bridge's
    /// `/api/playlist/expand` endpoint (the export-youtube-playlist-style
    /// extraction). Used as a robustness fallback by `resolvePlaylist`. Returns
    /// an empty array on any failure. Already-imported tracks (by sourceTrackID)
    /// are filtered out using `existingSongs`.
    func expandPlaylistTracks(url: String, existingSongs: [Song]) async -> [StreamTrack] {
        var components = URLComponents()
        components.path = "/api/playlist/expand"
        components.queryItems = [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "limit", value: "1000"),
        ]
        guard var request = makeRequest(components.string ?? "/api/playlist/expand") else { return [] }
        request.timeoutInterval = 130
        if let accountToken = AccountService.shared?.token {
            request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }

        struct ExpandItem: Decodable { let id: String?; let title: String?; let url: String? }
        struct ExpandResponse: Decodable { let source: String; let count: Int; let items: [ExpandItem] }

        do {
            let (data, response) = try await Core.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            let decoded = try JSONDecoder().decode(ExpandResponse.self, from: data)
            let haveIDs = Set(existingSongs.compactMap { $0.sourceTrackID })
            let items = decoded.items.compactMap { item -> StreamTrack? in
                guard let id = item.id, !id.isEmpty else { return nil }
                if haveIDs.contains("\(decoded.source):\(id)") { return nil }
                return StreamTrack(
                    id: id,
                    title: item.title ?? "Unknown Title",
                    artist: "",
                    durationSeconds: 0,
                    thumbnailURL: "",
                    source: decoded.source,
                    youtubeURL: item.url ?? ""
                )
            }
            return StreamingService.dedupedByID(items)
        } catch {
            appWarn("expandPlaylistTracks failed: \(error.localizedDescription)", category: "network")
            return []
        }
    }
}
