import AVFoundation
import SwiftUI
import UIKit

// MARK: - TabTransitionStyle

enum TabTransitionStyle: String, CaseIterable, Identifiable, Codable {
    case scalePop
    case slide
    case fadeOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scalePop: return "Scale Pop"
        case .slide:    return "Slide"
        case .fadeOnly: return "Fade Only"
        }
    }
}

// MARK: - NavbarDisplayMode

/// The two modes `CustomTabBar` can render as, without ever changing the
/// oval bar's own footprint (height/shape) — only what's drawn inside it.
/// User-switchable from both Settings (Appearance) and Now Playing, sharing
/// the same `@AppStorage` key so either surface always reflects the other's
/// current choice.
enum NavbarDisplayMode: String, CaseIterable, Identifiable {
    /// The original always-visible 7-tab row.
    case tabs
    /// Replaces the tab row with a compact "Informative MiniPlayer" —
    /// circular artwork, marquee title, seeker, and transport controls —
    /// while a song is loaded. Falls back to `.tabs` content when nothing
    /// is playing, since an empty mini player would be a dead end with no
    /// way to navigate anywhere.
    case miniPlayer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tabs:       return "Tabs"
        case .miniPlayer: return "Mini Player"
        }
    }
}

// MARK: - NavbarSelectionStyle

/// Customization option for `CustomTabBar`'s `.tabs` mode — how the
/// currently-selected tab is highlighted. Part of "give users customization
/// options" for that mode, alongside `showTabLabels` below.
enum NavbarSelectionStyle: String, CaseIterable, Identifiable {
    /// The original look: a small glass "bubble" behind just the icon.
    case glassPill
    /// A thin colored line under the whole button (icon + label).
    case underline
    /// A full capsule background behind the whole button, matching the
    /// Settings screen's own tab-picker style (see `SettingsView.tabPicker`).
    case filledCapsule

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glassPill:     return "Glass Pill"
        case .underline:     return "Underline"
        case .filledCapsule: return "Filled Capsule"
        }
    }
}

// MARK: - ContentView

/// Root of the app's UI. Hosts whichever interface edition is selected —
/// the Lumen redesign (`LumenRootView`) or the original interface
/// (`ClassicContentView`, unchanged) — and rebuilds the tree when the user
/// switches, so every `AppTheme` read picks up the new edition's palette.
struct ContentView: View {
    @AppStorage(InterfaceEdition.storageKey) private var editionRaw: String = InterfaceEdition.current.rawValue
    /// Both editions read colors through static getters, so a new interface
    /// style repaints by rebuilding the tree (tabs persist; see `commitPalette`).
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        let edition = InterfaceEdition(rawValue: editionRaw) ?? .lumen
        // UIKit-drawn controls (segmented pickers, switches…) take their
        // look from appearance proxies, which only affect views created
        // afterwards — so the skin is set before the tree below is built.
        let _ = LumenUIKitSkin.apply(edition)
        Group {
            switch edition {
            case .lumen:   LumenRootView()
            case .classic: ClassicContentView()
            }
        }
        .id("\(editionRaw)-\(appearance.paletteStamp)")
        .transition(.opacity)
    }
}

// MARK: - ClassicContentView

/// The original interface, exactly as it shipped before Lumen.
struct ClassicContentView: View {

    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var bridgeHealth: BridgeHealthService
    @EnvironmentObject private var social: SocialService
    @EnvironmentObject private var library: LibraryManager
    @ObservedObject private var toastCenter = ToastCenter.shared

    /// Persists the last-selected tab across launches.
    @AppStorage("selected_tab") private var selectedTab = 0
    /// Same key `CustomTabBar` reads to decide which tabs to render — kept
    /// here too so this view can redirect away from a tab the user just hid
    /// while it was the active one (see the `.onChange` below), rather than
    /// leaving them stranded on a screen with no corresponding bar button.
    @AppStorage("navbarHiddenTabs") private var hiddenTabsRaw: String = ""
    @State private var showCarMode = false

    /// Drives a quick scale "pop" on the freshly-selected tab's content —
    /// dips slightly below 1.0 then springs back to 1.0 each time the tab changes.
    @State private var tabPopScale: CGFloat = 1.0
    /// Vertical dip used by the "Slide" transition style.
    @State private var tabSlideOffset: CGFloat = 0
    /// Opacity dip used by the "Slide" and "Fade Only" transition styles.
    @State private var tabContentOpacity: Double = 1.0
    @AppStorage("tab_transition_style") private var tabTransitionStyleRaw: String = TabTransitionStyle.scalePop.rawValue

