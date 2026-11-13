import SwiftUI

// MARK: - Root

struct TVContentView: View {
    @StateObject private var account = TVAccount.shared
    @StateObject private var client = TVBridgeClient.shared
    // Adopted here (not constructed) for the same reason `client`/`account`
    // are — see TVPlayerModel.shared's doc comment. Not otherwise used
    // directly in this view; holding the reference here just keeps it
    // consistent with the rest of this file's root-level singleton pattern.
    @StateObject private var player = TVPlayerModel.shared
    @State private var selection: TVDestination = .home

    var body: some View {
        if account.isLoggedIn, let token = account.token {
            NavigationStack {
                // Three columns: navigation | content | what's playing.
                //
                // This replaces a top nav bar over a full-width content area with
                // a mini-player strip inset across the bottom. Side by side, a
                // left/right move changes region and an up/down move stays inside
                // one, so navigation is no longer in the path of scrolling a list
                // and the player is no longer in the path of leaving it.
                //
                // The player column is composed with a plain `if`. v1.7.0 pinned
                // the player as a `safeAreaInset` that rendered an empty view when
                // nothing was playing, and wrapped it in a focus section — a
                // zero-size focus section inside a safe-area inset, in exactly the
                // state the app launches in, which made it relaunch in a loop.
                // Here, nothing playing means no view at all: nothing to size,
                // nothing to focus, no empty branch to get wrong.
                HStack(spacing: 0) {
                    TVSideRail(
                        selection: $selection,
                        accountName: account.user?.name ?? "Account",
                        accountBadge: client.notifications.filter(\.isUnread).count,
                        user: account.user,
                        baseURL: client.baseURL
                    )
                    // Above the content column, so the focused item's floating
                    // name label paints over it rather than under it.
                    .zIndex(1)

                    ZStack {
                        switch selection {
                        case .home:
                            TVHomeView(client: client, token: token)
                        case .library:
                            TVLibraryView(client: client, token: token)
                        case .playlists:
                            TVPlaylistsView(client: client, token: token)
                        case .discover:
                            TVDiscoverView(client: client, token: token)
                        case .search:
                            TVSearchView(client: client, token: token)
                        case .account:
                            TVAccountView(client: client, account: account, token: token)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .focusSection()

                    // The player column is HIDDEN on Search.
                    //
                    // tvOS's search surface brings the system keyboard, which it
                    // lays out across the full width of the window regardless of
                    // what else is on screen — so with the card present the
                    // keyboard drew straight over it and over the rail, which is
                    // the overlap in the 1.13.2 screenshot. Nothing in the app
                    // can reposition a system keyboard, so the fix is to give the
                    // screen the width it is going to take anyway.
                    //
                    // Hidden for the full player too: that screen is pushed over
                    // this shell and already shows everything the card does.
                    if player.current != nil,
                       !player.isShowingFullPlayer,
                       selection != .search {
                        TVNowPlayingPanel(model: player, client: client, token: token)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeOut(duration: 0.3), value: player.current == nil)
                .animation(.easeOut(duration: 0.25), value: selection == .search)
                .background(TVAmbientBackground())
                .navigationDestination(for: TVPlayContext.self) { ctx in
                    TVPlayerView(context: ctx, client: client, token: token)
                }
            }
            // Fetched here (not just inside TVAccountView.task, as before) so
            // the nav bar's unread badge is accurate even before Account is
            // ever visited this session.
            .task {
                // Runs for the life of the session — see TVAdvancedTelemetry.
                TVAdvancedTelemetry.HitchMonitor.shared.start()
                TVAdvancedTelemetry.noteScreen(selection.rawValue)
                if client.notifications.isEmpty { await client.fetchNotifications(token: token) }
                // Eagerly primes the stream-ticket cache (see TVBridgeClient's
                // doc comment on it) right at session start — covers both a
                // cold launch already signed in and a fresh interactive
                // sign-in, since this `.task` fires either way the first time
                // this branch of the view appears. Without this, the very
                // first track played each session would still go out with no
                // ticket (streamURL(for:)'s own opportunistic refresh only
                // helps from the SECOND track onward).
                await client.refreshStreamTicketIfNeeded(token: token)
            }
            .onChange(of: selection) { newValue in
                TVAdvancedTelemetry.noteScreen(newValue.rawValue)
            }
        } else {
            TVLoginView(account: account)
        }
    }
}

// MARK: - Search tab

struct TVSearchView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    @State private var query = ""

    private var queue: [TVPlayable] { client.results.compactMap { client.playable(from: $0) } }

    var body: some View {
        // UISearchController-backed so the system tvOS keyboard (and its
        // dictation microphone) is available — SwiftUI's `.searchable` has no
        // supported way to offer voice input. See TVDictationSearch.
        TVDictationSearch(text: $query, placeholder: "Search YouTube", onChange: runSearch) {
            resultsBody
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var resultsBody: some View {
        if client.isSearching {
            TVLoadingState(text: "Searching… this can take a moment")
                .frame(maxHeight: .infinity, alignment: .top)
        } else if let err = client.searchError {
            TVEmptyState(systemImage: "exclamationmark.magnifyingglass",
                         title: "Search didn't work",
                         message: err)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if client.results.isEmpty {
            ScrollView { emptyState }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                TVSectionHeader(title: "Results",
                                subtitle: "\(client.results.count) matches for “\(query)”")
                    .padding(.horizontal, TVMetrics.margin)
                    .padding(.top, 20)
                TVCardGrid(items: client.results) { track, cell in
                    NavigationLink(value: TVPlayContext(queue: queue, startID: track.id)) {
                        TVTrackCard(track: track, width: cell)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .tvSearchTrackActions(client: client, token: token, track: track)
                }
            }
        }
    }

    /// Debounced search-as-you-type. tvOS search keyboards don't reliably fire
    /// a submit action, so the query runs as the text changes — including text
    /// arriving from dictation, which produces no submit event at all.
    private func runSearch(_ value: String) {
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard query == value else { return }  // user kept typing/speaking
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                client.results = []
                client.searchError = nil
            } else {
                await client.search(value)
            }
        }
    }

    /// An empty query surfaces something real to browse straight away — the
    /// same Discover Mix data the Discover tab shows, framed as suggestions.
    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 30) {
            TVEmptyState(
                systemImage: "waveform.and.magnifyingglass",
                title: "Find anything",
                message: "Search YouTube by song, artist or album — or press the microphone and just say it."
            )
            .padding(.bottom, 20)

            if !client.discoverMix.isEmpty {
                let suggestQueue = client.discoverMix.compactMap { client.playable(from: $0) }
                TVShelfSection(title: "Try One Of These", subtitle: "Based on your most-played artists") {
                    ForEach(client.discoverMix) { track in
                        NavigationLink(value: TVPlayContext(queue: suggestQueue, startID: track.id)) {
                            TVTrackCard(track: track)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .tvSearchTrackActions(client: client, token: token, track: track)
                    }
                }
            }
        }
        .padding(.bottom, 60)
        .task {
            if client.discoverMix.isEmpty { await client.fetchDiscoverMix(token: token) }
        }
    }
}

/// A YouTube/search result as a 16:9 thumbnail card — the shape the source
/// material actually comes in, so the thumbnail isn't cropped to a square.
struct TVTrackCard: View {
    let track: TVTrack
    var width: CGFloat = 340

    var body: some View {
        TVArtworkCardLabel(
            title: track.title,
            subtitle: track.artist.isEmpty ? "Unknown Artist" : track.artist,
            width: width,
            aspectRatio: 16.0 / 9.0
        ) {
            TVAuthImage(url: URL(string: track.thumbnailURL), token: nil) {
                TVArtPlaceholder(systemImage: "music.note")
            }
        }
    }
}

// MARK: - Account tab

struct TVAccountView: View {
    @ObservedObject var client: TVBridgeClient
    @ObservedObject var account: TVAccount
    let token: String

    private var unreadNotificationCount: Int {
        client.notifications.filter(\.isUnread).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVMetrics.section) {
                profileHeader
                    // Its own focus region: Sign Out is the only control in it
                    // and the escape hatch from a bad restored session, so it
                    // must be reachable from the tiles below with one "up".
                    .focusSection()

                VStack(alignment: .leading, spacing: 22) {
                    TVSectionHeader(title: "Your Account")
                    HStack(spacing: 28) {
                        tile("Listening Stats", subtitle: "Plays, streaks, badges",
                             systemImage: "chart.bar.fill") {
                            TVStatsView(client: client, token: token)
                        }
                        tile("Notifications",
                             subtitle: unreadNotificationCount > 0 ? "\(unreadNotificationCount) unread" : "All caught up",
                             systemImage: "bell.fill", badge: unreadNotificationCount) {
                            TVNotificationsView(client: client, token: token)
                        }
                        tile("Sessions", subtitle: "Devices signed in",
                             systemImage: "rectangle.stack.badge.person.crop") {
                            TVSessionsView(client: client, account: account, token: token)
                        }
                        tile("Listen Together", subtitle: TVListenTogether.shared.isInRoom ? "In a room" : "Join a friend",
                             systemImage: "person.2.wave.2.fill") {
                            TVListenTogetherView(client: client, token: token)
                        }
                        tile("Settings", subtitle: "Playback & display",
                             systemImage: "gearshape.fill") {
                            TVSettingsView()
                        }
                    }
                }
                .padding(.horizontal, TVMetrics.margin)
                .focusSection()

                if !client.friendsListening.isEmpty {
                    VStack(alignment: .leading, spacing: 22) {
                        TVSectionHeader(title: "Friends Listening Now")
                        TVFriendsListeningCard(friendsListening: client.friendsListening)
                    }
                    .frame(maxWidth: 1200, alignment: .leading)
                    .padding(.horizontal, TVMetrics.margin)
                }

                VStack(alignment: .leading, spacing: 22) {
                    TVSectionHeader(title: "Listening Activity",
                                    subtitle: "What people who share their listening have played")
                    TVSocialActivityFeed(activity: client.socialActivity)
                }
                // Bounded: the feed rows contain spacers, which grow to
                // whatever width they're offered.
                .frame(maxWidth: 1200, alignment: .leading)
                .padding(.horizontal, TVMetrics.margin)
            }
            .padding(.bottom, 80)
        }
        .task {
            if client.notifications.isEmpty { await client.fetchNotifications(token: token) }
            if client.stats == nil { await client.fetchStats(token: token) }
            // Unlike the two guards above, these ran unconditionally — every
            // navigation into Account re-issued both round trips (plus
            // whatever `fetchFriendsListening` itself fans out to for
            // presence) even when already loaded this session. Same
            // `.isEmpty` guard shape as `notifications` above; genuinely
            // having zero friends/activity means this re-fetches each visit,
            // same accepted tradeoff that row already has.
            if client.friendsListening.isEmpty { await client.fetchFriendsListening(token: token) }
            if client.socialActivity.isEmpty { await client.fetchSocialActivity(token: token) }
        }
    }

