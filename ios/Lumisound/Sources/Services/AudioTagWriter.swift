import AVFoundation

/// On-device audio metadata embedding — used by the download-relay path
/// (`StreamingService+DownloadToLibrary.swift`) since that path fetches raw
/// CDN bytes with no server-side tagging (`ios-bridge/main.py`'s
/// `/api/download/relay` deliberately does none, unlike the job-based
/// `/api/download` flow, which still embeds tags server-side via ffmpeg).
///
/// Writes the same fields the server used to embed: title/artist/album
/// (common-keyspace items, read back by `DocumentImportService.makeSong`
/// via `commonMetadata`) and a custom `LUMISOUND_ID` tag (read back via a
/// case-insensitive substring match on the item's identifier/key — see
/// `DocumentImportService.swift`).
enum AudioTagWriter {

    /// Embeds metadata into the file at `url`, returning a NEW file at a
    /// sibling temp URL — the original, untagged file at `url` is left
    /// untouched. Returns `nil` on any failure; callers MUST treat that as
    /// "fall back to the original, untagged file" rather than an error —
    /// losing the `LUMISOUND_ID` tag only means `DownloadLedgerStore`'s
    /// existing belt-and-suspenders dedup carries the load instead of the
    /// embedded-tag detection in `DocumentImportService`.
    /// Containers AVFoundation cannot demux, and therefore cannot tag.
    ///
    /// `tag` exports to m4a via AVAssetExportSession, which requires the SOURCE
    /// to be readable by AVFoundation. Ogg/Opus and WebM are not: there is no Ogg
    /// demuxer on the platform at all (the same limitation that makes
    /// `scheduleCurrent` route these through a transcode, and that leaves
    /// `Song.sourceTrackID` nil for every .opus download). Passthrough export of
    /// one of these "succeeds" and produces an unreadable file.
    private static let untaggableExtensions: Set<String> = ["opus", "ogg", "oga", "webm"]

    /// Whether tagging this file can possibly work.
    ///
    /// Exists because the failure was being discovered the expensive way, over and
    /// over: the caller exported, the export reported success, the output failed
    /// its readability check, and the whole thing was retried on the next pass.
    /// Telemetry counted 29,436 such failures across 340 Ogg/Opus files — an
    /// average of 87 attempts each — none of which could ever have succeeded.
    /// Checked through `effectiveExtension` so a `.lms`-locked file is judged by
    /// the real container inside it rather than by the lock's own extension.
    static func canTag(fileAt url: URL) -> Bool {
        tagsCanWrite(path: url.path) || !untaggableExtensions.contains(
            LumisoundExclusiveExtensionService.effectiveExtension(for: url))
    }