    /// Full-view transition screen state — see `TabTransitionOverlay`/
    /// `TransitionContext`. `shownTransitionContexts` is session-only
    /// (plain `@State`, not persisted) so each of these fires once per
    /// launch, the first time its tab is actually opened — not on every
    /// return visit, which would make routine navigation feel much slower.
    /// Always on, no Settings toggle, by design.
    @State private var activeTransition: TransitionContext? = nil
    @State private var shownTransitionContexts: Set<TransitionContext> = []
    /// Locked in once, at the moment a transition starts (inside
    /// `.onChange(of: selectedTab)`) — NOT recomputed inside `body`, which
    /// re-evaluates on every state change and would make advancing/mutating
    /// state from within it undefined behavior.
    @State private var activeTransitionAnimationStyle: ProfileEffectStyle = .aurora
    @State private var lastTransitionAnimationStyle: ProfileEffectStyle? = nil

    /// Set in Settings → Playback. When off, the floating Car Mode button is
    /// hidden and connecting to a car stereo no longer auto-presents it.
    @AppStorage("carModeEnabled") private var carModeEnabled: Bool = false

    /// Self "I'm online" heartbeat for the Social Ecosystem presence feature
    /// (POST /api/social/presence every ~45s while foregrounded). Owned here
    /// rather than injected from LumisoundApp — ContentView is the one view
    /// mounted for the app's entire foreground lifetime, so it's the natural
    /// place to start/stop it on login/logout and to fire a best-effort
    /// "going offline" beacon on backgrounding (see the notification
    /// subscriptions at the bottom of `body`). Wraps the shared singleton
    /// (see `PresenceService.shared`'s doc comment) rather than a private
    /// instance — `LiveUpdateService`'s presence-event callback (wired from
    /// `AccountService`) delivers to `.shared`, and `FriendsListView`/
    /// `PublicProfileView` need to see those same live-pushed updates, so
    /// all three must share one instance instead of each polling
    /// independently.
    @StateObject private var presenceService = PresenceService.shared

    init() {
        // The native UITabBar itself is hidden (see `.toolbar(.hidden, for:
        // .tabBar)` in `body`) in favor of `CustomTabBar` below, which is
        // what makes a 7th tab a horizontal-scroll rather than getting
        // silently collapsed into iOS's automatic "More" tab (the native
        // UITabBarController does that itself past 5 items on iPhone). That
        // alone only hides the bar's CHROME, though — hiding the drawn
        // bar doesn't stop UITabBarController from applying that same
        // collapsing behavior internally to whichever view controllers a
        // `TabView` hands it, invisibly to SwiftUI. `body` avoids the actual
        // trigger by never giving any single `TabView` more than 5 real
        // `.tag()`ed children in the first place (see the comment above that
        // `TabView` there) — the two tabs beyond that are rendered as
        // sibling branches outside any TabView entirely, where
        // UITabBarController has no involvement at all. No UITabBarAppearance
        // configuration needed here as a result.

        // Navigation bar — fully transparent so gallery background shows
        // through, for EVERY UINavigationBar in the app (this is the sole
        // source of that transparency — nothing else needs to touch nav bar
        // appearance). A handful of individual screens used to ALSO call
        // the modern SwiftUI `.toolbarBackground(.hidden, for:
        // .navigationBar)` on top of this, redundantly re-requesting the
        // same transparent background this proxy already guarantees
        // app-wide. Under iOS 26's Liquid Glass, that double-application
        // left two independent back-button layers rendered on those
        // specific screens (a legacy UIKit one underneath the new floating
        // glass one) — visible as two stacked circular back buttons. Fixed
        // by removing those redundant per-screen calls (see e.g.
        // SettingsView.swift, LibraryView.swift) rather than touching this
        // proxy, since every other screen in the app relies on this being
        // the ONLY thing making its nav bar transparent.
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.backgroundColor = .clear
        navAppearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        // List/TableView — clear background so gallery shows through list rows.
        UITableView.appearance().backgroundColor = .clear
    }