    /// The profile as a banner across the top: avatar, name, a couple of
    /// headline numbers, and Sign Out.
    private var profileHeader: some View {
        HStack(alignment: .center, spacing: 40) {
            TVAvatarView(user: account.user, baseURL: client.baseURL, diameter: 168)

            VStack(alignment: .leading, spacing: 10) {
                Text("SIGNED IN")
                    .font(TVType.eyebrow)
                    .tracking(2.4)
                    .foregroundStyle(TVPalette.neonAlt)
                Text(account.user?.name ?? "Signed in")
                    .font(TVType.display)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let username = account.user?.username, !username.isEmpty {
                    Text("@\(username)")
                        .font(TVType.rowDetail)
                        .foregroundStyle(TVPalette.textSecondary)
                }
                if let stats = client.stats {
                    HStack(spacing: 14) {
                        statPill("\(stats.totalPlays) plays", systemImage: "play.fill")
                        statPill(listenTime(stats.totalListenSeconds), systemImage: "clock.fill")
                    }
                    .padding(.top, 6)
                }
            }

            Spacer(minLength: 20)

            Button(role: .destructive) {
                account.logout()
            } label: {
                TVPillLabel(title: "Sign Out", systemImage: "rectangle.portrait.and.arrow.right",
                            style: .secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(40)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(TVPalette.brand)
                    .opacity(0.35)
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.6)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, TVMetrics.margin)
        .padding(.top, 40)
    }

    private func statPill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 19, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.1), in: Capsule())
    }

    private func listenTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        if hours > 0 { return "\(hours)h listened" }
        return "\((seconds % 3600) / 60)m listened"
    }

    @ViewBuilder
    private func tile<Destination: View>(
        _ title: String, subtitle: String, systemImage: String, badge: Int = 0,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            TVAccountTileLabel(title: title, subtitle: subtitle,
                               systemImage: systemImage, badge: badge)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// One Account tile. A FIXED width: a label inside a tvOS button is offered an
/// unconstrained width, and a greedy one grows past the screen — where the
/// focus engine cannot reach it. Four of these fit the content column even
/// with the Now Playing card open.
private struct TVAccountTileLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var badge: Int = 0

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(TVPalette.brand))
                    .shadow(color: TVPalette.violet.opacity(0.5), radius: 12, y: 4)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(red: 0.96, green: 0.33, blue: 0.47)))
                }
            }
            Spacer(minLength: 16)
            Text(title)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.system(size: 18))
                .foregroundStyle(TVPalette.textTertiary)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .padding(24)
        .frame(width: 262, height: 200, alignment: .topLeading)
        .tvNeonCard(cornerRadius: 26, isFocused: isFocused)
    }
}
