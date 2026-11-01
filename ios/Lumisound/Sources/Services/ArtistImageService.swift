import Foundation
import UIKit

/// Fetches and caches real artist profile pictures, distinct from any track's
/// album artwork. Previously, artist rows/grid cells fell back to showing the
/// album art of whichever song happened to be first for that artist — which
/// looks like "random folder/track art" rather than an actual artist photo.
///
/// Source: Deezer's public search API (`api.deezer.com/search/artist`), which
/// requires no API key and returns `picture_xl` / `picture_medium` fields that
/// are genuine artist photos (not album covers). If Deezer has no match, no
/// image is returned and callers should fall back to a generic person icon —
/// never to a track's album art.
///
/// Caching mirrors `ArtworkService`'s memory + disk cache pattern: an
/// `NSCache` for fast in-memory hits, plus JPEG files under Caches/ArtistImages
/// keyed by a sanitized lowercase artist name so images persist across launches.
final class ArtistImageService {
    static let shared = ArtistImageService()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL

    /// In-memory set of artist names known to have no Deezer match, so we don't
    /// repeatedly hit the network for artists with no photo available.
    private var noImageKeys: Set<String> = []
    private let noImageLock = NSLock()

    private init() {
        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = 40 * 1024 * 1024 // 40 MB

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let dir = (caches ?? FileManager.default.temporaryDirectory).appendingPathComponent("ArtistImages", isDirectory: true)
        diskCacheURL = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Same as ArtworkService: drop decoded images on a memory warning or
        // when backgrounded; they reload from the disk cache.
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.memoryCache.removeAllObjects()
            }
        }
    }

    /// Clears the in-memory image cache and the "no match" lookup set — used
    /// by `CacheManagerService` when the user clears the on-disk cache
    /// directory, so stale hits/misses aren't served from memory afterward.
    func clearCache() {
        memoryCache.removeAllObjects()
        noImageLock.lock()
        noImageKeys.removeAll()
        noImageLock.unlock()
    }

    /// Returns a cached image (memory or disk) without making a network request.
    func cachedImage(for artist: String) -> UIImage? {
        let key = cacheKey(for: artist)
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }
        if let onDisk = loadFromDisk(key: key) {
            setMemoryCache(onDisk, forKey: key)
            return onDisk
        }
        return nil
    }

    /// Loads the artist's profile picture, checking memory/disk caches first,
    /// then falling back to a Deezer artist search. Returns `nil` if no
    /// real artist photo could be found — callers should show a generic
    /// person icon in that case, never a track's album art.
    func loadImage(for artist: String) async -> UIImage? {
        let key = cacheKey(for: artist)

        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }
        if let onDisk = loadFromDisk(key: key) {
            setMemoryCache(onDisk, forKey: key)
            return onDisk
        }

        if isKnownNoImage(key) { return nil }

        // Try the full name, then the cleaned primary-artist name (strips
        // "feat."/"&"/"," collaborators that prevent an exact match), across
        // each public source in turn.
        // Deezer -> MusicBrainz -> Wikimedia Commons lookup in the Rust core.
        let image = await artistImageFetch(artist: artist).flatMap { UIImage(data: $0) }
        guard let image else {
            markNoImage(key)
            return nil
        }

        setMemoryCache(image, forKey: key)
        saveToDisk(image: image, key: key)
        return image
    }

    /// Produces an ordered, de-duplicated list of name variants to try: the
    /// full trimmed name first, then a "primary artist only" variant with any
    /// `feat.`/`ft.`/`&`/`,`/`x`/`vs` collaborator suffix stripped — since a
    /// combined credit like "Artist A feat. Artist B" rarely matches a single
    /// artist record on these services.
    private func artistNameCandidates(from artist: String) -> [String] {
        let full = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = [full]
        let separators = [" feat.", " feat ", " ft.", " ft ", " featuring ", " & ", ", ", " x ", " vs.", " vs "]
        // Cut at the earliest collaborator separator found, taking everything
        // before it as the primary artist. Matched case-insensitively directly
        // on `full` so the resulting substring uses the original casing.
        var earliest: String.Index?
        for sep in separators {
            if let range = full.range(of: sep, options: .caseInsensitive) {
                if earliest == nil || range.lowerBound < earliest! {
                    earliest = range.lowerBound
                }
            }
        }
        if let cut = earliest {
            let primary = String(full[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !primary.isEmpty, primary.localizedCaseInsensitiveCompare(full) != .orderedSame {
                result.append(primary)
            }
        }
        return result
    }

    /// Warms the cache for the given artist names at background priority.
    func prefetch(artists: [String]) {
        Task(priority: .background) {
            for artist in artists {
                guard cachedImage(for: artist) == nil else { continue }
                _ = await loadImage(for: artist)
            }
        }
    }

    // MARK: - Deezer

    private func fetchFromDeezer(artist: String) async -> UIImage? {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.localizedCaseInsensitiveCompare("Unknown Artist") != .orderedSame,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/artist?q=\(encoded)&limit=1")
        else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]],
              let first = results.first
        else { return nil }

        // Prefer the largest available photo; Deezer's "default" placeholder
        // images use a recognizable filename fragment we filter out.
        let candidates = [
            first["picture_xl"] as? String,
            first["picture_big"] as? String,
            first["picture_medium"] as? String
        ].compactMap { $0 }

        for candidateStr in candidates {
            guard !candidateStr.contains("artist//"), !candidateStr.isEmpty,
                  let imageURL = URL(string: candidateStr) else { continue }
            if let image = await fetchRemoteImage(url: imageURL) {
                return image
            }
        }
        return nil
    }

    private func fetchRemoteImage(url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }

    // MARK: - MusicBrainz + Wikimedia Commons (recommended public source)

    /// Resolves an artist photo via MusicBrainz (search → URL relations) and
    /// Wikimedia Commons. MusicBrainz exposes an `image` URL relation that
    /// usually points at a Wikimedia Commons file; we resolve that to a direct
    /// image via the Commons API. Requires a descriptive User-Agent per
    /// MusicBrainz policy.
    private func fetchFromMusicBrainz(artist: String) async -> UIImage? {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.localizedCaseInsensitiveCompare("Unknown Artist") != .orderedSame,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://musicbrainz.org/ws/2/artist/?query=artist:\(encoded)&fmt=json&limit=1")
        else { return nil }

        guard let json = await fetchJSON(searchURL),
              let artists = json["artists"] as? [[String: Any]],
              let mbid = artists.first?["id"] as? String,
              let relURL = URL(string: "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=url-rels&fmt=json")
        else { return nil }

        guard let relJSON = await fetchJSON(relURL),
              let relations = relJSON["relations"] as? [[String: Any]]
        else { return nil }

        // Find an "image" relation; resolve Wikimedia Commons file pages to a
        // direct image URL, otherwise use the URL as-is.
        for relation in relations where (relation["type"] as? String) == "image" {
            guard let urlObj = relation["url"] as? [String: Any],
                  let resource = urlObj["resource"] as? String else { continue }
            if let direct = await resolveCommonsImageURL(resource) ?? URL(string: resource),
               let image = await fetchRemoteImage(url: direct) {
                return image
            }
        }
        return nil
    }

    /// If `resource` is a Wikimedia Commons "File:" page, asks the Commons API
    /// for the direct image URL; returns nil for non-Commons URLs.
    private func resolveCommonsImageURL(_ resource: String) async -> URL? {
        guard resource.contains("commons.wikimedia.org"),
              let fileRange = resource.range(of: "File:")
        else { return nil }
        let fileName = String(resource[fileRange.lowerBound...])
        guard let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let apiURL = URL(string: "https://commons.wikimedia.org/w/api.php?action=query&titles=\(encoded)&prop=imageinfo&iiprop=url&iiurlwidth=500&format=json")
        else { return nil }

        guard let json = await fetchJSON(apiURL),
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any],
              let firstPage = pages.values.first as? [String: Any],
              let imageInfo = firstPage["imageinfo"] as? [[String: Any]],
              let info = imageInfo.first
        else { return nil }

        if let thumb = info["thumburl"] as? String, let url = URL(string: thumb) { return url }
        if let full = info["url"] as? String, let url = URL(string: full) { return url }
        return nil
    }

    /// Fetches and parses a JSON object, sending the User-Agent MusicBrainz/
    /// Wikimedia ask third-party clients to provide.
    private func fetchJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue("Lumisound/1.0 (https://github.com/HollowHeavenXR/Lumisound)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (data, response) = try? await Core.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - Cache helpers

    private func cacheKey(for artist: String) -> String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func sanitizedKey(_ key: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>| ")
        return key.components(separatedBy: illegal).joined(separator: "_")
    }

    private func diskPath(key: String) -> URL {
        diskCacheURL.appendingPathComponent("\(sanitizedKey(key)).jpg")
    }

    private func loadFromDisk(key: String) -> UIImage? {
        let path = diskPath(key: key)
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let image = UIImage(data: data)
        else { return nil }
        return image
    }

    private func saveToDisk(image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        try? data.write(to: diskPath(key: key), options: .atomic)
    }

    private func setMemoryCache(_ image: UIImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func isKnownNoImage(_ key: String) -> Bool {
        noImageLock.lock()
        defer { noImageLock.unlock() }
        return noImageKeys.contains(key)
    }

    private func markNoImage(_ key: String) {
        noImageLock.lock()
        defer { noImageLock.unlock() }
        noImageKeys.insert(key)
    }
}
