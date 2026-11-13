import SwiftUI
import UIKit

// MARK: - Artists Tab
//
// Restructured 2026-09, in step with the Albums tab. Before: a bare list or
// grid, with the column switch as three toolbar icons and every row
// re-querying and re-counting the artist's songs on each render. Now:
//
// - "Top Artists": big round portraits of the artists you have the most
//   songs by, each with a play button.
// - A controls row: sort (Name, Most Songs, Most Albums, Most Played), the
//   artist count, a random-artist button, and the list / 2 / 3 switch.
// - A–Z sections with a jump rail once the library has 30+ artists.
// - Rows and cells show album and song counts, a now-playing marker, a play
//   button, and a context menu (play, shuffle, play next, add to queue).
// - The Library search field filters artists.
//
// Per-artist counts are computed once per library change, off the main
// actor.

struct ArtistSummary: Identifiable {
    let name: String
    let songCount: Int
    let albumCount: Int
    let playCount: Int
    /// All of the artist's songs, album by album, in track order.
    let songs: [Song]

    var id: String { name }

    var detailLine: String {
        "\(albumCount) \(albumCount == 1 ? "album" : "albums") · \(songCount) \(songCount == 1 ? "song" : "songs")"
    }

    static func build(from allSongs: [Song], playCounts: [String: Int]) -> [ArtistSummary] {
        var buckets: [String: [Song]] = [:]
        for song in allSongs { buckets[song.artistName, default: []].append(song) }
        return buckets.map { name, songs in
            let ordered = songs.sorted {
                let order = $0.albumName.localizedCaseInsensitiveCompare($1.albumName)
                return order == .orderedSame ? AlbumSummary.albumOrder($0, $1) : order == .orderedAscending
            }
            return ArtistSummary(
                name: name,
                songCount: songs.count,
                albumCount: Set(songs.map(\.groupableAlbumName)).count,
                playCount: songs.reduce(0) { $0 + (playCounts[$1.id] ?? 0) },
                songs: ordered
            )
        }
    }
}

enum ArtistSortOrder: String, CaseIterable, Identifiable {
    case name, mostSongs, mostAlbums, mostPlayed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name:       return "Name"
        case .mostSongs:  return "Most Songs"
        case .mostAlbums: return "Most Albums"
        case .mostPlayed: return "Most Played"
        }
    }

    var icon: String {
        switch self {
        case .name:       return "textformat"
        case .mostSongs:  return "music.note"
        case .mostAlbums: return "square.stack"
        case .mostPlayed: return "chart.bar.fill"
        }
    }

    func apply(to artists: [ArtistSummary]) -> [ArtistSummary] {
        let byName: (ArtistSummary, ArtistSummary) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        switch self {
        case .name:       return artists.sorted(by: byName)
        case .mostSongs:  return artists.sorted { $0.songCount != $1.songCount ? $0.songCount > $1.songCount : byName($0, $1) }
        case .mostAlbums: return artists.sorted { $0.albumCount != $1.albumCount ? $0.albumCount > $1.albumCount : byName($0, $1) }
        case .mostPlayed: return artists.sorted { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : byName($0, $1) }
        }
    }
}

private struct ArtistSection: Identifiable {
    let title: String?
    let artists: [ArtistSummary]
    var id: String { title.map(Self.anchor(for:)) ?? "artists-section-all" }
    static func anchor(for title: String) -> String { "artists-section-\(title)" }
}

struct ArtistsTab: View {
    /// The Library screen's (debounced) search text.
    var searchText: String = ""

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    @AppStorage("library_artists_columns") private var columns: Int = 1
    @AppStorage("library_artists_sort") private var sortRaw: String = ArtistSortOrder.name.rawValue

    @State private var allArtists: [ArtistSummary] = []
    @State private var topArtists: [ArtistSummary] = []
    @State private var sections: [ArtistSection] = []
    @State private var visibleCount = 0
    @State private var hasLoaded = false

    private static let sectioningThreshold = 30

