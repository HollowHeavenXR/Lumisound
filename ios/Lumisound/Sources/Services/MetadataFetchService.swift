import Foundation
import UIKit

// MARK: - OnlineMetadata

struct OnlineMetadata {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let genre: String?
    let year: String?
    let artworkURL: URL?
}

// MARK: - MetadataFetchService

/// Fetches song metadata from a chain of free public APIs:
///   1. iTunes Search API  (best coverage for mainstream music)
///   2. MusicBrainz        (open music encyclopedia, great for indie/classical)
///   3. Deezer Search API  (European catalogue, often fills gaps)
/// Results are cached in memory for the lifetime of the app.
actor MetadataFetchService {
    static let shared = MetadataFetchService()

    // nil-wrapped Optional means "already looked up, nothing found"

    private init() {}

    /// Looks up metadata using a chain of free APIs. Returns the first successful result.
    /// *filename*, when provided, lets a multi-candidate iTunes result set be
    /// reviewed by Aria Lumi (built-in, always on) instead of the plain
    /// "exact match or first result" heuristic — see `fetchFromItunes`.
    /// Lookup + source fallback + caching run in the Rust core
    /// (rust/core/src/metadata.rs). When iTunes offers several candidates,
    /// Aria (via the bridge) picks the one that fits the filename best.
    func fetchMetadata(title: String, artist: String, filename: String? = nil) async -> OnlineMetadata? {
        guard let r = await metadataLookup(title: title, artist: artist), !r.candidates.isEmpty else {
            AppLogger.shared.warn("MetadataFetch: no results from any source for \"\(title)\"", category: "network")
            return nil
        }
        var bestIndex = Int(r.bestIndex)
        if r.source == "itunes", r.candidates.count > 1, let filename {
            let candidates = r.candidates.map {
                MetadataCandidate(title: $0.title ?? "", artist: $0.artist ?? "", album: $0.album, year: $0.year,
                                  source: "itunes", artwork_url: $0.artworkUrl)
            }
            if let resolution = await AccountService.shared?.resolveMetadata(filename: filename, candidates: candidates),
               candidates.indices.contains(resolution.bestIndex) {
                bestIndex = resolution.bestIndex
                await IntelligenceSuggestionCache.shared.store(filename, title: candidates[bestIndex].title,
                                                               artist: candidates[bestIndex].artist, memoryID: resolution.memoryID)
            }
        }
        let b = r.candidates[min(bestIndex, r.candidates.count - 1)]
        AppLogger.shared.log("MetadataFetch[\(r.source)]: \"\(title)\"", category: "network")
        return OnlineMetadata(trackName: b.title, artistName: b.artist, albumName: b.album, genre: b.genre, year: b.year,
                              artworkURL: b.artworkUrl.flatMap { URL(string: $0) })
    }

    private static let maxEnrichableDuration: TimeInterval = 20 * 60

    func enrich(song: Song) async -> Song {
        var s = song
        guard song.duration < Self.maxEnrichableDuration else { return s }
        let meta = await fetchMetadata(title: song.title, artist: song.artist, filename: song.url?.lastPathComponent)
        guard let meta else { return s }

        if s.artist.isEmpty, let a = meta.artistName { s.artist = a }
        if s.album.isEmpty,  let a = meta.albumName  { s.album  = a }
        if s.genre.isEmpty,  let g = meta.genre      { s.genre  = g }
        if s.year.isEmpty,   let y = meta.year       { s.year   = y }

        return s
    }
}