    static func tag(
        fileAt url: URL,
        title: String?,
        artist: String?,
        album: String?,
        sourceTrackID: String,
        thumbnailURL: String? = nil,
        genre: String? = nil,
        year: String? = nil,
        trackNumber: Int? = nil
    ) async -> URL? {
        // Refused up front rather than discovered after a failed export. Logged
        // at info, not warning: for an Ogg/Opus library this is the expected
        // answer for every track, and 29k warnings about an unsupported container
        // buried the telemetry it was competing with.
        // Rust core (lofty): tags written in place on a copy, any container
        // (Opus/Ogg included), no re-encode. AVFoundation export below is
        // only the fallback for files lofty can't parse.
        let effectiveExt = LumisoundExclusiveExtensionService.effectiveExtension(for: url)
        if tagsCanWrite(path: url.path) {
            let copy = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension(effectiveExt)
            do {
                try FileManager.default.copyItem(at: url, to: copy)
                try tagsWrite(path: copy.path, tags: TrackTags(
                    title: title, artist: artist, album: album, genre: genre, year: year,
                    trackNumber: trackNumber.flatMap { $0 > 0 ? UInt32($0) : nil },
                    sourceTrackId: sourceTrackID.isEmpty ? nil : sourceTrackID, thumbnailUrl: thumbnailURL))
                appLog("AudioTagWriter: tagged in place (\(effectiveExt), sourceTrackID: \(sourceTrackID))", category: "network")
                return copy
            } catch {
                try? FileManager.default.removeItem(at: copy)
                appWarn("AudioTagWriter: core tag write failed (\(error.localizedDescription)) — trying AVFoundation export", category: "network")
            }
        }
        guard canTag(fileAt: url) else {
            appLog("AudioTagWriter: \(url.lastPathComponent) is a container AVFoundation cannot tag — skipping (sourceTrackID: \(sourceTrackID))", category: "network")
            return nil
        }

        let startTime = Date()
        let outURL = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let asset = AVURLAsset(url: url)
        guard let session = makeSession(asset: asset) else {
            appWarn("AudioTagWriter: could not create export session (passthrough and AAC presets both failed) for sourceTrackID: \(sourceTrackID)", category: "network")
            return nil
        }
        let presetUsed = session.presetName == AVAssetExportPresetPassthrough ? "passthrough" : "AAC-fallback"
        session.outputFileType = .m4a
        session.outputURL = outURL
        session.metadata = buildMetadataItems(
            title: title, artist: artist, album: album, sourceTrackID: sourceTrackID, thumbnailURL: thumbnailURL,
            genre: genre, year: year, trackNumber: trackNumber
        )

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        guard session.status == .completed else {
            appWarn("AudioTagWriter: export failed (preset: \(presetUsed), elapsed: \(String(format: "%.2f", elapsed))s, sourceTrackID: \(sourceTrackID)): \(session.error?.localizedDescription ?? "unknown error")", category: "network")
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
        // `.completed` is the export session's own status, not proof the
        // resulting file actually opens — a genuinely truncated/corrupt
        // output (the app backgrounded/memory-pressured mid-export, etc.)
        // can still report `.completed`. Verify before handing this back as
        // success, matching the same "confirm playable before trusting it"
        // rule AudioEncoderService.convertPermanently already follows —
        // every caller here goes on to either replace an existing good file
        // or import this as a brand-new one, so a false "success" is a real
        // corruption risk, not just a cosmetic one.
        guard CorruptFileFinderService.isValidAudioFile(at: outURL) else {
            appWarn("AudioTagWriter: export reported success but output is unreadable (preset: \(presetUsed), elapsed: \(String(format: "%.2f", elapsed))s, sourceTrackID: \(sourceTrackID))", category: "network")
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
        appLog("AudioTagWriter: tagged (preset: \(presetUsed), elapsed: \(String(format: "%.2f", elapsed))s, sourceTrackID: \(sourceTrackID))", category: "network")
        return outURL
    }

    /// Passthrough (stream copy, no re-encode) when available — the file is
    /// already whatever container/codec the source served, so there's no
    /// reason to spend time/quality re-encoding just to add tags. Falls back
    /// to the same AAC preset `AudioEncoderService.aacExport` already uses
    /// elsewhere in this app if passthrough isn't compatible with the asset.
    private static func makeSession(asset: AVURLAsset) -> AVAssetExportSession? {
        if let passthrough = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            return passthrough
        }
        return AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
    }

    private static func buildMetadataItems(
        title: String?, artist: String?, album: String?, sourceTrackID: String, thumbnailURL: String? = nil,
        genre: String? = nil, year: String? = nil, trackNumber: Int? = nil
    ) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func commonItem(_ identifier: AVMetadataIdentifier, _ value: String?) -> AVMutableMetadataItem? {
            guard let value, !value.isEmpty else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            return item
        }

        if let item = commonItem(.commonIdentifierTitle, title) { items.append(item) }
        if let item = commonItem(.commonIdentifierArtist, artist) { items.append(item) }
        if let item = commonItem(.commonIdentifierAlbumName, album) { items.append(item) }
        // iTunes-keyspace genre/year/track-number atoms — raw FourCC keys
        // (the standard, stable MP4/iTunes metadata list: "©gen"/"©day"/
        // "trkn"), not `AVMetadataIdentifier` enum cases, matching the same
        // `.keySpace`/`.key` construction the LUMISOUND_ID/THUMBNAIL items
        // below already use. `DocumentImportService.makeSong`'s generic
        // `.metadata` scan (`idRaw.contains("genre"/"year")`) picks these up
        // the same way it reads a bridge-downloaded file's tags, so a track
        // re-tagged here round-trips identically.
        func iTunesItem(_ key: String, _ value: String?) -> AVMutableMetadataItem? {
            guard let value, !value.isEmpty else { return nil }
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = key as NSString
            item.value = value as NSString
            return item
        }
        if let item = iTunesItem("\u{a9}gen", genre) { items.append(item) }
        if let item = iTunesItem("\u{a9}day", year) { items.append(item) }
        if let trackNumber, trackNumber > 0 {
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = "trkn" as NSString
            item.value = trackNumber as NSNumber
            items.append(item)
        }

        // Custom LUMISOUND_ID tag. Matches what the server-side ffmpeg pass
        // used to write (a generic mp4 "mdta" metadata atom, forced via
        // `-movflags +use_metadata_tags` — see main.py's _do_download_job
        // comment on why that flag is required for mp4 to keep custom keys).
        // .quickTimeMetadata is that same generic-atom keyspace in
        // AVFoundation; its auto-derived identifier is "mdta/LUMISOUND_ID",
        // which lowercased contains "lumisound_id" — matching the reader's
        // case-insensitive substring check exactly. Skipped entirely when
        // empty (a plain local import with no bridge-assigned source id)
        // rather than writing a useless empty atom.
        if !sourceTrackID.isEmpty {
            let idItem = AVMutableMetadataItem()
            idItem.keySpace = .quickTimeMetadata
            idItem.key = "LUMISOUND_ID" as NSString
            idItem.value = sourceTrackID as NSString
            items.append(idItem)
        }

        // Same purpose as the server's own `LUMISOUND_THUMBNAIL` tag (see
        // main.py's tag_cmd) — ArtworkService.fetchEmbeddedThumbnailURL
        // reads this back as a recovery path when a track's cache-keyed
        // artwork ever goes missing (cache cleared, cache-format-version
        // purge, ...). Written here too so on-device tagging (this app's
        // relay-download path, and the repair migration for tracks whose
        // embedded metadata got wiped by an old re-encode bug) closes the
        // same gap the server-side job-based download path already covers.
        if let thumbnailURL, !thumbnailURL.isEmpty {
            let thumbItem = AVMutableMetadataItem()
            thumbItem.keySpace = .quickTimeMetadata
            thumbItem.key = "LUMISOUND_THUMBNAIL" as NSString
            thumbItem.value = thumbnailURL as NSString
            items.append(thumbItem)
        }

        return items
    }
}
