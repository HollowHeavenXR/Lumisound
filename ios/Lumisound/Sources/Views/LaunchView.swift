import SwiftUI
import UIKit

// MARK: - LaunchScreenStyle

enum LaunchScreenStyle: String, CaseIterable, Identifiable, Codable {
    case aurora
    case minimalist

    var id: String { rawValue }
    var displayName: String { self == .aurora ? "Aurora" : "Minimalist" }
}

// MARK: - LaunchView
//
// Remade 2026-09. The old screen was an icon with rings and a spinner over a
// generic accent blur; it said nothing about *your* library and nothing about
// what it was waiting for. Now:
//
// - Backdrop: a slowly drifting wall of the library's own album covers,
//   darkened and blurred (Aurora), or the plain theme background
//   (Minimalist / Reduce Motion).
// - Centerpiece: the app icon as the label of a spinning record, with a
//   tone-arm-free, groove-lined disc and an accent rim light.
// - A greeting (the signed-in user, or the wordmark) and library stats.
// - A live step list — Library → Sync → Ready — with the scan count while
//   scanning, instead of an unexplained spinner.
// - The account prompt is a glass bottom card over the same backdrop.
//
// Timing is unchanged: held until the scan and pull-sync actually finish,
// with a 1.2s minimum and 10s cap (see the hold task in `.onAppear`).

