import AVFoundation
import Foundation
import UIKit

/// Persists per-file iTunes/MusicBrainz/Deezer enrichment results.
///
/// Previously each `enrichFromCache` call read the *entire* `[String: [String: String]]`
/// dictionary from `UserDefaults`, mutated one entry, and wrote the whole thing back —
/// an O(n) plist (de)serialization on every single song. Importing a few thousand
/// tracks meant a few thousand full-dictionary read/encode/write cycles (effectively
/// O(n²)), which is exactly the kind of work that stalls the UI and can trip the
/// watchdog during a big import. This actor loads once, keeps the cache in memory,
/// and writes back at most once per batch via `persist()`.
actor EnrichmentCacheStore {
    static let shared = EnrichmentCacheStore()

    private static let cacheKey = "doc_import_enrich_v1"

    private var cache: [String: [String: String]]
    private var dirty = false

    private init() {
        cache = (UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: [String: String]]) ?? [:]
    }

    func lookup(_ filename: String) -> [String: String]? {
        cache[filename]
    }

    func store(_ filename: String, entry: [String: String]) {
        cache[filename] = entry
        dirty = true
    }

    /// Flushes pending writes to `UserDefaults` in a single pass. Call once after
    /// a batch of imports/scans completes — not per song.
    func persist() {
        guard dirty else { return }
        UserDefaults.standard.set(cache, forKey: Self.cacheKey)
        dirty = false
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
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "mp4", "opus",
        "m4v", "mov",  // video containers with audio tracks
        "webm", "ogg", // yt-dlp can fall back to these containers for /api/download
        LumisoundExclusiveExtensionService.marker  // "lms" — converted tracks, see that type
    ]
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

        let destination = try destinationURL(for: sourceURL)
        let manager = FileManager.default

        // If the destination already exists with the same byte size as the source,
        // the file is already fully imported — skip the redundant copy and just
        // return a Song built from the existing destination file.
        if manager.fileExists(atPath: destination.path) {
            let srcSize = (try? manager.attributesOfItem(atPath: sourceURL.path))?[.size] as? Int
            let dstSize = (try? manager.attributesOfItem(atPath: destination.path))?[.size] as? Int
            if let srcSize, let dstSize, srcSize == dstSize {
                appLog("importFile: already imported \(destination.lastPathComponent)", category: "library")
                return await makeSong(for: destination)
            }
            // Sizes differ (partial or updated file) — remove and re-copy.
            do {
                try manager.removeItem(at: destination)
            } catch {
                appError("importFile: could not remove stale file \(destination.lastPathComponent): \(error)", category: "library")
                throw DocumentImportError.copyFailed
            }
        }

        do {
            try manager.copyItem(at: sourceURL, to: destination)
            appLog("importFile: copied \(destination.lastPathComponent)", category: "library")
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // importFiles(from:) runs up to 4 of these concurrently — two
            // different source files that sanitize to the same destination
            // filename (confirmed in the field: a share-sheet drop can
            // deliver the same name twice in quick succession) both pass
            // this function's OWN existence check above before either has
            // actually created the destination, so the second one to
            // reach `copyItem` hits this error instead of the graceful
            // dedup that check was meant to provide — the whole import
            // used to fail outright for exactly this reason. Re-resolve
            // now that the race is settled: if it's genuinely the same
            // file (matching size), adopt whichever copy already won;
            // otherwise retry once under a de-duplicated name instead of
            // failing.
            let srcSize = (try? manager.attributesOfItem(atPath: sourceURL.path))?[.size] as? Int
            let dstSize = (try? manager.attributesOfItem(atPath: destination.path))?[.size] as? Int
            if let srcSize, let dstSize, srcSize == dstSize {
                appLog("importFile: lost a concurrent-import race for \(destination.lastPathComponent) — adopting the other copy", category: "library")
                return await makeSong(for: destination)
            }
            let deduped = Self.uniqueDestinationURL(for: destination, in: manager)
            do {
                try manager.copyItem(at: sourceURL, to: deduped)
                appLog("importFile: copied \(deduped.lastPathComponent) (de-duplicated after a name collision)", category: "library")
            } catch {
                appError("importFile: copy failed for \(sourceURL.lastPathComponent) even after de-duplicating: \(error)", category: "library")
                throw DocumentImportError.copyFailed
            }
            return await makeSong(for: deduped)
        } catch {
            appError("importFile: copy failed for \(sourceURL.lastPathComponent): \(error)", category: "library")
            throw DocumentImportError.copyFailed
        }

        return await makeSong(for: destination)
    }

    /// `destination`, renamed with a numeric suffix (`name 2.ext`, `name 3.ext`, …)
    /// until it no longer collides with an existing file.
    private static func uniqueDestinationURL(for destination: URL, in manager: FileManager) -> URL {
        let directory = destination.deletingLastPathComponent()
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var suffix = 2
        var candidate = destination
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }

    private func destinationURL(for sourceURL: URL) throws -> URL {
        let libraryDir = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Imported Music", isDirectory: true)

        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        let safeName = baseName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        return libraryDir.appendingPathComponent("\(safeName).\(ext)")
    }

    /// Exposed so LibraryManager can build Song objects when scanning the Documents folder directly.
    func makeSong(for url: URL) async -> Song {
        appLog("Processing: \(url.lastPathComponent)", category: "library")
        // A `.lms`-locked track's on-disk bytes are XOR-masked (see
        // LumisoundLockFormat) — AVFoundation cannot read ANY metadata,
        // artwork, or audio properties from `url` directly for such a
        // file. Every read below goes through `readableURL` instead, which
        // is a no-op for anything not `.lms`-marked. Without this, every
        // converted track's embedded title/artist/album/artwork silently
        // failed to read and fell back to the raw filename (still showing
        // the inner ".m4a"/etc extension) — the "still seeing .m4a in the
        // title" / "metadata and artwork data is bugged" reports.
        let readableURL = LumisoundExclusiveExtensionService.playableURL(for: url)
        var loadedDuration: Double = 0

        // Filename fallback title: strip BOTH the outer Lumisound marker
        // (".lms") and the real container extension underneath it
        // (`effectiveExtension`'s counterpart for the whole filename) — a
        // plain `url.deletingPathExtension()` only strips one level, which
        // for a locked "Song.m4a.lms" file left the fallback title reading
        // "Song.m4a" whenever the metadata read above came up empty.
        let fallbackTitle = LumisoundExclusiveExtensionService.isConverted(url)
            ? url.deletingPathExtension().deletingPathExtension().lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        var title = fallbackTitle
        var artist = ""
        var album = ""
        var genre = ""
        var trackNumber = 0
        var year = ""
        var sourceTrackID: String?
        // Set true only by the parent-folder-name fallback below — never by
        // an actual embedded/enriched tag — so the Albums tab can tell a real
        // album apart from a folder name standing in for one. See
        // `Song.albumInferredFromFolder`.
        var albumInferredFromFolder = false

        var sampleRate = 0
        var bitrate = 0
        // Tags + stream properties from the Rust core (lofty, every
        // container incl. Opus); AVFoundation only if it can't parse the file.
        if let r = scanReadTrack(path: url.path, cacheDir: CoreAudio.unlockDir) {
            title = r.title
            artist = r.artist
            album = r.album
            albumInferredFromFolder = r.albumInferredFromFolder
            genre = r.genre
            year = r.year
            trackNumber = Int(r.trackNumber)
            sourceTrackID = r.sourceTrackId
            loadedDuration = r.duration
            sampleRate = Int(r.sampleRate)
            bitrate = Int(r.bitrateKbps)
            if sourceTrackID == nil, ["m4a", "mp4", "m4v", "mov"].contains(LumisoundExclusiveExtensionService.effectiveExtension(for: url)) {
                // Files tagged by the older AVFoundation exporter carry the id
                // as a QuickTime mdta key only AVFoundation reads.
                sourceTrackID = await LumisoundExclusiveExtensionService.embeddedSourceTrackID(fileURL: url)
            }
        } else {
        let asset = AVURLAsset(url: readableURL)
        loadedDuration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let metadata = (try? await asset.load(.metadata)) ?? []
        for item in commonMetadata {
            switch item.commonKey?.rawValue {
            case "title":
                title = item.stringValue ?? title
            case "artist":
                artist = item.stringValue ?? artist
            // AVFoundation's common key is "albumName"
            // (`AVMetadataKey.commonKeyAlbumName`), not "album". Matching only
            // "album" meant embedded album tags were never read: every imported
            // file fell through to the folder-name fallback below (shown as
            // "Unknown Album" in the Albums tab) unless the online iTunes
            // lookup happened to find one. "album" is kept in case any
            // container reports it that way.
            case "albumName", "album":
                album = item.stringValue ?? album
            default:
                break
            }
        }

        // Scan all metadata (covers ID3, iTunes atoms, etc.) for fields not
        // available through the common key set.
        for item in metadata {
            let idRaw = item.identifier?.rawValue.lowercased() ?? ""
            let keyRaw = (item.key as? String)?.lowercased() ?? ""

            // Stable source ID embedded by the bridge's /api/download (e.g.
            // "youtube:dQw4w9WgXcQ") — stored as a custom MP4/ID3/Vorbis tag
            // named "LUMISOUND_ID". Surfaces under different identifier forms
            // depending on container, so check both the identifier and key.
            if sourceTrackID == nil, idRaw.contains("lumisound_id") || keyRaw.contains("lumisound_id") {
                sourceTrackID = item.stringValue
            }

            if genre.isEmpty, Self.isGenreIdentifier(idRaw), let raw = item.stringValue {
                genre = Self.cleanedGenre(raw)
            }

            // Track number — present as e.g. "tracknumber", "track", "itunes/tracknumber"
            if trackNumber == 0, Self.isTrackNumberIdentifier(idRaw) {
                if let raw = item.stringValue {
                    // ID3 TRCK can be "5/12" — take the part before the slash
                    let part = raw.split(separator: "/").first.map(String.init) ?? raw
                    trackNumber = Int(part.trimmingCharacters(in: .whitespaces)) ?? 0
                } else if let num = try? await item.load(.numberValue) {
                    trackNumber = num.intValue
                }
            }

            // Year — present as "year", "date", "recordingyear" depending on format
            if year.isEmpty,
               Self.isYearIdentifier(idRaw)
            {
                if let raw = item.stringValue {
                    // ISO 8601 date strings like "2003-11-06" — keep only the year portion
                    year = String(raw.prefix(4))
                } else if let num = try? await item.load(.numberValue) {
                    year = "\(num.intValue)"
                }
            }
        }

        // Extract audio technical properties via AVAudioFile, which is the
        // simplest way to get sampleRate without decoding format descriptions.

        if let audioFile = try? AVAudioFile(forReading: readableURL) {
            let rate = audioFile.processingFormat.sampleRate
            if rate > 0 { sampleRate = Int(rate.rounded()) }
        }

        // Bitrate lives in the audio track's format description (kCMFormatDescriptionExtension_VerbatimSampleDescription
        // or the audio stream basic description bitrate field is not always populated).
        // The most reliable cross-format path is through AVAssetTrack's estimatedDataRate.
        let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
        if let track = audioTracks?.first,
           let estimatedRate = try? await track.load(.estimatedDataRate),
           estimatedRate > 0
        {
            bitrate = Int((estimatedRate / 1000).rounded())   // store as kbps
        }

        // Opus/Ogg files: AVFoundation does not parse Vorbis comments from the Ogg container.
        // As a fallback, read the OpusTags packet directly from the binary file.
        // `effectiveExtension` (not raw `pathExtension`) so this still recognizes the
        // real container format for a file already converted to the Lumisound-exclusive
        // extension (see LumisoundExclusiveExtensionService) — its outer ".lms" alone
        // would otherwise look like neither opus/ogg nor a known video container.
        }
        let fileExt = LumisoundExclusiveExtensionService.effectiveExtension(for: url)
        let opusExtensions: Set<String> = ["opus", "ogg"]
        if opusExtensions.contains(fileExt), title == fallbackTitle {
            let vorbis = Self.readVorbisComments(url: readableURL)
            if let v = vorbis["TITLE"],  !v.isEmpty { title  = v }
            if let v = vorbis["ARTIST"], !v.isEmpty { artist = v }
            if let v = vorbis["ALBUM"],  !v.isEmpty { album  = v }
            if let v = vorbis["GENRE"],  !v.isEmpty { genre  = v }
            if let v = vorbis["DATE"] ?? vorbis["YEAR"], !v.isEmpty { year = String(v.prefix(4)) }
            if trackNumber == 0, let v = vorbis["TRACKNUMBER"] ?? vorbis["TRACK"], !v.isEmpty {
                trackNumber = Int(v.split(separator: "/").first.map(String.init) ?? v) ?? 0
            }
            if sourceTrackID == nil, let v = vorbis["LUMISOUND_ID"], !v.isEmpty {
                sourceTrackID = v
            }
        }

        // Filename fallback: if title is still the raw filename, try "Artist - Title" pattern
        if title == fallbackTitle && title.contains(" - ") {
            let parts = title.components(separatedBy: " - ")
            if parts.count >= 2 {
                if artist.isEmpty { artist = parts[0].trimmingCharacters(in: .whitespaces) }
                title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            }
        }

        // For video files (.mp4, .m4v, .mov), extract the first frame as artwork and
        // write it to both memory and disk cache so it survives restarts.
        let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
        if videoExtensions.contains(fileExt) {
            let asset = AVURLAsset(url: readableURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            let time = CMTime(seconds: 1, preferredTimescale: 600)
            var thumbImage: UIImage?
            if #available(iOS 16, *) {
                thumbImage = (try? await generator.image(at: time)).map { UIImage(cgImage: $0.image) }
            } else {
                thumbImage = (try? generator.copyCGImage(at: time, actualTime: nil)).map { UIImage(cgImage: $0) }
            }
            if let img = thumbImage {
                ArtworkService.shared.cacheImage(img, forKey: url.lastPathComponent)
            }
        }

        // When no album tag is present, use the immediate parent folder name as album
        // so music organised in Artist/Album/track.mp3 structures is grouped correctly.
        // This is a display/local-grouping convenience only — `albumInferredFromFolder`
        // marks it as such so the Albums tab (which must stay strictly metadata-derived,
        // per FoldersTab already being the real "browse by folder" feature) can exclude
        // it from the albums grid instead of showing the user's own folder name
        // disguised as an album.
        if album.isEmpty {
            let parentName = url.deletingLastPathComponent().lastPathComponent
            let skipFolders: Set<String> = ["Imported Music", "Documents", ""]
            if !skipFolders.contains(parentName) {
                album = parentName
                albumInferredFromFolder = true
            }
        }

        // Derive a stable ID from the file's path relative to Documents rather than
        // a fresh random UUID. A random ID meant every re-import (cache miss after
        // an app reinstall changed the sandbox container UUID, or simply a modified
        // file) minted a brand-new identity — silently orphaning any favorite or
        // playlist entry that referenced the old ID. Keying on the relative path
        // keeps the same song's identity stable across rescans and reinstalls.
        let stableID = ScanCacheService.documentsRelativePath(for: url).map { "local:\($0)" }
        let dateAdded = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate

        var song = Song(
            id: stableID ?? UUID().uuidString,
            title: title,
            artist: artist,
            album: album,
            duration: loadedDuration.isFinite ? loadedDuration : 0,
            url: url,
            artworkCacheKey: url.lastPathComponent,
            trackNumber: trackNumber,
            year: year,
            genre: genre,
            bitrate: bitrate,
            sampleRate: sampleRate,
            sourceTrackID: sourceTrackID,
            dateAdded: dateAdded
        )
        song.albumInferredFromFolder = albumInferredFromFolder

        appLog("Metadata: \"\(song.title)\" by \(song.artist.isEmpty ? "unknown" : song.artist) [\(fileExt), \(String(format: "%.0f", song.duration))s]\(albumInferredFromFolder ? " (album inferred from folder name)" : "")", category: "library")
        // Explicit line for sourceTrackID specifically — it's the single
        // field ArtworkService's deterministic hqdefault.jpg fallback
        // depends on (see that file's "no sourceTrackID" log), so knowing
        // right at import time whether a track got one (and from where) is
        // what actually lets a later "no artwork" report be traced back to
        // its root cause instead of guessing.
        if let sourceTrackID {
            appLog("Metadata: sourceTrackID=\(sourceTrackID) for \"\(song.title)\"", category: "library")
        } else {
            appLog("Metadata: no sourceTrackID found for \"\(song.title)\" (ext=\(fileExt)) — checked commonMetadata, all metadata items, and vorbis comments if applicable", category: "library")
        }

        // Enrich sparse metadata via iTunes Search API. Only fires when artist or
        // genre is missing — common for YouTube downloads where yt-dlp fills in
        // title but leaves artist/album blank. Results are cached across restarts
        // via UserDefaults so the API isn't hit every launch.
        if song.artist.isEmpty || song.album.isEmpty || song.genre.isEmpty {
            song = await Self.enrichFromCache(song: song)
        }

        return song
    }

    /// Lightweight, local-only re-read of a track's embedded tags — used by the
    /// periodic background metadata refresh. Unlike `makeSong`, this skips the
    /// `AVAudioFile`/bitrate probe, the video-artwork-frame extraction, and the
    /// online iTunes/MusicBrainz/Deezer enrichment chain, so it's cheap enough to
    /// run on a small rotating batch of tracks every few minutes. Returns `nil`
    /// if nothing changed (the common case), so callers can skip persistence work.
    func refreshTags(for url: URL, current: Song) async -> Song? {
        // See makeSong's `readableURL` comment — a `.lms`-locked track's raw
        // bytes aren't a valid audio container to AVFoundation.
        let readableURL = LumisoundExclusiveExtensionService.playableURL(for: url)
        let asset = AVURLAsset(url: readableURL)
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let metadata = (try? await asset.load(.metadata)) ?? []

        var title = current.title
        var artist = current.artist
        var album = current.album
        // Genre and year start empty so the file's own tags win: carried
        // over, a value an earlier online lookup guessed (before these tags
        // could be read at all) would block the real one. Restored below
        // when the file has none.
        var genre = ""
        var trackNumber = current.trackNumber
        var year = ""
        var sourceTrackID = current.sourceTrackID

        for item in commonMetadata {
            switch item.commonKey?.rawValue {
            case "title":
                title = item.stringValue ?? title
            case "artist":
                artist = item.stringValue ?? artist
            // "albumName", not "album" — see `makeSong`.
            case "albumName", "album":
                album = item.stringValue ?? album
            default:
                break
            }
        }

        for item in metadata {
            let idRaw = item.identifier?.rawValue.lowercased() ?? ""
            let keyRaw = (item.key as? String)?.lowercased() ?? ""

            if sourceTrackID == nil, idRaw.contains("lumisound_id") || keyRaw.contains("lumisound_id") {
                sourceTrackID = item.stringValue
            }

            if genre.isEmpty, Self.isGenreIdentifier(idRaw), let raw = item.stringValue {
                genre = Self.cleanedGenre(raw)
            }

            if trackNumber == 0, Self.isTrackNumberIdentifier(idRaw) {
                if let raw = item.stringValue {
                    let part = raw.split(separator: "/").first.map(String.init) ?? raw
                    trackNumber = Int(part.trimmingCharacters(in: .whitespaces)) ?? 0
                } else if let num = try? await item.load(.numberValue) {
                    trackNumber = num.intValue
                }
            }

            if year.isEmpty,
               Self.isYearIdentifier(idRaw)
            {
                if let raw = item.stringValue {
                    year = String(raw.prefix(4))
                } else if let num = try? await item.load(.numberValue) {
                    year = "\(num.intValue)"
                }
            }
        }

        let fileExt = LumisoundExclusiveExtensionService.effectiveExtension(for: url)
        let opusExtensions: Set<String> = ["opus", "ogg"]
        let fallbackTitle = LumisoundExclusiveExtensionService.isConverted(url)
            ? url.deletingPathExtension().deletingPathExtension().lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        if opusExtensions.contains(fileExt), title == fallbackTitle {
            let vorbis = Self.readVorbisComments(url: readableURL)
            if let v = vorbis["TITLE"],  !v.isEmpty { title  = v }
            if let v = vorbis["ARTIST"], !v.isEmpty { artist = v }
            if let v = vorbis["ALBUM"],  !v.isEmpty { album  = v }
            if let v = vorbis["GENRE"],  !v.isEmpty { genre  = v }
            if let v = vorbis["DATE"] ?? vorbis["YEAR"], !v.isEmpty { year = String(v.prefix(4)) }
            if trackNumber == 0, let v = vorbis["TRACKNUMBER"] ?? vorbis["TRACK"], !v.isEmpty {
                trackNumber = Int(v.split(separator: "/").first.map(String.init) ?? v) ?? 0
            }
            if sourceTrackID == nil, let v = vorbis["LUMISOUND_ID"], !v.isEmpty {
                sourceTrackID = v
            }
        }

        if title == fallbackTitle && title.contains(" - ") {
            let parts = title.components(separatedBy: " - ")
            if parts.count >= 2 {
                if artist.isEmpty { artist = parts[0].trimmingCharacters(in: .whitespaces) }
                title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            }
        }

        var albumInferredFromFolder = false
        if album.isEmpty {
            let parentName = url.deletingLastPathComponent().lastPathComponent
            let skipFolders: Set<String> = ["Imported Music", "Documents", ""]
            if !skipFolders.contains(parentName) {
                album = parentName
                albumInferredFromFolder = true
            }
        }

        if genre.isEmpty { genre = current.genre }
        if year.isEmpty { year = current.year }

        guard title != current.title || artist != current.artist || album != current.album
            || genre != current.genre || year != current.year || trackNumber != current.trackNumber
            || sourceTrackID != current.sourceTrackID
        else {
            return nil
        }

        // Specifically call out a sourceTrackID recovery/loss — this is the
        // periodic re-scan (LibraryManager.startPeriodicMetadataRefresh)
        // catching up on a field the initial `makeSong` import missed, which
        // directly unlocks ArtworkService's deterministic hqdefault.jpg
        // fallback for a track that couldn't use it before.
        if current.sourceTrackID == nil, sourceTrackID != nil {
            appLog("refreshTags: recovered sourceTrackID=\(sourceTrackID!) for \"\(current.title)\" on re-scan", category: "library")
        } else if current.sourceTrackID != nil, sourceTrackID == nil {
            appWarn("refreshTags: lost previously-known sourceTrackID for \"\(current.title)\" on re-scan", category: "library")
        }

        var refreshed = current
        refreshed.title = title
        refreshed.artist = artist
        refreshed.album = album
        refreshed.genre = genre
        refreshed.year = year
        refreshed.trackNumber = trackNumber
        refreshed.sourceTrackID = sourceTrackID
        // Only touch the "is this album name real metadata or a folder-name
        // stand-in" flag when `album` actually changed this pass — otherwise
        // carry forward whatever `current` already had (copied in via
        // `var refreshed = current` above). If it changed via the fallback
        // above, mark it inferred; if it changed any other way, a real tag
        // read produced it, so it's no longer folder-inferred even if it was
        // before (e.g. the file was retagged since the last scan).
        if album != current.album {
            refreshed.albumInferredFromFolder = albumInferredFromFolder
        }
        return refreshed
    }

    // MARK: - Tag identifiers
    //
    // Format-specific metadata identifiers, lowercased. Matching only on words
    // like "genre" / "year" / "tracknumber" caught QuickTime and Vorbis-style
    // names but none of the ID3 frames (id3/TCON, id3/TYER, id3/TDRC,
    // id3/TRCK) or iTunes atoms (itsk/©gen, itsk/©day) that MP3 and M4A files
    // actually use. So genre, year and track number were never read from
    // MP3s. The missing genre then sent every such track to the online
    // lookup, which filled in the year of whatever real song matched the
    // title.

    static func isGenreIdentifier(_ id: String) -> Bool {
        id.contains("genre") || id.hasSuffix("/tcon") || id.hasSuffix("%a9gen") || id.hasSuffix("\u{a9}gen")
    }

    static func isYearIdentifier(_ id: String) -> Bool {
        id.contains("year") || id.contains("date")
            || id.hasSuffix("/tyer") || id.hasSuffix("/tdrc") || id.hasSuffix("/tory")
            || id.hasSuffix("%a9day") || id.hasSuffix("\u{a9}day")
    }

    static func isTrackNumberIdentifier(_ id: String) -> Bool {
        id.contains("tracknumber") || id.hasSuffix("/track") || id.hasSuffix("/trck") || id.hasSuffix("/trkn")
    }

    /// ID3 genres can be stored as a numeric reference, "(17)" or "(17)Rock".
    /// Keeps the text when there is some; otherwise returns the raw value.
    static func cleanedGenre(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")") else { return trimmed }
        let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? trimmed : rest
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

    // MARK: - Vorbis comment binary parser

    /// Reads Vorbis comments directly from the binary data of an Opus (Ogg) file.
    ///
    /// AVFoundation does not expose Vorbis comments for .opus/.ogg files through the
    /// standard `AVURLAsset.commonMetadata` or `.metadata` APIs. The OpusTags packet
    /// lives in the SECOND Ogg page of the stream and has a simple binary format:
    ///   "OpusTags" magic | vendor string (length + UTF-8) | user comment list
    /// Each user comment is a "KEY=VALUE" UTF-8 string preceded by its 4-byte LE length.
    static func readVorbisComments(url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 60 else { return [:] }
        let bytes = data

        // Walk Ogg pages; we want the SECOND one (OpusTags)
        var offset = 0
        var pageIndex = 0

        while offset + 27 < bytes.count {
            // Verify OggS capture pattern
            guard bytes[offset] == 0x4F, bytes[offset+1] == 0x67,
                  bytes[offset+2] == 0x67, bytes[offset+3] == 0x53 else { break }

            let segCount = Int(bytes[offset + 26])
            let headerSize = 27 + segCount
            guard offset + headerSize <= bytes.count else { break }

            // Sum segment sizes to find page data length
            var pageDataLen = 0
            for i in 0..<segCount { pageDataLen += Int(bytes[offset + 27 + i]) }

            let dataStart = offset + headerSize
            guard dataStart + pageDataLen <= bytes.count else { break }

            pageIndex += 1
            if pageIndex == 2 {
                // OpusTags magic
                let magic = [UInt8]("OpusTags".utf8)
                guard pageDataLen >= 8,
                      bytes[dataStart..<(dataStart+8)].elementsEqual(magic) else { break }

                var pos = dataStart + 8

                // Skip vendor string
                guard pos + 4 <= bytes.count else { break }
                let vendorLen = le32(bytes, pos); pos += 4
                pos += vendorLen

                // Comment count
                guard pos + 4 <= bytes.count else { break }
                let count = le32(bytes, pos); pos += 4

                var result: [String: String] = [:]
                for _ in 0..<min(count, 200) {
                    guard pos + 4 <= bytes.count else { break }
                    let cLen = le32(bytes, pos); pos += 4
                    guard cLen > 0, pos + cLen <= bytes.count else { pos += cLen; continue }
                    if let str = String(bytes: bytes[pos..<(pos+cLen)], encoding: .utf8),
                       let eq = str.firstIndex(of: "=") {
                        let key   = String(str[str.startIndex..<eq]).uppercased()
                        let value = String(str[str.index(after: eq)...])
                        result[key] = value
                    }
                    pos += cLen
                }
                return result
            }

            offset = dataStart + pageDataLen
        }
        return [:]
    }

    /// Reads a 4-byte little-endian UInt32 from `data` at `offset`.
    private static func le32(_ data: Data, _ offset: Int) -> Int {
        Int(UInt32(data[offset])
          | UInt32(data[offset+1]) << 8
          | UInt32(data[offset+2]) << 16
          | UInt32(data[offset+3]) << 24)
    }
}
