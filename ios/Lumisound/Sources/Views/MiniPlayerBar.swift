import SwiftUI
import UIKit

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager

    // Tapping the mini player switches to the Now Playing tab rather than
    // presenting a second, freshly-instantiated NowPlayingView in a sheet.
    // Previously each of the ~8 screens hosting MiniPlayerBar owned its own
    // sheet-presented NowPlayingView, so the view's timers/animations/lyrics
    // fetches could run twice (once in the Tab 2 instance, once in the sheet)
    // whenever a sheet was open. Reusing the same @AppStorage key as
    // ContentView's TabView selection means there is only ever one
    // NowPlayingView instance alive.
    @AppStorage("selected_tab") private var selectedTab = 0

    /// Shared with `CustomTabBar`/Settings/Now Playing — see
    /// `NavbarDisplayMode`'s doc comment. When the oval tab bar itself is
    /// showing the Informative MiniPlayer, this separate bar would be a
    /// redundant second player stacked right above it, so it hides entirely
    /// in that mode rather than just when nothing's playing.
    @AppStorage("navbarDisplayMode") private var navbarMode: NavbarDisplayMode = .tabs

    private let playHaptic  = UIImpactFeedbackGenerator(style: .light)
    private let skipHaptic  = UIImpactFeedbackGenerator(style: .medium)
    private let heartHaptic = UIImpactFeedbackGenerator(style: .soft)

    // One-shot burst ring shown when a song is favorited from the mini
    // player — not looping, so it's unrelated to the repeatForever-freeze
    // bug class fixed elsewhere; it just plays out once and holds at rest.
    @State private var heartBurstScale: CGFloat = 1.0
    @State private var heartBurstOpacity: Double = 0

    /// BUG FIXED: `CustomTabBar.totalHeight`'s reservation used to live only
    /// inside `barContent`'s own modifier chain — when nothing was playing
    /// (or, since Navbar Mode shipped, whenever Mini Player navbar mode was
    /// active), `body` rendered a bare `EmptyView` with NO padding at all,
    /// silently dropping every hosting screen's bottom clearance for the
    /// floating `CustomTabBar`. Any screen relying solely on
    /// `.safeAreaInset(edge: .bottom) { MiniPlayerBar() }` for that
    /// clearance (Library/Queue/Cloud Services/Friends/Profile and several
    /// detail screens — see this type's own doc comment) could then have
    /// its bottommost content sit unreachable behind the tab bar. The
    /// reservation now lives on `body` itself, unconditionally, so it
    /// always applies regardless of which branch below actually renders.
    var body: some View {
        // Lumen draws its own mini player in the shell's dock; the classic
        // screens it hosts keep calling this, so it steps aside there.
        if InterfaceEdition.isLumen {
            EmptyView()
        } else {
            classicBody
        }
    }

    private var classicBody: some View {
        Group {
            if player.currentSong != nil, navbarMode != .miniPlayer {
                barContent
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .padding(.bottom, CustomTabBar.totalHeight)
    }

    private var barContent: some View {
        ZStack(alignment: .top) {
            // Progress bar at the very top — its own view so the high-frequency
            // position ticks (every 0.25–0.5s) only re-render this sliver, not the
            // whole mini-player (which is mounted on most screens at once).
            MiniPlayerProgressBar()

            // Main content
            HStack(spacing: 12) {
                // Tap target for opening Now Playing — scoped to JUST the artwork
                // and text (not the whole bar). Attaching it to the full bar and
                // then trying to "absorb" taps on `controls` with empty
                // .simultaneousGesture/.onTapGesture handlers (the previous
                // approach) pits SwiftUI's gesture recognizers against the
                // Buttons below: taps on Play/Pause, Skip, and the heart could
                // intermittently fail to register OR also pop open the Now
                // Playing sheet — the "miniplayer freaks out" behavior reported.
                // Scoping the gesture to a non-interactive region sidesteps the
                // competition entirely; button taps now always go to the buttons.
                HStack(spacing: 12) {
                    artworkThumbnail
                        .id(player.currentSong?.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    songInfo
                        .id(player.currentSong?.id)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.25), value: player.currentSong?.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedTab = 1
                }

                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .frame(height: 80)
        }
        .adaptiveGlass(in: Rectangle())
        // `CustomTabBar.totalHeight`'s reservation now lives on `body`
        // itself (see its doc comment) so it applies whether or not this
        // content actually renders — no longer duplicated here.
    }

    private var artworkThumbnail: some View {
        Group {
            if let song = player.currentSong {
                ArtworkThumbnail(song: song, size: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 5, x: 0, y: 3)
            }
        }
    }

    private var songInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let song = player.currentSong {
                MarqueeText(
                    text: song.displayName,
                    font: .subheadline.weight(.semibold),
                    color: AppTheme.textPrimary
                )
                .frame(height: 18)
                MarqueeText(
                    text: song.artistName,
                    font: .caption,
                    color: AppTheme.textSecondary
                )
                .frame(height: 14)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            // Heart / Favorite button
            if let song = player.currentSong {
                Button {
                    if LuaFeatureFlags.hapticFeedback { heartHaptic.impactOccurred() }
                    library.toggleFavorite(songID: song.id)
                } label: {
                    ZStack {
                        Circle()
                            .stroke(AppTheme.dynamicAccent, lineWidth: 1.5)
                            .frame(width: 16, height: 16)
                            .scaleEffect(heartBurstScale)
                            .opacity(heartBurstOpacity)
                        Image(systemName: library.isFavorite(songID: song.id) ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(library.isFavorite(songID: song.id) ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: library.isFavorite(songID: song.id))
                .onChange(of: library.isFavorite(songID: song.id)) { isFavorite in
                    guard isFavorite else { return }
                    heartBurstScale = 1.0
                    heartBurstOpacity = 0.8
                    withAnimation(.easeOut(duration: 0.45)) {
                        heartBurstScale = 2.2
                        heartBurstOpacity = 0
                    }
                }
            }

            // Play / Pause
            Button {
                if LuaFeatureFlags.hapticFeedback { playHaptic.impactOccurred() }
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
                        .frame(width: 38, height: 38)
                        .shadow(color: AppTheme.dynamicAccent.opacity(0.4), radius: 6, x: 0, y: 3)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
            }
            .buttonStyle(PressableButtonStyle())
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: player.isPlaying)

            // Skip Next
            Button {
                if LuaFeatureFlags.hapticFeedback { skipHaptic.impactOccurred() }
                player.userSkipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .buttonStyle(PressableButtonStyle())
        }
        .onAppear {
            playHaptic.prepare()
            skipHaptic.prepare()
            heartHaptic.prepare()
        }
    }
}

// MARK: - MiniPlayerProgressBar

/// Renders the thin progress sliver atop the mini-player. Observes `PlaybackProgress`
/// directly (instead of reading `player.position`/`player.duration`) so its frequent
/// re-renders stay isolated to this small view rather than cascading through
/// `MiniPlayerBar`'s `objectWillChange` to every screen hosting it.
private struct MiniPlayerProgressBar: View {
    @EnvironmentObject private var progress: PlaybackProgress

    var body: some View {
        GeometryReader { geo in
            let fraction = progress.duration > 0 ? progress.position / progress.duration : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.surface)
                    .frame(height: 3)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.dynamicAccent, AppTheme.dynamicAccentSecondary],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(fraction), height: 3)
                    .animation(.linear(duration: 0.25), value: progress.position)
            }
        }
        .frame(height: 3)
    }
}
