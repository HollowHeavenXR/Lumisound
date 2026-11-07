import SwiftUI
import UniformTypeIdentifiers

// MARK: - StreamSearchView

struct StreamSearchView: View {

    @EnvironmentObject var streaming: StreamingService
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var library: LibraryManager
    @EnvironmentObject var account: AccountService

    @State var searchText        = ""
    /// Cached by `refreshLibraryMatches()`.
    @State var matchingLocalSongs: [Song] = []
    @State var matchingDownloadHistory: [DownloadHistoryTrack] = []
    @State var selectedSource    = "youtube"
    @State var loadingTrackID:   String? = nil
    @State var downloadingTrackIDs: Set<String> = []
    @State var downloadedTrackIDs: Set<String> = []
    @State var failedTrackIDs: Set<String> = []

    // Server library download tracking (separate from streaming downloads)
    @State var downloadingServerTrackIDs: Set<String> = []
    @State var downloadedServerTrackIDs: Set<String> = []

    @AppStorage("autoCloudBackup") var autoCloudBackup: Bool = false
    /// Same key ContentView's TabView selection and MiniPlayerBar's
    /// "jump to Playing" already use — lets `notConfiguredView` (see
    /// StreamSearchView+NotConfigured.swift) switch straight to the
    /// Settings tab instead of pushing a second, separate SettingsView via
    /// NavigationLink, which would show a back button that the tab's own
    /// SettingsView instance (a NavigationStack root) never does.
    @AppStorage("selected_tab") var selectedTab = 0

    // My Library upload
    @State var showUploadPicker = false
    @State var deletingUserTrackPath: String? = nil
    @State var selectedInfoTrack: UserMusicTrack? = nil

    // Playlist batch download
    @State var isDownloadingAll   = false
    @State var downloadAllDone    = 0
    @State var downloadAllTotal   = 0

    // Animation: tracks results version so we can stagger the fade-in
    @State var resultsAnimationToken: UUID = UUID()

    // Streaming search results layout — 1 column is the original single-row
    // list; 2/3 switch to a compact artwork-forward grid (StreamTrackGridCell),
    // mirroring the same user-configurable column count already used for
    // Albums/Songs/Folders (see AlbumsTab's "library_albums_columns").
    @AppStorage("stream_search_columns") var searchResultColumns: Int = 1

    // Trending searches & autocomplete suggestions
    @State var trendingQueries: [SearchQueryCount] = []
    @State var suggestions: [SearchQueryCount] = []

    // Trending mechanics: which time window is active (in days — 1/7/30 map
    // to Today/This Week/This Month, all backed by the existing
    // `searchTrending(days:)` bridge parameter), whether a fetch is in
    // flight, and when the list was last refreshed so the UI can show a
    // "how stale is this" indicator instead of presenting counts that might
    // be minutes or hours old as if they were live.
    @State var trendingWindowDays: Int = 7
    @State var isLoadingTrending = false
    @State var trendingLastUpdated: Date? = nil

    // Namespace for the source-picker pill's sliding selection indicator.
    @Namespace var sourcePillNamespace

    let sources = ["youtube", "soundcloud", "server", "my"]

    /// Defaulted so the existing `StreamSearchView()` call site (the Cloud
    /// Services tab itself) is unaffected — only callers that want to deep
    /// link in with a query pre-filled (e.g. tapping a Home hub "Similar
    /// Listeners" suggestion) need to pass this.
    init(initialSearchText: String = "") {
        _searchText = State(initialValue: initialSearchText)
    }

    var body: some View {
        if InterfaceEdition.isLumen {
            lumenBody
        } else {
            classicBody
        }
    }

    private var classicBody: some View {
        NavigationStack {
            Group {
                if streaming.isConfigured {
                    configuredBody
                } else {
                    notConfiguredView
                }
            }
            .navigationTitle("Cloud Services")
            .navigationBarTitleDisplayMode(.large)
            .background(GalleryBackgroundView().ignoresSafeArea())
            // Consolidates the server-side features here (the "Cloud Services" hub)
            // so everything that talks to the bridge/account lives in one tab.
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    LumiMenu {
                        NavigationLink(destination: SubscriptionsView()) {
                            Label("Subscriptions & Tracked Playlists", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        NavigationLink(destination: DiscoverView()) {
                            Label("Discover", systemImage: "sparkles")
                        }
                        NavigationLink(destination: DiscoverMixView()) {
                            Label("Discover Mix", systemImage: "wand.and.stars")
                        }
                        if account.isLoggedIn {
                            NavigationLink(destination: SharedPlaylistsView()) {
                                Label("Shared With Me", systemImage: "person.2.fill")
                            }
                            NavigationLink(destination: PendingImportsView()) {
                                Label("Pending Imports", systemImage: "tray.and.arrow.down")
                            }
                        }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                }
            }
            // Every other tab (Library, Queue, etc.) shows MiniPlayerBar so tapping a
            // track gives instant visual confirmation that playback started. This tab
            // was missing it — tapping ▶ on a search result appeared to do nothing
            // because the only feedback (the mini player appearing/updating) happened
            // off-screen on a different tab, making "play" feel like a no-op.
            .safeAreaInset(edge: .bottom) {
                MiniPlayerBar()
            }
        }
    }

}
