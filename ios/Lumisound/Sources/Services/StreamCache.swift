import Foundation

/// The temp-file cache that streamed tracks are downloaded into before they
/// play (`downloadAndSchedule`, `prefetchUpcomingStreamIfNeeded`).
///
/// Analysis and metadata readers (ReplayGain, BPM, embedded artwork, ...)
/// must read a streamed song from this local copy, never from its URL: an
/// AVURLAsset pointed at the bridge's `/api/stream/proxy` opens it with a
/// burst of byte-range requests, and every one of them made the bridge run
/// yt-dlp. Browsing the Library alone fired ~100 of those for one song,
/// starving the track that was actually trying to play.
enum StreamCache {
    /// Filename stem shared by every writer of the cache.
    static func key(for url: URL) -> String {
        let bytes = Array(url.absoluteString.utf8)
        var hash: UInt64 = 5381
        for byte in bytes { hash = hash &* 31 &+ UInt64(byte) }
        return String(hash, radix: 16)
    }

    /// The downloaded copy of `url`, whatever extension it was saved under.
    static func cachedFile(for url: URL) -> URL? {
        let stem = "stream_\(key(for: url))."
        let dir = FileManager.default.temporaryDirectory
        for ext in ["m4a", "opus", "webm", "mp3", "flac", "wav"] {
            let candidate = dir.appendingPathComponent(stem + ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// A URL that can be read without touching the network: `url` itself for
    /// a file, the cached download for a stream, nil when there is none yet.
    static func localURL(for url: URL) -> URL? {
        if url.isFileURL { return url }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return url }
        return cachedFile(for: url)
    }
}
