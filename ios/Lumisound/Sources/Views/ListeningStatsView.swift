import SwiftUI

/// All-time on-device listening stats — top songs, top artists, total plays,
/// estimated listening time — computed entirely from `PlayHistoryStore`
/// (itself fed by `AudioPlayerManager` once a track has played ~5s, so
/// instant skips don't count). No server involved; nothing here leaves the
/// device. Doesn't break down by week/month since only a running total +
/// last-played date is tracked per song, not a full per-play log.
struct ListeningStatsView: View {
    @EnvironmentObject private var library: LibraryManager

    @State private var totalPlays = 0
    @State private var estimatedSeconds: TimeInterval = 0
    @State private var topSongs: [(song: Song, plays: Int)] = []
    @State private var topArtists: [(artist: String, plays: Int)] = []

    var body: some View {
        LKPage(title: "Listening Stats", subtitle: "All-time, from this device only.", icon: "chart.bar.fill", tint: .pink) {
            HStack(spacing: 10) {
                LKStat(value: "\(totalPlays)", label: "Plays", icon: "play.fill", tint: .pink)
                LKStat(value: estimatedTimeText, label: "Listening time", icon: "clock.fill", tint: .purple)
                LKStat(value: "\(topArtists.count)", label: "Top artists", icon: "music.mic", tint: .orange)
            }
            if topSongs.isEmpty && topArtists.isEmpty {
                LKEmpty(icon: "chart.bar", title: "No listening yet", message: "Play a few songs and your stats appear here.", tint: .pink)
            }
            if !topSongs.isEmpty {
                podium
                LKCard(title: "Top songs") {
                    ForEach(Array(topSongs.enumerated()), id: \.offset) { index, entry in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(index < 3 ? .pink : AppTheme.textSecondary)
                                .frame(width: 22)
                            SongRow(song: entry.song, isCurrent: false)
                            Text("\(entry.plays)×").font(.caption.monospacedDigit()).foregroundStyle(.pink)
                        }
                        if index < topSongs.count - 1 { LKDivider(inset: 32) }
                    }
                }
            }
            if !topArtists.isEmpty {
                LKCard(title: "Top artists") {
                    let most = Double(topArtists.first?.plays ?? 1)
                    ForEach(Array(topArtists.enumerated()), id: \.offset) { index, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.artist).font(.subheadline).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                Spacer()
                                Text("\(entry.plays)").font(.caption.monospacedDigit()).foregroundStyle(AppTheme.textSecondary)
                            }
                            GeometryReader { geo in
                                Capsule().fill(Color.purple.opacity(index == 0 ? 0.9 : 0.45))
                                    .frame(width: max(6, geo.size.width * Double(entry.plays) / max(most, 1)))
                            }
                            .frame(height: 5)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            Text("A play counts after 5 seconds. Listening time is estimated from plays × track length.")
                .font(.caption2).foregroundStyle(AppTheme.textSecondary).padding(.horizontal, 6)
        }
        .onAppear(perform: recompute)
    }

    private var estimatedTimeText: String {
        let hours = Int(estimatedSeconds) / 3600
        let minutes = (Int(estimatedSeconds) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// The three most-played songs on a podium.
    private var podium: some View {
        let top = Array(topSongs.prefix(3))
        let order = top.count == 3 ? [1, 0, 2] : Array(0..<top.count)
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(order, id: \.self) { i in
                let entry = top[i]
                VStack(spacing: 6) {
                    Text(i == 0 ? "🥇" : i == 1 ? "🥈" : "🥉").font(.title2)
                    Text(entry.song.displayName).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2).multilineTextAlignment(.center)
                    Text("\(entry.plays) plays").font(.caption2).foregroundStyle(AppTheme.textSecondary)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.pink.opacity(i == 0 ? 0.85 : 0.45).gradient)
                        .frame(height: i == 0 ? 70 : i == 1 ? 50 : 36)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(LKCardBackground(tint: .pink))
    }

    private func recompute() {
        let history = PlayHistoryStore.shared
        let songs = library.allSongs

        var plays = 0
        var seconds: TimeInterval = 0
        var artistPlays: [String: Int] = [:]
        var songPlays: [(song: Song, plays: Int)] = []

        for song in songs {
            let count = history.playCount(for: song.id)
            guard count > 0 else { continue }
            plays += count
            seconds += song.duration * Double(count)
            artistPlays[song.artistName, default: 0] += count
            songPlays.append((song: song, plays: count))
        }

        totalPlays = plays
        estimatedSeconds = seconds
        topSongs = Array(songPlays.sorted { $0.plays > $1.plays }.prefix(15))
        topArtists = Array(
            artistPlays.map { (artist: $0.key, plays: $0.value) }
                .sorted { $0.plays > $1.plays }
                .prefix(10)
        )
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
