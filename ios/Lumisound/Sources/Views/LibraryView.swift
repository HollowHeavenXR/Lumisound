import SwiftUI

// MARK: - Tab enum

enum LibraryTab: String, CaseIterable {
    // The hub is the new default landing tab — a dashboard of shortcuts to
    // real playlists/folders/favorites plus a few auto-generated groupings
    // (see `LibraryHubView`). It sits *alongside* the traditional browsing
    // tabs below, elevating access to them rather than replacing anything —
    // every tab that existed before this redesign is still here, unchanged.
    case hub       = "Home"
    case songs     = "Songs"
    case artists   = "Artists"
    case albums    = "Albums"
    case folders   = "Folders"
    case genres    = "Genres"
    case playlists = "Playlists"
    case favorites = "Favorites"
    case moods     = "Moods"
    // Promoted to a first-class library section rather than staying a tile in
    // AccountView's grid. Podcasts are a content TYPE — the same kind of thing as
    // Songs, Albums and Playlists — and the feature had zero subscriptions across
    // the whole user base while its only entry point was one of ten equal tiles
    // inside a settings screen. Somewhere nobody looks for content is the wrong
    // place to keep content.
    case podcasts  = "Podcasts"

    var icon: String {
        switch self {
        case .hub:        return "square.grid.2x2.fill"
        case .songs:      return "music.note"
        case .artists:    return "music.mic"
        case .albums:     return "square.stack"
        case .folders:    return "folder"
        case .genres:     return "guitars"
        case .playlists:  return "music.note.list"
        case .favorites:  return "heart"
        case .moods:      return "theatermasks"
        case .podcasts:   return "mic.square"
        }
    }
}

