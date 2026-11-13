import SwiftUI
import AVFoundation
import UIKit

extension View {
    /// `.contentTransition(.symbolEffect(.replace))` needs iOS 17 — this
    /// app's deployment target is iOS 16 — so this falls back to a plain
    /// opacity content transition on 16, which still crossfades the SF
    /// Symbol change, just without the "replace" morph animation.
    @ViewBuilder
    func symbolReplaceTransition() -> some View {
        if #available(iOS 17.0, *) {
            self.contentTransition(.symbolEffect(.replace))
        } else {
            self.contentTransition(.opacity)
        }
    }
}

// MARK: - NowPlayingArtworkStyle

enum NowPlayingArtworkStyle: String, CaseIterable, Identifiable {
    // Batch 1 of a full visual overhaul (2026-07) — replaces the original
    // vinylDisc/albumArt/polaroid/floatingCards/minimalist/glassmorphism
    // styles with entirely new concepts + animations. Existing users' saved
    // style preference (persisted by rawValue) won't match any new case and
    // falls back to the default — expected, since the old styles no longer
    // exist in any form.
    case kaleidoscopeBloom
    case synthwaveHorizon
    case equalizerCutout
    case liquidBlobFrame
    case origamiFoldReveal
    case mosaicShatter
    // Batch 2 of the visual overhaul — replaces retroCRT/spectrumWaveform/
    // cassetteTape/neonGlow/auraGlow/tiltCard.
    case circuitPulse
    case radarSweep
    case discoMirrorBall
    case frostedIceCrystal
    case bioluminescentTide
    case cometOrbit
    // Batch 3 (final) of the visual overhaul — replaces marquee/holographic/
    // ripple/popArt/starfield/stainedGlass. All 18 styles have now been
    // replaced at least once since the original set.
    case paperLayersParallax
    case chalkboardSketch
    case vinylCrateStack
    case moltenGlassDrip
    case confettiBurstLoop
    case shadowPuppetSilhouette
    // 19th style, added alongside the 2026-07 local-features batch — a
    // genuine real-time FFT spectrum reacting to actual playback (not a
    // decorative animation like the other 18), via AudioVisualizerService.
    case liveSpectrum
    // Batch 4 — 6 additional presets added on top of the existing 19,
    // rounding out the music-format/retro-media concepts (vinyl, cassette)
    // and a few visual techniques (aurora curtains, water reflection, neon
    // flicker, VHS glitch) not yet covered by any prior style.
    case vinylGrooveSpiral
    case cassetteReelSpin
    case auroraVeil
    case rippleReflection
    case neonSignFlicker
    case vhsScanGlitch
    // "Full True Animated Artwork Like Apple Music Does" — unlike the 24
    // styles above (all generated visual effects layered on the static
    // cover), this is REAL motion: a short muted loop of the actual source
    // video's own opening seconds, for YouTube-sourced tracks the server
    // could extract one for. See TrueMotionArtworkView/MotionArtworkService.
    case trueMotion

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kaleidoscopeBloom: return "Prism Bloom"
        case .synthwaveHorizon:  return "Night Drive"
        case .equalizerCutout:   return "Bar Window"
        case .liquidBlobFrame:   return "Lava Lens"
        case .origamiFoldReveal: return "Paper Crane"
        case .mosaicShatter:     return "Tile Pulse"
        case .circuitPulse:      return "Signal Board"
        case .radarSweep:        return "Sonar"
        case .discoMirrorBall:   return "Glitter Ball"
        case .frostedIceCrystal: return "Frost Bloom"
        case .bioluminescentTide: return "Glow Tide"
        case .cometOrbit:        return "Orbit Rings"
        case .paperLayersParallax:   return "Cut Paper"
        case .chalkboardSketch:      return "Sketchbook"
        case .vinylCrateStack:       return "Record Shelf"
        case .moltenGlassDrip:       return "Honey Drip"
        case .confettiBurstLoop:     return "Streamers"
        case .shadowPuppetSilhouette: return "Lantern"
        case .liveSpectrum:           return "Halo Spectrum"
        case .vinylGrooveSpiral:      return "Turntable"
        case .cassetteReelSpin:       return "Mixtape"
        case .auroraVeil:             return "Northern Lights"
        case .rippleReflection:       return "Still Water"
        case .neonSignFlicker:        return "Neon Frame"
        case .vhsScanGlitch:          return "Tape Glitch"
        case .trueMotion:             return "True Motion"
        }
    }

    var iconName: String {
        switch self {
        case .kaleidoscopeBloom: return "hexagon.fill"
        case .synthwaveHorizon:  return "sun.horizon.fill"
        case .equalizerCutout:   return "chart.bar.fill"
        case .liquidBlobFrame:   return "drop.circle.fill"
        case .origamiFoldReveal: return "triangle.fill"
        case .mosaicShatter:     return "square.grid.3x3.fill"
        case .circuitPulse:      return "cpu.fill"
        case .radarSweep:        return "dot.radiowaves.left.and.right"
        case .discoMirrorBall:   return "sparkles"
        case .frostedIceCrystal: return "snowflake"
        case .bioluminescentTide: return "water.waves"
        case .cometOrbit:        return "circle.dotted"
        case .paperLayersParallax:   return "square.stack.fill"
        case .chalkboardSketch:      return "pencil.and.outline"
        case .vinylCrateStack:       return "square.stack.3d.down.right.fill"
        case .moltenGlassDrip:       return "flame.fill"
        case .confettiBurstLoop:     return "party.popper.fill"
        case .shadowPuppetSilhouette: return "theatermasks.fill"
        case .liveSpectrum:           return "waveform"
        case .vinylGrooveSpiral:      return "circle.circle.fill"
        case .cassetteReelSpin:       return "recordingtape"
        case .auroraVeil:             return "moon.stars.fill"
        case .rippleReflection:       return "target"
        case .neonSignFlicker:        return "lightbulb.fill"
        case .vhsScanGlitch:          return "tv.fill"
        case .trueMotion:             return "play.rectangle.fill"
        }
    }
}