    private var sortOrder: ArtistSortOrder { ArtistSortOrder(rawValue: sortRaw) ?? .name }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: max(1, columns))
    }

    private func rebuildSections() {
        let filtered = query.isEmpty ? allArtists : allArtists.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let sorted = sortOrder.apply(to: filtered)
        visibleCount = sorted.count
        guard sortOrder == .name, sorted.count >= Self.sectioningThreshold else {
            sections = [ArtistSection(title: nil, artists: sorted)]
            return
        }
        var keys: [String] = []
        var buckets: [String: [ArtistSummary]] = [:]
        for artist in sorted {
            let key = Self.letter(of: artist.name)
            if buckets[key] == nil { keys.append(key) }
            buckets[key, default: []].append(artist)
        }
        sections = keys.map { ArtistSection(title: $0, artists: buckets[$0] ?? []) }
    }

    private static func letter(of text: String) -> String {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.first { CharacterSet.alphanumerics.contains($0) }
            .map { String($0).uppercased() } ?? "#"
        return first.rangeOfCharacter(from: .letters) != nil ? first : "#"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if hasLoaded && allArtists.isEmpty {
                    EmptyStateView(icon: "music.mic", title: "No artists", message: "Add music to see artists here.")
                        .padding(.top, 60)
                } else {
                    content
                }
            }
            .overlay(alignment: .trailing) {
                let letters = sections.compactMap(\.title)
                if letters.count >= 4 {
                    AlphabetIndexRail(letters: letters) { letter in
                        withAnimation(LumiMotion.fade(0.25)) {
                            proxy.scrollTo(ArtistSection.anchor(for: letter), anchor: .top)
                        }
                    }
                    .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(0.55))
                    .padding(.trailing, 2)
                    .padding(.top, 240)
                }
            }
        }
        .background(Color.clear.ignoresSafeArea())
        .task(id: library.allSongs.count) {
            let songs = library.allSongs
            let playCounts = Dictionary(
                songs.map { ($0.id, PlayHistoryStore.shared.playCount(for: $0.id)) },
                uniquingKeysWith: { first, _ in first }
            )
            let built = await Task.detached(priority: .userInitiated) {
                ArtistSummary.build(from: songs, playCounts: playCounts)
            }.value
            guard !Task.isCancelled else { return }
            allArtists = built
            topArtists = Array(
                built.filter { $0.name != "Unknown Artist" }
                    .sorted { $0.songCount != $1.songCount ? $0.songCount > $1.songCount : $0.name < $1.name }
                    .prefix(10)
            )
            hasLoaded = true
            rebuildSections()
            ArtistImageService.shared.prefetch(artists: built.map(\.name))
        }
        .onChange(of: searchText) { _ in rebuildSections() }
        .onChange(of: sortRaw) { _ in
            withAnimation(LumiMotion.fade(0.25)) { rebuildSections() }
        }
    }

    // MARK: Content

    private var content: some View {
        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
            if query.isEmpty, topArtists.count >= 3 {
                TopArtistsShelf(artists: topArtists, onPlay: play)
            }

            controlsRow
                .padding(.horizontal, 16)

            if visibleCount == 0, hasLoaded, !query.isEmpty {
                Text("No artists match \u{201C}\(query)\u{201D}.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            }

            ForEach(sections) { section in
                Section {
                    artistGrid(section.artists)
                } header: {
                    if let title = section.title {
                        ArtistLetterHeader(title: title, count: section.artists.count)
                    }
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 190)
    }

    @ViewBuilder
    private func artistGrid(_ artists: [ArtistSummary]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: columns == 1 ? 8 : 22) {
            ForEach(artists) { artist in
                NavigationLink {
                    ArtistDetailView(artist: artist.name)
                } label: {
                    if columns == 1 {
                        ArtistListRow(artist: artist, isPlaying: isPlaying(artist))
                    } else {
                        ArtistGridCell(artist: artist, compact: columns >= 3, isPlaying: isPlaying(artist))
                    }
                }
                .buttonStyle(PressableButtonStyle())
                // Drawn over the link rather than inside its label, where
                // the link would take its taps (see FoldersTab).
                .overlay {
                    ArtistPlayButtonOverlay(isRow: columns == 1, compact: columns >= 3) { play(artist) }
                }
                .contextMenu { artistMenu(artist) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.trailing, sections.count > 1 && columns == 1 ? 10 : 0)
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack(spacing: 8) {
            LumiPicker(selection: $sortRaw) {
                ForEach(ArtistSortOrder.allCases) { order in
                    Label(order.label, systemImage: order.icon).lumiOptionLabel(order.label).tag(order.rawValue)
                }
            } trigger: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(sortOrder.label)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(0.7))
            }

            Text("\(visibleCount) \(visibleCount == 1 ? "artist" : "artists")")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                guard let artist = sections.flatMap(\.artists).randomElement() else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.setQueue(artist.songs.smartShuffled(), startIndex: 0, autoplay: true)
                ToastCenter.shared.show("Shuffling \(artist.name)", category: .info, icon: "dice.fill")
            } label: {
                Image(systemName: "dice.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .frame(width: 32, height: 32)
                    .adaptiveGlass(in: Circle(), fallback: AppTheme.surface.opacity(0.7))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Shuffle a random artist")

            HStack(spacing: 2) {
                layoutButton(columns: 1, icon: "list.bullet", label: "List")
                layoutButton(columns: 2, icon: "square.grid.2x2", label: "Two-column grid")
                layoutButton(columns: 3, icon: "square.grid.3x3", label: "Three-column grid")
            }
            .padding(3)
            .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(0.7))
        }
    }

    private func layoutButton(columns target: Int, icon: String, label: String) -> some View {
        Button {
            withAnimation(LumiMotion.settle) { columns = target }
        } label: {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(columns == target ? Color.white : AppTheme.textSecondary)
                .frame(width: 30, height: 26)
                .background {
                    if columns == target { Capsule().fill(AppTheme.dynamicAccent) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(columns == target ? .isSelected : [])
    }

    // MARK: Actions

    private func isPlaying(_ artist: ArtistSummary) -> Bool {
        player.currentSong?.artistName == artist.name
    }

    private func play(_ artist: ArtistSummary) {
        guard !artist.songs.isEmpty else { return }
        player.setQueue(artist.songs, startIndex: 0, autoplay: true)
    }

    @ViewBuilder
    private func artistMenu(_ artist: ArtistSummary) -> some View {
        Button { play(artist) } label: { Label("Play", systemImage: "play.fill") }
        Button {
            player.setQueue(artist.songs.smartShuffled(), startIndex: 0, autoplay: true)
        } label: { Label("Shuffle", systemImage: "shuffle") }
        Divider()
        Button {
            for song in artist.songs.reversed() { player.insertNext(song: song) }
            ToastCenter.shared.show("\(artist.name) plays next", category: .success, icon: "text.insert")
        } label: { Label("Play Next", systemImage: "text.insert") }
        Button {
            for song in artist.songs { player.appendToQueue(song: song) }
            ToastCenter.shared.show(
                "Added \(artist.songCount) song\(artist.songCount == 1 ? "" : "s") to queue",
                category: .success, icon: "text.badge.plus"
            )
        } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
    }
}

// MARK: - Top Artists shelf

private struct TopArtistsShelf: View {
    let artists: [ArtistSummary]
    let onPlay: (ArtistSummary) -> Void

    private let size: CGFloat = 116

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(AppTheme.dynamicAccent)
                Text("Top Artists")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .font(.title3.weight(.bold))
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                        NavigationLink {
                            ArtistDetailView(artist: artist.name)
                        } label: {
                            VStack(spacing: 8) {
                                ZStack(alignment: .topLeading) {
                                    ArtistAvatar(artist: artist.name, size: size)
                                        .overlay(Circle().stroke(AppTheme.dynamicAccent.opacity(index == 0 ? 0.9 : 0.25), lineWidth: index == 0 ? 3 : 1.5))
                                        .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
                                    Text("\(index + 1)")
                                        .font(.caption.weight(.heavy))
                                        .foregroundStyle(.white)
                                        .frame(width: 26, height: 26)
                                        .background(AppTheme.dynamicAccentGradient, in: Circle())
                                        .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                                }
                                Text(artist.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .lineLimit(1)
                                Text("\(artist.songCount) songs")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            .frame(width: size + 8)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .overlay(alignment: .top) {
                            Button {
                                onPlay(artist)
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(AppTheme.dynamicAccentGradient, in: Circle())
                                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityLabel("Play \(artist.name)")
                            .offset(x: size / 2 - 14, y: size - 34)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

// MARK: - Section header

private struct ArtistLetterHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.title3.weight(.heavy))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppTheme.surface.opacity(0.7), in: Capsule())
            Rectangle()
                .fill(AppTheme.textSecondary.opacity(0.18))
                .frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            LinearGradient(
                colors: [AppTheme.background.opacity(0.85), AppTheme.background.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - List row

private struct ArtistListRow: View {
    let artist: ArtistSummary
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 14) {
            ArtistAvatar(artist: artist.name, size: 56)
                .overlay(Circle().stroke(isPlaying ? AppTheme.dynamicAccent : .white.opacity(0.1), lineWidth: isPlaying ? 2 : 1))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                    Text(artist.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isPlaying ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                        .lineLimit(1)
                }
                Text(artist.detailLine)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            // Room for the play button overlay.
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(8)
        .adaptiveGlass(
            tint: isPlaying ? AppTheme.dynamicAccent.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous),
            fallback: isPlaying ? AppTheme.dynamicAccent.opacity(0.12) : AppTheme.surface.opacity(0.55)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Grid cell

private struct ArtistGridCell: View {
    let artist: ArtistSummary
    let compact: Bool
    let isPlaying: Bool

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ArtistAvatar(artist: artist.name, size: geo.size.width)
                    .overlay(Circle().stroke(isPlaying ? AppTheme.dynamicAccent : .white.opacity(0.1), lineWidth: isPlaying ? 3 : 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(spacing: 2) {
                Text(artist.name)
                    .font((compact ? Font.caption : .subheadline).weight(.semibold))
                    .foregroundStyle(isPlaying ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(.center)
                Text(compact ? "\(artist.songCount) songs" : artist.detailLine)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Play button overlay

private struct ArtistPlayButtonOverlay: View {
    let isRow: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        GeometryReader { geo in
            let side: CGFloat = compact ? 28 : 34
            Button(action: action) {
                Image(systemName: "play.fill")
                    .font(.system(size: side * 0.4, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: side, height: side)
                    .background(AppTheme.dynamicAccentGradient, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Play artist")
            .position(
                // Grid: on the lower right of the round portrait (it's as
                // wide as the cell).
                x: isRow ? geo.size.width - side / 2 - 16 : geo.size.width * 0.85 - side / 2 + 4,
                y: isRow ? geo.size.height / 2 : geo.size.width * 0.85 - side / 2 + 4
            )
        }
    }
}
