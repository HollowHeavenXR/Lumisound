import SwiftUI
import UIKit

// MARK: - Albums Tab
//
// 2026-09 restructure. The old tab was a bare grid (one stat chip, a column
// menu in the toolbar, cells that only navigated). It now has:
//
// - a "Recently Added" carousel of big cover cards (hidden while searching),
// - a controls row — sort menu, a random-album button, and the list/2/3
//   column switch that used to live in the toolbar,
// - A–Z (or decade) sections with pinned headers and a jump rail,
// - cells with a play button on the cover, a year/track-count line, and a
//   context menu (play, shuffle, play next, add to queue),
// - filtering by the Library search field, which previously did nothing on
//   this tab.
//
// Everything is drawn with the app's theme tokens (`AppTheme`) and
// `adaptiveGlass`, so it follows the selected theme, accent, Lua preset and
// glass settings. Song rows elsewhere keep following the user's row style —
// this screen only shows albums, never `SongRow`.

// MARK: - Album summary

/// Everything the Albums screens show about one album, computed once per
/// library change off the main actor (see `AlbumsTab`'s `.task`) instead of
/// re-deriving it from `songs(inAlbum:)` in every cell's body.
struct AlbumSummary: Identifiable {
    let name: String
    /// The most common artist, or "Various Artists" for a compilation.
    let artist: String
    let year: Int?
    let genre: String?
    let songCount: Int
    let totalDuration: TimeInterval
    let dateAdded: Date?
    /// First track in track order — whose artwork stands for the album.
    let coverSong: Song?
    /// Tracks in album order.
    let songs: [Song]

    var id: String { name }

    /// "2019 · 12 songs" — whichever parts are known.
    var detailLine: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        parts.append("\(songCount) \(songCount == 1 ? "song" : "songs")")
        return parts.joined(separator: " · ")
    }

    static func build(from allSongs: [Song]) -> [AlbumSummary] {
        var buckets: [String: [Song]] = [:]
        for song in allSongs {
            buckets[song.groupableAlbumName, default: []].append(song)
        }
        return buckets.map { name, songs in
            let ordered = songs.sorted(by: Self.albumOrder)
            return AlbumSummary(
                name: name,
                artist: Self.primaryArtist(of: songs),
                year: songs.compactMap { Self.parseYear($0.year) }.max(),
                genre: Self.mostCommon(songs.map(\.genre)),
                songCount: songs.count,
                totalDuration: songs.reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) },
                dateAdded: songs.compactMap(\.dateAdded).max(),
                coverSong: ordered.first,
                songs: ordered
            )
        }
    }

    /// Track number first (untagged tracks last), then title.
    static func albumOrder(_ a: Song, _ b: Song) -> Bool {
        let ta = a.trackNumber > 0 ? a.trackNumber : Int.max
        let tb = b.trackNumber > 0 ? b.trackNumber : Int.max
        if ta != tb { return ta < tb }
        return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }

    /// Year tags come in as "2019", "2019-04-12", "2019/04" — the first four
    /// digits are the year.
    static func parseYear(_ raw: String) -> Int? {
        let digits = raw.trimmingCharacters(in: .whitespaces).prefix(4)
        guard digits.count == 4, let year = Int(digits), year > 1000 else { return nil }
        return year
    }

    private static func primaryArtist(of songs: [Song]) -> String {
        var counts: [String: Int] = [:]
        for song in songs { counts[song.artistName, default: 0] += 1 }
        guard let top = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else {
            return "Unknown Artist"
        }
        // Three or more artists with none on most of the tracks reads as a
        // compilation, the way every music app labels one.
        if counts.count >= 3, Double(top.value) / Double(songs.count) < 0.5 {
            return "Various Artists"
        }
        return top.key
    }

    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { counts[trimmed, default: 0] += 1 }
        }
        return counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key
    }
}

// MARK: - Sort order

