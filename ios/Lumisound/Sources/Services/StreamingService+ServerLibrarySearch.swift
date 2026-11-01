import Foundation
import UIKit

extension StreamingService {

    // MARK: - Server Library Search

    /// Searches the server's local music library via `GET /api/library/server`.
    /// Results are published on `serverTracks`. An empty `query` browses the
    /// whole server library (the bridge lists everything when no search filter
    /// is given) so the Server tab actually loads content on open instead of
    /// sitting empty until the user types. On error the `errorMessage` is set.
    func searchServerLibrary(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        appLog("searchServerLibrary: \"\(trimmed)\" (browse-all: \(trimmed.isEmpty))", category: "network")
        isSearchingServer = true
        errorMessage = nil
        defer { isSearchingServer = false }

        var components = URLComponents()
        components.path = "/api/library/server"
        components.queryItems = [
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "limit",  value: "200"),
        ]

        guard var request = makeRequest(components.string ?? "/api/library/server") else {
            errorMessage = "Invalid bridge URL."
            return
        }
        request.timeoutInterval = 20

        struct ServerLibraryResponse: Decodable {
            let tracks: [ServerTrack]
            let total: Int
            let dir: String?
            let configured: Bool?
        }

        do {
            let decoded = try await NetworkRetry.withRetry {
                let (data, response) = try await Core.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200..<300).contains(httpResponse.statusCode) {
                    throw StreamingError.httpError(httpResponse.statusCode)
                }
                return try JSONDecoder().decode(ServerLibraryResponse.self, from: data)
            }
            serverTracks = decoded.tracks
            serverLibraryConfigured = decoded.configured ?? true
            appLog("searchServerLibrary: \(serverTracks.count) result(s) for \"\(trimmed)\" (configured: \(serverLibraryConfigured == true))", category: "network")
        } catch {
            appError("searchServerLibrary: \(error.localizedDescription)", category: "network")
            errorMessage = "Streaming service is unavailable right now. Please try again later."
            serverTracks = []
        }
    }
}
