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
    private var cache: [String: OnlineMetadata?] = [:]

    private init() {}

    /// Looks up metadata using a chain of free APIs. Returns the first successful result.
    /// *filename*, when provided, lets a multi-candidate iTunes result set be
    /// reviewed by Aria Lumi (built-in, always on) instead of the plain
    /// "exact match or first result" heuristic — see `fetchFromItunes`.
    func fetchMetadata(title: String, artist: String, filename: String? = nil) async -> OnlineMetadata? {
        let rawTitle  = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return nil }

        let cacheKey = "\(rawTitle)|\(rawArtist)"
        if let cached = cache[cacheKey] {
            return cached
        }

        // 1. iTunes
        if let meta = await fetchFromItunes(title: rawTitle, artist: rawArtist, filename: filename) {
            cache[cacheKey] = meta
            AppLogger.shared.log("MetadataFetch[iTunes]: \"\(rawTitle)\"", category: "network")
            return meta
        }

        // 2. MusicBrainz (rate-limited: 1 req/sec — acceptable for one-off enrichment)
        if let meta = await fetchFromMusicBrainz(title: rawTitle, artist: rawArtist) {
            cache[cacheKey] = meta
            AppLogger.shared.log("MetadataFetch[MusicBrainz]: \"\(rawTitle)\"", category: "network")
            return meta
        }

        // 3. Deezer
        if let meta = await fetchFromDeezer(title: rawTitle, artist: rawArtist) {
            cache[cacheKey] = meta
            AppLogger.shared.log("MetadataFetch[Deezer]: \"\(rawTitle)\"", category: "network")
            return meta
        }

        AppLogger.shared.warn("MetadataFetch: no results from any source for \"\(rawTitle)\"", category: "network")
        cache[cacheKey] = .some(nil)
        return nil
    }

    // MARK: - iTunes

    private func fetchFromItunes(title: String, artist: String, filename: String? = nil) async -> OnlineMetadata? {
        let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=3&country=US"),
              let (data, response) = try? await Core.data(for: URLRequest(url: url, timeoutInterval: 10)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              !results.isEmpty
        else { return nil }

        var best = results.first(where: {
            ($0["trackName"] as? String ?? "").lowercased() == title.lowercased()
        }) ?? results[0]

        // Whenever there's more than one candidate, let Aria Lumi review the
        // whole set rather than only stepping in when NONE of them exactly
        // matches the title — a title that looks exact can still be the
        // wrong artist/album/version, which the plain heuristic below has no
        // way to catch since it stops looking the moment a title matches.
        // Still gated on `results.count > 1`: with a single candidate
        // there's nothing to disambiguate, so asking would just be a wasted
        // call. Falls straight through to the existing `best` above on any
        // failure or low-confidence pick.
        if results.count > 1, let filename {
            let candidates = results.map { result -> MetadataCandidate in
                let art100 = result["artworkUrl100"] as? String ?? ""
                let art600 = result["artworkUrl600"] as? String
                    ?? art100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                return MetadataCandidate(
                    title: result["trackName"] as? String ?? "",
                    artist: result["artistName"] as? String ?? "",
                    album: result["collectionName"] as? String,
                    year: (result["releaseDate"] as? String).map { String($0.prefix(4)) },
                    source: "itunes",
                    artwork_url: art600.isEmpty ? nil : art600
                )
            }
            if let resolution = await AccountService.shared?.resolveMetadata(filename: filename, candidates: candidates) {
                best = results[resolution.bestIndex]
                await IntelligenceSuggestionCache.shared.store(
                    filename,
                    title: candidates[resolution.bestIndex].title,
                    artist: candidates[resolution.bestIndex].artist,
                    memoryID: resolution.memoryID
                )
            }
        }

        let art100 = best["artworkUrl100"] as? String ?? ""
        let art600 = best["artworkUrl600"] as? String
            ?? art100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return OnlineMetadata(
            trackName:  best["trackName"]       as? String,
            artistName: best["artistName"]       as? String,
            albumName:  best["collectionName"]   as? String,
            genre:      best["primaryGenreName"] as? String,
            year:       (best["releaseDate"] as? String).map { String($0.prefix(4)) },
            artworkURL: URL(string: art600)
        )
    }

    // MARK: - MusicBrainz

    private func fetchFromMusicBrainz(title: String, artist: String) async -> OnlineMetadata? {
        let query = artist.isEmpty ? "recording:\"\(title)\"" : "recording:\"\(title)\" AND artist:\"\(artist)\""
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://musicbrainz.org/ws/2/recording?query=\(encoded)&limit=3&fmt=json")
        else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Lumisound/1.0 (https://github.com/HollowHeavenXR/Lumisound)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        guard let (data, response) = try? await Core.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordings = json["recordings"] as? [[String: Any]],
              !recordings.isEmpty
        else { return nil }

        let best = recordings.first(where: {
            ($0["title"] as? String ?? "").lowercased() == title.lowercased()
        }) ?? recordings[0]

        let trackName   = best["title"] as? String
        let artistName  = (best["artist-credit"] as? [[String: Any]])?.first?["name"] as? String
        let releases    = best["releases"] as? [[String: Any]]
        let albumName   = releases?.first?["title"] as? String
        let date        = releases?.first?["date"] as? String

        return OnlineMetadata(
            trackName:  trackName,
            artistName: artistName,
            albumName:  albumName,
            genre:      nil,    // MusicBrainz doesn't return genre directly in recording search
            year:       date.map { String($0.prefix(4)) },
            artworkURL: nil     // Artwork requires Cover Art Archive; skip for speed
        )
    }

    // MARK: - Deezer

    private func fetchFromDeezer(title: String, artist: String) async -> OnlineMetadata? {
        let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=3"),
              let (data, response) = try? await Core.data(for: URLRequest(url: url, timeoutInterval: 10)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]],
              !results.isEmpty
        else { return nil }

        let best = results.first(where: {
            ($0["title"] as? String ?? "").lowercased() == title.lowercased()
        }) ?? results[0]
        let album     = best["album"] as? [String: Any]
        let artist2   = best["artist"] as? [String: Any]
        let coverURL  = album?["cover_big"] as? String ?? album?["cover"] as? String

        return OnlineMetadata(
            trackName:  best["title"]    as? String,
            artistName: artist2?["name"] as? String,
            albumName:  album?["title"]  as? String,
            genre:      nil,
            year:       nil,
            artworkURL: coverURL.flatMap { URL(string: $0) }
        )
    }

    /// Convenience: enriches `song` with any fields currently missing, using a single
    /// iTunes lookup. Returns the updated Song (or the original if nothing was found).
    /// Tracks at or beyond this length are essentially never a real single
    /// song in iTunes/MusicBrainz/Deezer's catalogs — a compilation, full
    /// album, or "whole playlist as one file" import routinely runs 20+
    /// minutes. `fetchFromItunes` falls back to its first search result
    /// whenever nothing matches the title exactly (see its doc comment),
    /// so querying with a compilation-style title doesn't fail cleanly —
    /// it silently returns an unrelated song's artist/album/genre, which
    /// then gets written back as if it were a real identification. Skipping
    /// enrichment entirely above this length is cheap insurance against
    /// that whole class of bogus match.
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
