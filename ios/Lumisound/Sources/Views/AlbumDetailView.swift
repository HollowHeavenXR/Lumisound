import SwiftUI

// MARK: - AlbumDetailView
//
// 2026-09 restructure, matching the Albums tab and the folder detail
// revamp: a big cover over a blurred backdrop, an "ALBUM · year" eyebrow,
// genre / songs / time chips, Play + Shuffle + queue buttons, the layout
// switch moved out of the toolbar into a row above the tracks, a summary
// footer, and a "More by <artist>" shelf. Track rows are still `SongRow` /
// `SongGridCell`, so they follow the user's row style and custom styles.

struct AlbumDetailView: View {
    let album: String

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var account: AccountService

    @AppStorage("albumDetail_columns") private var columns: Int = 1

    // Pushes driven by state rather than NavigationLinks: the header and
    // footer are rows of a List in list mode, and a NavigationLink anywhere
    // in a List row turns the whole row into that link.
    @State private var showArtist = false
    @State private var pushedAlbum: String?

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: max(1, columns))
    }

    /// Tracks in album order and the album's summary, cached — both used to
    /// be computed properties, re-sorted on every one of the dozen-odd reads
    /// per render (and this view re-renders on every player update).
    /// Rebuilt when the library changes (see `.task` in `body`).
    @State private var songs: [Song] = []
    @State private var summary: AlbumSummary?
    @State private var moreByArtist: [String] = []
    /// So "No tracks" doesn't flash for the frame before the first load.
    @State private var hasLoaded = false

    private func reload() {
        let tracks = library.songs(inAlbum: album).sorted(by: AlbumSummary.albumOrder)
        songs = tracks
        summary = AlbumSummary.build(from: tracks).first
        moreByArtist = computeMoreByArtist()
        hasLoaded = true
    }

    private var artistName: String {
        summary?.artist ?? songs.first?.artistName ?? "Unknown Artist"
    }

    private var isCompilation: Bool { artistName == "Various Artists" }

    private var totalDurationText: String {
        let total = Int(songs.reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) }.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    /// Other albums by the same artist, for the shelf at the bottom.
    private func computeMoreByArtist() -> [String] {
        guard !isCompilation, artistName != "Unknown Artist" else { return [] }
        var seen = Set<String>()
        return library.songs(byArtist: artistName)
            .map(\.groupableAlbumName)
            .filter { $0 != album && $0 != "Unknown Album" && seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func trackSubtitle(for song: Song) -> String {
        let artist = isCompilation ? song.artistName : song.durationText
        return song.trackNumber > 0 ? "\(song.trackNumber) · \(artist)" : artist
    }

    var body: some View {
        Group {
            if columns == 1 {
                List {
                    Section {
                        headerBlock
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listSectionSeparator(.hidden)

                    // Same SongRow as the Songs tab, so rows follow the
                    // user's row style everywhere.
                    Section {
                        if songs.isEmpty, hasLoaded {
                            EmptyStateView(icon: "square.stack", title: "No tracks", message: "This album has no tracks.")
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(songs) { song in
                                Button {
                                    player.play(song: song, in: songs, uiSource: "album")
                                } label: {
                                    SongRow(
                                        song: song,
                                        isCurrent: player.currentSong?.id == song.id,
                                        subtitle: trackSubtitle(for: song)
                                    )
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(AppTheme.elevatedSurface.opacity(0.6))
                                )
                                .listRowSeparator(.hidden)
                            }
                        }
                    }

                    Section {
                        footerBlock
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listSectionSeparator(.hidden)
                }
                // .plain to match the main Library's edge-to-edge list.
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        headerBlock

                        if songs.isEmpty, hasLoaded {
                            EmptyStateView(icon: "square.stack", title: "No tracks", message: "This album has no tracks.")
                                .padding(.top, 40)
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: 14) {
                                ForEach(songs) { song in
                                    Button {
                                        player.play(song: song, in: songs, uiSource: "album")
                                    } label: {
                                        SongGridCell(
                                            song: song,
                                            isCurrent: player.currentSong?.id == song.id,
                                            subtitle: song.durationText,
                                            trackNumber: song.trackNumber
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        footerBlock
                    }
                    // Clearance for the mini player + tab bar — see SongsTab.
                    .padding(.bottom, 190)
                }
            }
        }
        // A pushed view doesn't inherit the Library root's background.
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle(album)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
        .task(id: library.allSongs.count) { reload() }
        .navigationDestination(isPresented: $showArtist) {
            ArtistDetailView(artist: artistName)
        }
        .navigationDestination(item: $pushedAlbum) { name in
            AlbumDetailView(album: name)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                LumiMenu {
                    Button {
                        for song in songs.reversed() { player.insertNext(song: song) }
                        ToastCenter.shared.show("\(album) plays next", category: .success, icon: "text.insert")
                    } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }
                    Button {
                        library.addFavorites(ids: Set(songs.map(\.id)))
                    } label: {
                        Label("Favorite All Tracks", systemImage: "heart")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(AppTheme.dynamicAccent)
                .disabled(songs.isEmpty)
            }
        }
    }

    // MARK: Header + actions + controls

    private var headerBlock: some View {
        VStack(spacing: 18) {
            AlbumHeaderView(
                album: album,
                artistName: artistName,
                year: summary?.year,
                genre: summary?.genre,
                songCount: songs.count,
                totalDurationText: totalDurationText,
                coverSong: songs.first,
                onArtistTap: { showArtist = true }
            )

            actionButtons
                .padding(.horizontal, 16)

            AlbumLinerNotesCard(album: album, artist: artistName)
                .padding(.horizontal, 16)

            controlsRow
                .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                player.setQueue(songs, startIndex: 0, autoplay: true)
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
                player.setQueue(songs.smartShuffled(), startIndex: 0, autoplay: true)
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
                for song in songs { player.appendToQueue(song: song) }
                ToastCenter.shared.show(
                    "Added \(songs.count) song\(songs.count == 1 ? "" : "s") to queue",
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
            .accessibilityLabel("Add album to queue")
        }
        .disabled(songs.isEmpty)
        .opacity(songs.isEmpty ? 0.5 : 1)
    }

    /// "Tracks" on the left, the list/grid switch on the right — the switch
    /// used to be three bare toolbar icons.
    private var controlsRow: some View {
        HStack {
            Text("Tracks")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)

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
                    if columns == target {
                        Capsule().fill(AppTheme.dynamicAccent)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(columns == target ? .isSelected : [])
    }

    // MARK: Footer

    private var footerBlock: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if let year = summary?.year {
                        Text("Released \(String(year))")
                    }
                    Text("\(songs.count) \(songs.count == 1 ? "song" : "songs") · \(totalDurationText)")
                }
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 16)
            }

            if !moreByArtist.isEmpty {
                MoreByArtistShelf(artist: artistName, albums: moreByArtist) { pushedAlbum = $0 }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}

// MARK: - More by artist

private struct MoreByArtistShelf: View {
    let artist: String
    let albums: [String]
    let onOpen: (String) -> Void

    @EnvironmentObject private var library: LibraryManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("More by \(artist)")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums, id: \.self) { name in
                        Button {
                            onOpen(name)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AlbumCoverView(
                                    song: library.songs(inAlbum: name).sorted(by: AlbumSummary.albumOrder).first,
                                    size: 140
                                )
                                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                                Text(name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(width: 140, alignment: .leading)
                            }
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Liner Notes
//
// A short Aria Lumi-written blurb about the album (GET /music/liner-notes),
// cached server-side PER ALBUM rather than per-user — since album facts
// don't change per listener, this costs at most one Gemini call EVER per
// unique album across the whole server, not once per user/day like Aria's
// Daily Pick. Renders nothing at all (no placeholder, no error state) when
// there's no blurb yet, so a cache-miss or logged-out state never leaves
// visible dead space on the album screen.
private struct AlbumLinerNotesCard: View {
    let album: String
    let artist: String

    @EnvironmentObject private var account: AccountService
    @State private var blurb: String?

    var body: some View {
        Group {
            if let blurb {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Liner Notes", systemImage: "text.quote")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.dynamicAccent)
                    Text(blurb)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .task(id: "\(artist)|\(album)") {
            blurb = await account.fetchLinerNotes(artist: artist, album: album)
        }
    }
}

// MARK: - Album Header

private struct AlbumHeaderView: View {
    let album: String
    let artistName: String
    let year: Int?
    let genre: String?
    let songCount: Int
    let totalDurationText: String
    let coverSong: Song?
    let onArtistTap: () -> Void

    private let coverSize: CGFloat = 230

    private var eyebrow: String {
        year.map { "ALBUM · \(String($0))" } ?? "ALBUM"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Big blurred-artwork backdrop — same component as the Songs,
            // Queue and Folder Detail headers.
            HeroArtworkBackdrop(song: coverSong, height: 440)

            VStack(spacing: 14) {
                AlbumCoverView(song: coverSong, size: coverSize, cornerRadius: 22)
                    .shadow(color: .black.opacity(0.55), radius: 22, y: 12)

                VStack(spacing: 6) {
                    Text(eyebrow)
                        .font(.caption2.weight(.heavy))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.dynamicAccent)
                    Text(album)
                        .font(.title.weight(.bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    if artistName == "Various Artists" || artistName == "Unknown Artist" {
                        Text(artistName)
                            .font(.headline)
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        Button(action: onArtistTap) {
                            HStack(spacing: 4) {
                                Text(artistName)
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                            }
                            .font(.headline)
                            .foregroundStyle(AppTheme.dynamicAccent)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 8) {
                        if let genre {
                            ScreenStatChip(icon: "guitars", text: genre)
                                .lineLimit(1)
                        }
                        ScreenStatChip(icon: "music.note", text: "\(songCount) \(songCount == 1 ? "song" : "songs")")
                        ScreenStatChip(icon: "clock", text: totalDurationText)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
    }
}
