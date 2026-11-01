import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - LyricsOVH fetch (plain text)

    func fetchLyricsOVH(title: String, artist: String) async -> [LrcLine]? {
        guard !artist.isEmpty,
              let encArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encTitle  = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(encArtist)/\(encTitle)")
        else { return nil }

        var req = URLRequest(url: url); req.timeoutInterval = 8
        guard let (data, resp) = try? await Core.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyrics = json["lyrics"] as? String,
              !lyrics.isEmpty
        else { return nil }

        return lyrics.components(separatedBy: "\n")
            .map { LrcLine(time: 0, text: $0) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
