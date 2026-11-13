import SwiftUI

// MARK: - TransitionContext
//
// Scoped deliberately: NOT every tab switch gets a transition screen (that
// would make routine navigation to already-instant tabs like Queue/Settings/
// Playing feel much slower for no reason) — only the handful of tabs that
// actually have real background work to do the first time they're opened
// each session (Cloud Services/Friends/Profile fetch from the network;
// Library only when a media-library scan is genuinely running). See
// ContentView's `.onChange(of: selectedTab)` for exactly when each fires.
enum TransitionContext: CaseIterable {
    case library
    case cloudServices
    case friends
    case profile

    var title: String {
        switch self {
        case .library:      return "Loading Your Library"
        case .cloudServices: return "Connecting to Cloud Services"
        case .friends:       return "Catching Up With Friends"
        case .profile:       return "Loading Your Profile"
        }
    }

    var icon: String {
        switch self {
        case .library:       return "music.note.list"
        case .cloudServices:  return "icloud.and.arrow.down"
        case .friends:        return "person.2.fill"
        case .profile:        return "person.crop.circle"
        }
    }

    /// Screen-aware tips — "smartscreen awareness": each context only ever
    /// shows tips relevant to the screen it's actually transitioning into,
    /// not the app's general tip pool (see `LaunchView.tips` for that one).
    var tips: [String] {
        switch self {
        case .library:
            return [
                "The Duplicate Finder matches songs by how they actually sound (audio fingerprinting), not just by title text.",
                "Library Health gives your whole library a single 0–100 score across duplicates, corruption, and missing metadata.",
                "Smart Playlists refresh themselves automatically based on rules like favorite status, play count, or genre.",
                "Force Metadata Sync (Settings → Library) re-reads and re-embeds corrected tags into the actual files, not just the app's cache.",
            ]
        case .cloudServices:
            return [
                "Tracked playlists auto-download new tracks as their source playlist grows — set one up from any search result.",
                "M3U playlists from another app can be imported directly — matched by filename, falling back to title and artist.",
                "Multiple tracked playlists now download in parallel instead of one at a time.",
                "Your preferred download format (FLAC, Opus, MP3...) is honored exactly — nothing gets silently re-encoded on its way in.",
            ]
        case .friends:
            return [
                "Listen Together keeps everyone's playback in sync over SharePlay, with a shared suggest-and-vote queue.",
                "Friend requests and activity both live here — tap a friend's now-playing entry to jump straight to that track.",
                "Your friends only see what you're listening to if Share Now Playing is on — check Profile → Edit Profile.",
                "Music Compatibility scores how closely your taste matches a friend's, based on real listening history.",
            ]
        case .profile:
            return [
                "Avatar Decoration and Profile Effect add looping animations to your avatar and banner — try them from Edit Profile.",
                "Pin up to 5 favorite tracks to showcase on your public profile.",
                "Your Listening Streak and Top Genres/Artists cards are opt-in — toggle them from Edit Profile.",
                "Verify your Discord account under Account → Security for a Discord Verified badge on your profile.",
            ]
        }
    }
}

// MARK: - TabTransitionOverlay

/// Full-screen loading transition shown the first time a session enters one
/// of `TransitionContext`'s tabs (or Library specifically while a scan is
/// running) — gives the destination screen's own existing background
/// loading (each already has its own onAppear/task fetch; this doesn't
/// duplicate that work, just covers it) a real window to finish before the
/// user sees a half-populated screen, while showing a screen-aware tip and
/// a rotating animated backdrop reused from `ProfileEffectOverlay` so
/// consecutive transitions don't all look identical. Always on — no
/// Settings toggle — but only for the specific contexts above, not every
/// navigation.
struct TabTransitionOverlay: View {
    let context: TransitionContext
    /// Picked once by the caller (see `ContentView.nextTransitionAnimationStyle`)
    /// so consecutive transitions cycle through different looks instead of
    /// repeating the same one.
    let animationStyle: ProfileEffectStyle
    /// Called once the hold window has elapsed — the caller clears its own
    /// state to dismiss this view.
    let onFinished: () -> Void

    @State private var tipIndex = 0
    @State private var contentOpacity: Double = 0
    @State private var iconScale: CGFloat = 0.7

    /// Same "minimum hold so it never just flickers, hard cap so nothing
    /// can trap the user" shape as `LaunchView`'s own scan-wait logic —
    /// deliberately time-boxed rather than polling each destination
    /// screen's own internal loading flags (several different services,
    /// several different flag shapes; a fixed, generous window that always
    /// gives real background work a fair chance to finish is far more
    /// robust than wiring up — and keeping in sync with — every one of
    /// them individually).
    private let holdSeconds: Double = 5.5

    var body: some View {
        ZStack {
            EditionScreenBackground()
            ProfileEffectOverlay(style: animationStyle, mainTint: AppTheme.dynamicAccent, subTint: AppTheme.dynamicAccentSecondary)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(AppTheme.dynamicAccent.opacity(0.18))
                        .frame(width: 110, height: 110)
                        .blur(radius: 20)
                    Circle()
                        .fill(AppTheme.surface)
                        .frame(width: 88, height: 88)
                    Image(systemName: context.icon)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AppTheme.dynamicAccent, AppTheme.dynamicAccentSecondary],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                }
                .scaleEffect(iconScale)

                Text(context.title)
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.textPrimary)

                ProgressView()
                    .tint(AppTheme.dynamicAccent)
                    .padding(.top, 4)

                Text(context.tips[tipIndex])
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
                    .id(tipIndex)
                    .transition(.opacity)

                Spacer()
                Spacer()
            }
            .opacity(contentOpacity)
        }
        .onAppear {
            tipIndex = Int.random(in: 0..<context.tips.count)
            withAnimation(LumiMotion.fade(0.3)) { contentOpacity = 1.0 }
            withAnimation(LumiMotion.settle) { iconScale = 1.0 }

            // Cycles to a second tip partway through the hold, for contexts
            // whose window is long enough that showing only one the whole
            // time would feel static — mirrors LaunchView's own tip-cycling,
            // just a single cycle rather than a repeating loop (this screen
            // is never up long enough to need more than that).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 0.5 * 1_000_000_000))
                guard context.tips.count > 1 else { return }
                withAnimation(LumiMotion.fade(0.4)) {
                    tipIndex = (tipIndex + 1) % context.tips.count
                }
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
                withAnimation(LumiMotion.glide(0.4)) { contentOpacity = 0 }
                try? await Task.sleep(nanoseconds: 400_000_000)
                onFinished()
            }
        }
    }
}
