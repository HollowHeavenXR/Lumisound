import Foundation
import UIKit

extension StreamingService {

    // MARK: - Upload Track with Metadata

    /// Uploads a local audio file to the user's personal music library, passing
    /// client-supplied metadata as query parameters so the server can populate
    /// `ios_user_music_metadata` immediately without an ffprobe pass.
    /// Returns the `UserMusicMetadataTrack` row created on the server.
    func uploadTrack(fileURL: URL, token: String, metadata: TrackMetadata, folder: String = "") async throws -> UserMusicMetadataTrack {
        appLog("uploadTrack: \(fileURL.lastPathComponent)", category: "network")
        isUploadingUserMusic = true
        uploadProgress = 0
        defer { isUploadingUserMusic = false; uploadProgress = 0 }

        let filename = fileURL.lastPathComponent
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "filename", value: filename),
        ]
        if !folder.isEmpty {
            queryItems.append(URLQueryItem(name: "folder", value: folder))
        }
        if let v = metadata.title,          !v.isEmpty { queryItems.append(URLQueryItem(name: "title",       value: v)) }
        if let v = metadata.artist,         !v.isEmpty { queryItems.append(URLQueryItem(name: "artist",      value: v)) }
        if let v = metadata.album,          !v.isEmpty { queryItems.append(URLQueryItem(name: "album",       value: v)) }
        if let v = metadata.genre,          !v.isEmpty { queryItems.append(URLQueryItem(name: "genre",       value: v)) }
        if let v = metadata.year,           !v.isEmpty { queryItems.append(URLQueryItem(name: "year",        value: v)) }
        if let v = metadata.durationSeconds               { queryItems.append(URLQueryItem(name: "duration",    value: String(v))) }
        if let v = metadata.bitrate                       { queryItems.append(URLQueryItem(name: "bitrate",     value: String(v))) }
        if let v = metadata.sampleRate                    { queryItems.append(URLQueryItem(name: "sample_rate", value: String(v))) }
        if metadata.hasArtwork == true { queryItems.append(URLQueryItem(name: "has_artwork", value: "true")) }

        var components = URLComponents()
        components.path = "/user/music/upload"
        components.queryItems = queryItems

        guard var request = makeRequest(components.string ?? "/user/music/upload") else {
            throw StreamingError.invalidURL
        }
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let (body, response) = try await Core.upload(for: request, fromFile: fileURL)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 413: throw StreamingError.httpError(413)
            default:  throw StreamingError.httpError(http.statusCode)
            }
        }

        uploadProgress = 1.0
        appLog("uploadTrack: uploaded \(filename)", category: "network")

        // The bridge returns the stored row with the upload. Only an older
        // bridge without it needs the whole list re-downloaded (that used to
        // happen after EVERY upload: 5k+ tracks, many times a minute during a
        // backup).
        struct UploadResponse: Decodable { let track: UserMusicMetadataTrack? }
        let returned = (try? JSONDecoder().decode(UploadResponse.self, from: body))?.track
        if let returned { mergeUserMusicMetadata(returned) }
        let resolved: UserMusicMetadataTrack?
        if let returned {
            resolved = returned
        } else {
            resolved = try await fetchUserMusicMetadata(token: token).first(where: { $0.filename == filename })
        }
        if let match = resolved {
            // A locked (`.lms`) upload's `has_artwork` flag only records
            // THAT it has embedded art, not the art itself — the server
            // can't extract it (XOR-masked bytes, same limitation as
            // ffprobe/loudness analysis elsewhere in this pipeline), so
            // without this a locked cloud track never shows artwork
            // anywhere it's browsed from (this was the actual bug behind
            // "tvOS shows no artwork for uploaded tracks" — it's not
            // tvOS-specific, the bytes just never existed server-side for
            // ANY client to fetch). Best-effort, off the critical path —
            // the upload itself already succeeded regardless of this.
            if LumisoundExclusiveExtensionService.isConverted(fileURL), metadata.hasArtwork == true, !match.id.isEmpty {
                if let jpeg = await LumisoundExclusiveExtensionService.embeddedThumbnailJPEGData(fileURL: fileURL) {
                    do {
                        try await uploadArtworkThumbnail(jpeg, forMetadataID: match.id, token: token)
                    } catch {
                        appWarn("uploadTrack: thumbnail upload failed for \(filename): \(error.localizedDescription)", category: "network")
                    }
                }
            }
            return match
        }
        // Fallback: synthesise a minimal response from the query params
        return UserMusicMetadataTrack(
            id: "",
            filename: filename,
            originalFilename: filename,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            genre: metadata.genre,
            year: metadata.year,
            durationSeconds: metadata.durationSeconds,
            fileSizeBytes: nil,
            bitrate: metadata.bitrate,
            sampleRate: metadata.sampleRate,
            mimeType: nil,
            hasArtwork: false,
            uploadedAt: nil,
            artworkURL: nil,
            bpm: nil,
            musicalKey: nil,
            loudnessLufs: nil,
            gainDb: nil
        )
    }

    /// Uploads a pre-extracted JPEG thumbnail for a locked track's cloud
    /// backup — see `LumisoundExclusiveExtensionService.embeddedThumbnailJPEGData`
    /// and `/user/music/artwork-upload` in main.py for why this exists as
    /// its own call instead of riding along on the audio upload itself.
    func uploadArtworkThumbnail(_ jpegData: Data, forMetadataID metadataID: String, token: String) async throws {
        var components = URLComponents()
        components.path = "/user/music/artwork-upload"
        components.queryItems = [URLQueryItem(name: "id", value: metadataID)]
        guard var request = makeRequest(components.string ?? "/user/music/artwork-upload") else {
            throw StreamingError.invalidURL
        }
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpegData
        let (_, response) = try await Core.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StreamingError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Cheap, file-transfer-free fix for a track whose server-side
    /// `has_artwork` is wrong — specifically, a Lumisound-locked upload's was
    /// hardcoded `false` at upload time for a while (the server can't
    /// ffprobe locked bytes itself; see `_locked_inner_ext`'s doc comment on
    /// the bridge). Matches by the server's own on-disk `filename` (as
    /// returned by `/user/music/metadata`), not `fileURL`, since this is
    /// called for a track that's already uploaded — there's no local file
    /// transfer here, just one metadata column.
    @discardableResult
    func patchArtworkFlag(filename: String, hasArtwork: Bool, token: String) async throws -> Bool {
        var components = URLComponents()
        components.path = "/user/music/artwork-flag"
        components.queryItems = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "has_artwork", value: hasArtwork ? "true" : "false"),
        ]
        guard var request = makeRequest(components.string ?? "/user/music/artwork-flag") else {
            throw StreamingError.invalidURL
        }
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await Core.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return false
        }
        return true
    }
}