    var body: some View {
        ZStack {
            GalleryBackgroundView()
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Invisible — checks once per install whether the server has a
            // backed-up watched-folder structure for this account and, if so,
            // prompts to redownload tracks back into their original folders.
            RestoreFoldersPromptView()

            // `.tabItem{}` below is vestigial — it's what a *visible* native
            // UITabBar would render, but that bar is hidden (see
            // `.toolbar(.hidden, for: .tabBar)`) in favor of `CustomTabBar`.
            // It's left in place anyway because `.tag()` is what `TabView`
            // uses to route `selection:`, and each `.tabItem{}` still gives
            // VoiceOver a label for the (invisible) native item — harmless
            // either way, just unused visually.
            //
            // Only tags 0-4 (5 tabs) are real `TabView` children — NOT all 7.
            // Hiding the native bar's chrome (`.toolbar(.hidden, for:
            // .tabBar)` below) only hides what's drawn on screen; it does
            // NOT stop `UITabBarController` from applying its own automatic
            // "collapse past the 5th item into 'More'" behavior to
            // WHICHEVER view controllers TabView hands it, entirely beneath
            // SwiftUI's abstraction. With all 7 tabs previously routed
            // through one TabView, selecting Friends/Profile/Settings
            // (items 5-7) could land on that hidden native "More" list
            // screen instead of the real tab content — a genuinely
            // different, still-functioning UIKit navigation controller
            // most of this app's UI never expected to be reachable, visible
            // as a second, unstyled back button leading to it. Keeping this
            // TabView's real child count at 5 (at, not past, the threshold)
            // means UIKit never has a reason to collapse anything — Profile
            // and Settings are rendered as sibling branches below instead,
            // fully outside any TabView/UITabBarController, where this
            // failure mode structurally cannot occur.
            Group {
                if selectedTab <= 4 {
                    TabView(selection: $selectedTab) {

                        // MARK: Tab 1 — Library
                        LibraryView()
                            .toolbar(.hidden, for: .tabBar)
                            .tabItem {
                                Label("Library", systemImage: "music.note.list")
                            }
                            .tag(0)

                        // MARK: Tab 2 — Now Playing
                        NowPlayingView()
                            .toolbar(.hidden, for: .tabBar)
                            .tabItem {
                                Label("Playing", systemImage: "play.circle")
                            }
                            .tag(1)

                        // MARK: Tab 3 — Queue
                        QueueView()
                            .toolbar(.hidden, for: .tabBar)
                            .tabItem {
                                Label("Queue", systemImage: "list.number")
                            }
                            .tag(2)

                        // MARK: Tab 4 — Search Streaming
                        StreamSearchView()
                            .toolbar(.hidden, for: .tabBar)
                            .tabItem {
                                Label("Cloud Services", systemImage: "icloud.and.arrow.down")
                            }
                            .tag(3)

                        // MARK: Tab 5 — Friends
                        // Its own NavigationStack since FriendsListView (like
                        // ProfileView below) is normally pushed from AccountView's
                        // Social section rather than hosted as a tab root.
                        NavigationStack {
                            FriendsListView()
                                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                        }
                            .toolbar(.hidden, for: .tabBar)
                            .tabItem {
                                Label("Friends", systemImage: "person.2.fill")
                            }
                            .tag(4)
                    }
                    // `.toolbar(.hidden, for: .tabBar)` has to be applied to
                    // each tab's OWN content (above), not to the TabView
                    // itself — it reads as a preference that bubbles up from
                    // whichever content is currently on screen, and applying
                    // it directly to the TabView container is a no-op the
                    // native UITabBar silently ignores.
                } else if selectedTab == 5 {
                    // MARK: Tab 6 — Profile (sibling branch, not a TabView
                    // child — see the comment above `Group`)
                    NavigationStack {
                        MyProfileTabView()
                            .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                    }
                } else {
                    // MARK: Tab 7 — Settings (sibling branch, not a TabView
                    // child — see the comment above `Group`). No
                    // MiniPlayerBar here, matching this tab's existing
                    // design (SettingsView has never shown one).
                    SettingsView()
                }
            }
            // Attached directly to the `Group` (not the TabView specifically
            // — this bar has to render identically across all three
            // branches above) so it sits flush against the real system safe
            // area (home indicator) — the bottommost element on screen,
            // same as any normal tab bar. NOTE: a `.safeAreaInset` applied
            // here does NOT propagate down into the TabView branch's own
            // tab content — SwiftUI/UIKit hosts each `.tabItem{}` page in
            // its own separate hierarchy, and safe-area/environment
            // propagation doesn't cross that boundary. That means each of
            // those tabs' own `.safeAreaInset(edge: .bottom) {
            // MiniPlayerBar() }` has no idea this bar exists and, left
            // alone, places MiniPlayerBar flush against that same real
            // bottom safe area — the two end up stacked in the exact same
            // place instead of MiniPlayerBar sitting above this bar (the
            // correct order — a first attempt at fixing their overlap had
            // this backwards, shifting the tab bar itself up instead of the
            // mini player). Fixed properly in `MiniPlayerBar` itself (see
            // its own doc comment), which now reserves
            // `CustomTabBar.totalHeight` of extra bottom padding so it
            // always renders above this bar rather than trying to make the
            // cross-branch safe-area propagation work (it structurally
            // can't).
            .safeAreaInset(edge: .bottom) {
                CustomTabBar(
                    selectedTab: $selectedTab,
                    hasCurrentSong: player.currentSong != nil,
                    avatarImage: account.avatarImage,
                    incomingFriendRequestCount: social.incomingRequests.count
                )
            }
            .tint(AppTheme.dynamicAccent)
            // Subtle cross-fade + "pop" scale-in between tabs. iOS 16 doesn't expose
            // a way to animate transitions *between* TabView pages or to animate the
            // native tab-bar icons themselves (`.symbolEffect(.bounce)` needs iOS 17),
            // so this gives the newly-selected tab's content a quick settle-in instead.
            .scaleEffect(tabPopScale)
            .offset(y: tabSlideOffset)
            .opacity(tabContentOpacity)
            .animation(.easeInOut(duration: 0.18), value: selectedTab)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: tabPopScale)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: tabSlideOffset)
            .animation(.easeInOut(duration: 0.15), value: tabContentOpacity)
            // Crash-context breadcrumb — "what was the user doing right before
            // the crash" is the single most useful fact for diagnosing reports
            // like "it just freezes/crashes sometimes". See AppLogger.breadcrumb.
            .onChange(of: selectedTab) { newValue in
                let names = ["Library", "Playing", "Queue", "Cloud Services", "Friends", "Profile", "Settings"]
                let name = names.indices.contains(newValue) ? names[newValue] : "tab \(newValue)"
                appBreadcrumb("Switched to \(name) tab")
                // Screen-view telemetry — there was previously no record at
                // all of what screen a user is actually looking at (only
                // the crash-context breadcrumb above, which stays on-device
                // and is only ever read back after a crash). Routed through
                // the existing batched/15s-flush AppLogger pipeline, not
                // RemoteLogger's unbatched one-POST-per-call path — a tab
                // switch is a discrete, low-frequency event (nothing like a
                // position tick), but it's still exactly the kind of thing
                // that pipeline's batching exists for.
                appLog("screen_entered: \(name)", category: "navigation")

                // Settle-in transition on the newly-selected tab's content —
                // style picked in Settings → Appearance. iOS 16 doesn't expose
                // a way to animate transitions *between* TabView pages or the
                // native tab-bar icons themselves, so all three styles work by
                // dipping then springing/fading back on the content itself.
                switch TabTransitionStyle(rawValue: tabTransitionStyleRaw) ?? .scalePop {
                case .scalePop:
                    tabPopScale = 0.98
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        tabPopScale = 1.0
                    }
                case .slide:
                    tabSlideOffset = 14
                    tabContentOpacity = 0.5
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        tabSlideOffset = 0
                        tabContentOpacity = 1.0
                    }
                case .fadeOnly:
                    tabContentOpacity = 0.3
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        tabContentOpacity = 1.0
                    }
                }

                // Full-view transition screen — see `TabTransitionOverlay`.
                // Library only qualifies while a scan is genuinely running
                // (otherwise it's already instant, nothing to cover); Cloud
                // Services/Friends/Profile qualify once each, the first time
                // this session they're actually opened.
                let qualifies: Bool
                let context: TransitionContext?
                switch newValue {
                case 0:
                    context = .library
                    qualifies = library.isScanning
                case 3:
                    context = .cloudServices
                    qualifies = true
                case 4:
                    context = .friends
                    qualifies = true
                case 5:
                    context = .profile
                    qualifies = true
                default:
                    context = nil
                    qualifies = false
                }
                if let context, qualifies, !shownTransitionContexts.contains(context) {
                    shownTransitionContexts.insert(context)
                    // Picks a style different from whichever one played last
                    // (when there's more than one to choose from) so two
                    // transitions never look identical back to back.
                    var candidates = ProfileEffectStyle.allCases.filter { $0 != .none }
                    if candidates.count > 1, let last = lastTransitionAnimationStyle {
                        candidates.removeAll { $0 == last }
                    }
                    let style = candidates.randomElement() ?? .aurora
                    lastTransitionAnimationStyle = style
                    activeTransitionAnimationStyle = style
                    activeTransition = context
                }
            }
            // No explicit .frame() on TabView — it must size itself from its content.
            // An explicit frame here can cause stretch/overflow on certain device sizes.
            .onChange(of: hiddenTabsRaw) { _ in
                // A tab was just hidden while it was the active one — jump
                // to the first still-visible tab instead of leaving the
                // user on a screen with no corresponding bar button.
                // Settings (6) is never hideable (see CustomTabBar.hiddenTabs)
                // so this can always fall back to it as a last resort.
                let hidden = Set(hiddenTabsRaw.split(separator: ",").compactMap { Int($0) })
                if hidden.contains(selectedTab) {
                    selectedTab = (0...6).first { !hidden.contains($0) } ?? 6
                }
            }

            // MARK: Full-view transition screen — see `TabTransitionOverlay`.
            // Above everything else (including CustomTabBar) since it's a
            // genuine full-screen cover, not a small floating element like
            // the toasts below.
            if let activeTransition {
                TabTransitionOverlay(
                    context: activeTransition,
                    animationStyle: activeTransitionAnimationStyle,
                    onFinished: { self.activeTransition = nil }
                )
                .transition(.opacity)
                .zIndex(10)
            }

            // MARK: Bridge Health Toast — floats above all content
            if bridgeHealth.showToast {
                VStack {
                    ToastView(message: bridgeHealth.toastMessage, isSuccess: bridgeHealth.toastIsSuccess)
                        .padding(.top, 56)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: bridgeHealth.showToast)
                .allowsHitTesting(false)
            }

            // MARK: App-wide categorized toasts — favorites, playlists, downloads, etc.
            VStack {
                ToastOverlay()
                    .padding(.top, 56)
                Spacer()
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toastCenter.current)
            .allowsHitTesting(false)

            // MARK: "Add an email address" prompt for accounts created before one
            // was required. Separate layer from the toasts above because it is
            // interactive — those are `.allowsHitTesting(false)`, which would
            // swallow this banner's own Add/Later buttons. Hides itself entirely
            // when the account has an address or the prompt is snoozed.
            VStack {
                EmailPromptBanner()
                    .padding(.top, 56)
                Spacer()
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: account.needsEmail)
        }
        .acoustIDConfirmSheet()
        .clipMakerSheet()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fullScreenCover(isPresented: $showCarMode) {
            CarModeView()
                .environmentObject(player)
        }
        // Floating car-mode button — top-right corner above tab bar content.
        // Hidden entirely when the user disables Car Mode in Settings → Playback.
        .overlay(alignment: .topTrailing) {
            if carModeEnabled {
                Button {
                    showCarMode = true
                } label: {
                    Image(systemName: "car.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.dynamicAccent)
                        .padding(10)
                        .adaptiveGlass(tint: AppTheme.dynamicAccent, in: Circle())
                }
                .padding(.trailing, 16)
                .padding(.top, 56)
            }
        }
        // Auto-activate when a genuine car stereo / CarPlay route becomes available.
        //
        // AVAudioSession posts route-change notifications from an internal audio
        // thread, NOT necessarily the main thread — mutating `@State` here directly
        // is a SwiftUI threading violation ("Publishing changes from background
        // threads is not allowed") that can crash the app the instant *any*
        // Bluetooth device connects or disconnects. Hop to the main actor first.
        //
        // Also narrowed the trigger from "any Bluetooth A2DP device" (which
        // matches ordinary headphones/earbuds too) to `.carAudio` only, so
        // pairing regular Bluetooth headphones no longer force-switches into
        // Car Mode — and guard against re-presenting an already-visible sheet.
        .onReceive(
            NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
        ) { notification in
            guard
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: reason) == .newDeviceAvailable
            else { return }
            Task { @MainActor in
                guard carModeEnabled, !showCarMode else { return }
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                let isCarAudio = outputs.contains { $0.portType == .carAudio }
                if isCarAudio { showCarMode = true }
            }
        }
        // Keeps the Friends tab's request-count badge (in CustomTabBar) fresh
        // without requiring a visit to the Friends tab first — same
        // "refresh on appear + on login" shape as the presence heartbeat below.
        .onAppear {
            Task { await social.fetchFriendRequests() }
        }
        .onReceive(account.$isLoggedIn) { loggedIn in
            if loggedIn {
                Task { await social.fetchFriendRequests() }
            }
        }
        // MARK: Social Ecosystem — presence heartbeat
        //
        // Starts/stops the "I'm online" polling heartbeat (POST
        // /api/social/presence every ~45s) alongside login state, same
        // start/stop-on-`$isLoggedIn` shape LumisoundApp already uses for
        // `account.startAutoPushTimer`/`stopAutoPushTimer`.
        .onAppear {
            if account.isLoggedIn {
                presenceService.startHeartbeat(account: account, player: player)
            }
        }
        .onReceive(account.$isLoggedIn) { loggedIn in
            if loggedIn {
                presenceService.startHeartbeat(account: account, player: player)
            } else {
                presenceService.stopHeartbeat()
            }
        }
        // Best-effort "going offline" beacon — not guaranteed to land (the
        // process may suspend mid-request), but the server's own 90s
        // presence-freshness window already covers the case where it
        // doesn't (see ios_presence_state's doc comment in schema.sql).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if account.isLoggedIn {
                presenceService.sendGoingOffline(account: account)
            }
        }
        // Resume the heartbeat immediately on return to foreground, rather
        // than waiting up to ~45s for the next scheduled tick.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if account.isLoggedIn {
                presenceService.startHeartbeat(account: account, player: player)
            }
        }
    }
}

