import SwiftUI
import UIKit

// MARK: - FavoritesView
//
// Restructured 2026-09. Before: a heart + title, one stat chip, two bordered
// buttons, and sort/layout in the toolbar. Now:
//
// - A header with a 2×2 mosaic of favorite covers, a "YOUR FAVORITES"
//   eyebrow, and chips for songs / total time / artists.
// - Play (filled), Shuffle (glass) and add-all-to-queue.
// - Artist filter chips — "All" plus your most-favorited artists — so 200+
//   favorites can be narrowed to one artist in a tap.
// - A controls row: sort (Title, Artist, Album, Longest, Most Played) and the
//   list / 2 / 3 column switch, moved out of the toolbar.
// - The Library search field filters favorites too.
//
// Rows are still `SongRow` / `SongGridCell`, so the user's row style and
// custom styles apply. Filtering and sorting are cached, not recomputed on
// every render.

enum FavoritesSortOrder: String, CaseIterable, Identifiable {
    case title, artist, album, longest, mostPlayed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title:      return "Title"
        case .artist:     return "Artist"
        case .album:      return "Album"
        case .longest:    return "Longest"
        case .mostPlayed: return "Most Played"
        }
    }

    var icon: String {
        switch self {
        case .title:      return "textformat"
        case .artist:     return "music.mic"
        case .album:      return "square.stack"
        case .longest:    return "timer"
        case .mostPlayed: return "chart.bar.fill"
        }
    }

    /// Main actor: Most Played reads `PlayHistoryStore`, which is.
    @MainActor
    func apply(to songs: [Song]) -> [Song] {
        let byTitle: (Song, Song) -> Bool = {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        switch self {
        case .title:
            return songs.sortedByDisplayName()
        case .artist:
            return songs.sorted {
                let order = $0.artistName.localizedCaseInsensitiveCompare($1.artistName)
                return order == .orderedSame ? byTitle($0, $1) : order == .orderedAscending
            }
        case .album:
            return songs.sorted {
                let order = $0.albumName.localizedCaseInsensitiveCompare($1.albumName)
                return order == .orderedSame ? AlbumSummary.albumOrder($0, $1) : order == .orderedAscending
            }
        case .longest:
            return songs.sorted { $0.duration != $1.duration ? $0.duration > $1.duration : byTitle($0, $1) }
        case .mostPlayed:
            // `uniquingKeysWith`, not `uniqueKeysWithValues` — the latter
            // traps on a duplicate id.
            let counts = Dictionary(
                songs.map { ($0.id, PlayHistoryStore.shared.playCount(for: $0.id)) },
                uniquingKeysWith: { first, _ in first }
            )
            return songs.sorted {
                let a = counts[$0.id] ?? 0, b = counts[$1.id] ?? 0
                return a != b ? a > b : byTitle($0, $1)
            }
        }
    }
}

struct FavoritesView: View {
    /// Whether this instance paints the gallery background itself: yes when
    /// pushed (LibraryHubView's shortcut — pushed views don't inherit the
    /// root's background), no when embedded as a LibraryView tab (which
    /// already paints one; two would render at different crops with a seam).
    var drawsOwnBackground: Bool = true
    /// The Library screen's (debounced) search text, when embedded there.
    var searchText: String = ""

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    @AppStorage("library_favorites_columns") private var columns: Int = 1
    @AppStorage("library_favorites_sort") private var sortRaw: String = FavoritesSortOrder.title.rawValue

    @State private var allFavorites: [Song] = []
    @State private var visible: [Song] = []
    @State private var topArtists: [FavoriteArtistCount] = []
    @State private var selectedArtist: String?
    @State private var hasLoaded = false

