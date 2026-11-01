import Foundation

/// Starts/polls/fetches results from the server-side AI stem-separation job
/// (see stem_separation.py + the `/api/stem-separation*` endpoints in
/// main.py). Real source separation (Demucs), not the on-device "Karaoke"
/// effect (AVAudioUnitEQ vocal-range notch — see AudioEffectsService) which
/// is a much cruder approximation; this is a distinct, heavier feature.
@MainActor
final class StemSeparationService: ObservableObject {
    enum State: Equatable {
        case idle
        case uploading
        case separating
        case done(vocalsURL: URL, instrumentalURL: URL)
        case failed(String)
    }

    @Published var state: State = .idle

    func separate(song: Song) async {
        guard let account = AccountService.shared, account.isLoggedIn else {
            state = .failed("Sign in to use stem separation.")
            return
        }
        state = .uploading
        do {
            let jobID = try await startJob(song: song, account: account)
            state = .separating
            let stems = try await pollAndDownload(jobID: jobID, account: account, title: song.title)
            state = .done(vocalsURL: stems.vocals, instrumentalURL: stems.instrumental)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "Separation failed.")
        }
    }

    func reset() {
        state = .idle
    }

    private func startJob(song: Song, account: AccountService) async throws -> String {
        let base = account.bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // YouTube-sourced: the bridge fetches audio itself (same as
        // /api/download), nothing to upload. Anything else (local import,
        // Personal Cloud Library, SoundCloud) has no server-side copy this
        // endpoint already knows how to reach, so the raw bytes go in the
        // request body instead.
        var videoID: String?
        if let sourceTrackID = song.sourceTrackID, sourceTrackID.hasPrefix("youtube:") {
            videoID = String(sourceTrackID.dropFirst("youtube:".count))
        }

        var components = URLComponents(string: base + "/api/stem-separation")
        var queryItems = [URLQueryItem(name: "title", value: song.title)]
        if let videoID { queryItems.append(URLQueryItem(name: "video_id", value: videoID)) }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw StemSeparationError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        if let tok = account.token {
            request.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }

        if videoID == nil {
            guard let songURL = song.url else { throw StemSeparationError.noAudioSource }
            let playableURL = LumisoundExclusiveExtensionService.playableURL(for: songURL)
            let data = try Data(contentsOf: playableURL)
            guard data.count <= 60 * 1024 * 1024 else { throw StemSeparationError.fileTooLarge }
            request.httpBody = data
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await Core.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StemSeparationError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct StartPayload: Decodable { let job_id: String }
        return try JSONDecoder().decode(StartPayload.self, from: data).job_id
    }

    private func pollAndDownload(jobID: String, account: AccountService, title: String) async throws -> (vocals: URL, instrumental: URL) {
        let base = account.bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let statusURL = URL(string: "\(base)/api/stem-separation/status?job_id=\(jobID)") else {
            throw StemSeparationError.invalidURL
        }
        struct StatusPayload: Decodable { let status: String; let error: String? }

        // A little past the server's own SEPARATION_TIMEOUT_SECONDS (600s,
        // see stem_separation.py) — the server itself gives up first, so
        // this is a backstop against an unreachable/hung bridge, not the
        // primary timeout.
        let deadline = Date().addingTimeInterval(630)
        while true {
            if Date() > deadline { throw StemSeparationError.timedOut }
            var request = URLRequest(url: statusURL)
            if let tok = account.token { request.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization") }
            let (data, _) = try await Core.data(for: request)
            let status = try JSONDecoder().decode(StatusPayload.self, from: data)
            switch status.status {
            case "done":
                let vocals = try await downloadStem(jobID: jobID, stem: "vocals", title: title, account: account)
                let instrumental = try await downloadStem(jobID: jobID, stem: "instrumental", title: title, account: account)
                return (vocals, instrumental)
            case "error":
                throw StemSeparationError.serverMessage(status.error ?? "Separation failed.")
            default:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func downloadStem(jobID: String, stem: String, title: String, account: AccountService) async throws -> URL {
        let base = account.bridgeURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/stem-separation/result?job_id=\(jobID)&stem=\(stem)") else {
            throw StemSeparationError.invalidURL
        }
        var request = URLRequest(url: url)
        if let tok = account.token { request.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization") }
        let (tempURL, response) = try await Core.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StemSeparationError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeTitle)-\(stem).m4a")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
}

enum StemSeparationError: LocalizedError {
    case invalidURL
    case noAudioSource
    case fileTooLarge
    case timedOut
    case serverError(Int)
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Couldn't reach the bridge."
        case .noAudioSource: return "This track has no audio to separate."
        case .fileTooLarge: return "This file is too large to upload for separation (60 MB max)."
        case .timedOut: return "Separation is taking longer than expected — try again later."
        case .serverError(let code): return "Server error (\(code))."
        case .serverMessage(let message): return message
        }
    }
}
