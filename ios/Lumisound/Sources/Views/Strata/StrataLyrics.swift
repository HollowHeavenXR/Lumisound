import SwiftUI

// MARK: - Strata lyrics
//
// Same sources and order as the classic player: your own synced lyrics
// (Lyrics Sync Editor / Aria), a .lrc next to the file, an imported plain
// .txt, then LRCLIB. Parsing and "which line is being sung" are Rust
// (strata.rs `strata_lyrics_parse` / `strata_lyric_index`).

enum StrataLyricsLoader {
    static func load(_ song: Song) async -> [StrataLyric] {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|")
        let base = song.id.components(separatedBy: illegal).joined(separator: "_")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Lyrics", isDirectory: true)
        var candidates = [dir.appendingPathComponent(base + ".lrc")]
        if let url = song.url, url.isFileURL { candidates.append(url.deletingPathExtension().appendingPathExtension("lrc")) }
        candidates.append(dir.appendingPathComponent(base + ".txt"))
        for c in candidates {
            if let text = try? String(contentsOf: c, encoding: .utf8) {
                let lines = strataLyricsParse(text: text)
                if !lines.isEmpty { return lines }
            }
        }
        return await lrclib(title: song.title, artist: song.artist, duration: song.duration)
    }

    private static func lrclib(title: String, artist: String, duration: TimeInterval) async -> [StrataLyric] {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if duration > 0 { c.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Lumisound/2.0 (Strata)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, resp) = try? await Core.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let text = (obj["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (obj["plainLyrics"] as? String) ?? ""
        return strataLyricsParse(text: text)
    }
}

struct StrataLyricsPanel: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var store: StrataStore
    @ObservedObject var progress: PlaybackProgress
    @State private var lines: [StrataLyric] = []
    @State private var loading = true

    var body: some View {
        let t = store.theme
        let times = lines.map(\.time)
        let current = Int(strataLyricIndex(times: times, position: progress.position))
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if loading {
                        Text("Finding lyrics…").font(.system(size: t.typeScale[3], weight: .bold)).foregroundStyle(StrataPalette.inkFaint)
                    } else if lines.isEmpty {
                        Text("No lyrics for this song").font(.system(size: t.typeScale[2], weight: .heavy)).foregroundStyle(StrataPalette.inkDim)
                        Text("Generate them with Aria from the full player's lyrics menu.").font(.system(size: t.typeScale[4])).foregroundStyle(StrataPalette.inkFaint)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text)
                            .font(.system(size: t.typeScale[2] + 2, weight: .heavy))
                            .tracking(-0.4)
                            .foregroundStyle(i == current ? StrataPalette.ink : (i < current ? StrataPalette.inkFaint : StrataPalette.inkDim))
                            .scaleEffect(i == current ? 1.0 : 0.96, anchor: .leading)
                            .animation(.easeOut(duration: 0.25), value: current)
                            .id(i)
                            .onTapGesture { if line.time > 0 { player.seek(to: line.time) } }
                    }
                    Color.clear.frame(height: 200)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 20)
            }
            .scrollIndicators(.hidden)
            .onChange(of: current) { _, i in
                guard i >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 0.3)) }
            }
        }
        .task(id: player.currentSong?.id) {
            loading = true
            lines = []
            if let song = player.currentSong { lines = await StrataLyricsLoader.load(song) }
            loading = false
        }
    }
}