struct LaunchView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var library: LibraryManager
    @Binding var isLoading: Bool

    @AppStorage("launch_screen_style") private var launchStyleRaw: String = LaunchScreenStyle.aurora.rawValue
    @AppStorage("app_reduce_motion") private var reduceMotion = false

    /// Reduce Motion always wins over the chosen style — no cover wall, no
    /// spinning record, no drift.
    private var isMinimalist: Bool {
        reduceMotion || LaunchScreenStyle(rawValue: launchStyleRaw) == .minimalist
    }

    @State private var showPrompt = false
    @State private var showLoginSheet = false
    @State private var loginStartOnRegister = false

    @State private var tipIndex = Int.random(in: 0..<LaunchView.tips.count)
    @State private var tipCyclingTask: Task<Void, Never>?

    @State private var appeared = false
    /// Set once the minimum hold has passed — before that, `isScanning` /
    /// `isSyncing` may not have flipped on yet, so the steps would read
    /// "done" for a moment and then un-done.
    @State private var minimumHoldPassed = false
    @State private var wallSongs: [Song] = []

    private var libraryStepDone: Bool { minimumHoldPassed && !library.isScanning }
    private var syncStepDone: Bool { minimumHoldPassed && !account.isSyncing }

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 0) {
                Spacer(minLength: 40)

                Group {
                    if InterfaceEdition.isLumen {
                        LumenLaunchMark(animate: appeared && !isMinimalist)
                    } else {
                        LaunchRecord(spinning: appeared && !isMinimalist)
                    }
                }
                    .scaleEffect(appeared ? 1 : 0.7)
                    .opacity(appeared ? 1 : 0)

                greeting
                    .padding(.top, 28)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)

                statsRow
                    .padding(.top, 18)
                    .opacity(appeared ? 1 : 0)

                Spacer(minLength: 24)

                progressCard
                    .padding(.horizontal, 20)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 24)

                Text(LaunchView.tips[tipIndex])
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 32)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                    .id(tipIndex)
                    .transition(.opacity)
                    .opacity(appeared ? 1 : 0)
            }

            if showPrompt && !account.isLoggedIn {
                accountPrompt
            }
        }
        .fontDesign(InterfaceEdition.isLumen ? .rounded : nil)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showPrompt)
        .animation(.easeInOut(duration: 0.3), value: libraryStepDone)
        .animation(.easeInOut(duration: 0.3), value: syncStepDone)
        .sheet(isPresented: $showLoginSheet, onDismiss: {
            if account.isLoggedIn {
                withAnimation(.easeOut(duration: 0.5)) { isLoading = false }
            }
        }) {
            LoginView(startOnRegister: loginStartOnRegister)
                .environmentObject(account)
        }
        .onAppear(perform: start)
        .task(id: library.allSongs.isEmpty) {
            // The library usually restores from its snapshot before this
            // appears; if it lands a moment later, fill the wall then.
            if wallSongs.isEmpty { wallSongs = Self.wallSongs(from: library.allSongs) }
        }
        .onChange(of: account.isLoggedIn) { loggedIn in
            if loggedIn {
                showLoginSheet = false
                withAnimation(.easeOut(duration: 0.5)) { isLoading = false }
            }
        }
        // The tip loop is a plain Task, which outlives this view unless
        // cancelled.
        .onChange(of: isLoading) { loading in
            if !loading { tipCyclingTask?.cancel() }
        }
    }

    // MARK: Backdrop

    @ViewBuilder
    private var backdrop: some View {
        if InterfaceEdition.isLumen {
            // Lumen: the lit ink ground, with the cover wall as a faint
            // texture behind it rather than the whole picture.
            ZStack {
                LumenBackdrop(intensity: 1.5)
                if !isMinimalist && wallSongs.count >= 6 {
                    LaunchCoverWall(songs: wallSongs, animate: appeared)
                        .opacity(0.22)
                        .blendMode(.screen)
                }
            }
            .ignoresSafeArea()
        } else if isMinimalist || wallSongs.count < 6 {
            ZStack {
                AppTheme.background
                if !isMinimalist {
                    RadialGradient(
                        colors: [AppTheme.dynamicAccent.opacity(0.35), .clear],
                        center: .top, startRadius: 0, endRadius: 520
                    )
                }
            }
            .ignoresSafeArea()
        } else {
            LaunchCoverWall(songs: wallSongs, animate: appeared)
                .ignoresSafeArea()
        }
    }

    /// Up to 18 songs from different albums, for the cover wall.
    static func wallSongs(from songs: [Song]) -> [Song] {
        var seen = Set<String>()
        var picked: [Song] = []
        for song in songs where seen.insert(song.groupableAlbumName).inserted {
            picked.append(song)
            if picked.count == 18 { break }
        }
        return picked
    }

    // MARK: Greeting

    @ViewBuilder
    private var greeting: some View {
        if account.isLoggedIn, let user = account.currentUser {
            VStack(spacing: 6) {
                Text(Self.timeOfDayGreeting)
                    .font(.caption.weight(.heavy))
                    .tracking(1.6)
                    .foregroundStyle(AppTheme.dynamicAccent)
                Text(user.displayName?.isEmpty == false ? user.displayName! : "@\(user.username)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if user.displayName?.isEmpty == false {
                    Text("@\(user.username)")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 24)
        } else {
            VStack(spacing: 6) {
                Text("Lumisound")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AppTheme.textPrimary, AppTheme.dynamicAccent],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                Text("Your music, your way")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    static var timeOfDayGreeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "GOOD MORNING"
        case 12..<17: return "GOOD AFTERNOON"
        case 17..<22: return "GOOD EVENING"
        default:      return "WELCOME BACK"
        }
    }

    // MARK: Stats

    @ViewBuilder
    private var statsRow: some View {
        if !library.allSongs.isEmpty {
            HStack(spacing: 8) {
                LaunchStatPill(icon: "music.note", text: "\(library.allSongs.count)")
                LaunchStatPill(icon: "music.mic", text: "\(library.artists.count)")
                LaunchStatPill(icon: "square.stack", text: "\(library.albums.count)")
                LaunchStatPill(icon: "music.note.list", text: "\(library.playlists.count)")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(library.allSongs.count) songs, \(library.artists.count) artists, \(library.albums.count) albums, \(library.playlists.count) playlists")
        }
    }

    // MARK: Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LaunchStepRow(
                title: libraryStepTitle,
                detail: libraryStepDetail,
                state: libraryStepDone ? .done : .active
            )
            if account.isLoggedIn {
                LaunchStepRow(
                    title: "Syncing your account",
                    detail: syncStepDone ? "Playlists, favorites and settings are up to date" : "Playlists, favorites and settings",
                    state: syncStepDone ? .done : (libraryStepDone ? .active : .pending)
                )
            }
            LaunchStepRow(
                title: "Ready",
                detail: nil,
                state: (libraryStepDone && (syncStepDone || !account.isLoggedIn)) ? .done : .pending
            )

            if let progress = library.scanProgress, progress.total > 0, !libraryStepDone {
                ProgressView(value: Double(progress.current), total: Double(progress.total))
                    .tint(AppTheme.dynamicAccent)
                    .animation(.easeOut(duration: 0.2), value: progress.current)
            }
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallback: AppTheme.surface.opacity(0.7))
    }

    private var libraryStepTitle: String {
        if let progress = library.scanProgress, progress.total > 0, !libraryStepDone {
            return "Scanning \(progress.current) of \(progress.total) songs"
        }
        return libraryStepDone ? "Library loaded" : "Loading your library"
    }

    private var libraryStepDetail: String? {
        libraryStepDone ? "\(library.allSongs.count) songs ready" : nil
    }

    // MARK: Account prompt

    private var accountPrompt: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45).ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 16) {
                Capsule()
                    .fill(AppTheme.textSecondary.opacity(0.35))
                    .frame(width: 36, height: 4)

                VStack(spacing: 6) {
                    Text("Welcome to Lumisound")
                        .font(.title2.bold())
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Create a free account to sync playlists, settings, and your personal library across devices.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    promptPerk(icon: "arrow.triangle.2.circlepath", text: "Sync across iPhone, iPad and Apple Watch")
                    promptPerk(icon: "person.2.fill", text: "Friends, Listen Together and shared playlists")
                    promptPerk(icon: "icloud.fill", text: "Cloud backup of your library")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

                Button {
                    loginStartOnRegister = true
                    showLoginSheet = true
                } label: {
                    Text("Create Account")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(AppTheme.dynamicAccentGradient, in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    loginStartOnRegister = false
                    showLoginSheet = true
                } label: {
                    Text("Log In")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(AppTheme.textPrimary)
                        .adaptiveGlass(in: Capsule(), fallback: AppTheme.elevatedSurface)
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    withAnimation(.easeOut(duration: 0.5)) {
                        showPrompt = false
                        isLoading = false
                    }
                } label: {
                    Text("Continue without account")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 26)
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous), fallback: AppTheme.surface)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func promptPerk(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.dynamicAccent)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    // MARK: Lifecycle

    private func start() {
        wallSongs = Self.wallSongs(from: library.allSongs)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
            appeared = true
        }

        tipCyclingTask?.cancel()
        tipCyclingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.4)) {
                    tipIndex = LaunchView.nextTipIndex(excluding: tipIndex)
                }
            }
        }

        Task {
            // Held until the real work is done — `library.isScanning` and
            // `account.isSyncing` — rather than a flat delay (a fixed 6s hold
            // once made every warm launch stall). The minimum keeps the
            // screen from flickering and covers the moment before the scan
            // and sync have flipped their flags on; the cap means a stuck
            // scan or sync can never trap the user here.
            let minimumHold: UInt64 = 800_000_000     //  0.8 s
            let maximumHold: UInt64 = 10_000_000_000  // 10.0 s
            let pollInterval: UInt64 = 250_000_000    //  0.25 s

            try? await Task.sleep(nanoseconds: minimumHold)
            await MainActor.run { minimumHoldPassed = true }
            var waited = minimumHold
            // A network sync only holds the screen briefly when the library is
            // already on screen from its snapshot; the sync finishes behind
            // the app instead of keeping the user waiting up to 10 s.
            let syncGrace: UInt64 = 2_000_000_000     //  2.0 s
            while waited < maximumHold {
                let elapsed = waited
                let stillBusy = await MainActor.run {
                    library.isScanning
                        || (account.isSyncing && (library.allSongs.isEmpty || elapsed < syncGrace))
                }
                guard stillBusy else { break }
                try? await Task.sleep(nanoseconds: pollInterval)
                waited += pollInterval
            }

            await MainActor.run {
                if !account.isLoggedIn {
                    withAnimation { showPrompt = true }
                } else {
                    withAnimation(.easeOut(duration: 0.5)) { isLoading = false }
                }
            }
        }
    }

    // MARK: - Loading tips
    //
    // Every tip references a real, currently-shipping feature — not filler
    // copy — so this doubles as passive feature discovery for anyone who
    // hasn't found a given screen yet.
    static let tips: [String] = [
        "Pin custom EQ, effects, and volume to a specific song from its track menu — Per-Track Sound remembers it every time that track plays.",
        "Turn on Skip Silent Intros in Settings → Playback & Audio to automatically skip past dead air at the start of local tracks.",
        "The Duplicate Finder matches songs by how they actually sound (audio fingerprinting), not just by title text.",
        "Smart Auto Crossfade reads how the outgoing track's ending actually sounds and snaps the fade to a downbeat.",
        "Practice Mode adds a tempo-synced metronome and a sub-100% speed slider — built for learning a track by ear.",
        "Focus Sessions pair a Pomodoro-style work/break timer with a soundtrack that pauses itself at each break.",
        "Listen Together keeps everyone's playback in sync over SharePlay, with a shared suggest-and-vote queue.",
        "Smart Playlists refresh themselves automatically based on rules like favorite status, play count, or genre.",
        "Library Health gives your whole library a single 0–100 score across duplicates, corruption, and missing metadata.",
        "Two-Factor Authentication is available under Account → Security — protect your account with an authenticator app.",
        "Verify your Discord account under Account → Security for a Discord Verified badge on your profile.",
        "Force Metadata Sync (Settings → Library) re-reads and re-embeds corrected tags into the actual files, not just the app's cache.",
        "Design your own Now Playing look in the built-in style editor — 25+ styles ship in, and yours can join the rotation.",
        "8D spatial audio, bass boost, nightcore, and 20+ other effects live under the Sound tab in Now Playing.",
        "M3U playlists from another app can be imported directly — matched by filename, falling back to title and artist.",
    ]

    /// A tip index different from `current` (when there's more than one tip
    /// to choose from) — avoids a same-tip-twice-in-a-row cycle, which would
    /// otherwise happen roughly 1-in-N times with a plain random pick.
    static func nextTipIndex(excluding current: Int) -> Int {
        guard tips.count > 1 else { return 0 }
        var next = Int.random(in: 0..<tips.count)
        while next == current { next = Int.random(in: 0..<tips.count) }
        return next
    }
}