// MARK: - LibraryView

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var folderService: MusicFolderService
    @EnvironmentObject private var moodService: MoodPlaylistService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var streaming: StreamingService

    @AppStorage("autoCloudBackup") private var autoCloudBackup: Bool = false
    /// Shared with SongsTab's sort chips (and Lua presets' default sort) —
    /// the toolbar menu and the chips are the same setting. This used to be
    /// its own "library_sort_option" that LibraryView applied before
    /// SongsTab re-sorted by the chips, so the menu barely did anything.
    @AppStorage("library_songs_sort") private var songSortRaw: String = SongSortOrder.title.rawValue
    // Mirrors SongsTab's own @AppStorage of the same key — multi-select is
    // only supported in the single-column List layout (see SongsTab), so the
    // toolbar's Select entry point is gated on it too.
    @AppStorage("library_songs_columns") private var songColumns: Int = 1

    @State private var selectedTab: LibraryTab = ScreenshotMode.initialLibraryTab ?? .hub
    @State private var searchText: String = ""
    @State private var debouncedSearch: String = ""
    @State private var filteredSongsState: [Song] = []
    @State private var showAddMusic = false
    @State private var showOpenSharedPlaylist = false
    @State private var backupSyncTask: Task<Void, Never>?

    // Songs tab multi-select
    @State private var isSelecting = false
    @State private var selectedSongIDs: Set<String> = []

    private var songSort: SongSortOrder {
        SongSortOrder(rawValue: songSortRaw) ?? .title
    }

    // MARK: Filtered songs for Songs tab (uses debounced search)

    nonisolated private static func filter(_ songs: [Song], query: String) -> [Song] {
        guard !query.isEmpty else { return songs }
        return songs.filter { song in
            song.displayName.localizedCaseInsensitiveContains(query)
                || song.artistName.localizedCaseInsensitiveContains(query)
                || song.albumName.localizedCaseInsensitiveContains(query)
        }
    }

    /// Filters off the main thread — three localized substring checks per
    /// song ran on the main thread for every (debounced) keystroke. Sorting
    /// is SongsTab's job (by the shared sort setting), so it isn't done here.
    private func recomputeFilteredSongs() async {
        let query = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let songs = library.allSongs
        guard !query.isEmpty else {
            filteredSongsState = songs
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            Self.filter(songs, query: query)
        }.value
        guard !Task.isCancelled else { return }
        filteredSongsState = result
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom scrollable tab bar
                LibraryTabBar(selectedTab: $selectedTab)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Error banner.
                if let error = library.errorMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.warning)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(AppTheme.warning)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(AppTheme.surface.opacity(0.5))
                }

                // Tab content. A plain crossfade on the internal tab switch —
                // each `tabContent` case is a structurally distinct view, so
                // without this SwiftUI just hard-cuts between them.
                tabContent
                    .id(selectedTab)
                    .transition(.opacity)
                    .animation(LumiMotion.fade(0.18), value: selectedTab)
            }
            .background(GalleryBackgroundView().ignoresSafeArea())
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            // Lives on the NavigationStack root — not on SongsTab, which is
            // mounted/torn down on every internal tab switch and previously
            // owned this modifier, occasionally leaving the search
            // controller's presentation stuck and swallowing all touches
            // (the "Songs tab locks out every other tab" bug). Always
            // present regardless of which internal tab is selected —
            // `SearchFieldPlacement.NavigationBarDrawerDisplayMode` has no
            // `.never` case to hide it conditionally, so unlike the old
            // per-screen `.searchable` this is visible on every Library
            // sub-tab, not just Songs. A harmless UX difference (the field
            // just does nothing on Albums/Artists/etc., same as before it
            // had a value typed in) in exchange for eliminating the mount/
            // unmount churn that caused the lockup.
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search songs, artists, albums…"
            )
            .toolbar { toolbarItems }
            .task(id: "\(library.allSongs.count)|\(debouncedSearch)") {
                // Keep the O(n log n) Songs-tab query out of SwiftUI body
                // evaluation. Player progress and navigation state can
                // invalidate this root many times without changing the data.
                await recomputeFilteredSongs()
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    LibrarySelectionActionBar(
                        selectedCount: selectedSongIDs.count,
                        onAddToPlaylist: { playlistID in
                            library.addSongs(ids: selectedSongIDs, toPlaylistID: playlistID)
                            isSelecting = false
                            selectedSongIDs.removeAll()
                        },
                        onDelete: {
                            library.removeImportedSongs(ids: selectedSongIDs)
                            isSelecting = false
                            selectedSongIDs.removeAll()
                        },
                        onCancel: {
                            isSelecting = false
                            selectedSongIDs.removeAll()
                        }
                    )
                    .environmentObject(library)
                } else {
                    MiniPlayerBar()
                }
            }
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
            .onAppear {
                library.scanWatchedFolders(using: folderService)
                library.scanLocalDocuments()
                scheduleBackupSync()
            }
            // Debounce search: wait 0.3 s after the user stops typing
            .onChange(of: searchText) { newValue in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    if searchText == newValue {
                        debouncedSearch = newValue
                    }
                }
            }
            // Auto-Backup originally only fired on the "download from search" path,
            // so anything imported, scanned from Documents, or pulled from a watched
            // folder never made it to the cloud. Re-check whenever the library's
            // song count settles — scheduleBackupSync debounces so a multi-batch
            // scan triggers one sync, not dozens, and backUpLibraryIfNeeded itself
            // skips songs already present server-side.
            .onChange(of: library.allSongs.count) { _ in
                scheduleBackupSync()
            }
            .onChange(of: selectedTab) { _ in
                isSelecting = false
                selectedSongIDs.removeAll()
            }
            .onChange(of: songColumns) { _ in
                // Multi-select only applies to the single-column List layout —
                // drop out of it if the user switches to grid mid-selection.
                isSelecting = false
                selectedSongIDs.removeAll()
            }
        }
    }

    /// Debounces auto-backup catch-up so rapid library changes (a scan landing in
    /// several batches, an import finishing) collapse into a single sync pass.
    private func scheduleBackupSync() {
        guard autoCloudBackup, account.isLoggedIn, let token = account.token else { return }
        backupSyncTask?.cancel()
        let songs = library.allSongs
        backupSyncTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            streaming.backUpLibraryIfNeeded(songs: songs, token: token)
        }
    }

    // MARK: Tab content switcher

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .hub:
            LibraryHubView(selectedTab: $selectedTab)
        case .songs:
            SongsTab(
                songs: filteredSongsState,
                searchText: $searchText,
                showAddMusic: $showAddMusic,
                isSelecting: $isSelecting,
                selectedSongIDs: $selectedSongIDs
            )
        case .artists:
            ArtistsTab(searchText: debouncedSearch)
        case .albums:
            AlbumsTab(searchText: debouncedSearch)
        case .folders:
            FoldersTab()
        case .genres:
            GenresTab()
        case .playlists:
            PlaylistsView()
        case .favorites:
            // LibraryView already paints the gallery background behind the
            // whole screen — see `drawsOwnBackground`.
            FavoritesView(drawsOwnBackground: false, searchText: debouncedSearch)
        case .moods:
            MoodPlaylistsView()
                .environmentObject(moodService)
        case .podcasts:
            PodcastsView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if selectedTab == .songs && !filteredSongsState.isEmpty {
                LumiMenu {
                    ForEach(SongSortOrder.allCases, id: \.self) { option in
                        Button {
                            songSortRaw = option.rawValue
                        } label: {
                            Label(option.label, systemImage: option.icon)
                            if songSort == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .tint(AppTheme.dynamicAccent)

                // Multi-select is only wired up for the single-column List
                // layout (see SongsTab) — grid-cell taps still just play.
                if songColumns == 1 {
                    Button {
                        withAnimation(LumiMotion.fade(0.18)) {
                            isSelecting.toggle()
                            if !isSelecting { selectedSongIDs.removeAll() }
                        }
                    } label: {
                        Text(isSelecting ? "Done" : "Select")
                    }
                    .tint(AppTheme.dynamicAccent)
                }
            }

            Button {
                showOpenSharedPlaylist = true
            } label: {
                Image(systemName: "link.badge.plus")
            }
            .tint(AppTheme.dynamicAccent)

            if library.isScanning {
                ProgressView()
                    .tint(AppTheme.dynamicAccent)
            } else {
                Button {
                    Task {
                        // Thorough re-scan: picks up new, deleted, AND changed-in-place
                        // files (not just new ones), re-scans watched folders + Apple
                        // Music, then pulls the latest favorites/playlists/settings from
                        // the server — all without restarting the app.
                        await library.refreshAll(folderService: folderService)
                        if account.isLoggedIn {
                            await account.pullSync(library: library, player: player)
                        }
                        if let result = library.lastScanResult {
                            ToastCenter.shared.show(result, category: .success, icon: "arrow.clockwise")
                        }
                    }
                } label: {
                    if library.isScanning {
                        ProgressView().tint(AppTheme.dynamicAccent)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .tint(AppTheme.dynamicAccent)
                .disabled(library.isScanning)
            }

            Button {
                showAddMusic = true
            } label: {
                Image(systemName: "plus")
            }
            .tint(AppTheme.dynamicAccent)
        }
    }
}
