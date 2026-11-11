import AVFoundation
import SwiftUI
import UIKit

// MARK: - StrataRootView
//
// The Strata shell. No tab bar: a Now band rides on top (tap to open the
// player), the screen is a stack of layers (Home / Library / Search / You
// at the bottom, everything opened on top of them), and the command
// capsule at the bottom switches layers and searches. Every screen inside
// is composed by the Rust core (StrataStore -> StrataCore).
//
// Carries the same app-wide duties as the Lumen and Classic shells (library
// scan, presence, car mode, toasts, backups) so it works alone.

struct StrataRootView: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var folderService: MusicFolderService
    @EnvironmentObject private var bridgeHealth: BridgeHealthService
    @ObservedObject private var toastCenter = ToastCenter.shared
    @StateObject private var presenceService = PresenceService.shared
    @StateObject private var store = StrataStore.shared

    @AppStorage("carModeEnabled") private var carModeEnabled: Bool = false
    @AppStorage("autoCloudBackup") private var autoCloudBackup: Bool = false
    @State private var showCarMode = false
    @State private var didBootstrap = false
    @State private var backupSyncTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            StrataPalette.ground.ignoresSafeArea()
            RestoreFoldersPromptView()

            VStack(spacing: 0) {
                StrataNowBand()
                NavigationStack(path: $store.path) {
                    layerRoot
                        .navigationDestination(for: StrataRoute.self) { route in
                            destination(route)
                        }
                }
            }

            StrataCapsule()
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            if store.showNow {
                StrataNowView()
                    .transition(.move(edge: .bottom))
                    .zIndex(5)
            }

            overlays
        }
        .environmentObject(store)
        .preferredColorScheme(.dark)
        .tint(StrataPalette.accent)
        .acoustIDConfirmSheet()
        .clipMakerSheet()
        .fullScreenCover(isPresented: $store.showCloud) {
            ZStack(alignment: .topTrailing) {
                StreamSearchView()
                Button { store.showCloud = false } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).padding(10)
                        .background(StrataPalette.raised, in: Circle())
                }
                .padding(.trailing, 16)
                .padding(.top, 4)
            }
        }
        .fullScreenCover(isPresented: $showCarMode) {
            CarModeView().environmentObject(player)
        }
        .onAppear {
            store.attach(library: library, player: player)
            bootstrap()
        }
        .onChange(of: library.allSongs.count) { _, _ in scheduleBackupSync() }
        .onReceive(account.$isLoggedIn) { loggedIn in
            if loggedIn { presenceService.startHeartbeat(account: account, player: player) } else { presenceService.stopHeartbeat() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if account.isLoggedIn { presenceService.sendGoingOffline(account: account) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if account.isLoggedIn { presenceService.startHeartbeat(account: account, player: player) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { n in
            guard let reason = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: reason) == .newDeviceAvailable else { return }
            Task { @MainActor in
                guard carModeEnabled, !showCarMode else { return }
                if AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .carAudio }) { showCarMode = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumenShowCarMode)) { _ in showCarMode = true }
    }

    @ViewBuilder
    private var layerRoot: some View {
        switch store.layer {
        case .home: StrataScreenHost(route: .home)
        case .library: StrataScreenHost(route: .library(tab: store.libraryTab))
        case .search: StrataSearchLayer()
        case .you: StrataScreenHost(route: .you)
        }
    }

    @ViewBuilder
    private func destination(_ route: StrataRoute) -> some View {
        switch route {
        case .settings(let page):
            Group {
                switch page {
                case "account": AccountView()
                case "audio", "haptics": SettingsView(lumenPage: .audio)
                case "appearance": SettingsView(lumenPage: .app)
                case "downloads": SettingsView(lumenPage: .ytdlp)
                default: LumenSettingsView()
                }
            }
            .toolbar(.visible, for: .navigationBar)
            .background(StrataPalette.ground.ignoresSafeArea())
        default:
            StrataScreenHost(route: route)
        }
    }

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
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toastCenter.current)
        .zIndex(10)
    }

    private func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        library.scanWatchedFolders(using: folderService)
        library.scanLocalDocuments()
        if account.isLoggedIn { presenceService.startHeartbeat(account: account, player: player) }
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

// MARK: - Search layer

