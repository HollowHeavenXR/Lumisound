import SwiftUI

// MARK: - ArtworkPaletteLoader (shared palette-loading helper)

/// Loads the dominant-color palette for a song's artwork, used by every Now
/// Playing artwork style for palette-driven glows/accents. Centralizes the
/// "use cached artwork if available, otherwise fetch it" + extraction logic
/// that was previously duplicated verbatim across nine artwork views.
enum ArtworkPaletteLoader {
    @MainActor
    static func palette(for song: Song?) async -> ArtworkPalette? {
        guard let song else { return nil }
        // Goes straight to the async path: a synchronous `LibraryManager`
        // lookup would read and decode the disk-cache JPEG on the MainActor,
        // hitching the UI on every track change. `loadArtwork`'s memory-cache
        // hit is just as fast, and its disk/remote fallbacks run off the main
        // thread.
        guard let image = await ArtworkService.shared.loadArtwork(for: song) else { return nil }
        return ArtworkColorExtractor.palette(from: image)
    }
}

// MARK: - ArtworkClock (wall-clock-driven ambient animation phases)

/// Computes ambient-loop animation phases directly from elapsed wall-clock
/// time instead of persisting them in `@State` via
/// `withAnimation(...repeatForever...)`. The old flip-a-flag-once-and-let-the-
/// curve-repeat pattern relies on a Core Animation transaction staying alive
/// indefinitely — but `NowPlayingView` re-renders every 0.25–0.5s while
/// playing (`PlaybackProgress.position` ticks that often), and that frequent
/// re-rendering was observed to freeze `repeatForever` animations mid-cycle
/// across every Now Playing artwork style. Deriving the phase fresh from
/// `TimelineView`'s `context.date` on every redraw sidesteps the whole
/// problem: there's no in-flight animation to interrupt, just a value
/// recomputed from elapsed time. Every artwork style's `body` should be
/// wrapped in `TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: ...))`
/// and read phases via these helpers instead of animating `@State` directly.
/// The `minimumInterval` caps every style at 60fps regardless of the
/// device's native refresh rate — these are ambient background motion, not
/// anything that benefits from ProMotion's 120Hz, so the extra redraws were
/// pure CPU/GPU/battery cost with no visible difference. Same reasoning
/// `start8DRotation`/`startTremolo`/`startVibrato` already apply to their own
/// `CADisplayLink`s via `preferredFrameRateRange` — this is the `TimelineView`
/// equivalent of that same cap.
enum ArtworkClock {
    /// A smooth 0→1→0 oscillation, matching the shape of the old
    /// `.easeInOut(duration: legDuration).repeatForever(autoreverses: true)`
    /// (`legDuration` = time for one direction of travel).
    static func pingPong(_ date: Date, legDuration: Double) -> Double {
        guard legDuration > 0 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        return 0.5 - 0.5 * cos(.pi * t / legDuration)
    }

    /// A linearly looping 0..<1 ramp, matching the shape of the old
    /// `.linear(duration: cycleDuration).repeatForever(autoreverses: false)`.
    static func loop(_ date: Date, cycleDuration: Double) -> Double {
        guard cycleDuration > 0 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        return t.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
    }
}

// MARK: - FloatModifier (shared utility for gentle vertical float)

struct FloatModifier: ViewModifier {
    let isPlaying: Bool
    let amount: CGFloat
    let speed: Double

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isPlaying)) { timeline in
            let phase = ArtworkClock.pingPong(timeline.date, legDuration: speed)
            content
                .offset(y: isPlaying ? -amount * phase : 0)
                .animation(LumiMotion.glide(0.4), value: isPlaying)
        }
    }
}

// MARK: - PressableButtonStyle

/// A button style that scales the label down slightly (and dims it) while
/// pressed, for tactile press feedback on transport/control buttons. Replaces
/// `.buttonStyle(.plain)` where a bit of physicality is wanted.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(LumiMotion.snap, value: configuration.isPressed)
    }
}

// MARK: - ShimmerOverlay

/// A diagonal light sweep that loops continuously across whatever it's
/// overlaid on — used for loading/placeholder states (artwork not yet
/// fetched, skeleton rows) throughout the app. Driven by
/// `TimelineView`/`ArtworkClock` like the Now Playing ambient loops, for the
/// same reason: immune to freezing from frequent parent re-renders.
struct ShimmerOverlay: View {
    var body: some View {
        // Capped well below 60fps: one of these runs per artwork still
        // loading, with no `paused:` condition (unlike the Now Playing
        // loops above — there's no "isPlaying" equivalent for a loading
        // placeholder, it's just "is this on screen"), so a fast fling
        // through a big grid/list can have dozens running at once — field
        // evidence (a user screen recording of choppy Folders-grid
        // scrolling, plus thermal telemetry showing "serious"/"fair" states
        // during ordinary browsing) traced real GPU/thermal cost to exactly
        // this kind of continuous per-cell animation. A slow 1.4s diagonal
        // sweep is visually indistinguishable at 15fps from 60fps; this cuts
        // the redraw count (and therefore cost, multiplied by however many
        // are on screen at once) by 4x.
        TimelineView(.animation(minimumInterval: LumiMotion.frame)) { timeline in
            let t = ArtworkClock.loop(timeline.date, cycleDuration: 1.4)
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.25), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.5)
                .offset(x: -geo.size.width * 0.5 + t * geo.size.width * 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - FilmGrainOverlay

/// A static, tiled speckle pattern drawn once with `Canvas` to suggest paper
/// or photo grain. Deterministic (seeded) so it doesn't shimmer or cost
/// anything per-frame — drawn a single time and left in place.
struct FilmGrainOverlay: View {
    var body: some View {
        Canvas { context, size in
            var generator = SeededRandom(seed: 1_337)
            let dotCount = Int((size.width * size.height) / 14)
            for _ in 0..<dotCount {
                let x = generator.nextDouble() * size.width
                let y = generator.nextDouble() * size.height
                let alpha = 0.05 + generator.nextDouble() * 0.18
                let dotSize = generator.nextDouble() < 0.5 ? 0.6 : 1.1
                let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
            }
        }
        .drawingGroup()
    }
}

/// A tiny deterministic PRNG (xorshift) used to lay out grain dots without
/// pulling in `GameplayKit` or reseeding `SystemRandomNumberGenerator` on
/// every redraw.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xdead_beef : seed
    }

    mutating func nextDouble() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}