enum AlbumSortOrder: String, CaseIterable, Identifiable {
    case title
    case artist
    case year
    case recentlyAdded
    case mostTracks
    case longest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title:         return "Title"
        case .artist:        return "Artist"
        case .year:          return "Year"
        case .recentlyAdded: return "Recently Added"
        case .mostTracks:    return "Most Tracks"
        case .longest:       return "Longest"
        }
    }

    var icon: String {
        switch self {
        case .title:         return "textformat"
        case .artist:        return "music.mic"
        case .year:          return "calendar"
        case .recentlyAdded: return "clock.arrow.circlepath"
        case .mostTracks:    return "number"
        case .longest:       return "timer"
        }
    }

    func apply(to albums: [AlbumSummary]) -> [AlbumSummary] {
        let byTitle: (AlbumSummary, AlbumSummary) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        switch self {
        case .title:
            return albums.sorted(by: byTitle)
        case .artist:
            return albums.sorted {
                let order = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                return order == .orderedSame ? byTitle($0, $1) : order == .orderedAscending
            }
        case .year:
            // Newest first; albums without a year tag go last.
            return albums.sorted {
                switch ($0.year, $1.year) {
                case let (a?, b?) where a != b: return a > b
                case (nil, _?): return false
                case (_?, nil): return true
                default: return byTitle($0, $1)
                }
            }
        case .recentlyAdded:
            return albums.sorted {
                ($0.dateAdded ?? .distantPast, $1.name) > ($1.dateAdded ?? .distantPast, $0.name)
            }
        case .mostTracks:
            return albums.sorted { $0.songCount != $1.songCount ? $0.songCount > $1.songCount : byTitle($0, $1) }
        case .longest:
            return albums.sorted { $0.totalDuration != $1.totalDuration ? $0.totalDuration > $1.totalDuration : byTitle($0, $1) }
        }
    }

    /// Section key for an album under this order, or nil when this order
    /// doesn't group (a "Most Tracks" list split by letter would be noise).
    func sectionKey(for album: AlbumSummary) -> String? {
        switch self {
        case .title:  return Self.letter(of: album.name)
        case .artist: return Self.letter(of: album.artist)
        case .year:
            guard let year = album.year else { return "Unknown Year" }
            return "\(year / 10 * 10)s"
        case .recentlyAdded, .mostTracks, .longest:
            return nil
        }
    }

    /// Whether the section keys are short enough for the jump rail.
    var usesIndexRail: Bool { self == .title || self == .artist }

    private static func letter(of text: String) -> String {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.first { CharacterSet.alphanumerics.contains($0) }
            .map { String($0).uppercased() } ?? "#"
        return first.rangeOfCharacter(from: .letters) != nil ? first : "#"
    }
}

// MARK: - Section

/// One run of albums under a header ("A", "1990s"), or the whole list
/// untitled when the sort order doesn't group.
struct AlbumSection: Identifiable {
    let title: String?
    let albums: [AlbumSummary]

    var id: String { title.map(Self.anchor(for:)) ?? "albums-section-all" }

    static func anchor(for title: String) -> String { "albums-section-\(title)" }

    static func group(_ sorted: [AlbumSummary], by order: AlbumSortOrder) -> [AlbumSection] {
        guard sorted.contains(where: { order.sectionKey(for: $0) != nil }) else {
            return [AlbumSection(title: nil, albums: sorted)]
        }
        var keys: [String] = []
        var buckets: [String: [AlbumSummary]] = [:]
        for album in sorted {
            let key = order.sectionKey(for: album) ?? "#"
            if buckets[key] == nil { keys.append(key) }
            buckets[key, default: []].append(album)
        }
        return keys.map { AlbumSection(title: $0, albums: buckets[$0] ?? []) }
    }
}

// MARK: - Albums Tab

struct AlbumsTab: View {
    /// The Library screen's (debounced) search text.
    var searchText: String = ""

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    @AppStorage("library_albums_columns") private var albumColumns: Int = 2
    @AppStorage("library_albums_sort") private var sortRaw: String = AlbumSortOrder.title.rawValue

    @State private var allAlbums: [AlbumSummary] = []
    @State private var recentAlbums: [AlbumSummary] = []
    @State private var hasLoaded = false

    private var sortOrder: AlbumSortOrder { AlbumSortOrder(rawValue: sortRaw) ?? .title }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Filtered + sorted + sectioned albums, cached — rebuilt only when the
    /// library, the search text or the sort changes (see `.task` below), not
    /// on every body pass (player updates re-render this view).
    @State private var visibleCount = 0
    @State private var sections: [AlbumSection] = []

