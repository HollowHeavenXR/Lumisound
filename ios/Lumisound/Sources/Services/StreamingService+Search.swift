import Foundation
import UIKit

extension StreamingService {

    // MARK: - Search

    func search(query: String, source: String = "youtube") async {
        guard isConfigured else {
            errorMessage = "Streaming service is unavailable right now."
            return
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        appLog("Search: \"\(query)\" [source: \(source)]", category: "network")
        isSearching = true
        isPlaylistResult = false
        errorMessage = nil
        defer { isSearching = false }

        var components = URLComponents()
        components.path = "/api/search"
        components.queryItems = [
            URLQueryItem(name: "q",      value: query),
            URLQueryItem(name: "limit",  value: "20"),
            URLQueryItem(name: "source", value: source),
        ]

        guard var request = makeRequest(components.string ?? "/api/search") else {
            errorMessage = "Invalid bridge URL."
            return
        }
        request.timeoutInterval = 20
        // Lets the bridge use this account's personally-uploaded yt-dlp
        // cookies (Settings -> YouTube Cookies) so search results include
        // age-restricted videos and aren't blocked by YouTube's
        // anonymous-request bot detection.
        if let accountToken = AccountService.shared?.token {
            request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }

        do {
            let tracks = try await NetworkRetry.withRetry {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200..<300).contains(httpResponse.statusCode) {
                    throw StreamingError.httpError(httpResponse.statusCode)
                }
                return try JSONDecoder().decode([StreamTrack].self, from: data)
            }
            searchResults = tracks
            // Start fetching the first screenful of thumbnails now so rows
            // render with artwork already decoded instead of popping in.
            RemoteImageLoader.shared.prefetch(tracks.prefix(24).compactMap { URL(string: $0.thumbnailURL) })
            appLog("Search returned \(tracks.count) result(s) for \"\(query)\"", category: "network")
        } catch {
            appError("Search failed: \(error.localizedDescription)", category: "network")
            errorMessage = "Streaming service is unavailable right now. Please try again later."
            searchResults = []
        }
    }

    /// Autocomplete suggestions for `q` — past queries from any user, starting
    /// with `q`, most popular first. Returns `[]` on no match or any failure.
    func searchSuggestions(query: String, limit: Int = 8) async -> [SearchQueryCount] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents()
        components.path = "/api/search/suggestions"
        components.queryItems = [
            URLQueryItem(name: "q",     value: trimmed),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        guard var request = makeRequest(components.string ?? "/api/search/suggestions") else { return [] }
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return []
            }
            return try JSONDecoder().decode([SearchQueryCount].self, from: data)
        } catch {
            return []
        }
    }

    /// Most popular search queries across all users in the last `days` days.
    /// Returns `[]` on no match or any failure.
    func searchTrending(limit: Int = 10, days: Int = 7) async -> [SearchQueryCount] {
        var components = URLComponents()
        components.path = "/api/search/trending"
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "days",  value: "\(days)"),
        ]
        guard var request = makeRequest(components.string ?? "/api/search/trending") else { return [] }
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return []
            }
            return try JSONDecoder().decode([SearchQueryCount].self, from: data)
        } catch {
            return []
        }
    }

    /// One-off lookup that finds the best streamable match for a title/artist pair
    /// without touching the published `searchResults`/`isSearching` state (which the
    /// Search tab UI is bound to). Used to resolve playable sources for tracks that
    /// arrived as metadata-only snapshots — e.g. shared/collaborative playlist tracks,
    /// which carry no stream URL by design. Returns `nil` on no match or any failure;
    /// callers should treat that as "skip this track" rather than a fatal error.
    func bestMatch(forTitle title: String, artist: String, source: String = "youtube") async -> StreamTrack? {
        guard isConfigured else { return nil }
        let query = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }

        var components = URLComponents()
        components.path = "/api/search"
        components.queryItems = [
            URLQueryItem(name: "q",      value: query),
            URLQueryItem(name: "limit",  value: "1"),
            URLQueryItem(name: "source", value: source),
        ]
        guard var request = makeRequest(components.string ?? "/api/search") else { return nil }
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return nil
            }
            let tracks = try JSONDecoder().decode([StreamTrack].self, from: data)
            return tracks.first
        } catch {
            return nil
        }
    }

    /// Fetches up to `limit` tracks for a raw query without touching the published
    /// `searchResults`/`isSearching`/`errorMessage` state — see `bestMatch` above for
    /// why that matters. Used by Auto-Radio to seed several related tracks from one
    /// query without clobbering whatever the user has up in the Search tab. Returns
    /// `[]` on no results or any failure.
    func relatedTracks(query: String, source: String = "youtube", limit: Int = 5) async -> [StreamTrack] {
        guard isConfigured else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents()
        components.path = "/api/search"
        components.queryItems = [
            URLQueryItem(name: "q",      value: trimmed),
            URLQueryItem(name: "limit",  value: String(limit)),
            URLQueryItem(name: "source", value: source),
        ]
        guard var request = makeRequest(components.string ?? "/api/search") else { return [] }
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return []
            }
            return try JSONDecoder().decode([StreamTrack].self, from: data)
        } catch {
            return []
        }
    }

    /// Same `/api/search` call as `search(query:source:)`, but returns the
    /// results directly instead of publishing them to `searchResults` —
    /// for callers that need search results without disturbing whatever
    /// the user currently has on the actual Search screen. Used by
    /// `DeadLinkHealingService`'s background pass, which must never clobber
    /// live UI state.
    func searchSilently(query: String, source: String = "youtube") async -> [StreamTrack] {
        guard isConfigured, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        var components = URLComponents()
        components.path = "/api/search"
        components.queryItems = [
            URLQueryItem(name: "q",      value: query),
            URLQueryItem(name: "limit",  value: "20"),
            URLQueryItem(name: "source", value: source),
        ]
        guard var request = makeRequest(components.string ?? "/api/search") else { return [] }
        request.timeoutInterval = 20
        if let accountToken = AccountService.shared?.token {
            request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return []
            }
            return try JSONDecoder().decode([StreamTrack].self, from: data)
        } catch {
            return []
        }
    }

    /// Checks whether `url` (a reconstructed source watch URL, e.g.
    /// `https://youtube.com/watch?v=<id>`) is still resolvable, via the
    /// existing `/api/track` metadata endpoint — no dedicated "liveness
    /// check" endpoint needed server-side, since a 404 there already means
    /// exactly "yt-dlp couldn't extract this" (see that endpoint's error
    /// handling in main.py). Used by `DeadLinkHealingService` to detect a
    /// removed/private video before attempting to find a replacement.
    func checkTrackAvailable(url: String) async -> Bool {
        guard isConfigured else { return true } // unknown -- don't treat as dead just because the bridge is unreachable
        var components = URLComponents()
        components.path = "/api/track"
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        guard var request = makeRequest(components.string ?? "/api/track") else { return true }
        request.timeoutInterval = 20
        if let accountToken = AccountService.shared?.token {
            request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return true }
            // Only a definitive 404 ("Could not fetch track metadata" / "Track
            // not found" in main.py's track_metadata) counts as genuinely dead —
            // any other status (timeout->408, auth issues, 5xx) is ambiguous and
            // must NOT be treated as "video removed", or a transient bridge
            // hiccup would trigger real relinking off bad information.
            return httpResponse.statusCode != 404
        } catch {
            return true // network error -- ambiguous, not evidence of removal
        }
    }
}
