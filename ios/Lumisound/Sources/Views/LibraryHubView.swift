import SwiftUI
import UIKit

// MARK: - Library Hub
//
// The Library tab's new landing screen — a dashboard ("hub") of shortcuts to
// the user's real playlists/folders/favorites, plus a few auto-generated
// groupings, sitting above the traditional Songs/Artists/Albums/Folders/...
// browsing tabs (still fully reachable via `LibraryTabBar` — see
// `LibraryTab.hub`, which sits alongside them rather than replacing them).
//
// Loosely inspired by a YouTube-Music-style home screen (a "speed dial" grid
// of shortcut tiles + horizontal carousels of curated content), but
// reinterpreted around Lumisound's own data model rather than cloned:
//   - Speed dial tiles = real `Playlist`s, `MusicFolderService` local
//     folders, and Favorites (if non-empty) — never placeholder content.
//   - Carousels = `SmartPlaylistStore`'s auto-generated mixes (the app's own
//     "auto-generated grouping" concept — Recently Added / Most Played /
//     Forgotten Favorites / Quick Listens, plus anything the user made
//     themselves), a Recently Added shelf, an On Repeat (most played) shelf,
//     a Forgotten Favorites shelf, and a Moods shelf if `MoodPlaylistService`
//     has classified anything yet.
//
// 2026-09 restructure: every shelf now belongs to a `HubZone` (Jump Back In,
// Made For You, Your Library, Rediscover, Stats & Social). The default order
// runs zone by zone under small zone headings, and a chip row under the quick
// actions narrows Home to a single zone.
struct LibraryHubView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var folderService: MusicFolderService
    @EnvironmentObject private var moodService: MoodPlaylistService
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var account: AccountService
    @ObservedObject private var smartPlaylistStore = SmartPlaylistStore.shared
    /// Shared app-wide instance (see `LumisoundApp`) — the dedicated
    /// Friends tab reads/mutates this same friends list, so this hub's
    /// Friends Activity card needs to reflect that shared state rather than
    /// a private copy that could show stale data right after visiting Friends.
    @EnvironmentObject private var social: SocialService

    /// Lets a carousel's "See All" chip (or a Moods tile) jump straight to
    /// the matching traditional browsing tab instead of the hub needing its
    /// own duplicate destination screen for content already browsable there.
    @Binding var selectedTab: LibraryTab

    @State private var shortcuts: [HubShortcut] = []
    @State private var recentlyAdded: [Song] = []
    @State private var mostPlayed: [Song] = []
    @State private var forgottenFavorites: [Song] = []
    @State private var recentlyPlayed: [Song] = []
    @State private var genreGroups: [(genre: String, songs: [Song])] = []
    @State private var hasLoadedOnce = false
    /// Snapshotted rather than computed in `body`: `songsPlayedTodayCount()`
    /// walks the whole library, and this view re-renders on every `player`
    /// publish. Refreshed by `reload()` and on each track change.
    @State private var songsPlayedToday = 0
    /// `nil` = "All". Not persisted: coming back to a Home narrowed to one
    /// zone without remembering why is more confusing than helpful.
    @State private var selectedZone: HubZone? = nil
    /// Hour the default order was picked for (see
    /// `HomeHubLayoutStore.defaultOrder(forHour:)`). Re-read on appear rather
    /// than in `body`, so sections never reshuffle mid-scroll when the clock
    /// crosses a boundary.
    @State private var layoutHour = Calendar.current.component(.hour, from: Date())
    /// `allSongs.count` as of the last completed `reload()` — see that
    /// `.task(id:)`'s guard for why this exists.
    @State private var lastReloadedSongCount: Int? = nil

    // 2026-07-20 Home Tab expansion — on-device-only additions, computed by
    // `reload()` alongside everything above. See `LibraryManager+HubContent.swift`.
    @State private var topArtistGroups: [(artist: String, songs: [Song], playCount: Int)] = []
    @State private var decadeGroups: [(decade: String, songs: [Song])] = []
    @State private var deeperCutsSongs: [Song] = []
    @State private var weeklyRecap: LibraryManager.HubWeeklyRecap? = nil

    // Server-backed extras — independent of the on-device reload() above,
    // since these come from the network rather than LibraryManager.
    @State private var weeklyMixSongs: [Song] = []
    @State private var similarListenerSearchQuery: String? = nil
    @State private var onThisDayGroups: [OnThisDayGroup] = []
    @State private var continueListeningPodcasts: [ContinueListeningPodcastItem] = []

    // MARK: Home hub customization — see `HomeHubCustomizationView`.
    //
    // Plain per-device `@AppStorage` (JSON-encoded arrays for the two list
    // preferences), not server-synced — matches `ContentView`'s
    // `tab_transition_style` convention for this kind of UI-only setting.
    @AppStorage(HomeHubLayoutStore.orderKey) private var sectionOrderRaw: String = ""
    @AppStorage(HomeHubLayoutStore.hiddenKey) private var hiddenSectionsRaw: String = ""
    @AppStorage("home_hub_custom_greeting") private var customGreeting: String = ""
    @AppStorage("home_hub_accent_hex") private var hubAccentHex: String?
    @State private var showCustomizationSheet = false
    @State private var showHumToSearch = false
    @State private var showNameThatTune = false

    /// This screen's own accent override (see `HomeHubCustomizationView`),
    /// resolved back to a `Color` via the same curated palette the profile
    /// accent picker uses — entirely separate storage from the profile's own
    /// `mainAccentHex`/`subAccentHex`. Falls back to the app-wide
    /// `AppTheme.dynamicAccent` when unset, so every section header/icon
    /// this feeds looks identical to before until a user actually opts in.
    private var resolvedAccent: Color {
        SocialAccentPalette.color(for: hubAccentHex) ?? AppTheme.dynamicAccent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if !hasLoadedOnce {
                    HubSkeleton()
                        .transition(.opacity)
                } else if library.allSongs.isEmpty {
                    VStack(spacing: 24) {
                        HubEmptyState()
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        // Listening history can outlive the local library,
                        // so still offer server-backed stations to a signed-in
                        // user who has not imported music on this device yet.
                        StationSuggestionsSection(accent: resolvedAccent)
                    }
                } else {
                    hubContent
                        .transition(.opacity)
                }
            }
            .padding(.top, 12)
            // Extra clearance below the last row — see SongsTab's identical
            // fix (clears MiniPlayerBar + tab bar).
            .padding(.bottom, 190)
            .animation(.easeInOut(duration: 0.35), value: hasLoadedOnce)
            .animation(.easeInOut(duration: 0.25), value: player.isPlaying)
        }
        .background(Color.clear.ignoresSafeArea())
        .task(id: library.allSongs.count) {
            // Debounced: `.task(id:)` already cancels the in-flight instance
            // of this exact task whenever `allSongs.count` changes again, so
            // sleeping briefly before doing any real work means a BURST of
            // individually-landing changes (several downloads finishing
            // within a couple seconds of each other, or a multi-step
            // rescan) collapses into exactly one `reload()` once things
            // settle, instead of restarting reload()'s whole ~8-scan derive
            // pipeline from scratch on every single increment. Confirmed via
            // a screen recording's frame-diff timeline: six separate
            // multi-second freeze windows inside 20 seconds, landing right
            // around a "2 downloads finished in the background" toast — the
            // pipeline was being cancelled and restarted faster than it
            // could ever finish, keeping the main actor busy the whole time.
            //
            // That debounce didn't cover a SEPARATE trigger for this same
            // task, though: `.task(id:)` restarts whenever this view
            // disappears and reappears — e.g. switching to the Now Playing/
            // Queue tab and back, or pushing a folder and popping back —
            // even when `allSongs.count` (the id) hasn't actually changed.
            // Every such reappearance re-ran the full ~9-pass reload()
            // pipeline from scratch for no reason, which is exactly what
            // produced "return to Library and it pauses for 5+ seconds":
            // nothing about the library had changed, there was just nothing
            // here stopping a no-op reappearance from paying the same cost
            // as a real data change. `lastReloadedSongCount` makes a
            // reappearance with an unchanged count a same-frame no-op;
            // an actual count change (download completed, import finished,
            // song evicted) still reloads exactly like before.
            guard lastReloadedSongCount != library.allSongs.count else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await reload()
            lastReloadedSongCount = library.allSongs.count
        }
        .task {
            await loadServerExtras()
        }
        .onAppear {
            layoutHour = Calendar.current.component(.hour, from: Date())
        }
        .onChange(of: player.currentSong?.id) { _ in
            songsPlayedToday = library.songsPlayedTodayCount()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCustomizationSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .tint(resolvedAccent)
                .accessibilityLabel("Customize Home")
            }
        }
        .sheet(isPresented: $showCustomizationSheet) {
            HomeHubCustomizationView()
        }
        .sheet(isPresented: $showHumToSearch) {
            HumToSearchView()
        }
        .sheet(isPresented: $showNameThatTune) {
            NameThatTuneView()
                .environmentObject(streaming)
        }
        .sheet(item: Binding(
            get: { similarListenerSearchQuery.map { IdentifiableQuery(text: $0) } },
            set: { similarListenerSearchQuery = $0?.text }
        )) { query in
            StreamSearchView(initialSearchText: query.text)
        }
    }

    private struct IdentifiableQuery: Identifiable { let text: String; var id: String { text } }

    @ViewBuilder
    private var hubContent: some View {
        // Pinned identity/action anchors — always first, never reorderable
        // or hideable (see `HubSectionKind`'s doc comment).
        HubGreetingHeader(
            displayName: account.currentUser?.displayName ?? account.currentUser?.username,
            songsPlayedToday: songsPlayedToday,
            customGreeting: customGreeting,
            accent: resolvedAccent
        )

        HubQuickActionsRow(
            hasLibrary: !library.allSongs.isEmpty,
            onShuffleAll: shuffleAll,
            onSurpriseMe: surpriseMe,
            onHumToSearch: { showHumToSearch = true },
            onNameThatTune: { showNameThatTune = true }
        )

        // Pinned, not a section: it only exists while something is paused,
        // and when it does it is the likeliest thing to tap.
        if let paused = player.currentSong, !player.isPlaying {
            HubResumeCard(song: paused, accent: resolvedAccent)
                .transition(.move(edge: .top).combined(with: .opacity))
        }

        let sections = visibleSections
        let zones = zonesPresent(in: sections)
        let activeZone = selectedZone.flatMap { zones.contains($0) ? $0 : nil }
        let displayed = activeZone.map { zone in sections.filter { $0.zone == zone } } ?? sections
        // Headings only make sense while each zone is one unbroken run; a
        // custom order that interleaves zones would repeat them.
        let showsZoneHeadings = activeZone == nil && zones.count > 1 && isZoneContiguous(sections)

        if zones.count > 1 {
            HubZoneFilterBar(zones: zones, selection: $selectedZone, activeZone: activeZone, accent: resolvedAccent)
        }

        // Everything below is data-driven: the persisted order (see
        // `HomeHubLayoutStore`) filtered to sections that are both not
        // user-hidden AND actually have content — each section's own
        // "only show if non-empty" guard lives in `sectionHasContent`
        // rather than inline `if`s here, since the sequence itself is no
        // longer hardcoded.
        ForEach(Array(displayed.enumerated()), id: \.element) { index, kind in
            VStack(alignment: .leading, spacing: 14) {
                if showsZoneHeadings, index == 0 || displayed[index - 1].zone != kind.zone {
                    HubZoneHeading(zone: kind.zone)
                }
                sectionContent(for: kind)
            }
        }
    }

    /// The user's chosen order (falling back to `HubSectionKind.defaultOrder`
    /// on first run), filtered down to sections that are both visible and
    /// non-empty.
    private var visibleSections: [HubSectionKind] {
        let order = HomeHubLayoutStore.resolvedOrder(sectionOrderRaw, hour: layoutHour)
        let hidden = hiddenSections
        return order.filter { !hidden.contains($0) && sectionHasContent($0) }
    }

    private var hiddenSections: Set<HubSectionKind> {
        HomeHubLayoutStore.decodeHidden(hiddenSectionsRaw)
    }

    /// Zones with at least one section on screen, in `HubZone.allCases` order
    /// so the chips stay put however the sections themselves are ordered.
    private func zonesPresent(in sections: [HubSectionKind]) -> [HubZone] {
        let present = Set(sections.map(\.zone))
        return HubZone.allCases.filter { present.contains($0) }
    }

    private func isZoneContiguous(_ sections: [HubSectionKind]) -> Bool {
        var finished = Set<HubZone>()
        var current: HubZone? = nil
        for kind in sections where kind.zone != current {
            if let current { finished.insert(current) }
            if finished.contains(kind.zone) { return false }
            current = kind.zone
        }
        return true
    }

    // MARK: Jump Back In / Recently Played split

    private static let jumpBackInLimit = 6

    private var jumpBackInSongs: [Song] {
        Array(recentlyPlayed.prefix(Self.jumpBackInLimit))
    }

    /// While Jump Back In is on, the Recently Played carousel continues where
    /// the grid stops instead of repeating its first six tracks.
    private var recentlyPlayedCarouselSongs: [Song] {
        hiddenSections.contains(.jumpBackIn) ? recentlyPlayed : Array(recentlyPlayed.dropFirst(Self.jumpBackInLimit))
    }

    /// Mirrors each section's original inline `if !x.isEmpty` guard from
    /// before this feature existed — a hidden-but-empty section and a
    /// visible-but-empty section both render nothing, exactly as today.
    private func sectionHasContent(_ kind: HubSectionKind) -> Bool {
        switch kind {
        case .onThisDay:          return !onThisDayGroups.isEmpty
        case .speedDial:          return !shortcuts.isEmpty
        case .weeklyMix:          return !weeklyMixSongs.isEmpty
        case .mixes:              return !smartPlaylistStore.playlists.isEmpty
        case .recentlyAdded:      return !recentlyAdded.isEmpty
        case .onRepeat:           return !mostPlayed.isEmpty
        case .recentlyPlayed:     return !recentlyPlayedCarouselSongs.isEmpty
        case .jumpBackIn:         return !recentlyPlayed.isEmpty
        // `StationSuggestionsSection` loads its own data and collapses to
        // nothing when there are no suggestions, so only gate on sign-in.
        case .stations:           return account.isLoggedIn
        case .genres:             return !genreGroups.isEmpty
        case .forgottenFavorites: return !forgottenFavorites.isEmpty
        case .moods:              return !moodBucketsWithSongs.isEmpty
        case .friendsActivity:    return !social.friendsActivity.isEmpty
        case .similarListeners:   return !account.similarListenerTracks.isEmpty
        case .achievements:       return (account.achievements?.totalPlays ?? 0) > 0
        case .weeklyRecap:        return weeklyRecap != nil
        case .topArtists:         return !topArtistGroups.isEmpty
        case .decades:            return !decadeGroups.isEmpty
        case .deeperCuts:         return !deeperCutsSongs.isEmpty
        case .continueListeningPodcasts: return !continueListeningPodcasts.isEmpty
        case .ariaDailyPick:      return account.ariaDailyPick?.track != nil
        }
    }

    @ViewBuilder
    private func sectionContent(for kind: HubSectionKind) -> some View {
        switch kind {
        case .onThisDay:
            HubOnThisDayTeaser(groups: onThisDayGroups, accent: resolvedAccent)

        case .speedDial:
            HubSpeedDialSection(shortcuts: shortcuts, accent: resolvedAccent)
                .transition(.move(edge: .top).combined(with: .opacity))

        case .weeklyMix:
            HubSongCarousel(
                title: "Weekly Mix", icon: "sparkles.tv",
                songs: weeklyMixSongs, seeAllTab: nil, selectedTab: $selectedTab, accent: resolvedAccent
            )

        case .mixes:
            mixesCarousel

        case .recentlyAdded:
            HubSongCarousel(
                title: "Recently Added", icon: "clock.badge.checkmark",
                songs: recentlyAdded, seeAllTab: .songs, selectedTab: $selectedTab, accent: resolvedAccent
            )

        case .onRepeat:
            HubSongCarousel(
                title: "On Repeat", icon: "flame.fill",
                songs: mostPlayed, seeAllTab: .songs, selectedTab: $selectedTab, accent: resolvedAccent
            )

        case .recentlyPlayed:
            HubSongCarousel(
                title: "Recently Played", icon: "clock.arrow.circlepath",
                songs: recentlyPlayedCarouselSongs, seeAllTab: .songs, selectedTab: $selectedTab, accent: resolvedAccent
            )

        case .jumpBackIn:
            HubJumpBackInGrid(songs: jumpBackInSongs, queue: recentlyPlayed, accent: resolvedAccent)

        case .stations:
            // Contextual stations use the same server-side signal fusion as
            // Auto-Radio, but without a current-track seed on Home.
            StationSuggestionsSection(accent: resolvedAccent)

        case .genres:
            HubGenresCarousel(groups: genreGroups, accent: resolvedAccent)

        case .forgottenFavorites:
            HubSongCarousel(
                title: "Forgotten Favorites", icon: "heart.slash",
                songs: forgottenFavorites, seeAllTab: .favorites, selectedTab: $selectedTab, accent: resolvedAccent
            )

        case .moods:
            moodsCarousel

        case .friendsActivity:
            HubFriendsActivityCarousel(entries: social.friendsActivity, accent: resolvedAccent)

        case .similarListeners:
            HubSimilarListenersCarousel(
                tracks: account.similarListenerTracks,
                listenerCount: account.similarListenerCount,
                accent: resolvedAccent,
                onSelect: { track in
                    similarListenerSearchQuery = [track.title, track.artist].compactMap { $0 }.joined(separator: " ")
                }
            )

        case .achievements:
            if let data = account.achievements {
                HubAchievementsTeaser(data: data, accent: resolvedAccent)
            }

        case .weeklyRecap:
            if let weeklyRecap {
                HubWeeklyRecapCard(recap: weeklyRecap, accent: resolvedAccent)
            }

        case .topArtists:
            HubTopArtistsCarousel(groups: topArtistGroups, accent: resolvedAccent)

        case .decades:
            HubDecadesCarousel(groups: decadeGroups, accent: resolvedAccent)

        case .deeperCuts:
            HubSongCarousel(
                title: "Deeper Cuts", icon: "waveform.badge.magnifyingglass",
                songs: deeperCutsSongs, seeAllTab: nil, selectedTab: $selectedTab, accent: resolvedAccent
            )

        case .continueListeningPodcasts:
            if let top = continueListeningPodcasts.first {
                HubContinueListeningPodcastsTeaser(item: top, accent: resolvedAccent)
            }

        case .ariaDailyPick:
            if let pick = account.ariaDailyPick, let track = pick.track {
                HubAriaDailyPickCard(track: track, reason: pick.reason, accent: resolvedAccent)
            }
        }
    }

    /// Plays a random song from the whole on-device library with shuffle
    /// enabled — `setQueue` (called by `play(song:in:)`) shuffles the queue
    /// itself whenever `shuffleEnabled` is already true by the time it runs,
    /// so setting it first is all this needs.
    private func shuffleAll() {
        guard let random = library.allSongs.randomElement() else { return }
        player.shuffleEnabled = true
        player.play(song: random, in: library.allSongs)
    }

    /// "Surprise Me" — unlike Shuffle All (a flat random pick across the
    /// WHOLE library), this is a weighted pick from the hub's own curated
    /// pools it already computed for the carousels below: forgotten
    /// favorites, on-repeat tracks, and recently played all get a share, so
    /// one tap surfaces something the hub's own personalization already
    /// decided is worth surfacing, rather than a genuinely uniform random
    /// song. Falls back to Shuffle All's plain random pick if the reload()
    /// pipeline hasn't populated those pools yet (e.g. first launch).
    private func surpriseMe() {
        var weighted: [Song] = []
        // Forgotten favorites get the heaviest weight — the whole point of
        // "surprise me" is resurfacing something the user liked but hasn't
        // heard in a while, not just repeating whatever's already on repeat.
        weighted.append(contentsOf: forgottenFavorites)
        weighted.append(contentsOf: forgottenFavorites)
        weighted.append(contentsOf: recentlyPlayed)
        weighted.append(contentsOf: mostPlayed)

        guard let pick = weighted.randomElement() ?? library.allSongs.randomElement() else { return }
        player.shuffleEnabled = false
        player.play(song: pick, in: library.allSongs)
        ToastCenter.shared.show("Surprise: \"\(pick.displayName)\"", category: .info, icon: "sparkles")
    }

    /// Fetches the network-backed hub extras once — independent of
    /// `reload()`'s on-device `library.allSongs.count` trigger, since these
    /// don't change just because the local library was rescanned.
    ///
    /// `@MainActor` is required, not cosmetic: `account`/`streaming`/`social`
    /// are all `@MainActor`-isolated services, so once e.g. `await
    /// streaming.fetchWeeklyMix(token:)` returns, a NONISOLATED caller
    /// resumes on an arbitrary background executor, not necessarily back on
    /// the main thread. The very next line here assigns straight into
    /// `@State` (`weeklyMixSongs`/`onThisDayGroups`/`continueListeningPodcasts`)
    /// — mutating SwiftUI `@State` off the main actor is a real crash, not
    /// just a warning, and matches a crash signature (SIGTRAP/SIGABRT inside
    /// this function's async continuation) confirmed recurring across
    /// several builds in production MetricKit telemetry (`crash_diagnostic`
    /// events, symbolicated via the release dSYMs). Pinning this function to
    /// `@MainActor` keeps every one of its own `async let` bodies — and the
    /// code that runs right after each inner `await` — on the main actor,
    /// while the awaited calls themselves still do their real work wherever
    /// they need to.
    @MainActor
    private func loadServerExtras() async {
        // Each step is a named @MainActor function rather than an inline
        // `async let x: Void = { ... }()` closure — an inline closure here
        // ambiguously inherits this function's @MainActor isolation in a way
        // the compiler can't reconcile with `async let`'s child-task model
        // ("expression is 'async' but is not marked with 'await'"); a named
        // async method called directly (same shape as `account.
        // fetchSimilarListeners()` below, which never had this problem) does
        // not have that ambiguity.
        async let weeklyMix: Void = loadWeeklyMix()
        async let similarListeners: Void = account.fetchSimilarListeners()
        async let ariaDailyPick: Void = account.fetchAriaDailyPick()
        async let friendsActivity: Void = social.fetchFriendsActivity()
        async let onThisDay: Void = loadOnThisDay()
        // Reuses the existing GET /user/achievements endpoint (already
        // powering the standalone `AchievementsView` reachable from
        // Settings) rather than adding new server support — the Home tab
        // just needed a compact teaser for data that already existed.
        async let achievements: Void = loadAchievements()
        // Cross-feed (no feed_url filter -- see main.py's doc comment on
        // get_podcast_episode_progress), paired with subscriptions for
        // display (show title/artwork) and playback (PodcastPlayback.play
        // needs the PodcastSubscription, not just the progress row).
        async let continueListeningPodcastsTask: Void = loadContinueListeningPodcasts()
        _ = await (weeklyMix, similarListeners, ariaDailyPick, friendsActivity, onThisDay, achievements, continueListeningPodcastsTask)
    }

    @MainActor
    private func loadWeeklyMix() async {
        guard let token = account.token else { return }
        await streaming.fetchWeeklyMix(token: token)
        weeklyMixSongs = streaming.weeklyMix.map { streaming.toSong(weeklyMixTrack: $0, token: token) }
    }

    @MainActor
    private func loadOnThisDay() async {
        guard account.isLoggedIn else { return }
        onThisDayGroups = await account.fetchOnThisDay()
    }

    @MainActor
    private func loadAchievements() async {
        guard account.isLoggedIn else { return }
        await account.fetchAchievements()
    }

    @MainActor
    private func loadContinueListeningPodcasts() async {
        guard account.isLoggedIn else { return }
        async let subsResult = account.fetchPodcastSubscriptions()
        async let progressResult = account.fetchRecentPodcastProgress(limit: 10)
        let subs = await subsResult
        let progressEntries = await progressResult
        let subsByFeed = Dictionary(subs.map { ($0.feedURL, $0) }, uniquingKeysWith: { first, _ in first })
        continueListeningPodcasts = progressEntries.compactMap { progress -> ContinueListeningPodcastItem? in
            guard let feedURL = progress.feedURL, let sub = subsByFeed[feedURL] else { return nil }
            return ContinueListeningPodcastItem(subscription: sub, progress: progress)
        }
    }

    // MARK: Mixes carousel

    private var mixesCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "Mixes For You", icon: "wand.and.stars", accent: resolvedAccent)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(smartPlaylistStore.playlists) { mix in
                        HubParallaxCard {
                            NavigationLink {
                                SmartPlaylistDetailView(playlistID: mix.id)
                            } label: {
                                HubMixCard(mix: mix)
                                    .environmentObject(library)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        .frame(width: 168, height: 168)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Moods carousel
    //
    // `MoodPlaylistService` doesn't expose a standalone per-bucket detail
    // view (it's owned by another workstream), so a mood tile jumps to the
    // existing `.moods` browsing tab rather than inventing a new push
    // destination into a screen this workstream doesn't own.

    private var moodBucketsWithSongs: [(bucket: MoodBucket, songs: [Song])] {
        [
            (MoodBucket.energetic, moodService.energeticSongs),
            (MoodBucket.chill, moodService.chillSongs),
            (MoodBucket.focus, moodService.focusSongs),
            (MoodBucket.sleep, moodService.sleepSongs),
        ].filter { !$0.1.isEmpty }
    }

    private var moodsCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "Moods", icon: "theatermasks.fill", seeAllTab: .moods, selectedTab: $selectedTab, accent: resolvedAccent)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(moodBucketsWithSongs.enumerated()), id: \.offset) { _, entry in
                        HubParallaxCard {
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    selectedTab = .moods
                                }
                            } label: {
                                HubMoodCard(bucket: entry.bucket, count: entry.songs.count, representative: entry.songs.first)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        .frame(width: 140, height: 140)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Data loading
    //
    // Snapshots everything into local `@State` off the render path (rather
    // than recomputing in `body` on every unrelated re-render — e.g. a
    // `player` publish from a track change), mirroring `FoldersTab`'s
    // `.task(id:)` pattern. Re-runs whenever `allSongs.count` changes.
    //
    // `async` with `Task.yield()` between each shelf, not a plain synchronous
    // function — several of these (see LibraryManager+HubContent.swift's own
    // header comment) are O(n log n) sorts over the whole library, and this
    // is all MainActor-isolated work (LibraryManager, PlayHistoryStore, etc.
    // are all @MainActor, so there's no way to genuinely move the CPU work
    // off the main thread here without a much larger, riskier refactor).
    // Run back-to-back as one synchronous block, up to 9 full-library passes
    // for a large library was a single uninterrupted stall long enough to
    // read as a "lag spike" — a real one, and specifically a HOME-screen one,
    // exactly matching that report. Yielding between shelves doesn't reduce
    // the total CPU time spent, but it lets the run loop interleave a frame
    // draw / touch event between each pass instead of blocking through all
    // of them at once, turning one long stall into several much smaller ones.
    //
    // Update: the shelves no longer need the main actor. `HubContentBuilder`
    // works on a copy of the songs and play history, so all of them are now
    // built in one detached task — the main thread only takes the snapshot
    // and assigns the results. Shortcuts split into two tiers: favorites/
    // playlists are a genuinely cheap O(1)/O(playlist count) pass and still
    // build here, but the folder shortcuts (`buildFolderShortcuts` below) do
    // an O(n) pass over the WHOLE library via `MusicFolderService
    // .localFolderGroups` — the exact same main-thread stall `FoldersTab` was
    // rewritten to avoid (that fix's own comment: "easily large enough to be
    // a visible main-thread stall... what made the Folders grid freeze and
    // lose scroll position"). This runs on every Home/Hub load, which is the
    // default tab, so it fired on most tab switches — moved into the same
    // detached task as the shelf snapshot below.
    //
    // `@MainActor` is load-bearing here, not cosmetic: `await Task.detached
    // { ... }.value` resumes on a background executor, not necessarily the
    // main thread, and the very next lines assign straight into `@State`
    // (`shortcuts`/`recentlyAdded`/`mostPlayed`/etc.) — mutating SwiftUI
    // `@State` off the main actor is a real crash. `async` functions do NOT
    // inherit a type's MainActor isolation the way synchronous members do,
    // so this needs the annotation explicitly rather than relying on
    // `LibraryHubView` being a `View`. Same bug class, same fix, as
    // `loadServerExtras()` above — confirmed as a recurring production
    // crash (SIGTRAP/SIGABRT) via MetricKit `crash_diagnostic` telemetry.
    @MainActor
    private func reload() async {
        shortcuts = Self.buildShortcuts(library: library)
        await Task.yield()
        let builder = library.hubContent
        let favorites = library.favoriteSongs
        let allSongs = library.allSongs
        let (folderShortcuts, snapshot) = await Task.detached(priority: .userInitiated) {
            (Self.buildFolderShortcuts(allSongs: allSongs), builder.snapshot(favorites: favorites))
        }.value
        guard !Task.isCancelled else { return }
        shortcuts += folderShortcuts
        recentlyAdded = snapshot.recentlyAdded
        mostPlayed = snapshot.mostPlayed
        forgottenFavorites = snapshot.forgottenFavorites
        recentlyPlayed = snapshot.recentlyPlayed
        genreGroups = snapshot.genreGroups
        topArtistGroups = snapshot.topArtistGroups
        decadeGroups = snapshot.decadeGroups
        deeperCutsSongs = snapshot.deeperCuts
        weeklyRecap = snapshot.weeklyRecap
        songsPlayedToday = library.songsPlayedTodayCount()
        if !hasLoadedOnce {
            withAnimation(.easeInOut(duration: 0.35)) { hasLoadedOnce = true }
        }
    }

    private static func buildShortcuts(library: LibraryManager) -> [HubShortcut] {
        var result: [HubShortcut] = []

        // One full-library pass, not two.
        let favorites = library.favoriteSongs
        if !favorites.isEmpty {
            result.append(HubShortcut(
                id: "favorites", kind: .favorites, title: "Favorites",
                songs: favorites, icon: "heart.fill"
            ))
        }

        // Most recently created first — matches "what did I just make" intuition,
        // and keeps a fresh playlist visible on the first speed-dial page even
        // once a user has accumulated many.
        for playlist in library.playlists.sorted(by: { $0.createdAt > $1.createdAt }) {
            result.append(HubShortcut(
                id: "playlist-\(playlist.id.uuidString)", kind: .playlist(playlist), title: playlist.name,
                songs: library.songs(for: playlist), icon: "music.note.list"
            ))
        }

        return result
    }

    /// The O(n) half of shortcut building — see the doc comment on `reload()`
    /// for why this is split out and run off the main actor.
    private static func buildFolderShortcuts(allSongs: [Song]) -> [HubShortcut] {
        MusicFolderService.localFolderGroups(from: allSongs).map { folder in
            HubShortcut(
                id: "folder-\(folder.id)", kind: .folder(folder), title: folder.id,
                songs: folder.songs, icon: "folder.fill"
            )
        }
    }
}

// MARK: - HubShortcut

/// One speed-dial tile's worth of data — always backed by something real in
/// the user's own library, never placeholder/sample content.
struct HubShortcut: Identifiable {
    enum Kind {
        case favorites
        case playlist(Playlist)
        case folder(MusicFolderService.LocalFolderGroup)
    }
    let id: String
    let kind: Kind
    let title: String
    let songs: [Song]
    let icon: String
}

// MARK: - Speed Dial Section

/// A swipeable, paged 2×2 grid of shortcut tiles with page dots below —
/// reinterprets the reference design's "speed dial" as a compact way to
/// surface every playlist/folder/favorites shortcut without an unbounded
/// scroll, since (unlike the carousels below) tiles here are meant to feel
/// like a fixed "home screen" rather than an endless shelf.
private struct HubSpeedDialSection: View {
    let shortcuts: [HubShortcut]
    var accent: Color = AppTheme.dynamicAccent
    @State private var page = 0

    private let perPage = 4
    private let spacing: CGFloat = 12
    private let horizontalPadding: CGFloat = 16

    private var pages: [[HubShortcut]] {
        stride(from: 0, to: shortcuts.count, by: perPage).map {
            Array(shortcuts[$0..<min($0 + perPage, shortcuts.count)])
        }
    }

    /// Deliberately not measured via `GeometryReader` around the whole
    /// section — a paged `TabView` needs an explicit height up front (it
    /// doesn't self-size like a `VStack` would), and `UIScreen.main.bounds`
    /// gives a perfectly good estimate for a phone-only layout like the
    /// rest of this screen already assumes (see `AlbumHeaderView`'s fixed
    /// 256pt artwork for the same reasoning).
    private var tileWidth: CGFloat {
        (UIScreen.main.bounds.width - horizontalPadding * 2 - spacing) / 2
    }

    private var tileHeight: CGFloat { tileWidth + 46 }
    private var pageHeight: CGFloat { tileHeight * 2 + spacing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "Quick Access", icon: "square.grid.2x2.fill", accent: accent)
                .padding(.horizontal, horizontalPadding)

            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, pageShortcuts in
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)],
                        spacing: spacing
                    ) {
                        ForEach(pageShortcuts) { shortcut in
                            HubSpeedDialTile(shortcut: shortcut, tileWidth: tileWidth)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: pageHeight)

            if pages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? accent : AppTheme.textSecondary.opacity(0.3))
                            .frame(width: i == page ? 16 : 6, height: 6)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: page)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct HubSpeedDialTile: View {
    let shortcut: HubShortcut
    let tileWidth: CGFloat

    @EnvironmentObject private var library: LibraryManager

    // Snapshotted once (see `.task(id:)` below) rather than recomputed every
    // body evaluation: both `listenedFraction` and `collageSongs` scan the
    // shortcut's full song list (and, for the former, do a PlayHistoryStore
    // lookup per song), and this tile previously also held an unused
    // `@EnvironmentObject var player: AudioPlayerManager` — since SwiftUI
    // invalidates every view holding a reference to an ObservableObject on
    // ANY of its `@Published` changes (not just ones the view actually
    // reads), that meant every visible speed-dial tile redid both scans on
    // every play/pause/track-change/queue-mutation even though this view
    // never used `player` for anything. Dropping the dependency and caching
    // the results fixes both the unnecessary re-renders and the repeated
    // O(n) work.
    @State private var listenedFraction: Double? = nil
    @State private var collage: [Song] = []
    // Custom, device-local folder cover art (see FolderCoverArtService) —
    // only meaningful for `.folder` shortcuts. LocalFolderDetailView and
    // FoldersTab's grid both show whatever custom cover is set for a
    // folder; this speed-dial tile never checked for one at all, so a
    // folder with a custom cover showed the generic song-collage instead
    // here specifically, inconsistent with every other place the same
    // folder's artwork appears.
    @State private var customFolderCover: UIImage? = nil
    // Observed so a cover change made from LocalFolderDetailView while this
    // tile was already mounted still reaches it — see
    // `FolderCoverArtService.changeCount`'s doc comment. `.task(id: songsKey)`
    // above only refires on a song-list change, not a cover change.
    @ObservedObject private var coverService = FolderCoverArtService.shared

    var body: some View {
        NavigationLink {
            destination
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let customFolderCover {
                        Image(uiImage: customFolderCover)
                            .resizable()
                            .scaledToFill()
                            .frame(width: tileWidth, height: tileWidth)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        HubArtworkCollage(
                            songs: collage,
                            size: tileWidth,
                            placeholderIcon: shortcut.icon
                        )
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(shortcut.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    // A thin "how much of this have you listened to" bar when
                    // it's meaningful (more than one song); otherwise just a
                    // plain track count — see `LibraryManager.listenedFraction`.
                    if let fraction = listenedFraction, shortcut.songs.count > 1 {
                        ProgressView(value: fraction)
                            .tint(AppTheme.dynamicAccent)
                            .frame(height: 3)
                    } else {
                        Text("\(shortcut.songs.count) \(shortcut.songs.count == 1 ? "song" : "songs")")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .frame(width: tileWidth, alignment: .leading)
        }
        .buttonStyle(PressableButtonStyle())
        // Keyed on the tile's songs, not just `shortcut.id`: the id of a
        // playlist tile never changes, so a tile first built while its songs
        // hadn't resolved yet (or before songs were added to the playlist)
        // kept an empty collage and a placeholder icon even after the hub
        // rebuilt it with the real songs.
        .task(id: songsKey) {
            listenedFraction = library.listenedFraction(of: shortcut.songs)
            collage = library.collageSongs(from: shortcut.songs)
            if case .folder(let folder) = shortcut.kind {
                customFolderCover = await FolderCoverArtService.shared.cover(for: folder.dirURL)
            } else {
                customFolderCover = nil
            }
        }
        .onChange(of: coverService.changeCount) { _ in
            guard case .folder(let folder) = shortcut.kind else { return }
            Task { customFolderCover = await FolderCoverArtService.shared.cover(for: folder.dirURL) }
        }
    }

    private var songsKey: String {
        "\(shortcut.id)|\(shortcut.songs.count)|\(shortcut.songs.first?.id ?? "")|\(shortcut.songs.last?.id ?? "")"
    }

    @ViewBuilder
    private var destination: some View {
        switch shortcut.kind {
        case .favorites:
            FavoritesView()
        case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist)
        case .folder(let folder):
            LocalFolderDetailView(folderName: folder.id, folderURL: folder.dirURL)
        }
    }
}

// MARK: - Artwork Collage

/// A single big thumbnail for 0-1 songs, or a 2×2 mosaic of up to 4 for a
/// richer "this is a real collection" look — always built from the
/// shortcut's actual songs (see `LibraryManager.collageSongs(from:)`), never
/// a placeholder image.
private struct HubArtworkCollage: View {
    let songs: [Song]
    let size: CGFloat
    let placeholderIcon: String

    var body: some View {
        Group {
            if songs.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.surface)
                    .overlay {
                        Image(systemName: placeholderIcon)
                            .font(.system(size: size * 0.28))
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
            } else if songs.count == 1 {
                ArtworkThumbnail(song: songs[0], size: size)
            } else {
                let half = (size / 2).rounded(.down)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkThumbnail(song: songs[0], size: half)
                        quadrant(index: 1, size: half)
                    }
                    HStack(spacing: 0) {
                        quadrant(index: 2, size: half)
                        quadrant(index: 3, size: half)
                    }
                }
                .frame(width: half * 2, height: half * 2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func quadrant(index: Int, size: CGFloat) -> some View {
        if songs.indices.contains(index) {
            ArtworkThumbnail(song: songs[index], size: size)
        } else {
            Rectangle().fill(AppTheme.surface).frame(width: size, height: size)
        }
    }
}

// MARK: - Section header (with optional "See All" chip)

private struct HubSectionHeader: View {
    let title: String
    let icon: String
    var seeAllTab: LibraryTab? = nil
    var selectedTab: Binding<LibraryTab>? = nil
    /// This screen's resolved accent (custom Home accent if set, else
    /// `AppTheme.dynamicAccent`) — see `LibraryHubView.resolvedAccent`. Only
    /// the icon is tinted (title stays `textPrimary`), matching the same
    /// icon-tinted/text-plain split `ProfileInfoCard` already uses elsewhere
    /// in the app, so an unusual accent color can't hurt title readability.
    var accent: Color = AppTheme.dynamicAccent

    var body: some View {
        HStack {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent)
                    .frame(width: 4, height: 22)
                Image(systemName: icon)
                    .foregroundStyle(accent)
                Text(title)
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .font(.title3.weight(.bold))
            Spacer()
            if let seeAllTab, let selectedTab {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        selectedTab.wrappedValue = seeAllTab
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text("See All")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Generic song carousel (Recently Added / On Repeat / Forgotten Favorites)

private struct HubSongCarousel: View {
    let title: String
    let icon: String
    let songs: [Song]
    var seeAllTab: LibraryTab? = nil
    @Binding var selectedTab: LibraryTab
    var accent: Color = AppTheme.dynamicAccent

    @EnvironmentObject private var player: AudioPlayerManager

    // Bigger than the old 132pt cards — more dramatic, art-forward tiles
    // matching the "card wall" treatment the Songs tab redesign uses.
    private let cardWidth: CGFloat = 152

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: title, icon: icon, seeAllTab: seeAllTab, selectedTab: $selectedTab, accent: accent)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(songs) { song in
                        HubParallaxCard {
                            Button {
                                player.play(song: song, in: songs)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ArtworkThumbnail(song: song, size: cardWidth)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
                                        .overlay(alignment: .bottomTrailing) { nowPlayingBadge(for: song) }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(song.displayName)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(song.artistName)
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: cardWidth, alignment: .leading)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        .frame(width: cardWidth, height: cardWidth + 50)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func nowPlayingBadge(for song: Song) -> some View {
        if player.currentSong?.id == song.id {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(AppTheme.dynamicAccent, in: Circle())
                .padding(6)
        }
    }
}

// MARK: - Resume card

/// Shown while a track is loaded but paused: the play button resumes in
/// place, the rest of the card opens Now Playing.
private struct HubResumeCard: View {
    let song: Song
    var accent: Color = AppTheme.dynamicAccent

    @EnvironmentObject private var player: AudioPlayerManager
    /// `ContentView`'s tab selection; 1 is Now Playing (the mini player
    /// uses the same value).
    @AppStorage("selected_tab") private var selectedAppTab = 0

    var body: some View {
        HStack(spacing: 12) {
            Button {
                selectedAppTab = 1
            } label: {
                HStack(spacing: 12) {
                    ArtworkThumbnail(song: song, size: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paused")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(accent)
                        Text(song.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Text(song.artistName)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Now Playing")

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(accent)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Resume \(song.displayName)")
        }
        .padding(10)
        .adaptiveGlass(
            tint: accent.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            fallback: AppTheme.surface
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Zone filter chips

/// "All" plus one chip per zone that currently has content. Tapping the
/// active chip again goes back to All.
private struct HubZoneFilterBar: View {
    let zones: [HubZone]
    @Binding var selection: HubZone?
    /// `selection` resolved against `zones` — a remembered zone whose last
    /// section just emptied out reads as All rather than an invisible chip.
    let activeZone: HubZone?
    var accent: Color = AppTheme.dynamicAccent

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", icon: nil, isSelected: activeZone == nil) {
                    selection = nil
                }
                ForEach(zones) { zone in
                    chip(title: zone.chipTitle, icon: zone.icon, isSelected: activeZone == zone) {
                        selection = activeZone == zone ? nil : zone
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: activeZone)
    }

    private func chip(title: String, icon: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { action() }
        } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : AppTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    Capsule().fill(accent)
                } else {
                    Capsule().fill(AppTheme.surface)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Zone heading

/// A quiet small-caps label above the first section of each zone — lighter
/// than `HubSectionHeader` so it reads as grouping, not as another shelf.
private struct HubZoneHeading: View {
    let zone: HubZone

    var body: some View {
        HStack(spacing: 8) {
            Text(zone.title.uppercased())
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(AppTheme.textSecondary)
            Rectangle()
                .fill(AppTheme.textSecondary.opacity(0.2))
                .frame(height: 1)
        }
        .padding(.horizontal, 16)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Jump Back In grid

/// The last few tracks as a dense two-column grid — six resumable tracks in
/// roughly the height of one carousel row, so "carry on where I left off"
/// is one tap from the top of Home without any sideways scrolling.
private struct HubJumpBackInGrid: View {
    let songs: [Song]
    /// Queue for playback — the full recently-played list, so playing one
    /// tile carries on into the tracks after it rather than stopping at six.
    let queue: [Song]
    var accent: Color = AppTheme.dynamicAccent

    @EnvironmentObject private var player: AudioPlayerManager

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "Jump Back In", icon: "arrow.uturn.backward.circle.fill", accent: accent)
                .padding(.horizontal, 16)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(songs) { song in
                    Button {
                        player.play(song: song, in: queue)
                    } label: {
                        tile(for: song)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func tile(for song: Song) -> some View {
        HStack(spacing: 10) {
            ArtworkThumbnail(song: song, size: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if player.currentSong?.id == song.id {
                Image(systemName: "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
                    .padding(.trailing, 4)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(
            tint: accent.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            fallback: AppTheme.surface
        )
    }
}

// MARK: - Quick Actions row

/// One-tap shortcuts pinned to the very top of the hub, above even the speed
/// dial — the hub is a "what do I want to do right now" landing screen, and
/// "just start playing something" is the single most common answer to that,
/// so it shouldn't need a scroll + a tap-into-a-tile to get there.
private struct HubQuickActionsRow: View {
    let hasLibrary: Bool
    let onShuffleAll: () -> Void
    let onSurpriseMe: () -> Void
    let onHumToSearch: () -> Void
    let onNameThatTune: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                actionChip(title: "Shuffle All", icon: "shuffle", action: onShuffleAll)
                    .disabled(!hasLibrary)
                    .opacity(hasLibrary ? 1 : 0.4)
                // Distinct from Shuffle All: a weighted pick from the hub's
                // own curated pools (forgotten favorites weighted heaviest)
                // instead of a flat random pick across the whole library —
                // see LibraryHubView.surpriseMe's doc comment.
                actionChip(title: "Surprise Me", icon: "sparkles", action: onSurpriseMe)
                    .disabled(!hasLibrary)
                    .opacity(hasLibrary ? 1 : 0.4)
                actionChip(title: "Hum to Search", icon: "waveform", action: onHumToSearch)
                    .disabled(!hasLibrary)
                    .opacity(hasLibrary ? 1 : 0.4)
                actionChip(title: "Name That Tune", icon: "waveform.badge.magnifyingglass", action: onNameThatTune)
            }
            .padding(.horizontal, 16)
        }
    }

    private func actionChip(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .adaptiveGlass(
                tint: AppTheme.dynamicAccent.opacity(0.16),
                in: Capsule(),
                fallback: AppTheme.surface
            )
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Greeting header
//
// A time-of-day-aware personalization touch (2026's music-app home screens
// lean hard on "this looks like it was built for you right now" — see e.g.
// Spotify's session-adaptive home) — pinned above even the quick actions
// row. The subtitle is a genuinely computed stat (distinct songs last played
// today), not decorative copy, falling back to a plain invitation when
// nothing's played yet today.
private struct HubGreetingHeader: View {
    let displayName: String?
    let songsPlayedToday: Int
    /// User-set override from `HomeHubCustomizationView` — when non-empty,
    /// replaces the computed greeting *and* subtitle below entirely (a
    /// single custom line rather than a greeting+stat pair), since the whole
    /// point is "show my own text instead of the automatic one." Clearing it
    /// back to empty restores the automatic greeting.
    var customGreeting: String = ""
    var accent: Color = AppTheme.dynamicAccent

    /// Whatever's currently playing (if anything) backs the hero's blurred
    /// artwork backdrop — the same `HeroArtworkBackdrop` component the
    /// Songs/Queue/Folder Detail redesign uses, so the very top of Home ties
    /// into the same "your library right now," not a generic banner. Falls
    /// back to its own ambient gradient when nothing's playing.
    @EnvironmentObject private var player: AudioPlayerManager

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Good night"
        }
    }

    private var subtitle: String {
        guard songsPlayedToday > 0 else { return "Ready to listen?" }
        return "You've played \(songsPlayedToday) song\(songsPlayedToday == 1 ? "" : "s") today"
    }

    private var trimmedCustomGreeting: String {
        customGreeting.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroArtworkBackdrop(song: player.currentSong, height: 150)

            VStack(alignment: .leading, spacing: 3) {
                if !trimmedCustomGreeting.isEmpty {
                    Text(trimmedCustomGreeting)
                        .font(.title.weight(.heavy))
                        .foregroundStyle(AppTheme.textPrimary)
                } else {
                    Text(displayName.map { "\(greeting), \($0)" } ?? greeting)
                        .font(.title.weight(.heavy))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - On This Day teaser
//
// A single compact card surfacing the server's `/user/on-this-day` feature
// (previously only reachable by already knowing it exists somewhere in
// Settings) right on the hub, with a real preview of today's top match
// rather than a blind "Open On This Day" button — tapping pushes the full
// `OnThisDayView` for every year/track it found.
private struct HubOnThisDayTeaser: View {
    let groups: [OnThisDayGroup]
    var accent: Color = AppTheme.dynamicAccent

    private var topGroup: OnThisDayGroup? { groups.first }
    private var topTrack: StreamTrack? { topGroup?.tracks.first }

    var body: some View {
        NavigationLink {
            OnThisDayView()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(accent.opacity(0.16))
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("On This Day")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    if let topTrack, let year = topGroup?.year {
                        Text("\(topTrack.title) — played in \(String(year))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text("See what you were listening to on this date")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(12)
            .adaptiveGlass(
                tint: accent.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                fallback: AppTheme.surface
            )
            .padding(.horizontal, 16)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Continue Listening (podcasts) teaser

struct ContinueListeningPodcastItem: Identifiable {
    let subscription: PodcastSubscription
    let progress: PodcastEpisodeProgress
    var id: String { progress.episodeGuid }
}

/// Resumes the single most-recently-updated in-progress podcast episode
/// across every subscription — same "compact teaser for a feature that
/// already exists" reasoning as `HubOnThisDayTeaser`. Tapping fetches that
/// one feed's episode list to resolve the audio URL (progress rows don't
/// store it — see main.py's doc comment on get_podcast_episode_progress)
/// before handing off to the shared `PodcastPlayback.play`.
private struct HubContinueListeningPodcastsTeaser: View {
    let item: ContinueListeningPodcastItem
    var accent: Color = AppTheme.dynamicAccent

    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var player: AudioPlayerManager
    @State private var isResolving = false

    var body: some View {
        Button {
            resumeAndPlay()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(accent.opacity(0.16))
                    if isResolving {
                        ProgressView()
                    } else {
                        Image(systemName: "headphones")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue Listening")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(item.progress.title?.isEmpty == false ? item.progress.title! : (item.subscription.title ?? "Podcast"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
            }
            .padding(12)
            .adaptiveGlass(
                tint: accent.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                fallback: AppTheme.surface
            )
            .padding(.horizontal, 16)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isResolving)
    }

    private func resumeAndPlay() {
        guard !isResolving else { return }
        isResolving = true
        Task {
            let episodes = await account.fetchPodcastEpisodes(feedURL: item.subscription.feedURL)
            isResolving = false
            guard let episode = episodes.first(where: { $0.guid == item.progress.episodeGuid }) else { return }
            PodcastPlayback.play(episode: episode, subscription: item.subscription, savedProgress: item.progress, player: player)
        }
    }
}

// MARK: - Achievements teaser
//
// A compact "how am I doing" summary of the existing GET /user/achievements
// feature (streaks + badge unlocks, already fully explorable via the
// standalone `AchievementsView` reachable from Settings) — surfaced right on
// the hub for the same reason `HubOnThisDayTeaser` is: a feature already
// worth having shouldn't only be discoverable by already knowing it's buried
// in Settings. Tapping pushes the existing full `AchievementsView` rather
// than duplicating its badge grid here.
private struct HubAchievementsTeaser: View {
    let data: AchievementsData
    var accent: Color = AppTheme.dynamicAccent

    private var subtitle: String {
        if data.currentStreakDays > 0 {
            return "\(data.currentStreakDays)-day streak · \(data.badges.count) badge\(data.badges.count == 1 ? "" : "s") unlocked"
        }
        return "\(data.badges.count) badge\(data.badges.count == 1 ? "" : "s") unlocked · \(data.totalPlays) plays"
    }

    var body: some View {
        NavigationLink {
            AchievementsView()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(accent.opacity(0.16))
                    Image(systemName: "trophy.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Streaks & Achievements")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(12)
            .adaptiveGlass(
                tint: accent.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                fallback: AppTheme.surface
            )
            .padding(.horizontal, 16)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - This Week recap card
//
// A non-interactive stat card (no detail screen to push into — unlike every
// other teaser here, this is entirely derived from on-device
// `PlayHistoryStore` data, not a server feature) surfacing
// `LibraryManager.weeklyRecap()`'s three numbers side by side.
private struct HubWeeklyRecapCard: View {
    let recap: LibraryManager.HubWeeklyRecap
    var accent: Color = AppTheme.dynamicAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "This Week", icon: "chart.bar.fill", accent: accent)
                .padding(.horizontal, 16)

            HStack(spacing: 10) {
                statTile(value: "\(recap.songsPlayed)", label: recap.songsPlayed == 1 ? "song played" : "songs played")
                statTile(value: "\(recap.estimatedMinutes)", label: "est. minutes")
                if let topArtist = recap.topArtist {
                    statTile(value: topArtist, label: "top artist", isCompact: true)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func statTile(value: String, label: String, isCompact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(isCompact ? .subheadline.weight(.bold) : .title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .adaptiveGlass(
            tint: accent.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            fallback: AppTheme.surface
        )
    }
}

// MARK: - Aria's Daily Pick
//
// One AI-picked track/day with a short reason (GET /user/aria/daily-pick),
// cached server-side so revisiting Home never costs an extra Gemini call —
// see that endpoint's doc comment in main.py. A single compact card, same
// "not a carousel" shape as `HubWeeklyRecapCard`/`HubAchievementsTeaser`,
// since there's only ever one pick to show per day.
private struct HubAriaDailyPickCard: View {
    let track: StreamTrack
    let reason: String?
    var accent: Color = AppTheme.dynamicAccent

    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var player: AudioPlayerManager
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "Aria's Daily Pick", icon: "sparkle", accent: accent)
                .padding(.horizontal, 16)

            Button {
                play()
            } label: {
                HStack(spacing: 12) {
                    CachedAsyncImage(url: URL(string: track.thumbnailURL)) { phase in
                        switch phase {
                        case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Image(systemName: "music.note")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .background(AppTheme.elevatedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                        if let reason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.textSecondary.opacity(0.85))
                                .italic()
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(accent)
                    }
                }
                .padding(12)
                .adaptiveGlass(
                    tint: accent.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                    fallback: AppTheme.surface
                )
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .padding(.horizontal, 16)
        }
    }

    private func play() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let url = try await streaming.streamURL(for: track)
                let song = streaming.toSong(track: track, streamURL: url)
                player.play(song: song, in: [song])
            } catch {
                streaming.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Top Artists carousel
//
// Ranks the on-device library's own artist tags by lifetime plays (see
// `LibraryManager.topArtistGroups`) — real listening behavior, not fetched
// data. Tapping an artist tile shuffle-plays everything by them, matching
// `HubGenresCarousel`'s identical "one tap to just start listening" pattern
// rather than pushing into a browsing screen for a single artist.
private struct HubTopArtistsCarousel: View {
    let groups: [(artist: String, songs: [Song], playCount: Int)]
    var accent: Color = AppTheme.dynamicAccent
    @EnvironmentObject private var player: AudioPlayerManager

    private let tileSize: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "Top Artists", icon: "music.mic", accent: accent)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(groups, id: \.artist) { group in
                        HubParallaxCard {
                            Button {
                                player.shuffleEnabled = true
                                if let first = group.songs.randomElement() {
                                    player.play(song: first, in: group.songs)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HubArtworkCollage(
                                        songs: Array(group.songs.prefix(4)),
                                        size: tileSize,
                                        placeholderIcon: "music.mic"
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.artist)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .lineLimit(1)
                                        Text("\(group.playCount) \(group.playCount == 1 ? "play" : "plays")")
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                                .frame(width: tileSize, alignment: .leading)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        .frame(width: tileSize, height: tileSize + 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Decades carousel
//
// Groups the on-device library by release decade (parsed from `Song.year`
// — see `LibraryManager.decadeGroups`), newest first. Tapping a tile
// shuffle-plays that decade, same one-tap pattern as Genres/Top Artists.
private struct HubDecadesCarousel: View {
    let groups: [(decade: String, songs: [Song])]
    var accent: Color = AppTheme.dynamicAccent
    @EnvironmentObject private var player: AudioPlayerManager

    private let tileSize: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "Decades", icon: "hourglass", accent: accent)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(groups, id: \.decade) { group in
                        HubParallaxCard {
                            Button {
                                player.shuffleEnabled = true
                                if let first = group.songs.randomElement() {
                                    player.play(song: first, in: group.songs)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HubArtworkCollage(
                                        songs: Array(group.songs.prefix(4)),
                                        size: tileSize,
                                        placeholderIcon: "hourglass"
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.decade)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .lineLimit(1)
                                        Text("\(group.songs.count) \(group.songs.count == 1 ? "song" : "songs")")
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                                .frame(width: tileSize, alignment: .leading)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        .frame(width: tileSize, height: tileSize + 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Genres carousel
//
// Groups the on-device library by its own embedded genre tags — real
// metadata already sitting unused on every `Song`, not a fetched/curated
// list. Tapping a tile shuffle-plays everything in that genre, matching the
// "one tap to just start listening" spirit of the rest of the hub rather
// than pushing into a browsing screen for a single genre.
private struct HubGenresCarousel: View {
    let groups: [(genre: String, songs: [Song])]
    var accent: Color = AppTheme.dynamicAccent
    @EnvironmentObject private var player: AudioPlayerManager

    private let tileSize: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "Genres", icon: "guitars.fill", accent: accent)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(groups, id: \.genre) { group in
                        HubParallaxCard {
                            Button {
                                player.shuffleEnabled = true
                                if let first = group.songs.randomElement() {
                                    player.play(song: first, in: group.songs)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HubArtworkCollage(
                                        songs: Array(group.songs.prefix(4)),
                                        size: tileSize,
                                        placeholderIcon: "guitars.fill"
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.genre)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .lineLimit(1)
                                        Text("\(group.songs.count) \(group.songs.count == 1 ? "song" : "songs")")
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                                .frame(width: tileSize, alignment: .leading)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        .frame(width: tileSize, height: tileSize + 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Friends Activity carousel

/// "What friends are playing" — surfaces the Social Ecosystem's friends-only
/// activity feed (recent plays/favorites, already gated server-side by each
/// friend's own `share_now_playing` privacy toggle) right on the hub instead
/// of it only living inside the Friends screen, so the two big features this
/// app shipped in the same window — the library hub and the social system —
/// actually feel like one app rather than two bolted together.
private struct HubFriendsActivityCarousel: View {
    let entries: [SocialActivityEntry]
    var accent: Color = AppTheme.dynamicAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "Friends Activity", icon: "person.2.wave.2.fill", accent: accent)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(entries.prefix(20)) { entry in
                        HubParallaxCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    SocialAvatarView(userId: entry.userId, size: 28)
                                    Text(entry.displayName ?? entry.username)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: entry.isPlayed ? "play.fill" : "heart.fill")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.dynamicAccent)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title ?? "Unknown Title")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .lineLimit(1)
                                    if let artist = entry.artist, !artist.isEmpty {
                                        Text(artist)
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(width: 168, height: 100, alignment: .topLeading)
                            .adaptiveGlass(
                                tint: AppTheme.dynamicAccent.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                fallback: AppTheme.surface
                            )
                        }
                        .frame(width: 168, height: 100)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Similar Listeners carousel

/// "Because listeners like you also play..." — real collaborative-filtering
/// recommendations from `/social/similar-listeners` (other opted-in users
/// whose top artists overlap with the caller's own). These are plain
/// title/artist suggestions, not something already in this user's library or
/// server storage, so tapping one opens the Cloud Services search pre-filled
/// with that title/artist rather than trying to play it directly.
private struct HubSimilarListenersCarousel: View {
    let tracks: [TrendingTrack]
    let listenerCount: Int
    var accent: Color = AppTheme.dynamicAccent
    let onSelect: (TrendingTrack) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSectionHeader(title: "Similar Listeners", icon: "person.3.sequence.fill", accent: accent)
                .padding(.horizontal, 16)
            Text("Based on \(listenerCount) listener\(listenerCount == 1 ? "" : "s") with taste like yours")
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(tracks.prefix(20)) { track in
                        HubParallaxCard {
                            Button { onSelect(track) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(AppTheme.dynamicAccent.opacity(0.16))
                                        Image(systemName: "waveform.badge.magnifyingglass")
                                            .font(.title3)
                                            .foregroundStyle(AppTheme.dynamicAccent)
                                    }
                                    .frame(width: 132, height: 132)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .lineLimit(1)
                                        if let artist = track.artist, !artist.isEmpty {
                                            Text(artist)
                                                .font(.caption2)
                                                .foregroundStyle(AppTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .frame(width: 132, alignment: .leading)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        .frame(width: 132, height: 178)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Mix card (SmartPlaylist — Recently Added / Most Played / Forgotten
// Favorites / Quick Listens / anything the user built themselves)

private struct HubMixCard: View {
    let mix: SmartPlaylist
    @EnvironmentObject private var library: LibraryManager

    // Snapshotted once per mix rather than re-evaluated (a full rule scan
    // over the library) on every body re-render — same reasoning as
    // `HubSpeedDialTile`'s `listenedFraction`/`collage` caching above.
    @State private var songs: [Song] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                AppTheme.dynamicAccentGradient
                if let song = songs.first {
                    ArtworkThumbnail(song: song, size: 168)
                        .opacity(0.85)
                }
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: mix.icon)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .frame(width: 168, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(mix.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs")")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(width: 168, alignment: .leading)
        .task(id: mix.id) {
            songs = mix.evaluate(over: library.allSongs, favorites: library.favoriteSongIDs)
        }
    }
}

// MARK: - Mood card

private struct HubMoodCard: View {
    let bucket: MoodBucket
    let count: Int
    let representative: Song?

    private var icon: String {
        switch bucket {
        case .energetic: return "bolt.fill"
        case .chill:     return "leaf.fill"
        case .focus:     return "target"
        case .sleep:     return "moon.stars.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.surface)
                if let representative {
                    ArtworkThumbnail(song: representative, size: 140)
                        .opacity(0.55)
                }
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: icon)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .frame(width: 140, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("\(count) \(count == 1 ? "song" : "songs")")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(width: 140, alignment: .leading)
    }
}

// MARK: - Carousel scroll parallax
//
// A light "physics" touch for horizontal carousels: cards nearer the screen's
// horizontal center render at full scale/opacity, cards further out shrink
// and fade slightly — cheap (`GeometryReader` + `.global` frame comparison,
// no scroll-offset preference-key plumbing) and works back to iOS 16 (the
// project's deployment target — `.scrollTransition` is iOS 17+ only, so this
// hand-rolled version is used instead of it everywhere in the hub).
private struct HubParallaxCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        GeometryReader { geo in
            let midX = geo.frame(in: .global).midX
            let screenMidX = UIScreen.main.bounds.width / 2
            let distance = abs(midX - screenMidX)
            let maxDistance = UIScreen.main.bounds.width / 2 + 100
            let normalized = min(distance / maxDistance, 1)
            content
                .scaleEffect(1 - normalized * 0.08)
                .opacity(1 - normalized * 0.25)
        }
    }
}

// MARK: - Loading skeleton

private struct HubSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 10) {
                skeletonBar(width: 130, height: 18).padding(.horizontal, 16)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            skeletonBlock(cornerRadius: 12).aspectRatio(1, contentMode: .fit)
                            skeletonBar(width: 90, height: 12)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    skeletonBar(width: 120, height: 16).padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(0..<4, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    skeletonBlock(cornerRadius: 10).frame(width: 132, height: 132)
                                    skeletonBar(width: 100, height: 10)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private func skeletonBlock(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppTheme.surface)
            .overlay(ShimmerOverlay().clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }

    private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(AppTheme.surface)
            .frame(width: width, height: height)
            .overlay(ShimmerOverlay().clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous)))
    }
}

// MARK: - Animated empty state

private struct HubEmptyState: View {
    @State private var animateIn = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(AppTheme.dynamicAccentGradient)
                .scaleEffect(animateIn ? 1 : 0.7)
            Text("Your hub is empty")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text("Add music to see your playlists, folders, and favorites collected here.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .opacity(animateIn ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65).delay(0.05)) {
                animateIn = true
            }
        }
    }
}
