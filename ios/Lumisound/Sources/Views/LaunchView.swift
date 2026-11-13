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
// Remade 2026-11: the "tuning dial". Three rings around the Lumisound mark —
// Library, Sync, Ready — fill as the real work finishes (the scan count
// sits in the centre while scanning), a circular spectrum turns around the
// mark, and soft light ribbons drift behind. All motion at most 60 fps, and
// none at all with Reduce Motion / Minimalist. Timing is unchanged: held
// until the scan and pull-sync finish, 0.8 s minimum, 10 s cap.

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

    private var libraryStepDone: Bool { minimumHoldPassed && !library.isScanning }
    private var syncStepDone: Bool { minimumHoldPassed && !account.isSyncing }

    /// 0…1 per step, for the dial's rings.
    private var libraryFill: Double {
        if libraryStepDone { return 1 }
        if let p = library.scanProgress, p.total > 0 { return Double(p.current) / Double(p.total) }
        return 0.18
    }
    private var syncFill: Double { !account.isLoggedIn || syncStepDone ? (libraryStepDone ? 1 : 0) : (libraryStepDone ? 0.35 : 0) }
    private var readyFill: Double { libraryStepDone && (syncStepDone || !account.isLoggedIn) ? 1 : 0 }

    var body: some View {
        ZStack {
            LaunchRibbons(animate: appeared && !isMinimalist)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 40)

                LaunchDial(library: libraryFill, sync: syncFill, ready: readyFill,
                           animate: appeared && !isMinimalist,
                           centre: dialCentreText)
                    .frame(width: 236, height: 236)
                    .scaleEffect(appeared ? 1 : 0.82)
                    .opacity(appeared ? 1 : 0)

                greeting
                    .padding(.top, 26)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)

                stepLegend
                    .padding(.top, 18)
                    .opacity(appeared ? 1 : 0)

                Spacer(minLength: 24)

                Text(LaunchView.tips[tipIndex])
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 30)
                    .id(tipIndex)
                    .transition(.opacity)
                    .opacity(appeared ? 1 : 0)
            }

            if showPrompt && !account.isLoggedIn {
                accountPrompt
            }
        }
        .animation(LumiMotion.settle, value: showPrompt)
        .animation(LumiMotion.glide, value: libraryStepDone)
        .animation(LumiMotion.glide, value: syncStepDone)
        .sheet(isPresented: $showLoginSheet, onDismiss: {
            if account.isLoggedIn {
                withAnimation(LumiMotion.fade) { isLoading = false }
            }
        }) {
            LoginView(startOnRegister: loginStartOnRegister)
                .environmentObject(account)
        }
        .onAppear(perform: start)
        .onChange(of: account.isLoggedIn) { loggedIn in
            if loggedIn {
                showLoginSheet = false
                withAnimation(LumiMotion.fade) { isLoading = false }
            }
        }
        // The tip loop is a plain Task, which outlives this view unless cancelled.
        .onChange(of: isLoading) { loading in
            if !loading { tipCyclingTask?.cancel() }
        }
    }

    /// The centre of the dial: the scan count while scanning, the song count when loaded.
    private var dialCentreText: (String, String) {
        if let p = library.scanProgress, p.total > 0, !libraryStepDone {
            return ("\(p.current)", "of \(p.total)")
        }
        if libraryStepDone, !library.allSongs.isEmpty {
            return ("\(library.allSongs.count)", "songs")
        }
        return ("", "")
    }

    private var stepLegend: some View {
        HStack(spacing: 14) {
            stepDot("Library", fill: libraryFill, colour: AppTheme.dynamicAccent)
            if account.isLoggedIn { stepDot("Sync", fill: syncFill, colour: AppTheme.dynamicAccentSecondary) }
            stepDot("Ready", fill: readyFill, colour: AppTheme.success)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(libraryStepDone ? (readyFill >= 1 ? "Ready" : "Syncing your account") : libraryStepTitle)
    }

    private func stepDot(_ title: String, fill: Double, colour: Color) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(colour.opacity(0.3), lineWidth: 2)
                Circle().trim(from: 0, to: fill).stroke(colour, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                if fill >= 1 { Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(colour) }
            }
            .frame(width: 14, height: 14)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(fill >= 1 ? AppTheme.textPrimary : AppTheme.textSecondary)
        }
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
                    withAnimation(LumiMotion.fade) {
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
        withAnimation(LumiMotion.arrive) {
            appeared = true
        }

        tipCyclingTask?.cancel()
        tipCyclingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                withAnimation(LumiMotion.fade) {
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
                    withAnimation(LumiMotion.settle) { showPrompt = true }
                } else {
                    withAnimation(LumiMotion.fade) { isLoading = false }
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

// MARK: - LaunchDial

/// Three rings — Library, Sync, Ready — fill as loading progresses, around
/// a circular spectrum that turns slowly and the Lumisound mark. Drawn in one
/// Canvas, at most 60 frames a second.
private struct LaunchDial: View {
    let library: Double
    let sync: Double
    let ready: Double
    let animate: Bool
    let centre: (String, String)

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !animate)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r = min(size.width, size.height) / 2
                    // Spectrum: 72 bars between the inner ring and the mark, a
                    // travelling wave so it reads as "listening".
                    let bars = 72
                    for i in 0..<bars {
                        let a = Double(i) / Double(bars) * .pi * 2 + t * 0.35
                        let wave = 0.5 + 0.5 * sin(Double(i) * 0.55 + t * 3.1) * cos(Double(i) * 0.21 - t * 1.7)
                        let inner = r * 0.47
                        let outer = inner + r * (0.04 + 0.13 * wave)
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
                        ctx.stroke(p, with: .color(AppTheme.dynamicAccent.opacity(0.25 + 0.55 * wave)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    // A glint orbiting the outer ring.
                    let ga = t * 0.9
                    let gp = CGPoint(x: c.x + cos(ga) * (r - 4), y: c.y + sin(ga) * (r - 4))
                    ctx.fill(Path(ellipseIn: CGRect(x: gp.x - 3, y: gp.y - 3, width: 6, height: 6)), with: .color(.white.opacity(0.8)))
                }
            }
            ring(fill: library, colour: AppTheme.dynamicAccent, inset: 0)
            ring(fill: sync, colour: AppTheme.dynamicAccentSecondary, inset: 14)
            ring(fill: ready, colour: AppTheme.success, inset: 28)
            VStack(spacing: 0) {
                if centre.0.isEmpty {
                    Image(systemName: "waveform")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(AppTheme.dynamicAccentGradient)
                } else {
                    Text(centre.0)
                        .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(AppTheme.textPrimary)
                        .contentTransition(.numericText())
                    Text(centre.1).font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.textSecondary)
                }
            }
            .frame(width: 92, height: 92)
            .background(Circle().fill(.ultraThinMaterial))
            .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
        .animation(LumiMotion.glide, value: library)
        .animation(LumiMotion.glide, value: sync)
        .animation(LumiMotion.glide, value: ready)
        .accessibilityHidden(true)
    }

    private func ring(fill: Double, colour: Color, inset: CGFloat) -> some View {
        ZStack {
            Circle().stroke(colour.opacity(0.14), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.001, fill))
                .stroke(AngularGradient(colors: [colour.opacity(0.5), colour], center: .center), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colour.opacity(fill > 0 ? 0.6 : 0), radius: 6)
        }
        .padding(inset)
    }
}