struct StrataSearchLayer: View {
    @EnvironmentObject private var store: StrataStore
    @State private var text = ""
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let t = store.theme
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(StrataPalette.accent)
                TextField("", text: $text, prompt: Text("Songs, artists, albums").foregroundColor(StrataPalette.inkFaint))
                    .font(.system(size: t.typeScale[2], weight: .bold))
                    .foregroundStyle(StrataPalette.ink)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(StrataPalette.inkFaint) }
                }
            }
            .padding(.horizontal, t.gutter)
            .frame(height: 56)
            .overlay(Rectangle().fill(StrataPalette.accent).frame(height: 2), alignment: .bottom)
            StrataScreenHost(route: .search(query: query))
        }
        .background(StrataPalette.ground)
        .task(id: text) {
            // Search runs in Rust on every pause in typing (120 ms).
            try? await Task.sleep(nanoseconds: 120_000_000)
            if !Task.isCancelled { query = text }
        }
        .onAppear { focused = text.isEmpty }
    }
}

// MARK: - Now band

/// Slim strip under the status bar: artwork, title, a hairline of progress.
struct StrataNowBand: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        if let song = player.currentSong {
            Button {
                withAnimation(.spring(response: t.motion[1] + 0.1, dampingFraction: t.motion[3])) { store.showNow = true }
            } label: {
                HStack(spacing: 10) {
                    StrataArt(song: song, size: 34, radius: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.displayName).font(.system(size: t.typeScale[4], weight: .heavy)).foregroundStyle(StrataPalette.ink).lineLimit(1)
                        Text(song.artistName).font(.system(size: t.typeScale[5], weight: .medium)).foregroundStyle(StrataPalette.inkFaint).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(StrataPalette.onAccent)
                            .frame(width: 36, height: 36)
                            .background(StrataPalette.accent, in: RoundedRectangle(cornerRadius: t.radius, style: .continuous))
                    }
                    .buttonStyle(StrataPress())
                    Button { player.userSkipToNext() } label: {
                        Image(systemName: "forward.end.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(StrataPalette.ink).frame(width: 30, height: 36)
                    }
                    .buttonStyle(StrataPress())
                }
                .padding(.horizontal, t.gutter)
                .padding(.vertical, 8)
                .background(StrataPalette.layer)
                .overlay(alignment: .bottom) { StrataBandProgress(progress: player.progress) }
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct StrataBandProgress: View {
    @ObservedObject var progress: PlaybackProgress

    var body: some View {
        GeometryReader { g in
            let f = progress.duration > 0 ? min(1, max(0, progress.position / progress.duration)) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(StrataPalette.rule)
                Rectangle().fill(StrataPalette.accent).frame(width: g.size.width * f)
            }
        }
        .frame(height: 2)
    }
}

// MARK: - Command capsule

/// Bottom capsule: the four base layers, the queue, and Cloud.
struct StrataCapsule: View {
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        HStack(spacing: 2) {
            ForEach(StrataLayer.allCases) { l in
                let on = store.layer == l
                Button { withAnimation(.spring(response: t.motion[1], dampingFraction: t.motion[3])) { store.selectLayer(l) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: l.glyph).font(.system(size: 15, weight: .bold))
                        if on { Text(l.title).font(.system(size: t.typeScale[4], weight: .heavy)).lineLimit(1).fixedSize() }
                    }
                    .padding(.horizontal, on ? 14 : 12)
                    .frame(height: 44)
                    .foregroundStyle(on ? StrataPalette.onAccent : StrataPalette.inkDim)
                    .background(on ? StrataPalette.accent : Color.clear, in: RoundedRectangle(cornerRadius: t.radius + 2, style: .continuous))
                }
                .buttonStyle(StrataPress())
            }
            Spacer(minLength: 0)
            Button { store.open(.queue) } label: {
                Image(systemName: "list.number").font(.system(size: 15, weight: .bold)).foregroundStyle(StrataPalette.inkDim).frame(width: 40, height: 44)
            }
            .buttonStyle(StrataPress())
            Button { store.showCloud = true } label: {
                Image(systemName: "icloud").font(.system(size: 15, weight: .bold)).foregroundStyle(StrataPalette.inkDim).frame(width: 40, height: 44)
            }
            .buttonStyle(StrataPress())
        }
        .padding(5)
        .background(StrataPalette.raised.opacity(0.97), in: RoundedRectangle(cornerRadius: t.radiusLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusLarge, style: .continuous).strokeBorder(StrataPalette.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }
}