// MARK: - NowPlayingScreenStyle (whole-screen style resolution)
//
// Part of the 2026-07 Now Playing redesign's customization expansion.
// Distinct from `NowPlayingArtworkStyle`/`CustomStyleArtworkView` (which
// only paint the artwork card itself), this resolves the granular knobs
// added to `CustomNowPlayingStyle` — typography, per-element color
// overrides, transport control layout, spacing density, corner radii,
// whole-screen background treatment — into concrete SwiftUI values
// consumed by `NowPlayingView`'s other sections (TrackInfo,
// TransportControls, ScrollContent, Artwork's style chips).
//
// Selecting one of the 19 built-in `NowPlayingArtworkStyle` presets (or no
// custom style at all) always resolves to `.standard`, which reproduces
// today's hardcoded look exactly — this customization layer is additive
// and opt-in, only taking effect once a user builds/edits a Custom Style.
// Other screens (e.g. a future Library row style system) can reuse this
// same shape/resolution pattern without depending on Now Playing itself —
// see the doc comment on `resolve(from:extractedPalette:)`.
struct NowPlayingScreenStyle {
    var titleFont: Font
    var titleColor: Color
    var artistFont: Font
    var artistColor: Color
    var accentColor: Color
    /// `nil` => callers should fall back to their own default (inactive
    /// transport buttons currently use `AppTheme.textPrimary`).
    var controlsColor: Color?
    var transportOrder: [CustomNowPlayingStyle.TransportControl]
    var hiddenTransportControls: Set<CustomNowPlayingStyle.TransportControl>
    var transportScale: CGFloat
    var sectionSpacing: CGFloat
    var elementCornerRadius: CGFloat
    var backgroundBlurRadius: CGFloat
    var backgroundDimming: Double

    static let standard = NowPlayingScreenStyle(
        titleFont: .title2.bold(),
        titleColor: AppTheme.textPrimary,
        artistFont: .body,
        artistColor: AppTheme.textSecondary,
        accentColor: AppTheme.dynamicAccent,
        controlsColor: nil,
        transportOrder: CustomNowPlayingStyle.TransportControl.allCases,
        hiddenTransportControls: [],
        transportScale: 1.0,
        sectionSpacing: 20,
        elementCornerRadius: 10,
        backgroundBlurRadius: 0,
        backgroundDimming: 0
    )

