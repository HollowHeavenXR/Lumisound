import SwiftUI

// MARK: - Home

/// Lumen's Home: a greeting, a hero for whatever you were last listening
/// to, quick tiles, then shelves built from the same `HubContentBuilder`
/// Classic's hub uses — computed off the main actor so a big library never
/// stalls the first frame.
struct LumenHomeView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var folderService: MusicFolderService
    @Environment(\.lumenOpenPlayer) private var openPlayer
    @Environment(\.lumenSelectTab) private var selectTab

    @AppStorage("carModeEnabled") private var carModeEnabled: Bool = false

    @State private var snapshot = HubContentBuilder.Snapshot()
    @State private var hasLoaded = false
    @State private var showAddMusic = false
    // Classic's hub surfaces this as a compact teaser card (see
    // HubOnThisDayTeaser); Lumen had the `.onThisDay` route wired up to push
    // the full OnThisDayView, but nothing on Home ever actually navigated to
    // it — reachable in theory, invisible in practice.
    @State private var onThisDayGroups: [OnThisDayGroup] = []

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Late night"
        }
    }

    private var firstName: String {
        let name = account.currentUser?.displayName ?? account.currentUser?.username ?? ""
        return name.split(separator: " ").first.map(String.init) ?? ""
    }

    private var snapshotKey: String {
        "\(library.allSongs.count)|\(library.favoriteSongIDs.count)|\(player.currentSong?.id ?? "-")"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                LumenScreenHeader(eyebrow: greeting, title: firstName.isEmpty ? "Listen Now" : firstName) {
                    HStack(spacing: 10) {
                        if carModeEnabled {
                            LumenIconButton(systemName: "car.fill", accessibilityLabel: "Car Mode") {
                                NotificationCenter.default.post(name: .lumenShowCarMode, object: nil)
                            }
                        }
                        LumenIconButton(systemName: "plus", accessibilityLabel: "Add Music") { showAddMusic = true }
                    }
                }

                if library.isScanning { scanBanner }

                if library.allSongs.isEmpty {
                    if !library.isScanning {
                        LumenEmptyState(
                            systemImage: "music.note.house",
                            title: "Your library is waiting",
                            message: "Import files, connect a watched folder, or pull from Apple Music to fill Lumisound with your music.",
                            actionTitle: "Add Music"
                        ) { showAddMusic = true }
                        .padding(.top, 40)
                    }
                } else {
                    hero
                    quickTiles
                    shelves
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .background(Color.clear)
        .refreshable {
            await library.refreshAll(folderService: folderService)
            if account.isLoggedIn {
                await account.pullSync(library: library, player: player)
            }
        }
        .task(id: snapshotKey) { await reload() }
        .sheet(isPresented: $showAddMusic) {
            AddMusicView()
                .environmentObject(library)
                .environmentObject(folderService)
        }
    }

    private func reload() async {
        // Debounce bursts (a scan publishes many count changes in a row).
        if hasLoaded { try? await Task.sleep(nanoseconds: 350_000_000) }
        guard !Task.isCancelled else { return }
        let builder = library.hubContent
        let favorites = library.favoriteSongs
        let result = await Task.detached(priority: .userInitiated) {
            builder.snapshot(favorites: favorites)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: hasLoaded ? 0.25 : 0)) { snapshot = result }
        hasLoaded = true
        // Self-guards on `isLoggedIn` and swallows its own failures — safe to
        // call unconditionally, same as every other account-backed fetch here.
        onThisDayGroups = await account.fetchOnThisDay()
    }

    // MARK: Scan

    private var scanBanner: some View {
        HStack(spacing: 14) {
            ProgressView().tint(LumenPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scanning your music")
                    .font(LumenType.headline(15))
                    .foregroundStyle(LumenPalette.textPrimary)
                if let p = library.scanProgress, p.total > 0 {
                    Text("\(p.current) of \(p.total) files")
                        .font(LumenType.caption(12))
                        .foregroundStyle(LumenPalette.textSecondary)
                    ProgressView(value: Double(p.current), total: Double(max(p.total, 1)))
                        .tint(LumenPalette.accent)
                } else {
                    Text("New tracks will appear as they're found.")
                        .font(LumenType.caption(12))
                        .foregroundStyle(LumenPalette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .lumenCard()
        .padding(.horizontal, LumenMetrics.gutter)
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        if let current = player.currentSong {
            heroCard(song: current, eyebrow: player.isPlaying ? "Now playing" : "Paused",
                     buttonTitle: player.isPlaying ? "Open Player" : "Resume",
                     buttonIcon: player.isPlaying ? "waveform" : "play.fill") {
                if !player.isPlaying { player.togglePlayPause() }
                openPlayer()
            }
        } else if let last = snapshot.recentlyPlayed.first {
            heroCard(song: last, eyebrow: "Jump back in", buttonTitle: "Play", buttonIcon: "play.fill") {
                player.play(song: last, in: snapshot.recentlyPlayed)
            }
        } else if let fresh = snapshot.recentlyAdded.first {
            heroCard(song: fresh, eyebrow: "Fresh in your library", buttonTitle: "Play", buttonIcon: "play.fill") {
                player.play(song: fresh, in: snapshot.recentlyAdded)
            }
        }
    }

    private func heroCard(song: Song, eyebrow: String, buttonTitle: String, buttonIcon: String,
                          action: @escaping () -> Void) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                ArtworkThumbnail(song: song, size: max(geo.size.width, 1), showsScrim: false)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 40, opaque: true)
                    .saturation(1.3)
                    .overlay(
                        LinearGradient(colors: [Color.black.opacity(0.15), Color.black.opacity(0.65)],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if player.currentSong?.id == song.id {
                            LumenEqualizerGlyph(isAnimating: player.isPlaying, color: .white, height: 11)
                        }
                        Text(eyebrow.uppercased())
                            .font(LumenType.eyebrow())
                            .tracking(1.4)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Text(song.displayName)
                        .font(LumenType.title(24))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(song.artistName)
                        .font(LumenType.body(15))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Button(action: action) {
                        Label(buttonTitle, systemImage: buttonIcon)
                            .font(LumenType.headline(14))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(LumenPressStyle())
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
                LumenArtwork(song: song, size: 112, radius: 16)
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 10)
            }
            .padding(20)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .padding(.horizontal, LumenMetrics.gutter)
    }

    // MARK: Quick tiles

    private var quickTiles: some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            quickTile("Favorites", icon: "heart.fill", colors: [LumenPalette.ember, Color(red: 0.85, green: 0.2, blue: 0.45)],
                      value: LumenRoute.favorites)
            quickTile("Recently Added", icon: "sparkles", colors: [LumenPalette.azure, Color(red: 0.2, green: 0.4, blue: 0.95)],
                      value: LumenRoute.recentlyAdded)
            quickTile("Most Played", icon: "flame.fill", colors: [LumenPalette.warning, LumenPalette.ember],
                      value: LumenRoute.mostPlayed)
            Button {
                let shuffled = library.allSongs.smartShuffled()
                if let first = shuffled.first { player.play(song: first, in: shuffled) }
            } label: {
                quickTileLabel("Shuffle All", icon: "shuffle", colors: [LumenPalette.iris, Color(red: 0.42, green: 0.25, blue: 0.9)])
            }
            .buttonStyle(LumenPressStyle())
            quickTile("Discover", icon: "safari.fill", colors: [LumenPalette.success, Color(red: 0.1, green: 0.6, blue: 0.6)],
                      value: LumenRoute.discover)
            quickTile("Moods", icon: "theatermasks.fill", colors: [Color(red: 0.95, green: 0.45, blue: 0.85), LumenPalette.iris],
                      value: LumenRoute.moods)
        }
        .padding(.horizontal, LumenMetrics.gutter)
    }

    private func quickTile(_ title: String, icon: String, colors: [Color], value: LumenRoute) -> some View {
        NavigationLink(value: value) {
            quickTileLabel(title, icon: icon, colors: colors)
        }
        .buttonStyle(LumenPressStyle())
    }

    private func quickTileLabel(_ title: String, icon: String, colors: [Color]) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text(title)
                .font(LumenType.headline(14))
                .foregroundStyle(LumenPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(LumenPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(LumenPalette.hairline, lineWidth: 1))
    }

    // MARK: Shelves

    @ViewBuilder
    private var shelves: some View {
        if !snapshot.recentlyPlayed.isEmpty {
            songShelf("Recently Played", subtitle: "Pick up where you left off", songs: snapshot.recentlyPlayed)
        }

        if !onThisDayGroups.isEmpty {
            onThisDayTeaser
        }

        if !library.playlists.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .trailing) {
                    LumenSectionHeader(title: "Your Playlists")
                    seeAllLink(.playlists)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(library.playlists.prefix(15)) { playlist in
                            NavigationLink(value: LumenRoute.playlist(playlist.id)) {
                                LumenShelfCard(title: playlist.name, subtitle: LumenFormat.count(playlist.songCount, "song")) {
                                    LumenCollage(songs: library.collageSongs(from: library.songs(for: playlist)),
                                                 size: 148, radius: 18, seed: playlist.name)
                                }
                            }
                            .buttonStyle(LumenPressStyle())
                        }
                    }
                    .padding(.horizontal, LumenMetrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }

        if !snapshot.topArtistGroups.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                LumenSectionHeader(title: "Your Artists", subtitle: "The voices you keep coming back to")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(snapshot.topArtistGroups, id: \.artist) { group in
                            NavigationLink(value: LumenRoute.artist(group.artist)) {
                                VStack(spacing: 8) {
                                    ArtistAvatar(artist: group.artist, size: 104)
                                        .clipShape(Circle())
                                        .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                                        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                                    Text(group.artist)
                                        .font(LumenType.headline(13))
                                        .foregroundStyle(LumenPalette.textPrimary)
                                        .lineLimit(1)
                                        .frame(width: 104)
                                }
                            }
                            .buttonStyle(LumenPressStyle())
                        }
                    }
                    .padding(.horizontal, LumenMetrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }

        if let recap = snapshot.weeklyRecap, recap.songsPlayed > 0 {
            weeklyRecapCard(recap)
        }

        if !snapshot.recentlyAdded.isEmpty {
            songShelf("Recently Added", subtitle: "New to your library", songs: snapshot.recentlyAdded, route: .recentlyAdded)
        }

        if !snapshot.genreGroups.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                LumenSectionHeader(title: "Browse by Genre")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(snapshot.genreGroups, id: \.genre) { group in
                            NavigationLink(value: LumenRoute.genre(group.genre)) {
                                ZStack(alignment: .bottomLeading) {
                                    LumenGeneratedArt(seed: group.genre)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.genre)
                                            .font(LumenType.title(17))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                        Text(LumenFormat.count(group.songs.count, "song"))
                                            .font(LumenType.caption(11))
                                            .foregroundStyle(.white.opacity(0.8))
                                    }
                                    .padding(14)
                                }
                                .frame(width: 160, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(LumenPressStyle())
                        }
                    }
                    .padding(.horizontal, LumenMetrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }

        if !snapshot.mostPlayed.isEmpty {
            songShelf("On Repeat", subtitle: "Your most-played tracks", songs: snapshot.mostPlayed, route: .mostPlayed)
        }

        if !snapshot.forgottenFavorites.isEmpty {
            songShelf("Rediscover", subtitle: "Favorites you haven't played in a while", songs: snapshot.forgottenFavorites)
        }

        if !snapshot.deeperCuts.isEmpty {
            songShelf("Deeper Cuts", subtitle: "From the genres you love, rarely played", songs: snapshot.deeperCuts)
        }

        if !snapshot.decadeGroups.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                LumenSectionHeader(title: "Through the Decades")
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(snapshot.decadeGroups, id: \.decade) { group in
                            LumenChip(title: group.decade, systemImage: "play.fill") {
                                let songs = group.songs.smartShuffled()
                                if let first = songs.first { player.play(song: first, in: songs) }
                            }
                        }
                    }
                    .padding(.horizontal, LumenMetrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// A compact teaser for the server's "On This Day" throwback — the
    /// `.onThisDay` route already pushed the full `OnThisDayView` just
    /// fine, but nothing on Home ever actually linked to it. Mirrors
    /// Classic's `HubOnThisDayTeaser` (a real preview of today's top match,
    /// not a blind "Open On This Day" button) in Lumen's own card style.
    private var onThisDayTeaser: some View {
        let topGroup = onThisDayGroups.first
        let topTrack = topGroup?.tracks.first
        return NavigationLink(value: LumenRoute.onThisDay) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(LumenPalette.accent.opacity(0.16))
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(LumenPalette.accent)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("On This Day")
                        .font(LumenType.headline(15))
                        .foregroundStyle(LumenPalette.textPrimary)
                    if let topTrack, let year = topGroup?.year {
                        Text("\(topTrack.title) — played in \(String(year))")
                            .font(LumenType.caption(12))
                            .foregroundStyle(LumenPalette.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text("See what you were listening to on this date")
                            .font(LumenType.caption(12))
                            .foregroundStyle(LumenPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumenPalette.textSecondary)
            }
            .lumenCard(fill: LumenPalette.accent.opacity(0.08))
            .padding(.horizontal, LumenMetrics.gutter)
        }
        .buttonStyle(LumenPressStyle())
    }

    private func songShelf(_ title: String, subtitle: String, songs: [Song], route: LumenRoute? = nil) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .trailing) {
                LumenSectionHeader(title: title, subtitle: subtitle)
                if let route { seeAllLink(route) }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(songs) { song in
                        Button {
                            player.play(song: song, in: songs)
                        } label: {
                            LumenShelfCard(title: song.displayName, subtitle: song.artistName) {
                                ZStack(alignment: .bottomTrailing) {
                                    LumenArtwork(song: song, size: 148, radius: 18)
                                    if player.currentSong?.id == song.id {
                                        LumenEqualizerGlyph(isAnimating: player.isPlaying, color: .white)
                                            .padding(8)
                                            .background(.black.opacity(0.5), in: Circle())
                                            .padding(8)
                                    }
                                }
                            }
                        }
                        .buttonStyle(LumenPressStyle())
                        .songContextMenu(for: song)
                    }
                }
                .padding(.horizontal, LumenMetrics.gutter)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func seeAllLink(_ route: LumenRoute) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 3) {
                Text("See all")
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .font(LumenType.caption(13))
            .foregroundStyle(LumenPalette.accent)
        }
        .padding(.trailing, LumenMetrics.gutter)
    }

    private func weeklyRecapCard(_ recap: HubContentBuilder.HubWeeklyRecap) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THIS WEEK")
                        .font(LumenType.eyebrow())
                        .tracking(1.6)
                        .foregroundStyle(LumenPalette.accent)
                    Text("Your week in sound")
                        .font(LumenType.title(20))
                        .foregroundStyle(LumenPalette.textPrimary)
                }
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(LumenPalette.glow)
            }
            HStack(spacing: 12) {
                LumenStat(value: "\(recap.songsPlayed)", label: "Plays")
                LumenStat(value: "\(recap.estimatedMinutes)", label: "Minutes")
                if let top = recap.topArtist {
                    LumenStat(value: top, label: "Top artist")
                }
            }
            NavigationLink(value: LumenRoute.rewind) {
                HStack {
                    Text("Open your Rewind")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(LumenType.headline(14))
                .foregroundStyle(LumenPalette.textPrimary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(LumenPalette.fill, in: Capsule())
            }
            .buttonStyle(LumenPressStyle())
        }
        .lumenCard(padding: 20)
        .padding(.horizontal, LumenMetrics.gutter)
    }
}
