import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - LRCLIB fetch (synced LRC)

    func fetchLRCLIB(title: String, artist: String, duration: TimeInterval) async -> [LrcLine]? {
        let headers = ["User-Agent": "Lumisound/1.0 (https://github.com/VoxeliseStudios/Lumisound)"]

        // 1. /api/get — exact match by track/artist/duration. LRCLIB matches
        //    duration within a couple seconds, so this avoids returning lyrics
        //    for a same-titled track by a different artist or a different
        //    recording/edit with a different runtime.
        if duration > 0 {
            var getComponents = URLComponents(string: "https://lrclib.net/api/get")!
            getComponents.queryItems = [
                URLQueryItem(name: "track_name",  value: title),
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "duration",    value: String(Int(duration.rounded()))),
            ]
            if let url = getComponents.url,
               let lines = await fetchLRCLIBResult(url: url, headers: headers, expectedDuration: duration) {
                return lines
            }
        }

        // 2. /api/search — fallback for tracks LRCLIB doesn't have an exact
        //    duration match for. Pick the result whose duration is closest to
        //    the local file's, instead of blindly trusting the first hit,
        //    which was often a different song/version entirely.
        var searchComponents = URLComponents(string: "https://lrclib.net/api/search")!
        searchComponents.queryItems = [
            URLQueryItem(name: "track_name",   value: title),
            URLQueryItem(name: "artist_name",  value: artist),
        ]
        guard let url = searchComponents.url else { return nil }
        var req = URLRequest(url: url)
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        req.timeoutInterval = 8

        guard let (data, resp) = try? await Core.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !results.isEmpty
        else { return nil }

        let best: [String: Any]
        if duration > 0 {
            best = results.min {
                let d0 = ($0["duration"] as? Double) ?? .infinity
                let d1 = ($1["duration"] as? Double) ?? .infinity
                return abs(d0 - duration) < abs(d1 - duration)
            } ?? results[0]

            // If even the closest match is way off (different song entirely),
            // don't show misleading lyrics/timing at all.
            if let bestDuration = best["duration"] as? Double, abs(bestDuration - duration) > 10 {
                return nil
            }
        } else {
            best = results[0]
        }

        return linesFromResult(best)
    }

    func fetchLRCLIBResult(url: URL, headers: [String: String], expectedDuration: TimeInterval) async -> [LrcLine]? {
        var req = URLRequest(url: url)
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        req.timeoutInterval = 8

        guard let (data, resp) = try? await Core.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // `expectedDuration` was previously accepted but never actually
        // checked here — this is the /api/get "exact match" path, which the
        // call site's comment assumes LRCLIB always honors strictly ("matches
        // duration within a couple seconds"). That's not guaranteed
        // server-side for every title/artist combination (LRCLIB's own
        // matching can fall back to a fuzzy title/artist hit when it has
        // nothing at the exact requested duration), and unlike the /api/search
        // fallback just above — which DOES reject a >10s-off result — nothing
        // caught a mismatched result here. A wrong-duration match plus
        // synced-LRC timestamps for a DIFFERENT (often shorter) recording is
        // exactly what produces "lyrics skip straight to the end": every
        // parsed line's timestamp falls before the real track's current
        // position almost immediately, so `LyricsView`'s "last line whose
        // timestamp <= currentPosition" always resolves to the final line.
        if expectedDuration > 0, let resultDuration = result["duration"] as? Double,
           abs(resultDuration - expectedDuration) > 10 {
            return nil
        }

        return linesFromResult(result)
    }

    func linesFromResult(_ result: [String: Any]) -> [LrcLine]? {
        // Prefer synced lyrics; fall back to plain text with no timestamps
        if let syncedLrc = result["syncedLyrics"] as? String, !syncedLrc.isEmpty {
            let lines = LrcParser.parse(syncedLrc)
            if !lines.isEmpty { return lines }
        }
        if let plain = result["plainLyrics"] as? String, !plain.isEmpty {
            // Wrap plain text lines as LrcLine with time=0 so they all display together
            return plain.components(separatedBy: "\n")
                .map { LrcLine(time: 0, text: $0) }
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return nil
    }
}