// MARK: - MyProfileTabView

/// The Profile tab's actual root content: the signed-in user's own
/// read-only public profile (`PublicProfileView`, self-preview) with an
/// "Edit Profile" button, rather than jumping straight into `ProfileView`'s
/// editor the way this tab used to. The editor is now a pushed destination
/// reached by tapping that button, on the same `NavigationStack` tab 6
/// already wraps this in — keeping back-button behavior consistent with
/// every other tab-root-to-detail push in this app (e.g. Friends ->
/// FriendsListView).
struct MyProfileTabView: View {
    @EnvironmentObject private var account: AccountService
    @State private var showEditor = false

    var body: some View {
        Group {
            if let userId = account.currentUser?.id {
                PublicProfileView(userId: userId, isSelfPreview: true) {
                    showEditor = true
                }
            } else {
                ProgressView().tint(AppTheme.dynamicAccent)
            }
        }
        .navigationDestination(isPresented: $showEditor) {
            ProfileView()
        }
    }
}

// MARK: - CustomTabBar

/// A fully custom bottom tab bar, replacing the native (hidden) `UITabBar`,
/// showing all 7 tabs as equal always-visible entries — unlike the native
/// `UITabBarController`, which automatically collapses anything past the
/// 5th item into an unstyled "More" list on iPhone. Purely hiding that
/// native bar's chrome doesn't stop the collapsing behavior itself, though
/// (it's driven by view-controller count, not visibility) — this bar's tap
/// targets stay decoupled from that entirely because `body`'s `TabView`
/// only ever holds 5 real `.tag()`ed children; the other 2 render as
/// sibling branches with no `TabView`/`UITabBarController` involved (see
/// the comment above that `TabView`). Wrapping the row in a horizontal
/// `ScrollView` means it degrades gracefully — spreads evenly across the
/// screen when everything fits (the common case), scrolls instead of
/// clipping when it doesn't (smaller phones, larger Dynamic Type sizes) —
/// rather than ever silently hiding a tab the way the native "More"
/// collapsing would have.
struct CustomTabBar: View {
    @Binding var selectedTab: Int
    let hasCurrentSong: Bool
    let avatarImage: UIImage?
    let incomingFriendRequestCount: Int

    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var progress: PlaybackProgress

