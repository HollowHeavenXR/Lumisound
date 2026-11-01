import AVFoundation
import Foundation
import UIKit

/// Per-file iTunes/MusicBrainz/Deezer enrichment results — the Rust core's
/// enrichment cache (in memory, written once per batch via `persist()`).
actor EnrichmentCacheStore {
    static let shared = EnrichmentCacheStore()

    private static let legacyKey = "doc_import_enrich_v1"

    private init() {
        if let legacy = UserDefaults.standard.dictionary(forKey: Self.legacyKey),
           let data = try? JSONSerialization.data(withJSONObject: legacy) {
            enrichCacheImportLegacy(json: data)
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        }
    }

    func lookup(_ filename: String) -> [String: String]? {
        enrichCacheLookup(filename: filename)
    }

    func store(_ filename: String, entry: [String: String]) {
        enrichCacheStore(filename: filename, entry: entry)
    }

    /// Call once after a batch of imports/scans — not per song.
    func persist() {
        enrichCachePersist()
    }
}

enum DocumentImportError: LocalizedError {
    case unreadableFile
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "The selected audio file could not be read."
        case .copyFailed:
            return "The audio file could not be copied into the app library."
        }
    }
}

struct DocumentImportService {
    /// Importable containers — the Rust core's list.
    static let supportedExtensions: Set<String> = Set(importSupportedExtensions())
    private var supportedExtensions: Set<String> { Self.supportedExtensions }

    func importFiles(from urls: [URL]) async throws -> [Song] {
        // Import up to 4 files concurrently to avoid overloading the filesystem
        // while still gaining a meaningful throughput win on large batches.
        let maxConcurrency = 4
        var songs: [Song] = []

        try await withThrowingTaskGroup(of: Song?.self) { group in
            var inFlight = 0

            for url in urls {
                // Throttle: wait for one slot to free before adding another task
                if inFlight >= maxConcurrency {
                    if let song = try await group.next() {
                        if let song { songs.append(song) }
                        inFlight -= 1
                    }
                }

                group.addTask {
                    try await self.importFile(from: url)
                }
                inFlight += 1
            }

            // Drain remaining tasks
            for try await song in group {
                if let song { songs.append(song) }
            }
        }

        // Flush any enrichment-cache writes accumulated during this batch in one shot
        // rather than once per song (see EnrichmentCacheStore).
        await EnrichmentCacheStore.shared.persist()

        return songs
    }

    private func importFile(from sourceURL: URL) async throws -> Song? {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard supportedExtensions.contains(sourceURL.pathExtension.lowercased()) else {
            return nil
        }
        // Copy into Imported Music in the Rust core: a same-size file already
        // there is reused, a different-sized one replaced, and two concurrent
        // imports racing to one name resolve without failing.
        let libraryDir = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("Imported Music", isDirectory: true)
        let copy: ImportCopy
        do {
            copy = try await Task.detached(priority: .utility) {
                try importCopyFile(source: sourceURL.path, libraryDir: libraryDir.path)
            }.value
        } catch {
            appError("importFile: copy failed for \(sourceURL.lastPathComponent): \(error)", category: "library")
            throw DocumentImportError.copyFailed
        }
        let destination = URL(fileURLWithPath: copy.path)
        appLog("importFile: \(copy.reused ? "already imported" : "copied") \(destination.lastPathComponent)", category: "library")
        return await makeSong(for: destination)
    }