    /// Resolves a concrete `NowPlayingScreenStyle` from a (possibly nil)
    /// selected custom style. `extractedPalette` is the live palette
    /// sampled from the current track's artwork — supplied by the caller
    /// (`NowPlayingView` loads it asynchronously via `ArtworkPaletteLoader`
    /// only when `custom.dynamicColorExtraction` is on, since sampling on
    /// every resolve would be wasteful) — and only actually used when
    /// `custom.dynamicColorExtraction` is true.
    static func resolve(from custom: CustomNowPlayingStyle?, extractedPalette: ArtworkPalette? = nil) -> NowPlayingScreenStyle {
        guard let custom = custom?.sanitized() else { return .standard }

        let accent: Color = {
            if custom.dynamicColorExtraction, let extractedPalette {
                return extractedPalette.primary
            }
            switch custom.accentSource {
            case .palette: return AppTheme.dynamicAccent
            case .custom:  return custom.customAccentColor.color
            }
        }()

        return NowPlayingScreenStyle(
            titleFont: custom.titleFontChoice.font(weight: custom.titleFontWeight.weight, size: CGFloat(22 * custom.titleFontScale)),
            titleColor: custom.titleColorOverrideEnabled ? custom.titleColor.color : AppTheme.textPrimary,
            artistFont: custom.artistFontChoice.font(weight: custom.artistFontWeight.weight, size: CGFloat(17 * custom.artistFontScale)),
            artistColor: custom.artistColorOverrideEnabled ? custom.artistColor.color : AppTheme.textSecondary,
            accentColor: accent,
            controlsColor: custom.controlsColorOverrideEnabled ? custom.controlsColor.color : nil,
            transportOrder: custom.transportControlOrder,
            hiddenTransportControls: custom.hiddenTransportControls,
            transportScale: CGFloat(custom.transportControlScale),
            sectionSpacing: 20 * custom.sectionSpacingDensity.multiplier,
            elementCornerRadius: CGFloat(custom.panelCornerRadius),
            backgroundBlurRadius: CGFloat(custom.backgroundBlurRadius),
            backgroundDimming: custom.backgroundDimming
        )
    }
}

// MARK: - Whole-screen custom background media (image / looping video)

/// Renders a selected custom style's whole-screen background media layer
/// (behind `GalleryBackgroundView`/artwork/controls) — a static custom
/// image, or a muted, silently-looping custom video. Both are opt-in via
/// `CustomNowPlayingStyle.customBackgroundMedia`; `.none` renders nothing.
struct NowPlayingCustomBackgroundMediaView: View {
    let style: CustomNowPlayingStyle
    // Whether the Now Playing screen is actually the front-most tab right
    // now — see NowPlayingView.isVisibleOnScreen's doc comment. Threaded
    // through to LoopingVideoBackgroundView, which otherwise has no way to
    // know: an AVPlayer doesn't pause itself just because its host view
    // scrolled off-screen inside the root TabView's always-instantiated
    // tabs.
    let isVisible: Bool

    var body: some View {
        Group {
            switch style.customBackgroundMedia {
            case .none:
                EmptyView()
            case .image:
                if let filename = style.customBackgroundImageFilename,
                   let uiImage = UIImage(contentsOfFile: CustomStyleMediaStore.url(for: filename).path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    EmptyView()
                }
            case .video:
                if let filename = style.customBackgroundVideoFilename {
                    LoopingVideoBackgroundView(url: CustomStyleMediaStore.url(for: filename), isVisible: isVisible)
                } else {
                    EmptyView()
                }
            }
        }
        .opacity(style.customBackgroundOpacity)
        .allowsHitTesting(false)
    }
}

