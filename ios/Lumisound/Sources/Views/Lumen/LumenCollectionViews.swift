import SwiftUI

// MARK: - Shared header

/// Top of every Lumen collection screen (album, artist, playlist, genre,
/// favorites): the collection's art floating over a blurred bloom of
/// itself, the title block, and Play / Shuffle.
struct LumenCollectionHeader<Art: View, Accessory: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String? = nil
    var subtitleRoute: LumenRoute? = nil
    let meta: String
    var bloomSong: Song? = nil
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder var art: () -> Art
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 18) {
            art()
                .shadow(color: .black.opacity(0.5), radius: 26, y: 16)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(eyebrow.uppercased())
                    .font(LumenType.eyebrow())
                    .tracking(1.6)
                    .foregroundStyle(LumenPalette.accent)
                Text(title)
                    .font(LumenType.display(28))
                    .foregroundStyle(LumenPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let subtitle {
                    if let subtitleRoute {
                        NavigationLink(value: subtitleRoute) {
                            HStack(spacing: 4) {
                                Text(subtitle)
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                            }
                            .font(LumenType.headline(16))
                            .foregroundStyle(LumenPalette.textSecondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(subtitle)
                            .font(LumenType.headline(16))
                            .foregroundStyle(LumenPalette.textSecondary)
                    }
                }
                Text(meta)
                    .font(LumenType.caption(12))
                    .foregroundStyle(LumenPalette.textTertiary)
            }
            .padding(.horizontal, LumenMetrics.gutter)

            HStack(spacing: 12) {
                LumenPrimaryButton(title: "Play", systemImage: "play.fill", expands: true, action: onPlay)
                LumenSecondaryButton(title: "Shuffle", systemImage: "shuffle", expands: true, action: onShuffle)
                accessory()
            }
            .padding(.horizontal, LumenMetrics.gutter)
        }
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            if let bloomSong {
                ArtworkThumbnail(song: bloomSong, size: 300, showsScrim: false)
                    .scaleEffect(1.4)
                    .frame(width: 420, height: 420)
                    .blur(radius: 70)
                    .opacity(0.55)
                    .offset(y: -120)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
        }
    }
}

extension LumenCollectionHeader where Accessory == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil, subtitleRoute: LumenRoute? = nil,
         meta: String, bloomSong: Song? = nil,
         onPlay: @escaping () -> Void, onShuffle: @escaping () -> Void,
         @ViewBuilder art: @escaping () -> Art) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle, subtitleRoute: subtitleRoute,
                  meta: meta, bloomSong: bloomSong, onPlay: onPlay, onShuffle: onShuffle,
                  art: art, accessory: { EmptyView() })
    }
}

private func totalDuration(_ songs: [Song]) -> TimeInterval {
    songs.reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) }
}

// MARK: - Album