// MARK: - LaunchCoverWall

/// The library's own covers in a tilted grid that drifts slowly upward,
/// darkened and blurred into a backdrop.
///
/// The grid is built once and drifted by a Core Animation loop. It used to be
/// rebuilt 30 times a second in a `TimelineView` — around sixty artwork views
/// per frame, under a full-screen blur re-applied each frame — which was
/// continuous main-thread and GPU work for as long as the loading screen
/// showed, and froze whenever loading itself held the main thread. Now the
/// blurred grid is rasterized once and only its position changes.
private struct LaunchCoverWall: View {
    let songs: [Song]
    let animate: Bool

    private let tile: CGFloat = 118
    private let gap: CGFloat = 10
    private let columns = 4
    /// The pattern repeats every `period` rows (covers and the brick offset
    /// both), so drifting exactly that far and jumping back is seamless.
    private let period = 6
    /// Points per second, as before.
    private let speed: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let rowHeight = tile + gap
            let rows = Int(geo.size.height * 1.4 / rowHeight) + period + 1
            let gridWidth = CGFloat(columns) * tile + CGFloat(columns - 1) * gap + tile
            let gridHeight = CGFloat(rows) * rowHeight
            let loopDistance = rowHeight * CGFloat(period)

            CoreAnimationLoop(
                .driftUp(distance: loopDistance, period: TimeInterval(loopDistance / speed)),
                isRunning: animate,
                rasterize: true
            ) {
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<columns, id: \.self) { col in
                                let song = songs[((row % period) * columns + col) % songs.count]
                                ArtworkThumbnail(song: song, size: tile, showsScrim: false)
                            }
                        }
                        // Alternate rows sit half a tile over, like brickwork.
                        .offset(x: row.isMultiple(of: 2) ? -tile / 2 : 0)
                    }
                }
                .blur(radius: 6)
                .frame(width: gridWidth, height: gridHeight)
            }
            .frame(width: gridWidth, height: gridHeight)
            .rotationEffect(.degrees(-12))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay(
            LinearGradient(
                colors: [
                    AppTheme.background.opacity(0.55),
                    AppTheme.background.opacity(0.8),
                    AppTheme.background.opacity(0.97)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .background(AppTheme.background)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - LaunchRecord

/// The app icon as the label of a spinning record.
private struct LaunchRecord: View {
    let spinning: Bool

    private let size: CGFloat = 210

    var body: some View {
        // The glow and spindle are circles centred on the axis, so only the
        // disc needs to turn — and the whole disc can, as one layer, because
        // the grooves are circles too. The spin runs as a Core Animation loop
        // so it keeps going while the main thread is busy loading; see
        // `CoreAnimationLoop`.
        ZStack {
            // Accent glow behind the disc.
            Circle()
                .fill(AppTheme.dynamicAccent)
                .frame(width: size * 0.9, height: size * 0.9)
                .blur(radius: 50)
                .opacity(0.45)

            CoreAnimationLoop(.spin(period: 6), isRunning: spinning) {
                disc
            }
            .frame(width: size, height: size)

            // Spindle.
            Circle()
                .fill(AppTheme.background)
                .frame(width: 8, height: 8)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
        .accessibilityHidden(true)
    }

    /// Everything that turns: disc, grooves, rim lights and label.
    private var disc: some View {
        ZStack {
            // Disc and grooves.
            Circle()
                .fill(Color(white: 0.06))
                .frame(width: size, height: size)
            ForEach(0..<9, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(i.isMultiple(of: 3) ? 0.09 : 0.04), lineWidth: 1)
                    .frame(width: size - 24 - CGFloat(i) * 11, height: size - 24 - CGFloat(i) * 11)
            }
            // Rim lights that turn with the disc.
            Circle()
                .trim(from: 0.05, to: 0.22)
                .stroke(
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: size - 8, height: size - 8)
            Circle()
                .trim(from: 0.55, to: 0.68)
                .stroke(AppTheme.dynamicAccent.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: size - 8, height: size - 8)

            // Label: an accent disc with the app icon on it, turning with
            // the record. The disc is there so the label reads as a
            // label even where the icon art is dark.
            ZStack {
                Circle()
                    .fill(AppTheme.dynamicAccentGradient)
                // The icon when it loads; a waveform glyph when it doesn't
                // (it drew nothing in the simulator screenshot runs).
                if let icon = UIImage(named: "AppIconDisplay") {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.3, height: size * 0.3)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.07, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size * 0.42, height: size * 0.42)
            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - LaunchStepRow

private struct LaunchStepRow: View {
    enum StepState { case pending, active, done }

    let title: String
    let detail: String?
    let state: StepState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(AppTheme.dynamicAccent)
                        .transition(.scale.combined(with: .opacity))
                case .active:
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.dynamicAccent)
                case .pending:
                    Circle()
                        .strokeBorder(AppTheme.textSecondary.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(state == .pending ? .regular : .semibold))
                    .foregroundStyle(state == .pending ? AppTheme.textSecondary : AppTheme.textPrimary)
                    .contentTransition(.numericText())
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - LaunchStatPill

private struct LaunchStatPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text(text)
                .font(AppTheme.monoFont(size: 13).weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(0.6))
    }
}
