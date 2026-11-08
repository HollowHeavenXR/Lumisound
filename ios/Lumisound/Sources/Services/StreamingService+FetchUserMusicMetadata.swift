import Foundation
import UIKit

extension StreamingService {

    // MARK: - Fetch User Music Metadata

    /// Fetches rich metadata for all uploaded tracks from `/user/music/metadata`.
    ///
    /// Callers that overlap (backup pass, thumbnail backfill, upload screen)
    /// share one request instead of each downloading the whole list, and a
    /// result younger than `maxAge` seconds is reused. The JSON (thousands of
    /// tracks) is decoded off the main thread.
    @discardableResult
    func fetchUserMusicMetadata(token: String, maxAge: TimeInterval = 0) async throws -> [UserMusicMetadataTrack] {
        if maxAge > 0, let at = userMusicMetadataFetchedAt, Date().timeIntervalSince(at) < maxAge {
            return userMusicMetadata
        }
        if let inFlight = userMusicMetadataTask {
            return try await inFlight.value
        }
        let task = Task { [weak self] () async throws -> [UserMusicMetadataTrack] in
            guard let self else { throw CancellationError() }
            return try await self.loadUserMusicMetadata(token: token)
        }
        userMusicMetadataTask = task
        defer { userMusicMetadataTask = nil }
        return try await task.value
    }

    private func loadUserMusicMetadata(token: String) async throws -> [UserMusicMetadataTrack] {
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

        let tracks = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(UserMusicMetadataResponse.self, from: data).tracks
        }.value
        userMusicMetadata = tracks
        userMusicMetadataFetchedAt = Date()
        appLog("fetchUserMusicMetadata: \(tracks.count) tracks", category: "network")
        return tracks
    }

    /// Adds or replaces one track in the cached list (after an upload), so
    /// views see it without re-downloading the whole list.
    func mergeUserMusicMetadata(_ track: UserMusicMetadataTrack) {
        guard !track.id.isEmpty else { return }
        if let i = userMusicMetadata.firstIndex(where: { $0.id == track.id }) {
            userMusicMetadata[i] = track
        } else {
            userMusicMetadata.insert(track, at: 0)
        }
    }
}

private struct UserMusicMetadataResponse: Decodable {
    let tracks: [UserMusicMetadataTrack]
}