struct LumenAlbumDetailView: View {
    let album: String

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    private var songs: [Song] {
        library.songs(inAlbum: album).sorted {
            if $0.trackNumber != $1.trackNumber { return ($0.trackNumber == 0 ? Int.max : $0.trackNumber) < ($1.trackNumber == 0 ? Int.max : $1.trackNumber) }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var artist: String {
        let counts = Dictionary(grouping: songs, by: \.artistName).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? "Unknown Artist"
    }

    private var year: String? { songs.map(\.year).first { !$0.isEmpty } }
    private var genre: String? { songs.map(\.genre).first { !$0.isEmpty } }

    var body: some View {
        let songs = self.songs
        ScrollView {
            LazyVStack(spacing: 0) {
                LumenCollectionHeader(
                    eyebrow: "Album",
                    title: album,
                    subtitle: artist,
                    subtitleRoute: .artist(artist),
                    meta: [year, genre, LumenFormat.count(songs.count, "song"), LumenFormat.duration(totalDuration(songs))]
                        .compactMap { $0 }.joined(separator: " · "),
                    bloomSong: songs.first,
                    onPlay: { if let first = songs.first { player.play(song: first, in: songs) } },
                    onShuffle: { let s = songs.smartShuffled(); if let first = s.first { player.play(song: first, in: s) } }
                ) {
                    LumenArtwork(song: songs.first, size: 240, radius: 24, fallbackSeed: album)
                }
                .padding(.bottom, 20)

                ForEach(Array(songs.enumerated()), id: \.element.id) { offset, song in
                    LumenTrackRow(song: song, index: song.trackNumber > 0 ? song.trackNumber : offset + 1,
                                  showsArtwork: false,
                                  subtitle: song.artistName == artist ? nil : song.artistName) {
                        player.play(song: song, in: songs)
                    }
                }

                moreByArtist
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .lumenScreen()
    }

    @ViewBuilder
    private var moreByArtist: some View {
        let others = Array(Set(library.songs(byArtist: artist).map(\.groupableAlbumName)))
            .filter { $0 != album && $0 != "Unknown Album" && !library.songs(inAlbum: $0).isEmpty }
            .sorted()
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                LumenSectionHeader(title: "More by \(artist)")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(others, id: \.self) { other in
                            NavigationLink(value: LumenRoute.album(other)) {
                                LumenShelfCard(title: other, subtitle: library.songs(inAlbum: other).first?.year) {
                                    LumenArtwork(song: library.songs(inAlbum: other).first, size: 140, radius: 16, fallbackSeed: other)
                                }
                            }
                            .buttonStyle(LumenPressStyle())
                        }
                    }
                    .padding(.horizontal, LumenMetrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 32)
        }
    }
}

// MARK: - Artist

struct LumenArtistDetailView: View {
    let artist: String

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var account: AccountService

    @State private var bio: ArtistBio?
    @State private var bioExpanded = false

    private var songs: [Song] { library.songs(byArtist: artist) }

    private var topSongs: [Song] {
        let history = PlayHistoryStore.shared.entries
        return songs.sorted { (history[$0.id]?.playCount ?? 0) > (history[$1.id]?.playCount ?? 0) }
            .prefix(5).map { $0 }
    }

    private var albums: [String] {
        Array(Set(songs.map(\.groupableAlbumName)))
            .filter { $0 != "Unknown Album" && !library.songs(inAlbum: $0).isEmpty }
            .sorted()
    }

    var body: some View {
        let songs = self.songs
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                LumenCollectionHeader(
                    eyebrow: "Artist",
                    title: artist,
                    meta: "\(LumenFormat.count(songs.count, "song")) · \(LumenFormat.count(albums.count, "album"))",
                    bloomSong: songs.first,
                    onPlay: { if let first = topSongs.first { player.play(song: first, in: topSongs + songs.filter { s in !topSongs.contains(where: { $0.id == s.id }) }) } },
                    onShuffle: { let s = songs.smartShuffled(); if let first = s.first { player.play(song: first, in: s) } }
                ) {
                    ArtistAvatar(artist: artist, size: 200)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .padding(.bottom, 24)

                if let text = bio?.bio, !text.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ABOUT")
                            .font(LumenType.eyebrow())
                            .tracking(1.6)
                            .foregroundStyle(LumenPalette.accent)
                        Text(text)
                            .font(LumenType.body(14))
                            .foregroundStyle(LumenPalette.textSecondary)
                            .lineLimit(bioExpanded ? nil : 4)
                        Button(bioExpanded ? "Less" : "More") {
                            withAnimation(LumiMotion.fade) { bioExpanded.toggle() }
                        }
                        .font(LumenType.headline(13))
                        .foregroundStyle(LumenPalette.accent)
                    }
                    .lumenCard()
                    .padding(.horizontal, LumenMetrics.gutter)
                    .padding(.bottom, 24)
                }

                if !topSongs.isEmpty {
                    LumenSectionHeader(title: "Top Songs").padding(.bottom, 8)
                    ForEach(topSongs) { song in
                        LumenTrackRow(song: song, subtitle: song.albumName) { player.play(song: song, in: topSongs) }
                    }
                }

                if !albums.isEmpty {
                    LumenSectionHeader(title: "Albums").padding(.top, 28).padding(.bottom, 14)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(albums, id: \.self) { album in
                                NavigationLink(value: LumenRoute.album(album)) {
                                    LumenShelfCard(title: album, subtitle: library.songs(inAlbum: album).first?.year) {
                                        LumenArtwork(song: library.songs(inAlbum: album).first, size: 148, radius: 16, fallbackSeed: album)
                                    }
                                }
                                .buttonStyle(LumenPressStyle())
                            }
                        }
                        .padding(.horizontal, LumenMetrics.gutter)
                    }
                    .scrollIndicators(.hidden)
                }

                if songs.count > topSongs.count {
                    LumenSectionHeader(title: "All Songs").padding(.top, 28).padding(.bottom, 8)
                    let sorted = songs.sortedByDisplayName()
                    ForEach(sorted) { song in
                        LumenTrackRow(song: song, subtitle: song.albumName) { player.play(song: song, in: sorted) }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .lumenScreen()
        .task(id: artist) {
            guard account.isLoggedIn else { return }
            bio = await account.fetchArtistBio(name: artist)
        }
    }
}

// MARK: - Playlist

struct LumenPlaylistDetailView: View {
    let playlistID: UUID

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var showFullEditor = false

    private var playlist: Playlist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        if let playlist {
            content(playlist)
        } else {
            LumenEmptyState(systemImage: "music.note.list", title: "Playlist not found",
                            message: "It may have been deleted on another device.")
                .lumenScreen()
        }
    }