    /// Exposed so LibraryManager can build Song objects when scanning the Documents folder directly.
    ///
    /// Tags and stream properties come from the Rust core (`scan_read_track`,
    /// lofty — every container incl. Opus, `.lms` read through its unlocked
    /// copy). AVFoundation is only the fallback for files the core can't parse,
    /// plus the first-frame thumbnail for video containers.
    func makeSong(for url: URL) async -> Song {
        appLog("Processing: \(url.lastPathComponent)", category: "library")
        let fileExt = LumisoundExclusiveExtensionService.effectiveExtension(for: url)
        let tags: SongTags
        var duration: Double = 0
        var sampleRate = 0
        var bitrate = 0
        if let r = scanReadTrack(path: url.path, cacheDir: CoreAudio.unlockDir) {
            var sourceTrackID = r.sourceTrackId
            if sourceTrackID == nil, ["m4a", "mp4", "m4v", "mov"].contains(fileExt) {
                // Files tagged by the older AVFoundation exporter carry the id
                // as a QuickTime mdta key only AVFoundation reads.
                sourceTrackID = await LumisoundExclusiveExtensionService.embeddedSourceTrackID(fileURL: url)
            }
            tags = SongTags(title: r.title, artist: r.artist, album: r.album,
                            albumInferredFromFolder: r.albumInferredFromFolder, genre: r.genre, year: r.year,
                            trackNumber: r.trackNumber, sourceTrackId: sourceTrackID)
            duration = r.duration
            sampleRate = Int(r.sampleRate)
            bitrate = Int(r.bitrateKbps)
        } else {
            let av = await Self.readWithAVFoundation(url: url)
            let f = tagApplyFallbacks(path: url.path, title: av.tags.title, artist: av.tags.artist, album: av.tags.album)
            tags = SongTags(title: f.title, artist: f.artist, album: f.album,
                            albumInferredFromFolder: f.albumInferredFromFolder, genre: av.tags.genre,
                            year: av.tags.year, trackNumber: av.tags.trackNumber, sourceTrackId: av.tags.sourceTrackId)
            duration = av.duration
            sampleRate = av.sampleRate
            bitrate = av.bitrate
        }

        // Video containers: first frame as artwork, cached to memory + disk.
        if ["mp4", "m4v", "mov"].contains(fileExt) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: LumisoundExclusiveExtensionService.playableURL(for: url)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            if let frame = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
                ArtworkService.shared.cacheImage(UIImage(cgImage: frame.image), forKey: url.lastPathComponent)
            }
        }

        // Stable id from the Documents-relative path: survives rescans and
        // reinstalls (a random id orphaned favourites/playlist entries).
        let stableID = ScanCacheService.documentsRelativePath(for: url).map { "local:\($0)" }
        let dateAdded = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        var song = Song(
            id: stableID ?? UUID().uuidString,
            title: tags.title,
            artist: tags.artist,
            album: tags.album,
            duration: duration.isFinite ? duration : 0,
            url: url,
            artworkCacheKey: url.lastPathComponent,
            trackNumber: Int(tags.trackNumber),
            year: tags.year,
            genre: tags.genre,
            bitrate: bitrate,
            sampleRate: sampleRate,
            sourceTrackID: tags.sourceTrackId,
            dateAdded: dateAdded
        )
        song.albumInferredFromFolder = tags.albumInferredFromFolder

        appLog("Metadata: \"\(song.title)\" by \(song.artist.isEmpty ? "unknown" : song.artist) [\(fileExt), \(String(format: "%.0f", song.duration))s]\(tags.albumInferredFromFolder ? " (album inferred from folder name)" : "")", category: "library")
        // sourceTrackID drives ArtworkService's deterministic thumbnail
        // fallback, so log where it came from (or that it's missing).
        if let id = tags.sourceTrackId {
            appLog("Metadata: sourceTrackID=\(id) for \"\(song.title)\"", category: "library")
        } else {
            appLog("Metadata: no sourceTrackID found for \"\(song.title)\" (ext=\(fileExt))", category: "library")
        }

        // Sparse metadata (common for YouTube downloads) -> cached online lookup.
        if song.artist.isEmpty || song.album.isEmpty || song.genre.isEmpty {
            song = await Self.enrichFromCache(song: song)
        }
        return song
    }

    /// Cheap local re-read of a track's embedded tags for the periodic
    /// background refresh (no stream probe, no artwork, no online lookup).
    /// Nil when nothing changed — the merge rules are the core's
    /// `tag_refresh_merge`.
    func refreshTags(for url: URL, current: Song) async -> Song? {
        let raw: SongTags
        if let r = scanReadRawTags(path: url.path, cacheDir: CoreAudio.unlockDir) {
            raw = r
        } else {
            raw = await Self.readWithAVFoundation(url: url).tags
        }
        let currentTags = SongTags(title: current.title, artist: current.artist, album: current.album,
                                   albumInferredFromFolder: current.albumInferredFromFolder ?? false, genre: current.genre,
                                   year: current.year, trackNumber: Int64(current.trackNumber),
                                   sourceTrackId: current.sourceTrackID)
        guard let merged = tagRefreshMerge(path: url.path, current: currentTags, raw: raw) else { return nil }
        if current.sourceTrackID == nil, let id = merged.sourceTrackId {
            appLog("refreshTags: recovered sourceTrackID=\(id) for \"\(current.title)\" on re-scan", category: "library")
        }
        var refreshed = current
        refreshed.title = merged.title
        refreshed.artist = merged.artist
        refreshed.album = merged.album
        refreshed.genre = merged.genre
        refreshed.year = merged.year
        refreshed.trackNumber = Int(merged.trackNumber)
        refreshed.sourceTrackID = merged.sourceTrackId
        refreshed.albumInferredFromFolder = merged.albumInferredFromFolder
        return refreshed
    }

    // MARK: - AVFoundation fallback (files the core can't parse)

    private struct AVRead {
        var tags: SongTags
        var duration: Double
        var sampleRate: Int
        var bitrate: Int
    }

    /// Raw tags through AVFoundation (no filename/folder fallbacks), item
    /// identifiers classified by the core's rules (ID3 frames, iTunes atoms,
    /// QuickTime/Vorbis names), then Ogg comments.
    private static func readWithAVFoundation(url: URL) async -> AVRead {
        let readableURL = LumisoundExclusiveExtensionService.playableURL(for: url)
        let asset = AVURLAsset(url: readableURL)
        var title = "", artist = "", album = "", genre = "", year = ""
        var trackNumber: Int64 = 0
        var sourceTrackID: String?
        for item in (try? await asset.load(.commonMetadata)) ?? [] {
            switch item.commonKey?.rawValue {
            case "title": title = item.stringValue ?? title
            case "artist": artist = item.stringValue ?? artist
            case "albumName", "album": album = item.stringValue ?? album
            default: break
            }
        }
        for item in (try? await asset.load(.metadata)) ?? [] {
            let id = item.identifier?.rawValue ?? (item.key as? String) ?? ""
            switch tagIdentifierKind(identifier: id) {
            case .sourceId where sourceTrackID == nil:
                sourceTrackID = item.stringValue
            case .genre where genre.isEmpty:
                if let raw = item.stringValue { genre = tagCleanGenre(raw: raw) }
            case .trackNumber where trackNumber == 0:
                if let raw = item.stringValue { trackNumber = tagParseTrackNumber(raw: raw) }
                else if let n = try? await item.load(.numberValue) { trackNumber = Int64(n.intValue) }
            case .year where year.isEmpty:
                if let raw = item.stringValue { year = tagParseYear(raw: raw) }
                else if let n = try? await item.load(.numberValue) { year = "\(n.intValue)" }
            default: break
            }
        }
        if ["opus", "ogg"].contains(LumisoundExclusiveExtensionService.effectiveExtension(for: url)), title.isEmpty {
            let v = vorbisCommentsRead(path: readableURL.path)
            if let x = v["TITLE"], !x.isEmpty { title = x }
            if let x = v["ARTIST"], !x.isEmpty { artist = x }
            if let x = v["ALBUM"], !x.isEmpty { album = x }
            if let x = v["GENRE"], !x.isEmpty { genre = x }
            if let x = v["DATE"] ?? v["YEAR"], !x.isEmpty { year = tagParseYear(raw: x) }
            if trackNumber == 0, let x = v["TRACKNUMBER"] ?? v["TRACK"] { trackNumber = tagParseTrackNumber(raw: x) }
            if sourceTrackID == nil, let x = v["LUMISOUND_ID"], !x.isEmpty { sourceTrackID = x }
        }
        var sampleRate = 0
        if let file = try? AVAudioFile(forReading: readableURL), file.processingFormat.sampleRate > 0 {
            sampleRate = Int(file.processingFormat.sampleRate.rounded())
        }
        var bitrate = 0
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            bitrate = Int((rate / 1000).rounded())
        }
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        return AVRead(
            tags: SongTags(title: title, artist: artist, album: album,
                           albumInferredFromFolder: false, genre: genre, year: year,
                           trackNumber: trackNumber, sourceTrackId: sourceTrackID),
            duration: duration, sampleRate: sampleRate, bitrate: bitrate)
    }

    // MARK: - Online Metadata Enrichment

    /// Returns a song with missing fields filled from the enrichment cache or the iTunes/MusicBrainz/Deezer chain.
    private static func enrichFromCache(song: Song) async -> Song {
        let filename = song.url?.lastPathComponent ?? song.title

        if let saved = await EnrichmentCacheStore.shared.lookup(filename) {
            var s = song
            if s.artist.isEmpty,      let v = saved["artist"], !v.isEmpty { s.artist = v }
            if s.album.isEmpty,       let v = saved["album"],  !v.isEmpty { s.album  = v }
            if s.genre.isEmpty,       let v = saved["genre"],  !v.isEmpty { s.genre  = v }
            if s.year.isEmpty,        let v = saved["year"],   !v.isEmpty { s.year   = v }
            return s
        }

        appLog("Enriching metadata via iTunes for \"\(song.title)\"", category: "library")
        let enriched = await MetadataFetchService.shared.enrich(song: song)
        var entry: [String: String] = [:]
        if enriched.artist != song.artist || enriched.album != song.album ||
           enriched.genre  != song.genre  || enriched.year  != song.year {
            if !enriched.artist.isEmpty { entry["artist"] = enriched.artist }
            if !enriched.album.isEmpty  { entry["album"]  = enriched.album  }
            if !enriched.genre.isEmpty  { entry["genre"]  = enriched.genre  }
            if !enriched.year.isEmpty   { entry["year"]   = enriched.year   }
            if !entry.isEmpty {
                appLog("iTunes enrichment applied for \"\(song.title)\": artist=\(enriched.artist), album=\(enriched.album)", category: "library")
            }
        }
        // Always record — an empty dict marks "checked, no results found" so the
        // lookup isn't retried on every app launch for tracks with no API match.
        await EnrichmentCacheStore.shared.store(filename, entry: entry)
        return enriched
    }
}