    /// Shared with Settings (Appearance) and Now Playing's own toggle — see
    /// `NavbarDisplayMode`'s doc comment.
    @AppStorage("navbarDisplayMode") private var navbarMode: NavbarDisplayMode = .tabs

    /// Tab-bar-mode customization, both set from Settings (Appearance) — see
    /// `NavbarSelectionStyle`'s doc comment.
    @AppStorage("navbarShowTabLabels") private var showTabLabels: Bool = true
    @AppStorage("navbarSelectionStyle") private var selectionStyle: NavbarSelectionStyle = .glassPill
    /// "Allow users to hide different tabs" — comma-joined tag numbers, set
    /// from Settings -> Appearance -> Hidden Tabs. Settings (tag 6) can
    /// never actually be hidden regardless of what's stored here (see
    /// `specs` below) — hiding the one screen that contains the toggle to
    /// un-hide tabs would strand a user with no way back.
    @AppStorage("navbarHiddenTabs") private var hiddenTabsRaw: String = ""

    /// The bar's total footprint from the true bottom safe-area edge
    /// (`.frame(height:)` + its own bottom `.padding`) — `MiniPlayerBar`
    /// reserves this much extra bottom padding so it always renders above
    /// this bar rather than the two overlapping. Not `private` for exactly
    /// that cross-file reference; internal (module-wide) is intentional.
    static let totalHeight: CGFloat = 60

