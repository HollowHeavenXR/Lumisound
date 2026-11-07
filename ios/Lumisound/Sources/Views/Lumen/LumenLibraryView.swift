import SwiftUI

// MARK: - Library index

struct LumenLibraryView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var folderService: MusicFolderService
    @EnvironmentObject private var streaming: StreamingService

    @State private var showAddMusic = false
    @State private var showNewPlaylist = false
    @State private var showOpenSharedPlaylist = false
    @State private var newPlaylistName = ""

    private struct Category: Identifiable {
        let id: String
        let title: String
        let icon: String
        let tint: Color
        let route: LumenRoute
        var detail: String? = nil
    }

    private var primaryCategories: [Category] {
        [
            Category(id: "songs", title: "Songs", icon: "music.note", tint: LumenPalette.iris, route: .songs,
                     detail: "\(library.allSongs.count)"),
            Category(id: "albums", title: "Albums", icon: "square.stack.fill", tint: LumenPalette.azure, route: .albums,
                     detail: "\(library.albums.count)"),
            Category(id: "artists", title: "Artists", icon: "music.mic", tint: Color(red: 0.95, green: 0.45, blue: 0.75), route: .artists,
                     detail: "\(library.artists.count)"),
            Category(id: "playlists", title: "Playlists", icon: "music.note.list", tint: LumenPalette.success, route: .playlists,
                     detail: "\(library.playlists.count)"),
            Category(id: "favorites", title: "Favorites", icon: "heart.fill", tint: LumenPalette.ember, route: .favorites,
                     detail: "\(library.favoriteSongIDs.count)"),
            Category(id: "genres", title: "Genres", icon: "guitars.fill", tint: LumenPalette.warning, route: .genres,
                     detail: "\(library.genres.count)"),
        ]
    }

    private var moreCategories: [Category] {
        [
            Category(id: "folders", title: "Folders", icon: "folder.fill", tint: Color(red: 0.4, green: 0.6, blue: 1), route: .folders),
            Category(id: "smart", title: "Smart Playlists", icon: "wand.and.stars", tint: LumenPalette.iris, route: .smartPlaylists),
            Category(id: "moods", title: "Moods", icon: "theatermasks.fill", tint: Color(red: 0.95, green: 0.45, blue: 0.85), route: .moods),
            Category(id: "podcasts", title: "Podcasts", icon: "mic.square.fill", tint: Color(red: 0.6, green: 0.35, blue: 0.95), route: .podcasts),
            Category(id: "downloads", title: "Downloads", icon: "arrow.down.circle.fill", tint: LumenPalette.azure, route: .downloads),
            Category(id: "deleted", title: "Recently Deleted", icon: "trash.fill", tint: LumenPalette.textTertiary, route: .recentlyDeleted),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LumenScreenHeader(eyebrow: libraryEyebrow, title: "Library") {
                    HStack(spacing: 10) {
                        if library.isScanning {
                            ProgressView().tint(LumenPalette.accent).frame(width: 38, height: 38)
                        } else {
                            LumenIconButton(systemName: "arrow.clockwise", accessibilityLabel: "Rescan library") { refresh() }
                        }
                        LumiMenu {
                            Button { showAddMusic = true } label: { Label("Add Music", systemImage: "square.and.arrow.down") }
                            Button { showNewPlaylist = true } label: { Label("New Playlist", systemImage: "music.note.list") }
                            Button { showOpenSharedPlaylist = true } label: { Label("Open Shared Playlist", systemImage: "link.badge.plus") }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(LumenPalette.textPrimary)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(LumenPalette.fill))
                                .overlay(Circle().strokeBorder(LumenPalette.hairline, lineWidth: 1))
                        }
                        .accessibilityLabel("Add")
                    }
                }

                if let error = library.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LumenPalette.warning)
                        Text(error).font(LumenType.caption(13)).foregroundStyle(LumenPalette.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .lumenCard(fill: LumenPalette.warning.opacity(0.12))
                    .padding(.horizontal, LumenMetrics.gutter)
                }

                categoryGrid

                VStack(alignment: .leading, spacing: 4) {
                    Text("MORE")
                        .font(LumenType.eyebrow())
                        .tracking(1.6)
                        .foregroundStyle(LumenPalette.textTertiary)
                        .padding(.bottom, 4)
                    ForEach(moreCategories) { category in
                        NavigationLink(value: category.route) {
                            LumenNavRow(title: category.title, systemImage: category.icon, tint: category.tint, detail: category.detail)
                        }
                        .buttonStyle(.plain)
                        if category.id != moreCategories.last?.id {
                            Divider().overlay(LumenPalette.hairline).padding(.leading, 48)
                        }
                    }
                }
                .lumenCard()
                .padding(.horizontal, LumenMetrics.gutter)

                recentAlbums
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await refreshAsync() }
        .sheet(isPresented: $showAddMusic) {
            AddMusicView()
                .environmentObject(library)
                .environmentObject(folderService)
        }
        .sheet(isPresented: $showOpenSharedPlaylist) {
            CollaborativePlaylistView(playlist: nil)
                .environmentObject(player)
                .environmentObject(account)
                .environmentObject(streaming)
                .environmentObject(library)
        }
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { library.createPlaylist(name: name) }
                newPlaylistName = ""
            }
        }
    }

    private var libraryEyebrow: String {
        let total = library.allSongs.reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) }
        return "\(LumenFormat.count(library.allSongs.count, "track")) · \(LumenFormat.duration(total))"
    }

    private var categoryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(primaryCategories) { category in
                NavigationLink(value: category.route) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Image(systemName: category.icon)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(
                                    LinearGradient(colors: [category.tint, category.tint.opacity(0.6)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .shadow(color: category.tint.opacity(0.45), radius: 10, y: 4)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(LumenPalette.textTertiary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                                .font(LumenType.headline(16))
                                .foregroundStyle(LumenPalette.textPrimary)
                            Text(category.detail ?? "")
                                .font(LumenType.mono(12))
                                .foregroundStyle(LumenPalette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lumenCard(radius: 20, padding: 14)
                }
                .buttonStyle(LumenPressStyle())
            }
        }
        .padding(.horizontal, LumenMetrics.gutter)
    }

    @ViewBuilder
    private var recentAlbums: some View {
        let albums = recentAlbumNames
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                LumenSectionHeader(title: "Recently Added Albums")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                    ForEach(albums, id: \.self) { album in
                        LumenAlbumCell(album: album)
                    }
                }
                .padding(.horizontal, LumenMetrics.gutter)
            }
        }
    }

    private var recentAlbumNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for song in library.recentlyAddedSongs(limit: 60) {
            let name = song.groupableAlbumName
            guard name != "Unknown Album", !seen.contains(name), !library.songs(inAlbum: name).isEmpty else { continue }
            seen.insert(name)
            result.append(name)
            if result.count == 6 { break }
        }
        return result
    }

    private func refresh() {
        Task { await refreshAsync() }
    }

    private func refreshAsync() async {
        await library.refreshAll(folderService: folderService)
        if account.isLoggedIn {
            await account.pullSync(library: library, player: player)
        }
        if let result = library.lastScanResult {
            ToastCenter.shared.show(result, category: .success, icon: "arrow.clockwise")
        }
    }
}