    private func content(_ playlist: Playlist) -> some View {
        let songs = library.songs(for: playlist)
        return List {
            LumenCollectionHeader(
                eyebrow: "Playlist",
                title: playlist.name,
                meta: "\(LumenFormat.count(songs.count, "song")) · \(LumenFormat.duration(totalDuration(songs)))",
                bloomSong: songs.first,
                onPlay: { if let first = songs.first { player.play(song: first, in: songs, playlistID: playlist.id) } },
                onShuffle: {
                    let s = songs.smartShuffled()
                    if let first = s.first { player.play(song: first, in: s, playlistID: playlist.id) }
                }
            ) {
                LumenCollage(songs: library.collageSongs(from: songs), size: 230, radius: 24, seed: playlist.name)
            }
            .padding(.bottom, 16)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if songs.isEmpty {
                LumenEmptyState(systemImage: "plus.circle", title: "Empty playlist",
                                message: "Add songs from any track's ••• menu, or open the full editor to search your library.")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(songs) { song in
                LumenTrackRow(song: song) {
                    player.play(song: song, in: songs, playlistID: playlist.id)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        library.removeSong(id: song.id, fromPlaylistID: playlist.id)
                    } label: { Label("Remove", systemImage: "minus.circle") }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        player.insertNext(song: song)
                        ToastCenter.shared.show("Playing next", category: .success, icon: "text.insert")
                    } label: { Label("Play Next", systemImage: "text.insert") }
                    .tint(LumenPalette.accent)
                }
            }
            .onMove { from, to in
                var ids = playlist.songIDs.filter { id in songs.contains { $0.id == id } }
                ids.move(fromOffsets: from, toOffset: to)
                library.reorderSongs(in: playlist.id, to: ids)
            }
            .onDelete { offsets in
                for index in offsets where songs.indices.contains(index) {
                    library.removeSong(id: songs[index].id, fromPlaylistID: playlist.id)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .lumenScreen()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isEditing {
                    Button("Done") { withAnimation(LumiMotion.glide) { isEditing = false } }
                } else {
                    LumiMenu {
                        Button { withAnimation(LumiMotion.glide) { isEditing = true } } label: { Label("Reorder & Remove", systemImage: "arrow.up.arrow.down") }
                        Button {
                            renameText = playlist.name
                            showRename = true
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button { showFullEditor = true } label: {
                            Label("Full Editor (Share, Export, Add Songs)", systemImage: "slider.horizontal.3")
                        }
                        Divider()
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Playlist", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Playlist options")
                }
            }
        }
        .navigationDestination(isPresented: $showFullEditor) {
            LumenRouteDestination(route: .playlistEditor(playlist.id))
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { library.renamePlaylist(playlist, to: name) }
            }
        }
        .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                library.deletePlaylist(playlist)
                dismiss()
            }
        } message: {
            Text("You can restore it from Recently Deleted.")
        }
    }
}

// MARK: - Song collections (favorites, genre, recently added, most played)

struct LumenSongCollectionView: View {
    enum Kind: Hashable {
        case favorites
        case recentlyAdded
        case mostPlayed
        case genre(String)
    }

    let kind: Kind

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    private var title: String {
        switch kind {
        case .favorites:       return "Favorites"
        case .recentlyAdded:   return "Recently Added"
        case .mostPlayed:      return "On Repeat"
        case .genre(let name): return name
        }
    }

    private var eyebrow: String {
        switch kind {
        case .favorites:     return "Collection"
        case .recentlyAdded: return "New"
        case .mostPlayed:    return "Most played"
        case .genre:         return "Genre"
        }
    }

    private var symbol: String {
        switch kind {
        case .favorites:     return "heart.fill"
        case .recentlyAdded: return "sparkles"
        case .mostPlayed:    return "flame.fill"
        case .genre:         return "guitars.fill"
        }
    }

    private var songs: [Song] {
        switch kind {
        case .favorites:       return library.favoriteSongs
        case .recentlyAdded:   return library.recentlyAddedSongs(limit: 100)
        case .mostPlayed:      return library.mostPlayedSongs(limit: 100)
        case .genre(let name): return library.songs(inGenre: name).sortedByDisplayName()
        }
    }

    var body: some View {
        let songs = self.songs
        ScrollView {
            LazyVStack(spacing: 0) {
                LumenCollectionHeader(
                    eyebrow: eyebrow,
                    title: title,
                    meta: "\(LumenFormat.count(songs.count, "song")) · \(LumenFormat.duration(totalDuration(songs)))",
                    bloomSong: songs.first,
                    onPlay: { if let first = songs.first { player.play(song: first, in: songs) } },
                    onShuffle: { let s = songs.smartShuffled(); if let first = s.first { player.play(song: first, in: s) } }
                ) {
                    ZStack {
                        LumenGeneratedArt(seed: title, symbol: symbol)
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                }
                .padding(.bottom, 20)

                if songs.isEmpty {
                    LumenEmptyState(systemImage: symbol, title: "Nothing here yet",
                                    message: kind == .favorites
                                        ? "Tap the heart on any track to keep it here."
                                        : "Play and add more music and this fills itself in.")
                }

                ForEach(songs) { song in
                    LumenTrackRow(song: song) { player.play(song: song, in: songs) }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .lumenScreen()
    }
}
