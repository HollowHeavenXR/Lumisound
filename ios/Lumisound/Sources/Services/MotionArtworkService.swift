import Foundation

// MARK: - MotionArtworkService
//
// Fetches and disk-caches the real "True Motion" animated-artwork clip for
// a YouTube-sourced track — see `/api/motion-artwork` in main.py for what
// this actually is (a short, muted, square-cropped loop of the source
// video's own opening seconds, not a generated visual effect). This is the
// client half of that: local disk cache so a track's clip is only ever
// downloaded once per device, keyed by video ID exactly like the server's
// own shared cache is keyed.
actor MotionArtworkService {
    static let shared = MotionArtworkService()

    private var inFlight: [String: Task<URL?, Never>] = [:]

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("motion-artwork", isDirectory: true)
    }

    /// Returns a local file URL for `videoID`'s motion clip — from disk
    /// cache if already fetched, otherwise downloads it from the bridge.
    /// Returns `nil` (never throws) if the clip isn't available for any
    /// reason (no network, server extraction failed, unsupported source) —
    /// callers fall back to the static artwork, per the "real feature or
    /// graceful fallback" rule this whole feature exists under.
    func clipURL(videoID: String, bridgeURL: String, token: String?) async -> URL? {
        let dir = cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let localURL = dir.appendingPathComponent("\(videoID).mp4")

        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        guard let token else { return nil }

        if let existing = inFlight[videoID] {
            return await existing.value
        }

        let task = Task<URL?, Never> {
            await Self.download(videoID: videoID, bridgeURL: bridgeURL, token: token, to: localURL)
        }
        inFlight[videoID] = task
        let result = await task.value
        inFlight[videoID] = nil
        return result
    }

    private static func download(videoID: String, bridgeURL: String, token: String, to localURL: URL) async -> URL? {
        var components = URLComponents(string: bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        components?.path = "/api/motion-artwork"
        components?.queryItems = [URLQueryItem(name: "video_id", value: videoID)]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Generous but bounded — the server's own extraction has a 90s
        // (yt-dlp) + 60s (ffmpeg) ceiling before it gives up, so this just
        // needs to comfortably outlast that on a slow connection.
        request.timeoutInterval = 180

        do {
            let (tmpURL, response) = try await Core.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: tmpURL)
                return nil
            }
            try? FileManager.default.removeItem(at: localURL)
            try FileManager.default.moveItem(at: tmpURL, to: localURL)
            return localURL
        } catch {
            appWarn("MotionArtworkService: fetch failed for \(videoID): \(error.localizedDescription)", category: "network")
            return nil
        }
    }
}
