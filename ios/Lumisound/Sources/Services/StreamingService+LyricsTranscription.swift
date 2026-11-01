import Foundation

// MARK: - Aria Lyrics Transcription

/// Result of `StreamingService.transcribeLyrics` — mirrors the shape
/// `/user/intelligence/lyrics-transcribe` returns.
struct LyricsTranscriptionResult {
    /// LRC-formatted text (`[mm:ss.xx]line` per line), ready to write
    /// straight to the same file `LyricsSyncEditorView`'s manual sync
    /// already writes to — see `NowPlayingView+Helpers.swift`'s
    /// `syncedLyricsURL(for:)`. Empty when `instrumental` is true.
    let lrc: String
    /// Words Aria made out but could NOT reliably time, one per line and with no
    /// timestamps. Populated (with `lrc` empty and `synced` false) when her
    /// timings fell outside the track's real length — see
    /// `lyrics_ai.timings_are_plausible` on the bridge. Worth keeping: the
    /// transcription itself is usually right even when the timing isn't.
    let plain: String
    /// False only for that case. Governs which file the caller writes to, which
    /// decides whether these outrank a genuinely-synced LRCLIB version later.
    let synced: Bool
    let instrumental: Bool
    let confidence: String
}

extension StreamingService {

    /// Has Aria Lumi listen to `song`'s own audio and produce (or, when
    /// `hintLyrics` is given, correct and re-time) synced lyrics for it —
    /// see `/user/intelligence/lyrics-transcribe` in main.py and
    /// `lyrics_ai.py` for how she actually does this (Gemini's native
    /// audio understanding, not a lyrics database lookup). This is the
    /// only lyrics source in the app that can produce anything for a
    /// user's own unreleased/personal recording, and the only one that
    /// verifies wording against the track's real audio rather than trusting
    /// fetched or imported text at face value.
    ///
    /// `hintLyrics`, when passed, should be whatever untimed text is
    /// already on hand for this track (an OVH fetch, a plain-text import) —
    /// Aria uses it as a starting point but still derives every timestamp
    /// from the audio herself and corrects any wording that doesn't match
    /// what she actually hears, so passing it both saves her work AND is
    /// the literal "cross-check this against what's playing" step.
    func transcribeLyrics(for song: Song, token: String, hintLyrics: String? = nil) async throws -> LyricsTranscriptionResult {
        guard let rawURL = song.url, rawURL.isFileURL else {
            throw StreamingError.invalidURL
        }
        // A Lumisound-locked (`.lms`) track's bytes are XOR-masked — Aria
        // (like the server's own ffprobe/loudness/artwork extraction
        // elsewhere in this app) can't listen to them directly. Upload the
        // unlocked, on-device-only view of the file instead, same as
        // `LumisoundExclusiveExtensionService.embeddedThumbnailJPEGData`
        // does for artwork.
        let uploadURL = LumisoundExclusiveExtensionService.playableURL(for: rawURL)

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "title", value: song.title.isEmpty ? song.displayName : song.title),
            URLQueryItem(name: "artist", value: song.artistName),
        ]
        // 6000-char server-side cap (see the endpoint's `max_length`) — an
        // oversized hint is truncated rather than failing the request, so a
        // very long imported lyrics file still gets SOME cross-check value
        // out of its first few thousand characters instead of none.
        if let hintLyrics, !hintLyrics.isEmpty {
            queryItems.append(URLQueryItem(name: "hint_lyrics", value: String(hintLyrics.prefix(6000))))
        }

        var components = URLComponents()
        components.path = "/user/intelligence/lyrics-transcribe"
        components.queryItems = queryItems

        guard var request = makeRequest(components.string ?? "/user/intelligence/lyrics-transcribe") else {
            throw StreamingError.invalidURL
        }
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(uploadURL.audioMIMEType, forHTTPHeaderField: "Content-Type")

        // Job-based, same shape as /api/download: this used to be a single
        // blocking upload+response held open until Gemini's native-audio
        // transcription finished, which for anything but a short track
        // routinely exceeded the Cloudflare Tunnel's ~100s edge timeout —
        // Aria could genuinely be in the middle of transcribing when the
        // connection got killed, surfacing as "doesn't complete"/a generic
        // network error even though nothing was actually wrong with the
        // transcription itself. Uploading now only needs to survive long
        // enough to hand the audio off and get a job_id back.
        request.timeoutInterval = 60

        let (startData, startResponse) = try await StreamingService.bulkTransferSession.upload(for: request, fromFile: uploadURL)
        guard let startHTTP = startResponse as? HTTPURLResponse, startHTTP.statusCode == 202 else {
            throw StreamingError.httpError((startResponse as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct StartPayload: Decodable { let job_id: String }
        guard let start = try? JSONDecoder().decode(StartPayload.self, from: startData),
              let statusURL = jobPollURL(from: request, path: "/user/intelligence/lyrics-transcribe/status", jobID: start.job_id) else {
            throw StreamingError.incompleteDownload
        }

        var statusRequest = request
        statusRequest.httpMethod = "GET"
        statusRequest.url = statusURL
        statusRequest.setValue(nil, forHTTPHeaderField: "Content-Type")
        statusRequest.timeoutInterval = 20

        struct StatusPayload: Decodable {
            let status: String
            let detail: String?
            let lrc: String?
            let plain: String?
            let synced: Bool?
            let instrumental: Bool?
            let confidence: String?
        }

        // Poll every 3s for up to 5 minutes — matches downloadToLibrary's
        // job-poll deadline; each poll itself is trivial and never
        // approaches the tunnel's edge timeout regardless of how long the
        // Gemini call actually takes server-side (bounded separately by the
        // 240s http_options timeout on lyrics_ai.py's generate_content call).
        let deadline = Date().addingTimeInterval(300)
        while true {
            if Date() > deadline {
                appWarn("transcribeLyrics: job poll timed out for \"\(song.displayName)\"", category: "network")
                throw StreamingError.timeout
            }
            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await Core.data(for: statusRequest)
            } catch {
                appWarn("transcribeLyrics: network error polling status for \"\(song.displayName)\": \(error.localizedDescription) — retrying poll", category: "network")
                try await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let status = try? JSONDecoder().decode(StatusPayload.self, from: data) else {
                throw StreamingError.incompleteDownload
            }
            switch status.status {
            case "pending":
                try await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            case "done":
                return LyricsTranscriptionResult(
                    lrc: status.lrc ?? "",
                    plain: status.plain ?? "",
                    // Absent on an older bridge, which only ever returned synced
                    // output — defaulting to true keeps that behaviour rather
                    // than silently treating every result as untimed.
                    synced: status.synced ?? true,
                    instrumental: status.instrumental ?? false,
                    confidence: status.confidence ?? "low"
                )
            default: // "error"
                appWarn("transcribeLyrics: job failed for \"\(song.displayName)\": \(status.detail ?? "unknown error")", category: "network")
                throw StreamingError.serverDetail(status.detail ?? "Aria couldn't transcribe this track.")
            }
        }
    }
}

private extension URL {
    /// Best-effort audio Content-Type from the file's real extension —
    /// good enough for the server's `ffmpeg`-free Gemini upload path,
    /// which only uses this to hint the audio codec, not to validate it.
    var audioMIMEType: String {
        switch pathExtension.lowercased() {
        case "mp3":         return "audio/mpeg"
        case "m4a", "mp4":  return "audio/mp4"
        case "aac":         return "audio/aac"
        case "flac":        return "audio/flac"
        case "wav":         return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "ogg":         return "audio/ogg"
        case "opus":        return "audio/opus"
        default:            return "audio/mpeg"
        }
    }
}
