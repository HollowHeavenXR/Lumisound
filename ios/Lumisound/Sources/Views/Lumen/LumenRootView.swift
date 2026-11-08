import AVFoundation
import SwiftUI
import UIKit

// MARK: - Tabs

enum LumenTab: String, CaseIterable, Identifiable {
    case home, search, library, cloud, you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:    return "Home"
        case .search:  return "Search"
        case .library: return "Library"
        case .cloud:   return "Cloud"
        case .you:     return "You"
        }
    }

    var systemImage: String {
        switch self {
        case .home:    return "house"
        case .search:  return "magnifyingglass"
        case .library: return "square.stack"
        case .cloud:   return "icloud.and.arrow.down"
        case .you:     return "person.crop.circle"
        }
    }

    var selectedSystemImage: String {
        switch self {
        case .home:    return "house.fill"
        case .search:  return "magnifyingglass"
        case .library: return "square.stack.fill"
        case .cloud:   return "icloud.and.arrow.down.fill"
        case .you:     return "person.crop.circle.fill"
        }
    }
}

// MARK: - Shell

/// Root of the Lumen interface: five tab roots kept alive once visited, a
/// floating dock (mini player over a tab bar) and the full-screen player
/// sliding over everything. Carries every app-wide duty the classic
/// `ClassicContentView` performs (toasts, banners, car mode, presence, the
/// library scan on launch) so neither edition depends on the other being
/// mounted.
struct LumenRootView: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var folderService: MusicFolderService
    @EnvironmentObject private var bridgeHealth: BridgeHealthService
    @EnvironmentObject private var social: SocialService
    @ObservedObject private var toastCenter = ToastCenter.shared
    @StateObject private var presenceService = PresenceService.shared

    @AppStorage("lumen_selected_tab") private var selectedTabRaw: String = LumenTab.home.rawValue
    @AppStorage("carModeEnabled") private var carModeEnabled: Bool = false
    @AppStorage("autoCloudBackup") private var autoCloudBackup: Bool = false
    @AppStorage("lumen_welcome_seen") private var welcomeSeen = false
    /// Classic's tab index. A few shared screens (Cloud's "not configured"
    /// prompt, for one) jump the user by writing it; Lumen translates those
    /// jumps to its own destinations — see `followClassicTabRequest`.
    @AppStorage("selected_tab") private var classicSelectedTab = 0

    @State private var visitedTabs: Set<LumenTab> = []
    @State private var paths: [LumenTab: NavigationPath] = [:]
    @State private var showNowPlaying = false
    @State private var showCarMode = false
    @State private var showWelcome = false
    @State private var didBootstrapLibrary = false
    @State private var backupSyncTask: Task<Void, Never>?

    private var selectedTab: LumenTab { LumenTab(rawValue: selectedTabRaw) ?? .home }

    init() {
        // Transparent navigation bars everywhere, so the backdrop shows
        // through — the same proxy Classic sets, applied here too so Lumen
        // never depends on Classic having been constructed first.
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.backgroundColor = .clear
        navAppearance.shadowColor = .clear
        let titleColor = UIColor(LumenPalette.textPrimary)
        let rounded = UIFont.systemFont(ofSize: 17, weight: .bold).fontDescriptor.withDesign(.rounded)
        let largeRounded = UIFont.systemFont(ofSize: 34, weight: .heavy).fontDescriptor.withDesign(.rounded)
        if let rounded {
            navAppearance.titleTextAttributes = [.font: UIFont(descriptor: rounded, size: 17), .foregroundColor: titleColor]
        }
        if let largeRounded {
            navAppearance.largeTitleTextAttributes = [.font: UIFont(descriptor: largeRounded, size: 34), .foregroundColor: titleColor]
        }
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UITableView.appearance().backgroundColor = .clear
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LumenBackdrop()

            RestoreFoldersPromptView()

            ZStack {
                ForEach(LumenTab.allCases) { tab in
                    if visitedTabs.contains(tab) || tab == selectedTab {
                        tabRoot(tab)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                Color.clear.frame(height: LumenMetrics.dockHeight(hasMiniPlayer: player.currentSong != nil))
                            }
                            .opacity(tab == selectedTab ? 1 : 0)
                            .allowsHitTesting(tab == selectedTab)
                            .accessibilityHidden(tab != selectedTab)
                    }
                }
            }

            LumenDock(
                selectedTab: selectedTab,
                youBadge: social.incomingRequests.count + account.unreadNotificationCount,
                onSelect: select,
                onOpenPlayer: { openPlayer() }
            )

            if showNowPlaying {
                LumenNowPlayingView(isPresented: $showNowPlaying)
                    .transition(.move(edge: .bottom))
                    .zIndex(5)
            }

            overlays
        }
        .lumenGlobalSkin()
        .preferredColorScheme(.dark)
        .acoustIDConfirmSheet()
        .clipMakerSheet()
        .fullScreenCover(isPresented: $showCarMode) {
            CarModeView().environmentObject(player)
        }
        .sheet(isPresented: $showWelcome) {
            LumenWelcomeSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .environment(\.lumenOpenPlayer, LumenOpenPlayerAction { openPlayer() })
        .environment(\.lumenSelectTab, LumenSelectTabAction { select($0) })
        .task(id: player.currentSong?.id) {
            await LumenAmbience.shared.update(for: player.currentSong)
        }
        .onAppear {
            visitedTabs.insert(selectedTab)
            bootstrapLibrary()
            if account.isLoggedIn {
                presenceService.startHeartbeat(account: account, player: player)
            }
            Task { await social.fetchFriendRequests() }
            if !welcomeSeen && !ScreenshotMode.isActive {
                welcomeSeen = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showWelcome = true }
            }
        }
        .onChange(of: selectedTabRaw) { _, _ in
            visitedTabs.insert(selectedTab)
            appBreadcrumb("Switched to Lumen \(selectedTab.title) tab")
        }
        .onChange(of: library.allSongs.count) { _, _ in scheduleBackupSync() }
        .onChange(of: classicSelectedTab) { _, new in followClassicTabRequest(new) }
        .onReceive(account.$isLoggedIn) { loggedIn in
            if loggedIn {
                Task { await social.fetchFriendRequests() }
                presenceService.startHeartbeat(account: account, player: player)
            } else {
                presenceService.stopHeartbeat()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if account.isLoggedIn { presenceService.sendGoingOffline(account: account) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if account.isLoggedIn { presenceService.startHeartbeat(account: account, player: player) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            guard
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: reason) == .newDeviceAvailable
            else { return }
            Task { @MainActor in
                guard carModeEnabled, !showCarMode else { return }
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                if outputs.contains(where: { $0.portType == .carAudio }) { showCarMode = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumenShowCarMode)) { _ in
            showCarMode = true
        }
    }

    // MARK: Tab roots

    @ViewBuilder
    private func tabRoot(_ tab: LumenTab) -> some View {
        switch tab {
        case .cloud:
            // StreamSearchView owns its NavigationStack; it is hosted as-is
            // and picks up Lumen's palette through AppTheme.
            StreamSearchView()
        default:
            NavigationStack(path: pathBinding(for: tab)) {
                Group {
                    switch tab {
                    case .home:    LumenHomeView()
                    case .search:  LumenSearchView()
                    case .library: LumenLibraryView()
                    case .you:     LumenYouView()
                    case .cloud:   EmptyView()
                    }
                }
                .lumenDestinations()
            }
        }
    }

    private func pathBinding(for tab: LumenTab) -> Binding<NavigationPath> {
        Binding(
            get: { paths[tab] ?? NavigationPath() },
            set: { paths[tab] = $0 }
        )
    }

    private func select(_ tab: LumenTab) {
        if tab == selectedTab {
            // Re-tapping the current tab pops it back to its root.
            withAnimation(.easeInOut(duration: 0.25)) { paths[tab] = NavigationPath() }
        } else {
            UISelectionFeedbackGenerator().selectionChanged()
            selectedTabRaw = tab.rawValue
        }
    }

    private func followClassicTabRequest(_ classicTab: Int) {
        switch classicTab {
        case 0:    select(.library)
        case 1, 2: openPlayer()
        case 3:    select(.cloud)
        case 4:    push(.friends, on: .you)
        case 5:    push(.profile, on: .you)
        case 6:    push(.settings, on: .you)
        default:   break
        }
    }

    private func push(_ route: LumenRoute, on tab: LumenTab) {
        selectedTabRaw = tab.rawValue
        paths[tab] = NavigationPath([route])
    }

    private func openPlayer() {
        guard player.currentSong != nil else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showNowPlaying = true }
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        VStack(spacing: 8) {
            if bridgeHealth.showToast {
                ToastView(message: bridgeHealth.toastMessage, isSuccess: bridgeHealth.toastIsSuccess)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            ToastOverlay().allowsHitTesting(false)
            EmailPromptBanner()
            Spacer()
        }
        .padding(.top, 56)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: bridgeHealth.showToast)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toastCenter.current)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: account.needsEmail)
        .zIndex(10)
    }

    // MARK: Library bootstrap
    //
    // Classic kicks off the launch scan from LibraryView.onAppear. Lumen's
    // shell is the first thing on screen, so it does the same here.

    private func bootstrapLibrary() {
        guard !didBootstrapLibrary else { return }
        didBootstrapLibrary = true
        library.scanWatchedFolders(using: folderService)
        library.scanLocalDocuments()
        scheduleBackupSync()
    }

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
}