// MARK: - Album cell

struct LumenAlbumCell: View {
    let album: String
    @EnvironmentObject private var library: LibraryManager

    var body: some View {
        let songs = library.songs(inAlbum: album)
        NavigationLink(value: LumenRoute.album(album)) {
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 8) {
                    LumenArtwork(song: songs.first, size: geo.size.width, radius: 16, fallbackSeed: album)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album)
                            .font(LumenType.headline(14))
                            .foregroundStyle(LumenPalette.textPrimary)
                            .lineLimit(1)
                        Text(songs.first?.artistName ?? "")
                            .font(LumenType.caption(12))
                            .foregroundStyle(LumenPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .aspectRatio(0.78, contentMode: .fit)
        }
        .buttonStyle(LumenPressStyle())
    }
}

// MARK: - Songs

struct LumenSongsListView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    @AppStorage("library_songs_sort") private var sortRaw: String = SongSortOrder.title.rawValue
    @State private var query = ""
    @State private var visible: [Song] = []
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

    private var sort: SongSortOrder { SongSortOrder(rawValue: sortRaw) ?? .title }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                VStack(spacing: 14) {
                    LumenSearchField(text: $query, prompt: "Filter \(library.allSongs.count) songs")
                    HStack(spacing: 10) {
                        LumenPrimaryButton(title: "Play", systemImage: "play.fill", expands: true) {
                            if let first = visible.first { player.play(song: first, in: visible) }
                        }
                        LumenSecondaryButton(title: "Shuffle", systemImage: "shuffle", expands: true) {
                            let shuffled = visible.shuffled()
                            if let first = shuffled.first { player.play(song: first, in: shuffled) }
                        }
                    }
                }
                .padding(.horizontal, LumenMetrics.gutter)
                .padding(.bottom, 12)

                if visible.isEmpty && !query.isEmpty {
                    LumenEmptyState(systemImage: "magnifyingglass", title: "No matches",
                                    message: "Nothing in your library matches “\(query)”.")
                }

                ForEach(visible) { song in
                    HStack(spacing: 0) {
                        if isSelecting {
                            Image(systemName: selectedIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(selectedIDs.contains(song.id) ? LumenPalette.accent : LumenPalette.textTertiary)
                                .padding(.leading, LumenMetrics.gutter)
                        }
                        LumenTrackRow(song: song) {
                            if isSelecting {
                                if selectedIDs.contains(song.id) { selectedIDs.remove(song.id) } else { selectedIDs.insert(song.id) }
                            } else {
                                player.play(song: song, in: visible)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .lumenScreen(title: "Songs")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LumiMenu {
                    ForEach(SongSortOrder.allCases, id: \.self) { option in
                        Button {
                            sortRaw = option.rawValue
                        } label: {
                            if sort == option { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort")
                Button(isSelecting ? "Done" : "Select") {
                    withAnimation { isSelecting.toggle(); selectedIDs.removeAll() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selectedIDs.isEmpty {
                LumenSelectionBar(selectedIDs: $selectedIDs, isSelecting: $isSelecting)
            }
        }
        .task(id: "\(library.allSongs.count)|\(query)|\(sortRaw)") { await recompute() }
    }

    private func recompute() async {
        if !visible.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard !Task.isCancelled else { return }
        let songs = library.allSongs
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sort = self.sort
        let history = PlayHistoryStore.shared.entries
        let result = await Task.detached(priority: .userInitiated) { () -> [Song] in
            let filtered = q.isEmpty ? songs : songs.filter {
                $0.displayName.localizedCaseInsensitiveContains(q)
                    || $0.artistName.localizedCaseInsensitiveContains(q)
                    || $0.albumName.localizedCaseInsensitiveContains(q)
            }
            switch sort {
            case .title:     return filtered.sortedByDisplayName()
            case .artist:    return filtered.sorted { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }
            case .dateAdded: return filtered.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
            case .playCount: return filtered.sorted { (history[$0.id]?.playCount ?? 0) > (history[$1.id]?.playCount ?? 0) }
            case .duration:  return filtered.sorted { $0.duration > $1.duration }
            }
        }.value
        guard !Task.isCancelled else { return }
        visible = result
    }
}

/// Bottom bar for multi-select: add to playlist, favorite, remove.
struct LumenSelectionBar: View {
    @Binding var selectedIDs: Set<String>
    @Binding var isSelecting: Bool
    @EnvironmentObject private var library: LibraryManager
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(selectedIDs.count) selected")
                .font(LumenType.headline(14))
                .foregroundStyle(LumenPalette.textPrimary)
            Spacer()
            LumiMenu {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) {
                        library.addSongs(ids: selectedIDs, toPlaylistID: playlist.id)
                        finish()
                    }
                }
            } label: {
                Image(systemName: "text.badge.plus").frame(width: 40, height: 40)
            }
            .accessibilityLabel("Add to playlist")
            Button {
                library.addFavorites(ids: selectedIDs)
                finish()
            } label: {
                Image(systemName: "heart").frame(width: 40, height: 40)
            }
            .accessibilityLabel("Add to Favorites")
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash").frame(width: 40, height: 40)
            }
            .accessibilityLabel("Remove from library")
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(LumenPalette.accent)
        .padding(.horizontal, 18)
        .frame(height: 58)
        .lumenGlass(in: Capsule(), fallback: LumenPalette.elevated)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .confirmationDialog("Remove \(selectedIDs.count) songs from your library?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                library.removeImportedSongs(ids: selectedIDs)
                finish()
            }
        }
    }

    private func finish() {
        withAnimation {
            selectedIDs.removeAll()
            isSelecting = false
        }
    }
}

// MARK: - Albums

struct LumenAlbumsGridView: View {
    @EnvironmentObject private var library: LibraryManager
    @State private var query = ""

    private var albums: [String] {
        let all = library.albums.filter { !library.songs(inAlbum: $0).isEmpty }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.localizedCaseInsensitiveContains(q)
                || (library.songs(inAlbum: $0).first?.artistName.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LumenSearchField(text: $query, prompt: "Filter albums")
                    .padding(.horizontal, LumenMetrics.gutter)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                    ForEach(albums, id: \.self) { album in
                        LumenAlbumCell(album: album)
                    }
                }
                .padding(.horizontal, LumenMetrics.gutter)
                if albums.isEmpty {
                    LumenEmptyState(systemImage: "square.stack", title: query.isEmpty ? "No albums yet" : "No matches",
                                    message: query.isEmpty ? "Albums appear here once your tracks carry album tags." : "Try a different name.")
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .lumenScreen(title: "Albums")
    }
}

// MARK: - Artists

struct LumenArtistsGridView: View {
    @EnvironmentObject private var library: LibraryManager
    @State private var query = ""

    private var artists: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? library.artists : library.artists.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LumenSearchField(text: $query, prompt: "Filter artists")
                    .padding(.horizontal, LumenMetrics.gutter)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 16)], spacing: 20) {
                    ForEach(artists, id: \.self) { artist in
                        NavigationLink(value: LumenRoute.artist(artist)) {
                            VStack(spacing: 8) {
                                ArtistAvatar(artist: artist, size: 100)
                                    .clipShape(Circle())
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
                                Text(artist)
                                    .font(LumenType.headline(13))
                                    .foregroundStyle(LumenPalette.textPrimary)
                                    .lineLimit(1)
                                Text(LumenFormat.count(library.songs(byArtist: artist).count, "song"))
                                    .font(LumenType.caption(11))
                                    .foregroundStyle(LumenPalette.textSecondary)
                            }
                        }
                        .buttonStyle(LumenPressStyle())
                    }
                }
                .padding(.horizontal, LumenMetrics.gutter)
                if artists.isEmpty {
                    LumenEmptyState(systemImage: "music.mic", title: query.isEmpty ? "No artists yet" : "No matches",
                                    message: query.isEmpty ? "Artists appear here as your library fills up." : "Try a different name.")
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .lumenScreen(title: "Artists")
    }
}

// MARK: - Playlists

struct LumenPlaylistsView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    NavigationLink(value: LumenRoute.smartPlaylists) {
                        featureTile("Smart", icon: "wand.and.stars", colors: [LumenPalette.iris, LumenPalette.azure])
                    }
                    .buttonStyle(LumenPressStyle())
                    NavigationLink(value: LumenRoute.favorites) {
                        featureTile("Favorites", icon: "heart.fill", colors: [LumenPalette.ember, Color(red: 0.85, green: 0.2, blue: 0.45)])
                    }
                    .buttonStyle(LumenPressStyle())
                }
                .padding(.horizontal, LumenMetrics.gutter)

                if library.playlists.isEmpty {
                    LumenEmptyState(systemImage: "music.note.list", title: "No playlists yet",
                                    message: "Gather tracks for any moment — tap New Playlist to start one.",
                                    actionTitle: "New Playlist") { showNewPlaylist = true }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                        ForEach(library.playlists) { playlist in
                            NavigationLink(value: LumenRoute.playlist(playlist.id)) {
                                GeometryReader { geo in
                                    VStack(alignment: .leading, spacing: 8) {
                                        LumenCollage(songs: library.collageSongs(from: library.songs(for: playlist)),
                                                     size: geo.size.width, radius: 18, seed: playlist.name)
                                            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                                        Text(playlist.name)
                                            .font(LumenType.headline(14))
                                            .foregroundStyle(LumenPalette.textPrimary)
                                            .lineLimit(1)
                                        Text(LumenFormat.count(playlist.songCount, "song"))
                                            .font(LumenType.caption(12))
                                            .foregroundStyle(LumenPalette.textSecondary)
                                    }
                                }
                                .aspectRatio(0.78, contentMode: .fit)
                            }
                            .buttonStyle(LumenPressStyle())
                            .contextMenu {
                                Button {
                                    let songs = library.songs(for: playlist)
                                    if let first = songs.first { player.play(song: first, in: songs, playlistID: playlist.id) }
                                } label: { Label("Play", systemImage: "play.fill") }
                                Button(role: .destructive) {
                                    library.deletePlaylist(playlist)
                                } label: { Label("Delete Playlist", systemImage: "trash") }
                            }
                        }
                    }
                    .padding(.horizontal, LumenMetrics.gutter)
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .lumenScreen(title: "Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewPlaylist = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New Playlist")
            }
        }
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { library.createPlaylist(name: name) }
                newPlaylistName = ""
            }
        }
    }

    private func featureTile(_ title: String, icon: String, colors: [Color]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16, weight: .bold))
            Text(title).font(LumenType.headline(15))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Genres

struct LumenGenresView: View {
    @EnvironmentObject private var library: LibraryManager

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(library.genres, id: \.self) { genre in
                    NavigationLink(value: LumenRoute.genre(genre)) {
                        ZStack(alignment: .bottomLeading) {
                            LumenGeneratedArt(seed: genre)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(genre)
                                    .font(LumenType.title(17))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(LumenFormat.count(library.songs(inGenre: genre).count, "song"))
                                    .font(LumenType.caption(11))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .padding(14)
                        }
                        .frame(height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(LumenPressStyle())
                }
            }
            .padding(.horizontal, LumenMetrics.gutter)
            .padding(.vertical, 8)
            if library.genres.isEmpty {
                LumenEmptyState(systemImage: "guitars", title: "No genres yet",
                                message: "Genres come from your tracks' tags.")
            }
        }
        .scrollIndicators(.hidden)
        .lumenScreen(title: "Genres")
    }
}
