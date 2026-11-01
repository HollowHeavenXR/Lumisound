import Foundation
import UIKit

extension StreamingService {

    // MARK: - Fetch User Music Metadata

    /// Fetches rich metadata for all uploaded tracks from `/user/music/metadata`.
    @discardableResult
    func fetchUserMusicMetadata(token: String) async throws -> [UserMusicMetadataTrack] {
        appLog("fetchUserMusicMetadata", category: "network")
        isLoadingUserMusicMetadata = true
        defer { isLoadingUserMusicMetadata = false }

        // No artificial 500-item cap on a user's cloud-backed library — request
        // the full set (server allows up to 100k).
        guard var request = makeRequest("/user/music/metadata?limit=100000") else {
            throw StreamingError.invalidURL
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await Core.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StreamingError.httpError(http.statusCode)
        }

        struct MetadataResponse: Decodable {
            let tracks: [UserMusicMetadataTrack]
            let total: Int
        }
        let decoded = try JSONDecoder().decode(MetadataResponse.self, from: data)
        userMusicMetadata = decoded.tracks
        appLog("fetchUserMusicMetadata: \(decoded.tracks.count) tracks", category: "network")
        return decoded.tracks
    }
}