extension Notification.Name {
    static let lumenShowCarMode = Notification.Name("lumenShowCarMode")
}

// MARK: - Environment actions

struct LumenOpenPlayerAction {
    let run: () -> Void
    func callAsFunction() { run() }
}

struct LumenSelectTabAction {
    let run: (LumenTab) -> Void
    func callAsFunction(_ tab: LumenTab) { run(tab) }
}

private struct LumenOpenPlayerKey: EnvironmentKey {
    static let defaultValue = LumenOpenPlayerAction {}
}

private struct LumenSelectTabKey: EnvironmentKey {
    static let defaultValue = LumenSelectTabAction { _ in }
}

extension EnvironmentValues {
    var lumenOpenPlayer: LumenOpenPlayerAction {
        get { self[LumenOpenPlayerKey.self] }
        set { self[LumenOpenPlayerKey.self] = newValue }
    }

    var lumenSelectTab: LumenSelectTabAction {
        get { self[LumenSelectTabKey.self] }
        set { self[LumenSelectTabKey.self] = newValue }
    }
}

// MARK: - Dock

/// The floating bottom stack: mini player (while something is loaded) above
/// a glass tab bar.
struct LumenDock: View {
    let selectedTab: LumenTab
    let youBadge: Int
    let onSelect: (LumenTab) -> Void
    let onOpenPlayer: () -> Void

    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var account: AccountService
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 8) {
            if player.currentSong != nil {
                LumenMiniPlayer(onOpen: onOpenPlayer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            tabBar
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: player.currentSong == nil)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(LumenTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: LumenMetrics.tabBarHeight)
        .lumenGlass(in: Capsule(), fallback: LumenPalette.surface.opacity(0.92))
        .overlay(Capsule().strokeBorder(LumenPalette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
    }

    private func tabButton(_ tab: LumenTab) -> some View {
        let selected = tab == selectedTab
        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { onSelect(tab) }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    icon(for: tab, selected: selected)
                        .frame(width: 46, height: 30)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(LumenPalette.glowHorizontal)
                                    .matchedGeometryEffect(id: "tab", in: selection)
                                    .shadow(color: LumenPalette.accent.opacity(0.5), radius: 8, y: 2)
                            }
                        }
                    if tab == .you, youBadge > 0 {
                        Text("\(min(youBadge, 99))")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(LumenPalette.error, in: Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
                Text(tab.title)
                    .font(.system(size: 10, weight: selected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(selected ? LumenPalette.textPrimary : LumenPalette.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("lumen.tab.\(tab.rawValue)")
    }

    @ViewBuilder
    private func icon(for tab: LumenTab, selected: Bool) -> some View {
        if tab == .you, let avatar = account.avatarImage {
            Image(uiImage: avatar)
                .resizable()
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(selected ? Color.white : Color.white.opacity(0.2), lineWidth: 1.5))
        } else {
            Image(systemName: selected ? tab.selectedSystemImage : tab.systemImage)
                .font(.system(size: 17, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? Color.white : LumenPalette.textSecondary)
        }
    }
}

// MARK: - Mini player

struct LumenMiniPlayer: View {
    let onOpen: () -> Void

    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var progress: PlaybackProgress
    @EnvironmentObject private var library: LibraryManager

    @State private var dragOffset: CGFloat = 0
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 12) {
                LumenArtwork(song: song, size: 44, radius: 10)
                    .id(song.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.displayName)
                        .font(LumenType.headline(14))
                        .foregroundStyle(LumenPalette.textPrimary)
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(LumenType.caption(12))
                        .foregroundStyle(LumenPalette.textSecondary)
                        .lineLimit(1)
                }
                .id(song.id)
                .transition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    haptic.impactOccurred()
                    library.toggleFavorite(songID: song.id)
                } label: {
                    let fav = library.isFavorite(songID: song.id)
                    Image(systemName: fav ? "heart.fill" : "heart")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(fav ? LumenPalette.ember : LumenPalette.textSecondary)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LumenPressStyle(scale: 0.85))
                .accessibilityLabel(library.isFavorite(songID: song.id) ? "Remove from Favorites" : "Add to Favorites")

                Button {
                    haptic.impactOccurred()
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                        .background(LumenPalette.glow, in: Circle())
                }
                .buttonStyle(LumenPressStyle(scale: 0.88))
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    haptic.impactOccurred()
                    player.userSkipToNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LumenPalette.textPrimary)
                        .frame(width: 34, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LumenPressStyle(scale: 0.85))
                .accessibilityLabel("Next track")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: LumenMetrics.miniPlayerHeight)
            .background {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.clear)
                        .lumenGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                                       fallback: LumenPalette.elevated.opacity(0.95))
                    progressLine
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(LumenPalette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            .offset(x: dragOffset)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture(perform: onOpen)
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) {
                            dragOffset = value.translation.width * 0.35
                        }
                    }
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                        if dy < -40, abs(dy) > abs(dx) {
                            onOpen()
                        } else if dx < -70 {
                            haptic.impactOccurred(); player.userSkipToNext()
                        } else if dx > 70 {
                            haptic.impactOccurred(); player.skipToPrevious()
                        }
                    }
            )
            .animation(.easeInOut(duration: 0.25), value: song.id)
            .accessibilityElement(children: .contain)
            .accessibilityHint("Opens the player. Swipe sideways to change track.")
        }
    }

    private var progressLine: some View {
        GeometryReader { geo in
            let fraction = progress.duration > 0 ? min(max(progress.position / progress.duration, 0), 1) : 0
            Capsule()
                .fill(LumenPalette.glowHorizontal)
                .frame(width: max(geo.size.width - 36, 0) * fraction, height: 2.5)
                .shadow(color: LumenPalette.accent.opacity(0.8), radius: 4)
                .padding(.horizontal, 18)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 3)
                .animation(.linear(duration: 0.25), value: progress.position)
        }
    }
}
