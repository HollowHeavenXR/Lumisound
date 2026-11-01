import Foundation

// MARK: - Models

struct SharedPlaylist: Codable, Identifiable {
    let id: String          // == share_token
    let name: String
    let owner: String
    let tracks: [SharedTrack]
    let trackCount: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id = "share_token"
        case name, owner, tracks
        case trackCount = "track_count"
        case createdAt  = "created_at"
    }
}

struct SharedTrack: Codable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: Double
}

// MARK: - CollaborativeService

@MainActor
final class CollaborativeService: ObservableObject {

    @Published var shareToken: String?        = nil
    @Published var shareURL: String?          = nil
    @Published var isLoading: Bool            = false
    @Published var errorMessage: String?      = nil
    @Published var importedPlaylist: SharedPlaylist? = nil

    // MARK: - Share a Playlist
    //
    // POST {bridgeURL}/user/playlists/share
    // Body: { "playlist_name": "...", "tracks": [...] }
    // Response: { "share_token": "...", "share_url": "..." }

    func sharePlaylist(
        playlistName: String,
        tracks: [Song],
        bridgeURL: String,
        authToken: String
    ) async {
        guard !bridgeURL.isEmpty else {
            errorMessage = "Bridge URL is not configured."
            return
        }

        let base = bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/user/playlists/share") else {
            errorMessage = "Invalid bridge URL."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        struct TrackPayload: Encodable {
            let id: String
            let title: String
            let artist: String
            let album: String
            let duration: Double
        }

        struct Body: Encodable {
            let playlist_name: String
            let tracks: [TrackPayload]
        }

        let trackPayloads = tracks.map {
            TrackPayload(
                id: $0.id,
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                duration: $0.duration
            )
        }

        let body = Body(playlist_name: playlistName, tracks: trackPayloads)
        guard let bodyData = try? JSONEncoder().encode(body) else {
            errorMessage = "Failed to encode request."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 20

        do {
            let (data, response) = try await Core.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                errorMessage = "Server error (HTTP \(http.statusCode))."
                return
            }

            struct ShareResponse: Decodable {
                let share_token: String
                let share_url: String
            }
            let decoded = try JSONDecoder().decode(ShareResponse.self, from: data)
            shareToken = decoded.share_token
            shareURL   = decoded.share_url
        } catch {
            errorMessage = "Failed to share playlist: \(error.localizedDescription)"
        }
    }

    // MARK: - Fetch a Shared Playlist
    //
    // GET {bridgeURL}/shared/{shareToken}   (no auth required)

    func fetchSharedPlaylist(shareToken: String, bridgeURL: String) async {
        guard !bridgeURL.isEmpty else {
            errorMessage = "Bridge URL is not configured."
            return
        }

        let trimmedToken = shareToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            errorMessage = "Please enter a share code."
            return
        }

        let base = bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/shared/\(trimmedToken)") else {
            errorMessage = "Invalid share token or bridge URL."
            return
        }

        isLoading = true
        errorMessage = nil
        importedPlaylist = nil
        defer { isLoading = false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        do {
            let (data, response) = try await Core.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 {
                    errorMessage = "Shared playlist not found. The link may have been revoked."
                    return
                }
                if !(200..<300).contains(http.statusCode) {
                    errorMessage = "Server error (HTTP \(http.statusCode))."
                    return
                }
            }
            let playlist = try JSONDecoder().decode(SharedPlaylist.self, from: data)
            importedPlaylist = playlist
        } catch {
            errorMessage = "Failed to load shared playlist: \(error.localizedDescription)"
        }
    }

    // MARK: - Revoke a Share
    //
    // DELETE {bridgeURL}/user/playlists/share/{shareToken}

    func revokeShare(shareToken: String, bridgeURL: String, authToken: String) async {
        guard !bridgeURL.isEmpty else {
            errorMessage = "Bridge URL is not configured."
            return
        }

        let base = bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/user/playlists/share/\(shareToken)") else {
            errorMessage = "Invalid bridge URL."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        do {
            let (_, response) = try await Core.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                errorMessage = "Failed to revoke link (HTTP \(http.statusCode))."
                return
            }
            self.shareToken = nil
            self.shareURL   = nil
        } catch {
            errorMessage = "Failed to revoke link: \(error.localizedDescription)"
        }
    }

    // MARK: - Reset

    func reset() {
        shareToken       = nil
        shareURL         = nil
        errorMessage     = nil
        importedPlaylist = nil
        isLoading        = false
    }
}
