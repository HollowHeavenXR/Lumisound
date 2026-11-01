import Foundation

// MARK: - WatchBridgeClient
//
// Minimal, standalone networking client for the watch's independent playback
// path (login, cloud-library listing, track download). Deliberately NOT
// shared with the phone's `AccountService`/`_makeRequest` — the
// `LumisoundWatch` target only compiles `LumisoundWatch/Sources` per
// project.yml, so `Sources/Services/AccountService+PrivateHelpers.swift`
// isn't available here — but it mirrors the same request shape byte-for-byte
// so the bridge sees an identical client: `Authorization: Bearer <jwt>`
// header, JSON bodies, FastAPI `{"detail": ...}` error bodies.
//
// Plain value type (String/String? only) so it can be constructed fresh from
// whatever `WatchAccountStore` state is current, with no actor-isolation
// concerns crossing into this struct's async methods.

struct WatchBridgeError: LocalizedError {
    let statusCode: Int
    let message: String
    var errorDescription: String? { message }
}

private struct WatchAPIErrorBody: Decodable { let detail: String }

/// Matches the bridge's `/auth/login` response shape: `{"user": {...}, "token": "..."}`.
/// The `user` object is intentionally not decoded — the watch only needs the token.
struct WatchAuthResponse: Decodable {
    let token: String
}

struct WatchBridgeClient {
    let bridgeURL: String
    let token: String?

    private func request(_ path: String, method: String = "GET", bodyData: Data? = nil, timeout: TimeInterval = 20) async throws -> Data {
        let base = bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: base + normalizedPath) else {
            throw WatchBridgeError(statusCode: 0, message: "Invalid bridge URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = timeout
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let bodyData {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = bodyData
        }

        let (data, response) = try await Core.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let detail = try? JSONDecoder().decode(WatchAPIErrorBody.self, from: data) {
                throw WatchBridgeError(statusCode: http.statusCode, message: detail.detail)
            }
            throw WatchBridgeError(statusCode: http.statusCode, message: "Server error (HTTP \(http.statusCode))")
        }
        return data
    }

    func login(username: String, password: String) async throws -> WatchAuthResponse {
        struct Body: Encodable {
            let username: String
            let password: String
            let device_name: String
        }
        let body = Body(username: username, password: password, device_name: "Apple Watch")
        let data = try await request("/auth/login", method: "POST", bodyData: try JSONEncoder().encode(body))
        return try JSONDecoder().decode(WatchAuthResponse.self, from: data)
    }

    func fetchLibrary() async throws -> [WatchTrack] {
        guard token != nil else {
            throw WatchBridgeError(statusCode: 401, message: "Not logged in")
        }
        let data = try await request("/user/music")
        let decoded = try JSONDecoder().decode(WatchTrackListResponse.self, from: data)
        return decoded.tracks
    }

    /// The `/user/music/stream` URL for a track — `path` is the server-relative
    /// path within the user's music dir (see main.py's `stream_user_music`).
    func streamURL(for track: WatchTrack) -> URL? {
        let base = bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var comps = URLComponents(string: base + "/user/music/stream")
        comps?.queryItems = [URLQueryItem(name: "path", value: track.serverPath)]
        return comps?.url
    }

    /// Downloads a track's full audio bytes for local on-watch caching.
    /// Standalone playback never streams live — see WatchLocalPlayerManager.
    func downloadData(for track: WatchTrack) async throws -> Data {
        guard let token, let url = streamURL(for: track) else {
            throw WatchBridgeError(statusCode: 401, message: "Not logged in")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 60
        let (data, response) = try await Core.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WatchBridgeError(statusCode: http.statusCode, message: "Download failed (HTTP \(http.statusCode))")
        }
        return data
    }
}