    /// Drives the sliding selection pill below via `matchedGeometryEffect` —
    /// shared across every tab button so SwiftUI animates the *same* pill
    /// moving from the old selected button's frame to the new one, instead
    /// of one pill fading out while a separate one fades in at the new spot.
    @Namespace private var selectionNamespace

    private struct TabSpec {
        let tag: Int
        let title: String
        let systemImage: String
    }

    /// Parsed from `hiddenTabsRaw` — tag 6 (Settings) is filtered back out
    /// unconditionally even if it somehow ended up in there, since that's
    /// the one screen containing the toggle to un-hide everything else.
    private var hiddenTabs: Set<Int> {
        Set(hiddenTabsRaw.split(separator: ",").compactMap { Int($0) }).subtracting([6])
    }

    private var specs: [TabSpec] {
        [
            TabSpec(tag: 0, title: "Library", systemImage: "music.note.list"),
            TabSpec(tag: 1, title: "Playing", systemImage: hasCurrentSong ? "play.circle.fill" : "play.circle"),
            TabSpec(tag: 2, title: "Queue", systemImage: "list.number"),
            TabSpec(tag: 3, title: "Cloud Services", systemImage: "icloud.and.arrow.down"),
            TabSpec(tag: 4, title: "Friends", systemImage: "person.2.fill"),
            TabSpec(tag: 5, title: "Profile", systemImage: "person.crop.circle"),
            TabSpec(tag: 6, title: "Settings", systemImage: "gearshape"),
        ].filter { !hiddenTabs.contains($0.tag) }
    }