    private func rebuildSections() {
        let filtered = query.isEmpty ? allAlbums : allAlbums.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || ($0.genre?.localizedCaseInsensitiveContains(query) ?? false)
        }
        let sorted = sortOrder.apply(to: filtered)
        visibleCount = sorted.count
        // Letter sections only pay off in a big library — in a small one
        // most letters hold one album, leaving a row per album with the rest
        // of the grid empty.
        sections = sorted.count >= Self.sectioningThreshold
            ? AlbumSection.group(sorted, by: sortOrder)
            : [AlbumSection(title: nil, albums: sorted)]
    }

    static let sectioningThreshold = 30

    private var gridColumns: [GridItem] {
        // `.top` so a one-line title doesn't sit lower than its two-line
        // neighbours — LazyVGrid centers cells in their row by default,
        // which is what knocked single-line albums out of line.
        Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: max(1, albumColumns))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if library.albums.isEmpty && allAlbums.isEmpty {
                    EmptyStateView(icon: "square.stack", title: "No albums", message: "Add music to see albums here.")
                        .padding(.top, 60)
                } else {
                    content
                }
            }
            .overlay(alignment: .trailing) {
                let letters = sections.compactMap(\.title)
                if sortOrder.usesIndexRail, letters.count >= 4 {
                    AlphabetIndexRail(letters: letters) { letter in
                        withAnimation(LumiMotion.fade(0.25)) {
                            proxy.scrollTo(AlbumSection.anchor(for: letter), anchor: .top)
                        }
                    }
                    .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(0.55))
                    .padding(.trailing, 2)
                    // Below the Recently Added shelf rather than centred
                    // over it.
                    .padding(.top, 260)
                }
            }
        }
        .background(Color.clear.ignoresSafeArea())
        .task(id: "\(library.allSongs.count)|\(library.albums.count)") {
            // Same off-main grouping as FoldersTab: O(n) over the whole
            // library, and re-run on every rebuild during a scan.
            let songs = library.allSongs
            let built = await Task.detached(priority: .userInitiated) {
                AlbumSummary.build(from: songs)
            }.value
            guard !Task.isCancelled else { return }
            allAlbums = built
            recentAlbums = Array(
                built
                    .filter { $0.dateAdded != nil }
                    .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
                    .prefix(10)
            )
            hasLoaded = true
            rebuildSections()
        }
        .onChange(of: searchText) { _ in rebuildSections() }
        .onChange(of: sortRaw) { _ in
            withAnimation(LumiMotion.fade(0.25)) { rebuildSections() }
        }
    }

    // MARK: Content

    private var content: some View {
        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
            if query.isEmpty, recentAlbums.count >= 3 {
                RecentlyAddedAlbumsShelf(albums: recentAlbums, onPlay: play)
            }

            controlsRow
                .padding(.horizontal, 16)

            if visibleCount == 0, hasLoaded, !query.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No matching albums",
                    message: "Nothing here matches \u{201C}\(query)\u{201D}."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
            }

            // ForEach ids double as the jump rail's scroll targets — ids
            // of a lazy stack's ForEach are reachable before they're built.
            ForEach(sections) { section in
                Section {
                    albumGrid(section.albums)
                } header: {
                    if let title = section.title {
                        AlbumIndexHeader(title: title, count: section.albums.count)
                    }
                }
            }
        }
        .padding(.top, 10)
        // Clearance for the mini player + tab bar — see SongsTab.
        .padding(.bottom, 190)
    }

    @ViewBuilder
    private func albumGrid(_ albums: [AlbumSummary]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: albumColumns == 1 ? 10 : 22) {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album.name)
                } label: {
                    if albumColumns == 1 {
                        AlbumListRow(album: album, isPlaying: isPlaying(album))
                    } else {
                        AlbumGridCell(album: album, compact: albumColumns >= 3, isPlaying: isPlaying(album))
                    }
                }
                .buttonStyle(PressableButtonStyle())
                // The play button is drawn over the link, not inside its
                // label — a Button inside a NavigationLink's label loses its
                // taps to the link (see FoldersTab's `expandedFolderIDs`).
                .overlay {
                    AlbumPlayButtonOverlay(isRow: albumColumns == 1, compact: albumColumns >= 3) {
                        play(album)
                    }
                }
                .contextMenu { albumMenu(album) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.trailing, sortOrder.usesIndexRail && albumColumns == 1 ? 10 : 0)
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack(spacing: 8) {
            LumiPicker(selection: $sortRaw) {
                ForEach(AlbumSortOrder.allCases) { order in
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

            Text("\(visibleCount) \(visibleCount == 1 ? "album" : "albums")")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                guard let album = sections.flatMap(\.albums).randomElement() else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                play(album)
                ToastCenter.shared.show("Playing \(album.name)", category: .info, icon: "dice.fill")
            } label: {
                Image(systemName: "dice.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .frame(width: 32, height: 32)
                    .adaptiveGlass(in: Circle(), fallback: AppTheme.surface.opacity(0.7))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Play a random album")

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
            withAnimation(LumiMotion.settle) { albumColumns = target }
        } label: {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(albumColumns == target ? Color.white : AppTheme.textSecondary)
                .frame(width: 30, height: 26)
                .background {
                    if albumColumns == target {
                        Capsule().fill(AppTheme.dynamicAccent)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(albumColumns == target ? .isSelected : [])
    }

    // MARK: Actions

    private func isPlaying(_ album: AlbumSummary) -> Bool {
        guard let current = player.currentSong else { return false }
        return current.groupableAlbumName == album.name
    }

    private func play(_ album: AlbumSummary) {
        guard !album.songs.isEmpty else { return }
        player.setQueue(album.songs, startIndex: 0, autoplay: true)
    }

    @ViewBuilder
    private func albumMenu(_ album: AlbumSummary) -> some View {
        Button { play(album) } label: { Label("Play", systemImage: "play.fill") }
        Button {
            player.setQueue(album.songs.smartShuffled(), startIndex: 0, autoplay: true)
        } label: { Label("Shuffle", systemImage: "shuffle") }
        Divider()
        Button {
            // insertNext puts each song straight after the current one, so
            // going in reverse leaves them in album order.
            for song in album.songs.reversed() { player.insertNext(song: song) }
            ToastCenter.shared.show("\(album.name) plays next", category: .success, icon: "text.insert")
        } label: { Label("Play Next", systemImage: "text.insert") }
        Button {
            for song in album.songs { player.appendToQueue(song: song) }
            ToastCenter.shared.show(
                "Added \(album.songCount) song\(album.songCount == 1 ? "" : "s") to queue",
                category: .success, icon: "text.badge.plus"
            )
        } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
    }
}

// MARK: - Section header

private struct AlbumIndexHeader: View {
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
        // Pinned while scrolling, so it needs its own backing — a soft
        // fade in the screen's background colour rather than a card.
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

// MARK: - Cover

/// An album's cover at a given size, with the empty-album placeholder.
struct AlbumCoverView: View {
    let song: Song?
    let size: CGFloat
    var cornerRadius: CGFloat = 14

    var body: some View {
        Group {
            if let song {
                ArtworkThumbnail(song: song, size: size, showsScrim: false)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.surface)
                    .overlay {
                        Image(systemName: "square.stack.fill")
                            .font(.system(size: size * 0.25))
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.75)
        )
    }
}

// MARK: - Grid cell

private struct AlbumGridCell: View {
    let album: AlbumSummary
    let compact: Bool
    let isPlaying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Sized from the real column width — a fixed size clips in three
            // columns and under-fills in one.
            GeometryReader { geo in
                AlbumCoverView(song: album.coverSong, size: geo.size.width, cornerRadius: compact ? 10 : 14)
                    .overlay(alignment: .topLeading) {
                        if isPlaying { AlbumNowPlayingBadge().padding(6) }
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font((compact ? Font.caption : .subheadline).weight(.semibold))
                    .foregroundStyle(isPlaying ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(.leading)
                Text(album.artist)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                if !compact {
                    Text(album.detailLine)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - List row

private struct AlbumListRow: View {
    let album: AlbumSummary
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 14) {
            AlbumCoverView(song: album.coverSong, size: 64, cornerRadius: 10)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                    Text(album.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isPlaying ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                        .lineLimit(1)
                }
                Text(album.artist)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                Text(album.detailLine)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            // Room for the play button overlay.
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(8)
        .adaptiveGlass(
            tint: isPlaying ? AppTheme.dynamicAccent.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            fallback: isPlaying ? AppTheme.dynamicAccent.opacity(0.12) : AppTheme.surface.opacity(0.55)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Play button overlay

/// The round play button drawn over a cell: bottom-right of the cover in the
/// grid, trailing edge in the list. Only the button itself takes touches —
/// the rest of the overlay is empty, so taps elsewhere reach the link.
private struct AlbumPlayButtonOverlay: View {
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
            .accessibilityLabel("Play album")
            .position(
                x: geo.size.width - side / 2 - (isRow ? 16 : 8),
                // In the grid the cover is as tall as the cell is wide.
                y: isRow ? geo.size.height / 2 : geo.size.width - side / 2 - 8
            )
        }
    }
}

/// Small "now playing" equalizer badge for a cover.
private struct AlbumNowPlayingBadge: View {
    var body: some View {
        Image(systemName: "waveform")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(6)
            .background(AppTheme.dynamicAccent, in: Circle())
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .accessibilityLabel("Now playing")
    }
}

// MARK: - Recently Added shelf

private struct RecentlyAddedAlbumsShelf: View {
    let albums: [AlbumSummary]
    let onPlay: (AlbumSummary) -> Void

    private let cardSize: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(AppTheme.dynamicAccent)
                Text("Recently Added")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .font(.title3.weight(.bold))
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album.name)
                        } label: {
                            card(album)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .overlay(alignment: .bottomTrailing) {
                            Button {
                                onPlay(album)
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .adaptiveGlass(tint: AppTheme.dynamicAccent.opacity(0.5), in: Circle(), fallback: AppTheme.dynamicAccent)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityLabel("Play \(album.name)")
                            .padding(12)
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

    private func card(_ album: AlbumSummary) -> some View {
        ZStack(alignment: .bottomLeading) {
            AlbumCoverView(song: album.coverSong, size: cardSize, cornerRadius: 22)

            // Legibility scrim for the caption.
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center, endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(album.artist)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 64)
            .padding(.bottom, 14)
        }
        .frame(width: cardSize, height: cardSize)
        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
    }
}