    private var sortOrder: FavoritesSortOrder { FavoritesSortOrder(rawValue: sortRaw) ?? .title }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: max(1, columns))
    }

    /// Changes whenever anything the visible list depends on changes.
    private var rebuildKey: String {
        "\(library.favoriteSongIDs.count)|\(library.allSongs.count)|\(sortRaw)|\(selectedArtist ?? "")|\(query)"
    }

    private func rebuild() {
        let favorites = library.favoriteSongs
        allFavorites = favorites

        var counts: [String: Int] = [:]
        for song in favorites { counts[song.artistName, default: 0] += 1 }
        topArtists = counts
            .filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(10)
            .map { FavoriteArtistCount(name: $0.key, count: $0.value) }
        if let selectedArtist, counts[selectedArtist] == nil { self.selectedArtist = nil }

        var filtered = favorites
        if let selectedArtist { filtered = filtered.filter { $0.artistName == selectedArtist } }
        if !query.isEmpty {
            filtered = filtered.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.artistName.localizedCaseInsensitiveContains(query)
                    || $0.albumName.localizedCaseInsensitiveContains(query)
            }
        }
        visible = sortOrder.apply(to: filtered)
        hasLoaded = true
    }

    // MARK: Body

    var body: some View {
        Group {
            if hasLoaded && allFavorites.isEmpty {
                ScrollView {
                    emptyState.padding(.top, 60)
                }
            } else if columns == 1 {
                List {
                    Section {
                        header
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listSectionSeparator(.hidden)

                    ForEach(visible) { song in
                        FavoriteRow(song: song, isCurrent: player.currentSong?.id == song.id)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(song: song, in: visible, uiSource: "favorites") }
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(AppTheme.elevatedSurface.opacity(0.6))
                            )
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    library.toggleFavorite(songID: song.id)
                                } label: {
                                    Label("Unfavorite", systemImage: "heart.slash")
                                }
                                .tint(AppTheme.error)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    player.insertNext(song: song)
                                    ToastCenter.shared.show("Playing next", category: .success, icon: "text.insert")
                                } label: {
                                    Label("Play Next", systemImage: "text.insert")
                                }
                                .tint(AppTheme.dynamicAccent)
                            }
                    }

                    if visible.isEmpty, hasLoaded {
                        noMatches.listRowBackground(Color.clear)
                    }

                    Color.clear.frame(height: 120)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                // `.plain` like every other song list — `.insetGrouped` split
                // this screen into floating cards with the wallpaper between.
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                ScrollView {
                    header
                    if visible.isEmpty, hasLoaded {
                        noMatches.padding(.top, 20)
                    }
                    LazyVGrid(columns: gridColumns, spacing: 18) {
                        ForEach(visible) { song in
                            Button {
                                player.play(song: song, in: visible, uiSource: "favorites")
                            } label: {
                                SongGridCell(song: song, isCurrent: player.currentSong?.id == song.id)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .contextMenu {
                                Button {
                                    player.insertNext(song: song)
                                } label: {
                                    Label("Play Next", systemImage: "text.insert")
                                }
                                Button(role: .destructive) {
                                    library.toggleFavorite(songID: song.id)
                                } label: {
                                    Label("Unfavorite", systemImage: "heart.slash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 190)
                }
                .background(Color.clear.ignoresSafeArea())
            }
        }
        .background {
            if drawsOwnBackground {
                GalleryBackgroundView().ignoresSafeArea()
            }
        }
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: rebuildKey) { rebuild() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .bottom) {
                HeroArtworkBackdrop(song: allFavorites.first, height: 250)

                HStack(alignment: .bottom, spacing: 16) {
                    FavoritesMosaic(songs: mosaicSongs, size: 132)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("YOUR FAVORITES")
                            .font(.caption2.weight(.heavy))
                            .tracking(1.4)
                            .foregroundStyle(AppTheme.dynamicAccent)
                        Text("Favorites")
                            .font(.largeTitle.weight(.heavy))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(summaryLine)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            actionButtons
                .padding(.horizontal, 16)

            if topArtists.count >= 2 {
                artistChips
            }

            controlsRow
                .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    /// Up to four favorites from different albums.
    private var mosaicSongs: [Song] {
        var seen = Set<String>()
        var picked: [Song] = []
        for song in allFavorites where seen.insert(song.groupableAlbumName).inserted {
            picked.append(song)
            if picked.count == 4 { break }
        }
        return picked
    }

    private var summaryLine: String {
        let count = allFavorites.count
        let total = allFavorites.reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let time = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        let artists = Set(allFavorites.map(\.artistName)).count
        return "\(count) \(count == 1 ? "song" : "songs") · \(time) · \(artists) \(artists == 1 ? "artist" : "artists")"
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                player.setQueue(visible, startIndex: 0, autoplay: true)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(AppTheme.dynamicAccentGradient, in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                player.setQueue(visible.shuffled(), startIndex: 0, autoplay: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .adaptiveGlass(tint: AppTheme.dynamicAccent.opacity(0.12), in: Capsule(), fallback: AppTheme.surface)
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                for song in visible { player.appendToQueue(song: song) }
                ToastCenter.shared.show(
                    "Added \(visible.count) song\(visible.count == 1 ? "" : "s") to queue",
                    category: .success, icon: "text.badge.plus"
                )
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.headline)
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .frame(width: 48, height: 48)
                    .adaptiveGlass(tint: AppTheme.dynamicAccent.opacity(0.12), in: Circle(), fallback: AppTheme.surface)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Add to queue")
        }
        .disabled(visible.isEmpty)
        .opacity(visible.isEmpty ? 0.5 : 1)
    }

    /// "All" plus the most-favorited artists; tapping one filters to them.
    private var artistChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                artistChip(name: nil, label: "All", count: allFavorites.count)
                ForEach(topArtists) { artist in
                    artistChip(name: artist.name, label: artist.name, count: artist.count)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    private func artistChip(name: String?, label: String, count: Int) -> some View {
        let isSelected = selectedArtist == name
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedArtist = isSelected ? nil : name
            }
        } label: {
            HStack(spacing: 6) {
                if let name {
                    ArtistAvatar(artist: name, size: 22)
                }
                Text(label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : AppTheme.textSecondary)
            }
            .foregroundStyle(isSelected ? .white : AppTheme.textPrimary)
            .padding(.leading, name == nil ? 12 : 4)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .background {
                if isSelected { Capsule().fill(AppTheme.dynamicAccent) }
            }
            .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(isSelected ? 0 : 0.7))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            LumiPicker(selection: $sortRaw) {
                ForEach(FavoritesSortOrder.allCases) { order in
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

            if selectedArtist != nil || !query.isEmpty {
                Text("\(visible.count) of \(allFavorites.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

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
            withAnimation(.easeInOut(duration: 0.2)) { columns = target }
        } label: {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(columns == target ? Color.white : AppTheme.textSecondary)
                .frame(width: 32, height: 26)
                .background {
                    if columns == target { Capsule().fill(AppTheme.dynamicAccent) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(columns == target ? .isSelected : [])
    }

    // MARK: Empty states

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.dynamicAccent.opacity(0.15))
                    .frame(width: 110, height: 110)
                Image(systemName: "heart.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(AppTheme.dynamicAccentGradient)
            }
            Text("No favorites yet")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("Tap the heart on Now Playing, or long-press any song and choose \u{201C}Add to Favorites\u{201D}.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }

    private var noMatches: some View {
        Text(query.isEmpty ? "No favorites by this artist." : "No favorites match \u{201C}\(query)\u{201D}.")
            .font(.subheadline)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

private struct FavoriteArtistCount: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

// MARK: - Mosaic

/// A 2×2 grid of covers (or fewer, filled with the first) with a heart badge.
private struct FavoritesMosaic: View {
    let songs: [Song]
    let size: CGFloat

    var body: some View {
        let half = size / 2
        ZStack(alignment: .bottomTrailing) {
            Group {
                if songs.count >= 4 {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ArtworkThumbnail(song: songs[0], size: half, showsScrim: false)
                            ArtworkThumbnail(song: songs[1], size: half, showsScrim: false)
                        }
                        HStack(spacing: 0) {
                            ArtworkThumbnail(song: songs[2], size: half, showsScrim: false)
                            ArtworkThumbnail(song: songs[3], size: half, showsScrim: false)
                        }
                    }
                } else if let first = songs.first {
                    ArtworkThumbnail(song: first, size: size, showsScrim: false)
                } else {
                    AppTheme.surface
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)

            Image(systemName: "heart.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(AppTheme.dynamicAccentGradient, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                .offset(x: 8, y: 8)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Favorite Row

private struct FavoriteRow: View {
    let song: Song
    let isCurrent: Bool

    @EnvironmentObject private var library: LibraryManager

    private let heartHaptic = UIImpactFeedbackGenerator(style: .soft)

    var body: some View {
        HStack(spacing: 0) {
            SongRow(song: song, isCurrent: isCurrent)

            Button {
                heartHaptic.impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    library.toggleFavorite(songID: song.id)
                }
            } label: {
                Image(systemName: "heart.fill")
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .font(.system(size: 18))
                    .padding(.leading, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove from Favorites")
        }
    }
}
