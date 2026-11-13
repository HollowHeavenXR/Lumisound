import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Artwork display (switches on style)

    /// What every artwork style should treat as "playing" for purposes of
    /// its own `TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isPlaying))` redraw loop —
    /// real playback state AND this screen actually being the front-most
    /// tab (`isVisibleOnScreen`, toggled in NowPlayingView's onAppear/
    /// onDisappear). See `isVisibleOnScreen`'s doc comment for why the
    /// latter matters: the root TabView keeps this tab instantiated at all
    /// times, so without this every style kept redrawing at up to 120Hz
    /// while the user was on a completely different tab with music playing
    /// — the common case, not an edge case. Deliberately NOT the same value
    /// as `player.isPlaying` used elsewhere in this view (the actual
    /// play/pause button, Now Playing info, etc. all still need the real,
    /// visibility-independent state) — scoped to just the artwork
    /// constructors below.
    var artworkIsPlaying: Bool {
        player.isPlaying && isVisibleOnScreen
    }

    @ViewBuilder
    var artworkDisplay: some View {
        if let builtinStyle = selectedBuiltinStyle {
            builtinArtworkDisplay(for: builtinStyle)
        } else if let custom = selectedCustomStyle {
            CustomStyleArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying, config: custom)
                .environmentObject(library)
        } else {
            KaleidoscopeBloomArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)
        }
    }

    @ViewBuilder
    func builtinArtworkDisplay(for style: NowPlayingArtworkStyle) -> some View {
        switch style {
        case .kaleidoscopeBloom:
            KaleidoscopeBloomArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .synthwaveHorizon:
            SynthwaveHorizonArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .equalizerCutout:
            EqualizerCutoutArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .liquidBlobFrame:
            LiquidBlobFrameArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .origamiFoldReveal:
            OrigamiFoldRevealArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .mosaicShatter:
            MosaicShatterArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .circuitPulse:
            CircuitPulseArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .radarSweep:
            RadarSweepArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .discoMirrorBall:
            DiscoMirrorBallArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .frostedIceCrystal:
            FrostedIceCrystalArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .bioluminescentTide:
            BioluminescentTideArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .cometOrbit:
            CometOrbitArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .paperLayersParallax:
            PaperLayersParallaxArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .chalkboardSketch:
            ChalkboardSketchArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .vinylCrateStack:
            VinylCrateStackArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .moltenGlassDrip:
            MoltenGlassDripArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .confettiBurstLoop:
            ConfettiBurstLoopArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .shadowPuppetSilhouette:
            ShadowPuppetSilhouetteArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .liveSpectrum:
            // LiveSpectrumArtworkView already gates its own FFT tap on
            // onAppear/onDisappear (see that view) — passing the plain
            // (non-visibility-gated) player.isPlaying here is deliberate,
            // since its onDisappear already stops all the real work, and
            // faking "not playing" here would also zero its bars the
            // instant the user left this tab rather than leaving that to
            // its own, more direct visibility check.
            LiveSpectrumArtworkView(song: player.currentSong, isPlaying: player.isPlaying)
                .environmentObject(library)

        case .vinylGrooveSpiral:
            VinylGrooveSpiralArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .cassetteReelSpin:
            CassetteReelSpinArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .auroraVeil:
            AuroraVeilArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .rippleReflection:
            RippleReflectionArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .neonSignFlicker:
            NeonSignFlickerArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .vhsScanGlitch:
            VHSScanGlitchArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)

        case .trueMotion:
            // TrueMotionArtworkView's "isPlaying" drives a real AVPlayer
            // (play/pause), not a TimelineView redraw loop — pausing the
            // clip's video decode off-screen is the same win for the same
            // reason, so this one also takes the visibility-gated value.
            TrueMotionArtworkView(song: player.currentSong, isPlaying: artworkIsPlaying)
                .environmentObject(library)
                .environmentObject(account)
        }
    }
}
