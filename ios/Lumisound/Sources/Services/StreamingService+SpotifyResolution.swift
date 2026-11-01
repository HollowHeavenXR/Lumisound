import Foundation
import UIKit

extension StreamingService {

    // MARK: - Spotify link resolution

    /// Resolves a Spotify track/album/playlist share URL via the bridge's
    /// `/api/spotify/resolve` endpoint and publishes the result on
    /// `searchResults`, exactly like `resolvePlaylist` does for YouTube/
    /// SoundCloud/Bandcamp links. The bridge never touches Spotify's own
    /// (DRM-protected) audio — it reads public metadata and hands back
    /// already-matched, playable YouTube tracks, so the response shape and
    /// this method's plumbing are identical to `resolvePlaylist`.
    func resolveSpotify(url: String, existingSongs: [Song] = []) async {
        guard isConfigured else {
            errorMessage = "Streaming service is unavailable right now."
            return
        }
        appLog("Resolving Spotify link: \(url)", category: "network")
        isResolvingPlaylist = true
        isPlaylistResult = false
        errorMessage = nil
        defer { isResolvingPlaylist = false }

        var components = URLComponents()
        components.path = "/api/spotify/resolve"
        components.queryItems = [
            URLQueryItem(name: "url",   value: url),
            URLQueryItem(name: "limit", value: "200"),
        ]
        let manifest = existingTrackManifest(songs: existingSongs)
        if !manifest.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "existing_ids", value: manifest))
        }

        guard var request = makeRequest(components.string ?? "/api/spotify/resolve") else {
            errorMessage = "Invalid bridge URL."
            return
        }
        request.timeoutInterval = 130
        if let accountToken = AccountService.shared?.token {
            request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }

        do {
            let (data, response) = try await Core.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300: break
                case 501:
                    errorMessage = "This server doesn't have Spotify import configured yet."
                    searchResults = []
                    return
                case 404:
                    errorMessage = "Couldn't find playable matches for that Spotify link."
                    searchResults = []
                    return
                case 408:
                    errorMessage = "Spotify resolve timed out. Try again."
                    searchResults = []
                    return
                default:
                    errorMessage = "Could not resolve Spotify link (HTTP \(http.statusCode))."
                    searchResults = []
                    return
                }
            }
            let tracks = StreamingService.dedupedByID(try JSONDecoder().decode([StreamTrack].self, from: data))
            searchResults = tracks
            isPlaylistResult = !tracks.isEmpty
            appLog("Resolved Spotify link: \(tracks.count) matched track(s)", category: "network")
        } catch {
            appError("Spotify resolve failed: \(error.localizedDescription)", category: "network")
            errorMessage = "Failed to resolve Spotify link: \(error.localizedDescription)"
            searchResults = []
        }
    }
}
