import AVFoundation

/// Computes a real-time frequency spectrum from the live audio graph, for
/// the "Live Spectrum" Now Playing artwork style. Taps `mainMixerNode` (see
/// `AudioPlayerManager.startVisualizerTap`) rather than decoding/analyzing
/// anything separately, so it reacts to exactly what's actually audible
/// (effects, EQ, crossfade included) — entirely on-device, no server.
///
/// Also the app's one real "audio listener/analyzer" — Auto EQ
/// (`AudioPlayerManager.applyAutoEQIfNeeded`) and Smart Auto Crossfade
/// (`AudioPlayerManager.smartFadeDuration`), both in
/// `AudioPlayerManager+Crossfade.swift`, read `bassLevel`/`midLevel`/
/// `trebleLevel`/`overallLevel` off the SAME per-buffer FFT pass this
/// already runs for the visualizer, rather than each standing up its own
/// tap/analysis (only one tap can be installed on `mainMixerNode` bus 0 at a
/// time, and a second FFT pass over the same audio would just be wasted CPU).
@MainActor
final class AudioVisualizerService: ObservableObject {
    static let shared = AudioVisualizerService()

    /// Identifies why a caller wants analysis running — the underlying tap
    /// stays installed as long as at least one reason is active. A `Set`
    /// (rather than a plain ref count) is what makes `start(for:)`/
    /// `stop(for:)` idempotent per-reason: the existing Live Spectrum view
    /// already calls `start()`/`stop()` from both `.onAppear`/`.onDisappear`
    /// AND `.onChange(of: isPlaying)` without them being strictly paired 1:1
    /// (SwiftUI view identity churn, multiple views bound to the same
    /// `isPlaying`, etc.) — a plain counter would drift out of sync and
    /// leave the tap either stuck on or stuck off. Inserting/removing the
    /// same reason twice is always safe.
    enum AnalysisReason: Hashable {
        case liveSpectrumUI
        case autoEQ
        case smartCrossfade
        case musicHaptics
        case galleryReactiveBackground
    }
    private var activeReasons: Set<AnalysisReason> = [] {
        // The core governor sets the analysis rate from who's asking (full
        // rate only for a visible visualizer) and the device's heat.
        didSet { HeatGovernor.core.setAnalysisReasons(reasons: activeReasonNames) }
    }

    var activeReasonNames: [String] { activeReasons.map { "\($0)" }.sorted() }

    /// Per buffer on the audio/tap thread: true when this buffer should be
    /// analyzed (the core's lock-free rate limit). Everything else is
    /// dropped before any copying or FFT.
    nonisolated static func wantsSample() -> Bool {
        HeatGovernor.core.wantsSample()
    }

    static let barCount = 24

    /// Smoothed per-bar magnitude, 0...1.
    @Published private(set) var magnitudes: [Float] = Array(repeating: 0, count: barCount)

    /// Coarse smoothed band energy, 0...1 (relative/self-referential, not
    /// calibrated to an absolute loudness reference) — derived from the same
    /// `fftMagnitudes` the 24-bar spectrum uses, just summed into 3 broad
    /// ranges instead of 24 log-spaced ones. Bass ~20-250Hz, mid
    /// ~250Hz-4kHz, treble ~4-16kHz.
    @Published private(set) var bassLevel: Float = 0
    @Published private(set) var midLevel: Float = 0
    @Published private(set) var trebleLevel: Float = 0
    /// Smoothed overall level across the full spectrum, 0...1.
    @Published private(set) var overallLevel: Float = 0

    private let fftSize = 2048

    private init() {}

    /// Requests analysis for `reason`. Safe to call repeatedly for the same
    /// reason (idempotent), and safe to call from multiple independent
    /// reasons at once — the tap stays installed as long as any reason is
    /// active. Back-compat no-arg overload defaults to the original Live
    /// Spectrum UI call sites' meaning.
    func start(for reason: AnalysisReason = .liveSpectrumUI) {
        let wasInactive = activeReasons.isEmpty
        activeReasons.insert(reason)
        appLog("AudioVisualizerService: start(for: \(reason)) — active reasons now \(activeReasons)", category: "audio")
        guard wasInactive else { return }
        guard AudioPlayerManager.shared != nil else {
            appWarn("AudioVisualizerService: start(for: \(reason)) requested but AudioPlayerManager.shared is nil — tap not installed", category: "audio")
            return
        }
        appLog("AudioVisualizerService: installing analyzer tap on the main mixer", category: "audio")
        lastLevelLogTime = .distantPast
        AudioPlayerManager.shared?.startVisualizerTap { [weak self] buffer in
            self?.process(buffer: buffer)
        }
    }

