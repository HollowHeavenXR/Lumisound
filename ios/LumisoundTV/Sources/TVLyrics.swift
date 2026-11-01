import Foundation

// MARK: - TVLyricLine / TVLrcParser
//
// Ported verbatim from ios/Lumisound/Sources/Utilities/LrcParser.swift — same
// LRC timestamp grammar (`[mm:ss]` or `[mm:ss.f]`/`[mm:ss.ff]`), same
// tenths-vs-hundredths fraction handling.

struct TVLyricLine: Identifiable, Hashable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

enum TVLrcParser {
    private static let pattern = #"\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,2}))?\]"#

    static func parse(_ content: String) -> [TVLyricLine] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var parsed: [TVLyricLine] = []

        for raw in content.split(whereSeparator: \.isNewline).map(String.init) {
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            let matches = regex.matches(in: raw, range: range)
            guard !matches.isEmpty else { continue }

            let text = regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            for match in matches {
                guard
                    let minuteRange = Range(match.range(at: 1), in: raw),
                    let secondRange = Range(match.range(at: 2), in: raw)
                else { continue }

                let minutes = TimeInterval(String(raw[minuteRange])) ?? 0
                let seconds = TimeInterval(String(raw[secondRange])) ?? 0
                var fraction: TimeInterval = 0

                if let fractionRange = Range(match.range(at: 3), in: raw) {
                    let digits = String(raw[fractionRange])
                    let value = TimeInterval(digits) ?? 0
                    fraction = digits.count == 1 ? value / 10 : value / 100
                }

                parsed.append(TVLyricLine(time: minutes * 60 + seconds + fraction, text: text))
            }
        }

        return parsed.sorted { $0.time < $1.time }
    }
}

// MARK: - TVLyricsService
//
// Looks for lyrics in three places, in this order:
//
//   1. **The Lumisound bridge** (`/user/lyrics`) — the account's own stored
//      lyrics: Aria's transcriptions, and corrections submitted from a phone.
//   2. **lrclib.net**, the public synced-lyrics database.
//   3. **api.lyrics.ovh**, plain text and unsynced, when lrclib has nothing.
//
// Step 1 was missing, and its absence is exactly why lyrics Aria had generated
// never appeared here. Aria's result was written to a file on the iPhone that
// asked for it and sent nowhere else, so no other device could see it — and
// this port only ever queried public databases, which by definition do not have
// those lyrics, because not being in a database is the whole reason Aria was
// asked to transcribe the track in the first place.
//
// The bridge's pre-existing `/api/lyrics` could not be used for this: it is
// gated on the SERVICE api key rather than a user token, so a tvOS request
// carrying an account JWT is rejected outright. `/user/lyrics` serves the same
// cache under user auth.

enum TVLyricsService {
    private static let headers = ["User-Agent": "Lumisound-tvOS/1.0 (https://github.com/HollowHeavenXR/Lumisound)"]

    static func fetch(title: String, artist: String, duration: TimeInterval) async -> [TVLyricLine]? {
        // Account-stored lyrics first — these are the ones the public databases
        // cannot supply, and a correction the user made should beat whatever
        // lrclib happens to hold.
        if let lines = await fetchFromBridge(title: title, artist: artist, duration: duration) {
            return lines
        }

        if duration > 0, var comps = URLComponents(string: "https://lrclib.net/api/get") {
            comps.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
            ]
            if let url = comps.url, let lines = await fetchGetResult(url: url, expectedDuration: duration) {
                return lines
            }
        }

        guard var searchComps = URLComponents(string: "https://lrclib.net/api/search") else { return await fetchPlainFallback(title: title, artist: artist) }
        searchComps.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let url = searchComps.url else { return await fetchPlainFallback(title: title, artist: artist) }

        var req = URLRequest(url: url)
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        req.timeoutInterval = 8

        guard let (data, resp) = try? await Core.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !results.isEmpty
        else { return await fetchPlainFallback(title: title, artist: artist) }

        let best: [String: Any]
        if duration > 0 {
            best = results.min {
                let d0 = ($0["duration"] as? Double) ?? .infinity
                let d1 = ($1["duration"] as? Double) ?? .infinity
                return abs(d0 - duration) < abs(d1 - duration)
            } ?? results[0]
            if let bestDuration = best["duration"] as? Double, abs(bestDuration - duration) > 10 {
                return await fetchPlainFallback(title: title, artist: artist)
            }
        } else {
            best = results[0]
        }

        if let lines = lines(from: best) { return lines }
        return await fetchPlainFallback(title: title, artist: artist)
    }

    /// Account-stored lyrics from the bridge, or nil when it has none.
    ///
    /// Silent on every failure: this is the first of three sources, so a
    /// signed-out session, an offline bridge or an empty cache must all simply
    /// fall through to the public databases rather than being treated as "this
    /// track has no lyrics".
    private static func fetchFromBridge(title: String, artist: String,
                                        duration: TimeInterval) async -> [TVLyricLine]? {
        // Both are main-actor state, so they are read there and then released —
        // the request itself has no business holding the main actor while it
        // waits on the network.
        let (token, baseURL) = await MainActor.run {
            (TVAccount.shared.token, TVBridgeClient.shared.baseURL)
        }
        guard let token,
              var comps = URLComponents(string: baseURL + "/user/lyrics")
        else { return nil }

        comps.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist),
        ]
        if duration > 0 {
            comps.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12

        struct Response: Decodable {
            let synced_lyrics: String?
            let plain_lyrics: String?
            let source: String?
        }
        guard let (data, response) = try? await Core.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }

        // Synced only. Plain text has no timestamps, and this screen highlights
        // the current line — an unsynced block here would sit frozen while the
        // song played, which reads as broken rather than as "unsynced". The
        // plain-text fallback below is a separate, deliberate last resort.
        guard let lrc = decoded.synced_lyrics, !lrc.isEmpty else { return nil }
        let lines = TVLrcParser.parse(lrc)
        guard !lines.isEmpty else { return nil }

        TVRemoteLogger.log(category: "lyrics", event: "lyrics_from_account",
                           detail: ["title": title,
                                    "source": decoded.source ?? "cache",
                                    "lineCount": lines.count])
        return lines
    }

    private static func fetchGetResult(url: URL, expectedDuration: TimeInterval) async -> [TVLyricLine]? {
        var req = URLRequest(url: url)
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        req.timeoutInterval = 8

        guard let (data, resp) = try? await Core.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if expectedDuration > 0, let resultDuration = result["duration"] as? Double,
           abs(resultDuration - expectedDuration) > 10 {
            return nil
        }
        return lines(from: result)
    }

    private static func lines(from result: [String: Any]) -> [TVLyricLine]? {
        if let syncedLrc = result["syncedLyrics"] as? String, !syncedLrc.isEmpty {
            let parsed = TVLrcParser.parse(syncedLrc)
            if !parsed.isEmpty { return parsed }
        }
        if let plain = result["plainLyrics"] as? String, !plain.isEmpty {
            return plain.components(separatedBy: "\n")
                .map { TVLyricLine(time: 0, text: $0) }
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return nil
    }

    /// Last resort: plain, unsynced lyrics from a second free API — only
    /// reached once lrclib has genuinely returned nothing usable.
    private static func fetchPlainFallback(title: String, artist: String) async -> [TVLyricLine]? {
        guard !title.isEmpty, !artist.isEmpty,
              let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)")
        else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await Core.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plain = result["lyrics"] as? String, !plain.isEmpty
        else { return nil }

        return plain.components(separatedBy: "\n")
            .map { TVLyricLine(time: 0, text: $0) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