// MARK: - LaunchRibbons

/// The backdrop: the theme background with three soft light ribbons drifting
/// across it in the accent colours. Still (and just the gradient) when motion is off.
private struct LaunchRibbons: View {
    let animate: Bool

    var body: some View {
        ZStack {
            AppTheme.background
            TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !animate)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let colours = [AppTheme.dynamicAccent, AppTheme.dynamicAccentSecondary, AppTheme.accentSoft]
                    for k in 0..<3 {
                        var p = Path()
                        let phase = t * (0.18 + Double(k) * 0.07) + Double(k) * 2.1
                        let baseY = size.height * (0.28 + 0.22 * Double(k))
                        p.move(to: CGPoint(x: -40, y: baseY))
                        var x: CGFloat = -40
                        while x <= size.width + 40 {
                            let y = baseY + CGFloat(sin(Double(x) / 110 + phase) * 46 + sin(Double(x) / 47 - phase * 1.6) * 14)
                            p.addLine(to: CGPoint(x: x, y: y))
                            x += 12
                        }
                        ctx.stroke(p, with: .color(colours[k].opacity(0.22)), style: StrokeStyle(lineWidth: 70, lineCap: .round, lineJoin: .round))
                    }
                }
                .blur(radius: 38)
            }
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: 120, endRadius: 600)
        }
    }
}
