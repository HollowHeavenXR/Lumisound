import Foundation
import UIKit

extension StreamingService {

    // MARK: - Harmonic Mixing Recommendations

    /// Other cloud-backed tracks in a Camelot-compatible musical key and/or
    /// similar tempo (half/double-time aware) to `seedID` — server does the
    /// ranking (`/user/music/recommendations`) using each track's already-
    /// analyzed bpm/musical_key, so both the seed and candidates need those
    /// fields populated (run "Analyze" / the metadata backfill first if not).
    func fetchRecommendations(seedID: String, token: String, limit: Int = 10) async throws -> RecommendationsResponse {
        guard var request = makeRequest("/user/music/recommendations?id=\(seedID)&limit=\(limit)") else {
            throw StreamingError.invalidURL
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await Core.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StreamingError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(RecommendationsResponse.self, from: data)
    }
}