    /// Releases `reason`'s interest in analysis. The underlying tap only
    /// actually stops once no reason remains active. Safe to call for a
    /// reason that was never started (a harmless no-op).
    func stop(for reason: AnalysisReason = .liveSpectrumUI) {
        activeReasons.remove(reason)
        appLog("AudioVisualizerService: stop(for: \(reason)) — active reasons now \(activeReasons)", category: "audio")
        guard activeReasons.isEmpty else { return }
        appLog("AudioVisualizerService: removing analyzer tap — no reasons remain active", category: "audio")
        AudioPlayerManager.shared?.stopVisualizerTap()
        magnitudes = Array(repeating: 0, count: Self.barCount)
        bassLevel = 0
        midLevel = 0
        trebleLevel = 0
        overallLevel = 0
    }

    /// Throttle for the periodic band-level trace below — `applySmoothed`
    /// runs on every audio buffer (tens of times/sec), so logging every call
    /// would flood the log; this proves the analyzer is actually receiving
    /// and processing live audio (not stuck at 0) without the spam.
    private var lastLevelLogTime: Date = .distantPast
    private let levelLogInterval: TimeInterval = 3.0

    /// Runs on the audio render thread (the tap's callback), not the main
    /// thread — `nonisolated` so it can execute there directly instead of
    /// needing to hop actors just to start; only the final publish step
    /// hops back to the main actor.
    nonisolated private func process(buffer: AVAudioPCMBuffer) {
        // Rate-limited by the callers (`wantsSample`) before this is reached.
        guard let channelData = buffer.floatChannelData else { return }
        let available = Int(buffer.frameLength)
        guard available > 0 else { return }
        let n = min(available, fftSize)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: n))
        let rate = Float(buffer.format.sampleRate > 0 ? buffer.format.sampleRate : 44100)
        // FFT + bar/band reduction in the Rust core.
        let s = spectrum(samples: samples, sampleRate: rate, fftSize: UInt32(fftSize), barCount: UInt32(Self.barCount))
        Task { @MainActor [weak self] in
            self?.applySmoothed(s.bars, bands: (s.bass, s.mid, s.treble, s.overall))
        }
    }

    private func applySmoothed(_ new: [Float], bands: (bass: Float, mid: Float, treble: Float, overall: Float)) {
        if new.count == magnitudes.count {
            for i in 0..<magnitudes.count {
                magnitudes[i] = magnitudes[i] * 0.55 + new[i] * 0.45
            }
        }
        let smoothing: Float = 0.7
        bassLevel = bassLevel * smoothing + bands.bass * (1 - smoothing)
        midLevel = midLevel * smoothing + bands.mid * (1 - smoothing)
        trebleLevel = trebleLevel * smoothing + bands.treble * (1 - smoothing)
        overallLevel = overallLevel * smoothing + bands.overall * (1 - smoothing)

        // Proof-of-life trace: confirms the analyzer is actually reading
        // live signal (levels tracking what's playing) rather than silently
        // stuck at 0 for every active reason — throttled so it's readable
        // instead of one line per buffer.
        //
        // `localOnly`: this fires every few seconds for as long as anything is
        // playing, which made it the single largest source of rows in the shared
        // server log table — 78,601 in one retention window, about 14% of
        // everything, for a line whose only use is watching one device analyse one
        // track. It stays in the console and in bug-report context, where it is
        // actually read, and no longer travels.
        let now = Date()
        if now.timeIntervalSince(lastLevelLogTime) >= levelLogInterval {
            lastLevelLogTime = now
            appLog(
                String(
                    format: "AudioVisualizerService: levels bass=%.2f mid=%.2f treble=%.2f overall=%.2f (reasons: %@)",
                    bassLevel, midLevel, trebleLevel, overallLevel, "\(activeReasons)"
                ),
                category: "audio",
                localOnly: true
            )
        }
    }
}