/// A muted, seamlessly-looping video background. Loops via a
/// `didPlayToEndTime` observer that seeks back to zero and replays, rather
/// than `AVPlayerLooper` — simpler to reason about for a single non-gapless
/// background loop, and avoids the extra `AVQueuePlayer` plumbing that
/// looper requires.
struct LoopingVideoBackgroundView: UIViewRepresentable {
    let url: URL
    let isVisible: Bool

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        let view = LoopingPlayerUIView()
        view.configure(url: url)
        view.setPlaying(isVisible)
        return view
    }

    func updateUIView(_ uiView: LoopingPlayerUIView, context: Context) {
        uiView.configure(url: url)
        // Re-applied on every update (not just when the URL changes) so a
        // flip of `isVisible` alone — the Now Playing tab losing/regaining
        // focus, with the same clip still selected — actually pauses/resumes
        // the decode. Previously `configure` unconditionally called `play()`
        // once at setup and nothing ever paused it again: this background
        // kept decoding and rendering an unmuted-resolution video loop
        // indefinitely, even while the user sat on a completely different
        // tab with the clip fully off-screen — a genuine, standalone battery/
        // heat cost with zero visible benefit, worse than the TimelineView
        // redraw-loop cost the other artwork styles had (real video decode,
        // not just a Canvas redraw).
        uiView.setPlaying(isVisible)
    }
}

final class LoopingPlayerUIView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var currentURL: URL?
    private var endObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    func configure(url: URL) {
        guard url != currentURL else { return }
        currentURL = url

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .none
        playerLayer.player = newPlayer
        player = newPlayer

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }
        // Deliberately NOT starting playback here — a brand new player
        // starts paused; `updateUIView`'s `setPlaying(isVisible)` call right
        // after this returns is what actually starts it, so a newly-selected
        // clip while this view is off-screen doesn't start decoding before
        // anyone can see it.
    }

    /// Starts/stops the actual decode — safe to call every SwiftUI update,
    /// not just on a real state change (`AVPlayer.play()`/`.pause()` are
    /// no-ops when already in that state).
    func setPlaying(_ playing: Bool) {
        if playing {
            player?.play()
        } else {
            player?.pause()
        }
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }
}

// MARK: - Animated mesh/gradient background overlay

/// A soft, slowly-animating background wash used when
/// `CustomNowPlayingStyle.useMeshGradient` is on. Uses the real SwiftUI
/// `MeshGradient` API on iOS 18+; falls back to an animated diagonal
/// `LinearGradient` sweep on older OS versions so the toggle still does
/// *something* rather than nothing pre-iOS 18.
struct NowPlayingMeshGradientBackground: View {
    let style: CustomNowPlayingStyle
    let extractedPalette: ArtworkPalette?
    // See NowPlayingView.isVisibleOnScreen's doc comment — without this,
    // this wash kept redrawing via TimelineView(.animation(minimumInterval: LumiMotion.frame)) at up to 120Hz
    // for as long as the app ran, even while the user was on a totally
    // different tab (the root TabView never deinits this one).
    let isVisible: Bool

    private var colorA: Color {
        if style.dynamicColorExtraction, let extractedPalette {
            return extractedPalette.primary
        }
        return style.backgroundColor1.color
    }

    private var colorB: Color {
        if style.dynamicColorExtraction, let extractedPalette {
            return extractedPalette.secondary
        }
        return style.backgroundColor2.color
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isVisible)) { timeline in
            let t = Float(ArtworkClock.pingPong(timeline.date, legDuration: 10))
            if #available(iOS 18.0, *) {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        SIMD2<Float>(0, 0), SIMD2<Float>(0.5, 0.05 + t * 0.1), SIMD2<Float>(1, 0),
                        SIMD2<Float>(0.05 - t * 0.1, 0.5), SIMD2<Float>(0.5, 0.5), SIMD2<Float>(0.95 + t * 0.1, 0.5),
                        SIMD2<Float>(0, 1), SIMD2<Float>(0.5, 0.95 - t * 0.1), SIMD2<Float>(1, 1)
                    ],
                    colors: [
                        colorA, colorA.opacity(0.7), colorB,
                        colorB.opacity(0.7), colorA.opacity(0.5), colorB.opacity(0.7),
                        colorB, colorA.opacity(0.7), colorA
                    ]
                )
            } else {
                LinearGradient(
                    colors: [colorA, colorB, colorA.opacity(0.85)],
                    startPoint: t > 0.5 ? .topLeading : .bottomLeading,
                    endPoint: t > 0.5 ? .bottomTrailing : .topTrailing
                )
            }
        }
        .allowsHitTesting(false)
    }
}
