import SwiftUI

/// A third Gallery Background source, alongside Photos and the static
/// palette-cycling Sonic Wallpaper: a LIVE audio-reactive backdrop that
/// pulses and drifts with whatever's actually playing right now, colored
/// from the current track's own artwork. Where Sonic Wallpaper cycles a
/// fixed palette on a timer regardless of playback, this one is driven
/// directly by `AudioVisualizerService`'s per-buffer bass/mid/treble energy —
/// the same live analyzer Music Haptics and Auto EQ already read off the
/// real audio graph — so the background genuinely breathes with the beat
/// instead of just being another slow, generic cycle.
///
/// Three soft radial "blobs" (bass/mid/treble, tinted from the artwork
/// palette) drift independently and scale with their own band's live
/// level, layered under a slow ambient rotation so it never looks
/// perfectly still even during a quiet passage.
struct ReactiveAuraBackgroundView: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @ObservedObject private var analyzer = AudioVisualizerService.shared
    @AppStorage("app_reduce_motion") private var reduceMotion = false
    @ObservedObject private var governor = HeatGovernor.shared
    /// Mounted in every tab; only the visible one animates.
    @State private var visible = false

    /// Frame rate the heat governor allows (1 fps "breathing" when it doesn't).
    private var frameInterval: Double {
        guard !reduceMotion, visible, governor.policy.backgroundMotion else { return 1.0 }
        return 1.0 / max(governor.policy.motionFps, 1)
    }

    @State private var palette: ArtworkPalette?
    @State private var paletteSongID: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: frameInterval)) { timeline in
            GeometryReader { geo in
                ZStack {
                    AppTheme.background

                    let colors = paletteColors
                    let drift = reduceMotion ? 0 : CGFloat(ArtworkClock.pingPong(timeline.date, legDuration: 40))
                    let size = min(geo.size.width, geo.size.height)

                    blob(
                        color: colors.0,
                        level: analyzer.bassLevel,
                        baseSize: size * 0.9,
                        center: UnitPoint(x: 0.25 + 0.1 * drift, y: 0.3),
                        in: geo.size
                    )
                    blob(
                        color: colors.1,
                        level: analyzer.midLevel,
                        baseSize: size * 0.75,
                        center: UnitPoint(x: 0.75 - 0.15 * drift, y: 0.65),
                        in: geo.size
                    )
                    blob(
                        color: colors.0.opacity(0.7),
                        level: analyzer.trebleLevel,
                        baseSize: size * 0.55,
                        center: UnitPoint(x: 0.5, y: 0.85 - 0.1 * drift),
                        in: geo.size
                    )
                }
                .drawingGroup()
            }
        }
        .ignoresSafeArea()
        .onAppear {
            visible = true
            analyzer.start(for: .galleryReactiveBackground)
            loadPaletteIfNeeded()
        }
        .onDisappear {
            visible = false
            analyzer.stop(for: .galleryReactiveBackground)
        }
        .onChange(of: player.currentSong?.id) { _ in
            loadPaletteIfNeeded()
        }
    }

    private var paletteColors: (Color, Color) {
        guard let palette else { return (AppTheme.dynamicAccent, AppTheme.accentSoft) }
        return (palette.primary, palette.secondary)
    }

    @ViewBuilder
    private func blob(color: Color, level: Float, baseSize: CGFloat, center: UnitPoint, in containerSize: CGSize) -> some View {
        // 1.0 at rest, up to ~1.35x at full energy — clamped so a sudden
        // loud transient doesn't blow the blob past the frame in one frame.
        let scale = 1.0 + CGFloat(min(1, max(0, level))) * 0.35
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.55), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: baseSize / 2
                )
            )
            .frame(width: baseSize, height: baseSize)
            .scaleEffect(scale)
            .position(x: containerSize.width * center.x, y: containerSize.height * center.y)
            .blur(radius: 40)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
    }

    private func loadPaletteIfNeeded() {
        guard let song = player.currentSong, song.id != paletteSongID else {
            if player.currentSong == nil { palette = nil; paletteSongID = nil }
            return
        }
        paletteSongID = song.id
        Task {
            guard let image = await ArtworkService.shared.loadArtwork(for: song),
                  let extracted = ArtworkColorExtractor.palette(from: image) else { return }
            guard player.currentSong?.id == song.id else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                palette = extracted
            }
        }
    }
}
