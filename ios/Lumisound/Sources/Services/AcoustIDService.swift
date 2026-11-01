import Foundation
import AVFoundation

// MARK: - AcoustIDService
//
// Identifies a track via Chromaprint audio fingerprint + the AcoustID/
// MusicBrainz database (POST /api/fingerprint/identify on the bridge), for
// tracks whose title/artist tags are wrong — a text-search-based lookup like
// MetadataFetchService can't help there, since the search query itself would
// use the wrong tags.
//
// Requires the user to be logged in (uses the same personal-session auth as
// AccountService) and to have a personal AcoustID API key configured in
// Settings — free registration at acoustid.org. There's no server-wide
// fallback key (unlike YouTube's): an AcoustID client key identifies an
// *application* registration, not a shared per-request credential, so each
// user brings their own.
//
// Only the first ~2 minutes of audio are needed to fingerprint a track (see
// the bridge's `fpcalc -length 120`), so the local file is trimmed and
// re-encoded to a small AAC clip before upload rather than sending the whole
// (possibly lossless, tens-of-MB) file. The bridge discards the upload
// immediately after fingerprinting it — nothing is persisted server-side.

// @MainActor (not a plain `actor`, matching AccountService/StreamingService)
// because `identify(song:)` reads AccountService.shared's MainActor-isolated
// `isLoggedIn`/`token`/`bridgeURL` synchronously. The async network/export
// work inside still suspends normally without blocking the UI thread.
@MainActor
final class AcoustIDService {
    static let shared = AcoustIDService()

    private init() {}

    struct Match {
        let title: String
        let artist: String?
        let album: String?
        let score: Double
    }

    enum IdentifyError: LocalizedError {
        case notLoggedIn
        case noLocalFile
        case trimFailed
        case notMatched
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "Sign in to identify tracks."
            case .noLocalFile: return "This track has no local audio file to analyze."
            case .trimFailed:  return "Couldn't prepare this track's audio for analysis."
            case .notMatched:  return "No confident match found for this track."
            case .server(let detail): return detail
            }
        }
    }

    /// Trims `song`'s local file to its first ~2 minutes, uploads that clip
    /// for fingerprint identification, and returns the best match. Throws
    /// `.noAPIKeyConfigured`-equivalent via `.server(...)` when the bridge
    /// reports no AcoustID key is set (HTTP 400) — see `Server error` mapping
    /// below, which surfaces the bridge's own "Add one in Settings" detail.
    func identify(song: Song) async throws -> Match {
        guard let rawURL = song.url, rawURL.isFileURL else {
            throw IdentifyError.noLocalFile
        }
        // A `.lms`-locked url's on-disk bytes are XOR-masked and unreadable
        // by AVURLAsset until unlocked -- without this, AcoustID identification
        // threw .trimFailed for every locked track.
        let sourceURL = LumisoundExclusiveExtensionService.playableURL(for: rawURL)

        let clipURL = try await trimmedClip(from: sourceURL)
        defer { try? FileManager.default.removeItem(at: clipURL) }

        guard let clipData = try? Data(contentsOf: clipURL) else {
            throw IdentifyError.trimFailed
        }
        return try await uploadForIdentification(clipData)
    }

    /// Identifies whatever's in an already-recorded `.m4a` clip — used by
    /// `NameThatTuneService` for a live-microphone "what's this song"
    /// lookup rather than fingerprinting a file already in the library.
    /// No local-file/trim step needed: the recording is already short
    /// (~12-15s) and already `.m4a`.
    func identify(recordingURL: URL) async throws -> Match {
        guard let clipData = try? Data(contentsOf: recordingURL) else {
            throw IdentifyError.trimFailed
        }
        return try await uploadForIdentification(clipData)
    }

    /// Shared upload + response-parsing path for both entry points above.
    private func uploadForIdentification(_ clipData: Data) async throws -> Match {
        guard let account = AccountService.shared, account.isLoggedIn, let token = account.token else {
            throw IdentifyError.notLoggedIn
        }

        let base = account.bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: base + "/api/fingerprint/identify")
        components?.queryItems = [URLQueryItem(name: "ext", value: "m4a")]
        guard let requestURL = components?.url else {
            throw IdentifyError.server("Invalid bridge URL")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = clipData

        let (responseData, response) = try await Core.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let detail = try? JSONDecoder().decode(ErrorBody.self, from: responseData) {
                throw IdentifyError.server(detail.detail)
            }
            throw IdentifyError.server("Server error (HTTP \(http.statusCode))")
        }

        let decoded = try JSONDecoder().decode(IdentifyResponse.self, from: responseData)
        guard decoded.matched, let title = decoded.title else {
            throw IdentifyError.notMatched
        }
        return Match(title: title, artist: decoded.artist, album: decoded.album, score: decoded.score ?? 0)
    }

    // MARK: - Trim to a small AAC clip

    /// Exports the first 120s (or the whole track, if shorter) of `url` as a
    /// small AAC-M4A clip in a temp location. Same export pattern as
    /// `AudioEncoderService.aacExport` — a proven, low-risk AVFoundation
    /// path — with a `timeRange` added to cap the clip length.
    private func trimmedClip(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw IdentifyError.trimFailed
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("acoustid_clip_\(UUID().uuidString).m4a")

        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else {
            throw IdentifyError.trimFailed
        }
        let clipSeconds = min(duration.seconds, 120)
        session.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: clipSeconds, preferredTimescale: 600)
        )
        session.outputFileType = .m4a
        session.outputURL = outURL

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: outURL)
            throw IdentifyError.trimFailed
        }
        return outURL
    }

    // MARK: - Response types

    private struct IdentifyResponse: Decodable {
        let matched: Bool
        let title: String?
        let artist: String?
        let album: String?
        let score: Double?
    }

    private struct ErrorBody: Decodable {
        let detail: String
    }
}