    var body: some View {
        // Both modes share this exact outer shape/size — height, capsule,
        // padding — so switching modes (Settings, or Now Playing's own
        // toggle) never changes the bar's footprint, only what's drawn
        // inside it, per the redesign's core constraint.
        Group {
            if navbarMode == .miniPlayer, player.currentSong != nil {
                miniPlayerContent
            } else {
                tabListContent
            }
        }
        .frame(height: 58)
        .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface)
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
        // Cross-fades between the two very different layouts instead of a
        // hard cut — covers both an explicit mode switch and mini-player
        // mode silently falling back to the tab row when playback stops.
        .animation(.easeInOut(duration: 0.25), value: navbarMode)
        .animation(.easeInOut(duration: 0.25), value: player.currentSong == nil)
        // Swipe up/down on the bar itself as a faster alternative to the
        // Settings/Now Playing toggle for switching Navbar Mode.
        // `.simultaneousGesture` (not `.gesture`) deliberately doesn't
        // claim exclusive priority — a plain `.gesture` here would compete
        // with `tabListContent`'s horizontal ScrollView and every button's
        // own tap gesture underneath it, breaking normal tab taps/scrolling.
        // A high minimum distance plus requiring the drag to be
        // meaningfully MORE vertical than horizontal keeps this from
        // firing on an ordinary horizontal scroll or tap.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dy) > 30, abs(dy) > abs(dx) * 1.5 else { return }
                    navbarModeSwipeHaptic.impactOccurred()
                    navbarMode = navbarMode == .miniPlayer ? .tabs : .miniPlayer
                }
        )
    }

    private let navbarModeSwipeHaptic = UIImpactFeedbackGenerator(style: .medium)

    private var tabListContent: some View {
        GeometryReader { outerGeo in
            ScrollView(.horizontal, showsIndicators: false) {
                // `GlassEffectContainer` is what actually makes the Glass
                // Pill selection indicator a *true* Liquid Glass morph (the
                // same fluid, refractive blob-glide system tab bars use)
                // instead of a plain resize/cross-fade. `iconView`'s pill
                // gives every instance the SAME `.glassEffectID("selectedTabPill",
                // in:)` — as long as all of those instances render inside one
                // shared container, the system interpolates ONE continuous
                // glass shape gliding/reshaping between tab positions rather
                // than rendering two independent glass layers and letting
                // `matchedGeometryEffect` merely animate their frames (which
                // is what this looked like before: a resizing circle, not
                // glass actually flowing between positions).
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(specs, id: \.tag) { spec in
                            tabButton(spec)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    // Forces the row to spread evenly across the bar's real
                    // available width when everything fits (a plain HStack in a
                    // ScrollView would otherwise hug the leading edge instead of
                    // filling the bar like a normal tab bar), while still
                    // letting it grow past that width — and scroll — if the
                    // content needs more room than the screen has.
                    .frame(minWidth: max(outerGeo.size.width - 12, 0))
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    // MARK: - Informative MiniPlayer mode

    /// The compact "Informative MiniPlayer" that replaces the tab row when
    /// `navbarMode == .miniPlayer` and a song is loaded: circular artwork,
    /// a marquee title (auto-scrolls when too long — `MarqueeText` already
    /// does exactly this, reused as-is) above a thin seeker, and
    /// previous/play-pause/next transport controls — resized to fit this
    /// bar's existing 58pt height rather than changing it.
    private var miniPlayerContent: some View {
        HStack(spacing: 10) {
            miniPlayerArtwork
                .contentShape(Rectangle())
                .onTapGesture { selectedTab = 1 }

            VStack(alignment: .leading, spacing: 4) {
                if let song = player.currentSong {
                    MarqueeText(text: song.displayName, font: .system(size: 12, weight: .semibold), color: AppTheme.textPrimary)
                        .frame(height: 14)
                }
                miniPlayerSeeker
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedTab = 1 }

            miniPlayerTransportControls
        }
        .padding(.horizontal, 12)
    }

    private var miniPlayerArtwork: some View {
        Group {
            if let song = player.currentSong {
                ArtworkThumbnail(song: song, size: 40)
            } else {
                Circle().fill(AppTheme.surface)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var miniPlayerSeeker: some View {
        GeometryReader { geo in
            let fraction = progress.duration > 0 ? progress.position / progress.duration : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.textSecondary.opacity(0.25))
                    .frame(height: 3)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.dynamicAccent, AppTheme.dynamicAccentSecondary],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)), height: 3)
                    .animation(.linear(duration: 0.25), value: progress.position)
            }
        }
        .frame(height: 3)
    }

    private var miniPlayerTransportControls: some View {
        HStack(spacing: 14) {
            Button {
                player.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.dynamicAccent, AppTheme.dynamicAccentSecondary],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
            }
            .buttonStyle(PressableButtonStyle())
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: player.isPlaying)

            Button {
                player.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    @ViewBuilder
    private func tabButton(_ spec: TabSpec) -> some View {
        let isSelected = selectedTab == spec.tag
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                selectedTab = spec.tag
            }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    iconView(for: spec)
                    if spec.tag == 4, incomingFriendRequestCount > 0 {
                        Text("\(min(incomingFriendRequestCount, 99))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(AppTheme.error, in: Circle())
                            .offset(x: 9, y: -6)
                    }
                }
                // Tab-bar-mode customization: labels can be hidden entirely
                // (icon-only bar) via Settings → Appearance.
                if showTabLabels {
                    Text(spec.title)
                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                }
                // Underline style's indicator — an empty-but-reserved-space
                // capsule when unselected (rather than the row's height
                // shifting depending on selection) keeps every button the
                // same height regardless of which one is currently active.
                if selectionStyle == .underline {
                    Capsule()
                        .fill(isSelected ? AppTheme.dynamicAccent : Color.clear)
                        .frame(width: 18, height: 3)
                }
            }
            // Only the text/icon *color* changes for the selected tab in the
            // default Glass Pill style — matching the plain native tab bar's
            // look — the sliding glass highlight is scoped to just the icon
            // (see `iconView`), not this whole button, so it never covers
            // the label. The Filled Capsule style below is the one exception
            // that highlights the whole button instead.
            .foregroundStyle(isSelected ? AppTheme.dynamicAccent : AppTheme.textSecondary)
            .padding(.vertical, 6)
            .padding(.horizontal, selectionStyle == .filledCapsule ? 6 : 0)
            .frame(minWidth: 58)
            .background {
                if selectionStyle == .filledCapsule, isSelected {
                    Capsule()
                        .fill(AppTheme.dynamicAccent.opacity(0.18))
                        .matchedGeometryEffect(id: "selectedTabCapsule", in: selectionNamespace)
                        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: selectedTab)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Stable handle for UI tests; the visible label can be hidden in Settings.
        .accessibilityIdentifier("tab.\(spec.tag)")
    }

    /// The Profile tab (tag 5) shows the user's real avatar instead of a
    /// system symbol — animated live via `AnimatedImageView` when it's a
    /// genuine multi-frame GIF, which is the entire point of this custom
    /// bar existing: a native `.tabItem{}` only ever accepts `Image`/`Text`
    /// content, so there was previously no supported way to make a tab
    /// icon actually animate without compositing a second view on top of
    /// the real (hidden) tab bar at a guessed screen position.
    @ViewBuilder
    private func iconView(for spec: TabSpec) -> some View {
        let isSelected = selectedTab == spec.tag
        Group {
            if spec.tag == 5, let avatarImage {
                Group {
                    if (avatarImage.images?.count ?? 0) > 1 {
                        AnimatedImageView(image: avatarImage, contentMode: .scaleAspectFill)
                    } else {
                        Image(uiImage: avatarImage)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(Circle())
            } else {
                Image(systemName: spec.systemImage)
                    .font(.system(size: 19))
                    .frame(width: 22, height: 22)
            }
        }
        // Fixed, modest 34×34 tap/highlight target around JUST the icon —
        // explicitly sized (not inherited from the button's full frame) so
        // the sliding selection pill is a small "bubble" behind the icon
        // like a native Liquid Glass tab bar, not a shape that can inherit
        // some other ambient/ideal size. A first pass at this let the pill
        // balloon into a giant circle that covered the icon AND the label
        // text underneath it — this fixed frame is what prevents that.
        .frame(width: 34, height: 34)
        .background {
            // Scoped to the Glass Pill style specifically — the Underline
            // and Filled Capsule styles (see `tabButton`) draw their own,
            // differently-shaped selection indicators instead.
            if isSelected, selectionStyle == .glassPill {
                Color.clear
                    .adaptiveGlass(tint: AppTheme.dynamicAccent.opacity(0.5), in: Circle(), fallback: AppTheme.dynamicAccent.opacity(0.18))
                    // `glassEffectID` (not `matchedGeometryEffect`) is what
                    // makes this a true Liquid Glass morph — every selected
                    // tab's pill shares this same id within `tabListContent`'s
                    // `GlassEffectContainer`, so the system renders ONE
                    // continuous glass shape fluidly gliding/reshaping
                    // between tab positions (real refraction/specular
                    // behavior, like the system tab bar) instead of two
                    // independently-glass-rendered circles whose FRAME
                    // `matchedGeometryEffect` merely cross-fades/resizes
                    // between.
                    .glassEffectID("selectedTabPill", in: selectionNamespace)
                    // Explicit animation tied directly to the same state
                    // this pill's presence depends on — a defensive backstop
                    // in case the transaction from `withAnimation` in the
                    // button's action doesn't carry through cleanly (e.g. if
                    // `selectedTab` changes from somewhere else, like
                    // MiniPlayerBar jumping to the Playing tab). Still needed
                    // with `glassEffectID` — the morph only animates inside an
                    // active animation transaction, same as before.
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: selectedTab)
            }
        }
    }
}
