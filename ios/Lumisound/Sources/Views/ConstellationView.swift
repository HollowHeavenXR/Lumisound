import SwiftUI

/// A visual, playful way to explore the library — genre/artist "stars"
/// scattered across the screen in a golden-angle spiral (Vogel's model, the
/// same even-distribution technique behind sunflower-seed/phyllotaxis
/// layouts), sized by how many songs are in each group. Deliberately not a
/// real physics simulation — a precomputed spiral already reads as an
/// organic scatter with no per-frame layout cost, and stays perfectly
/// stable (no jitter, no overlap resolution needed) at any library size.
/// Tapping a star opens it; "Shuffle Play" mirrors the Home dashboard's
/// Genres/Top Artists carousels' one-tap-to-listen behavior.
struct ConstellationView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    @State private var mode: Mode = .genres
    @State private var selected: Star?

    private enum Mode: String, CaseIterable, Identifiable {
        case genres = "Genres"
        case artists = "Artists"
        var id: String { rawValue }
    }

    private struct Star: Identifiable {
        let id: String
        let name: String
        let songs: [Song]
    }

    private var stars: [Star] {
        switch mode {
        case .genres:
            return library.genreGroups(limit: 40).map { Star(id: "genre-\($0.genre)", name: $0.genre, songs: $0.songs) }
        case .artists:
            return library.topArtistGroups(limit: 40).map { Star(id: "artist-\($0.artist)", name: $0.artist, songs: $0.songs) }
        }
    }

    var body: some View {
        ZStack {
            GalleryBackgroundView().ignoresSafeArea()

            if stars.isEmpty {
                EmptyStateView(
                    icon: "sparkles",
                    title: "Nothing to Map Yet",
                    message: "Add some music to your library to see your constellation."
                )
            } else {
                GeometryReader { geo in
                    ZStack {
                        ForEach(Array(stars.enumerated()), id: \.element.id) { index, star in
                            starView(star, index: index, in: geo.size)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .navigationTitle("Constellation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
        .sheet(item: $selected) { star in
            starDetailSheet(star)
        }
    }

    private func starView(_ star: Star, index: Int, in size: CGSize) -> some View {
        let position = spiralPosition(index: index, total: stars.count, in: size)
        let diameter = starDiameter(songCount: star.songs.count)
        return Button {
            selected = star
        } label: {
            ZStack {
                Circle()
                    .fill(AppTheme.dynamicAccent.opacity(0.25 + 0.5 * sizeFraction(star.songs.count)))
                Circle()
                    .strokeBorder(AppTheme.dynamicAccent.opacity(0.6), lineWidth: 1)
                if diameter > 44 {
                    Text(star.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(4)
                }
            }
            .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.plain)
        .position(position)
    }

    /// Vogel's golden-angle spiral — evenly scatters `total` points with no
    /// two ever landing in the same direction from center, and radius
    /// growing with `sqrt(index)` so density stays roughly even from
    /// center to edge instead of bunching in the middle.
    private func spiralPosition(index: Int, total: Int, in size: CGSize) -> CGPoint {
        let goldenAngle = 137.5077640500378 * .pi / 180
        let angle = Double(index) * goldenAngle
        let maxRadius = min(size.width, size.height) / 2 - 40
        let radius = maxRadius * sqrt(Double(index) / Double(max(1, total)))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private func sizeFraction(_ songCount: Int) -> Double {
        guard let maxCount = stars.map({ $0.songs.count }).max(), maxCount > 0 else { return 0 }
        return sqrt(Double(songCount) / Double(maxCount))
    }

    private func starDiameter(songCount: Int) -> CGFloat {
        24 + CGFloat(sizeFraction(songCount)) * 56
    }

    @ViewBuilder
    private func starDetailSheet(_ star: Star) -> some View {
        NavigationStack {
            LKPage(title: "Constellation", subtitle: "Your artists as a map of stars.", icon: "sparkles", tint: .indigo) {
                LKSection {
                    Button {
                        player.shuffleEnabled = true
                        if let first = star.songs.randomElement() {
                            player.play(song: first, in: star.songs)
                        }
                        selected = nil
                    } label: {
                        Label("Shuffle Play", systemImage: "shuffle")
                    }
                }

                LKSection("\(star.songs.count) Songs") {
                    ForEach(star.songs.prefix(50), id: \.id) { song in
                        Button {
                            player.play(song: song, in: star.songs)
                            selected = nil
                        } label: {
                            SongRow(song: song, isCurrent: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(GalleryBackgroundView().ignoresSafeArea())
            .navigationTitle(star.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
