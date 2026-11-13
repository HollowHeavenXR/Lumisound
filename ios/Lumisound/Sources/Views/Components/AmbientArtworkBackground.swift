import SwiftUI

/// A soft, animated color wash sampled from the current track's artwork —
/// two large blurred blobs that slowly drift and breathe behind the Now
/// Playing artwork display, similar to Apple Music / Spotify's ambient
/// now-playing backgrounds. Shared across all `NowPlayingArtworkStyle`
/// presets so every style gets a less "flat" backdrop for free.
struct AmbientArtworkBackground: View {
    let song: Song?
    // Same visibility/playing gate every `*ArtworkView` style's own
    // TimelineView takes (see NowPlayingView.isVisibleOnScreen's doc
    // comment) — this wash sits behind ALL of them, so leaving it
    // ungated meant it alone kept the per-frame redraw cost alive even for
    // a style whose own TimelineView WAS correctly paused/off-screen-aware.
    let isPlaying: Bool

    @EnvironmentObject private var library: LibraryManager
    @State private var palette: ArtworkPalette?

    /// The glow is drawn on a canvas well beyond the artwork and faded out
    /// radially before its edge. It used to be rasterized (`drawingGroup`)
    /// into the 320pt square it was laid out in, which cut the blur off
    /// along a hard edge — the visible "box" behind every artwork style.
    static let canvasSide: CGFloat = 560

    var body: some View {
        // 10fps. Each frame re-blurs and re-rasterizes the largest layer on the
        // screen (a 70pt blur over a 560pt canvas, through `drawingGroup`), for
        // as long as Now Playing is open with music playing — sustained GPU
        // work that warms the phone over a long session. The blobs move about
        // 4pt a second under that blur, under half a point per frame even at
        // 10fps, so the lower rate is not visible; it was 30fps, and before
        // that 60.
        TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isPlaying)) { timeline in
            let drift = ArtworkClock.pingPong(timeline.date, legDuration: 9) * 36
            let pulse = 1.0 + ArtworkClock.pingPong(timeline.date, legDuration: 7) * 0.18

            ZStack {
                if let palette {
                    Circle()
                        .fill(palette.primary)
                        .frame(width: 300, height: 300)
                        .offset(x: -80 + drift, y: -50 - drift * 0.6)
                        .scaleEffect(pulse)

                    Circle()
                        .fill(palette.secondary)
                        .frame(width: 280, height: 280)
                        .offset(x: 90 - drift, y: 60 + drift * 0.5)
                        .scaleEffect(2 - pulse)
                }
            }
            .frame(width: Self.canvasSide, height: Self.canvasSide)
            .blur(radius: 70)
            .mask(
                RadialGradient(
                    colors: [.white, .white.opacity(0.6), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: Self.canvasSide / 2
                )
            )
            .drawingGroup()
            .opacity(0.55)
            .allowsHitTesting(false)
            .animation(LumiMotion.fade(1.2), value: palette)
        }
        .frame(width: Self.canvasSide, height: Self.canvasSide)
        .task(id: song?.id) {
            await loadPalette()
        }
    }

    private func loadPalette() async {
        palette = await ArtworkPaletteLoader.palette(for: song)
    }
}
