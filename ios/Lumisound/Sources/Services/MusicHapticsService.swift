import AVFoundation
import CoreHaptics
import Foundation

/// Music Haptics: plays each track's haptic score in step with what you hear.
///
/// Everything musical lives in the Rust core (rust/core/src/haptics.rs):
/// the full-track analysis that turns kicks into deep thumps, snares into
/// firm taps, hats into light ticks and sustained bass into a rumble that
/// follows it, and the scheduler that times each event against the engine
/// position, the output latency (Bluetooth adds ~0.3 s) and the playback
/// speed, and notices seeks. This class only feeds the scheduled cues to
/// Core Haptics, a short look-ahead at a time.
///
/// Scores are cached per file; the next track in the queue is analysed
/// ahead so haptics are there from its first beat.
@MainActor
final class MusicHapticsService {
    static let shared = MusicHapticsService()

    /// How strong the haptics feel (Settings → Playback → Music Haptics).
    enum Strength: String, CaseIterable, Identifiable {
        case subtle, balanced, intense
        var id: String { rawValue }
        var title: String {
            switch self {
            case .subtle: "Subtle"
            case .balanced: "Balanced"
            case .intense: "Intense"
            }
        }
        var scale: Float {
            switch self {
            case .subtle: 0.6
            case .balanced: 1.0
            case .intense: 1.35
            }
        }
    }

    static let strengthKey = "musicHaptics.strength"
    static var strength: Strength {
        Strength(rawValue: UserDefaults.standard.string(forKey: strengthKey) ?? "") ?? .balanced
    }

    /// How often cues are handed over, and how far ahead they reach.
    private static let tickInterval: TimeInterval = 0.15
    private static let lookahead: Double = 0.45

    private var engine: CHHapticEngine?
    private var timer: Timer?
    private var isRunning = false
    private var scheduler: HapticScheduler?
    private var scoreSongID: String?
    private var scoreTask: Task<Void, Never>?
    private var prewarmedSongID: String?
    /// Players handed to Core Haptics with the time their last cue ends.
    private var players: [(player: CHHapticPatternPlayer, endsAt: Date)] = []

    var isAvailable: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    private init() {}

    func updatePlayback(enabled: Bool, isPlaying: Bool, engineAvailable: Bool) {
        if enabled && isPlaying && engineAvailable && isAvailable {
            startIfNeeded()
        } else {
            stop()
        }
    }

    // MARK: Engine

    private func startIfNeeded() {
        guard !isRunning else { return }
        guard let player = AudioPlayerManager.shared, player.isPlaying, !player.isUsingOpusPlayer else { return }
        guard let hapticEngine = try? CHHapticEngine() else {
            appWarn("Music Haptics unavailable: Core Haptics engine could not be created", category: "audio")
            return
        }
        // Haptics only: never touch the app's audio session.
        hapticEngine.playsHapticsOnly = true
        hapticEngine.isAutoShutdownEnabled = false
        hapticEngine.resetHandler = { [weak self] in
            Task { @MainActor in self?.restartAfterEngineReset() }
        }
        hapticEngine.stoppedHandler = { [weak self] reason in
            appLog("Music Haptics engine stopped: \(reason.rawValue)", category: "audio")
            Task { @MainActor in self?.players.removeAll() }
        }
        do {
            try hapticEngine.start()
        } catch {
            appWarn("Music Haptics unavailable: Core Haptics engine failed to start (\(error.localizedDescription))", category: "audio")
            return
        }
        engine = hapticEngine
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.02
        loadScore(for: player.currentSong)
        appLog("Music Haptics on (\(Self.strength.title))", category: "audio")
    }

    private func restartAfterEngineReset() {
        guard isRunning else { return }
        players.removeAll()
        scheduler?.reset()
        try? engine?.start()
    }

    private func stop() {
        guard isRunning || timer != nil else { return }
        timer?.invalidate()
        timer = nil
        stopPlayers()
        scheduler?.reset()
        engine?.stop()
        engine = nil
        isRunning = false
        scoreTask?.cancel()
        scoreTask = nil
        scheduler = nil
        scoreSongID = nil
    }

    // MARK: Scores

    /// Uses the cached score at once, else analyses the track off the main
    /// thread (haptics join in as soon as it's ready).
    private func loadScore(for song: Song?) {
        guard let song, song.id != scoreSongID else { return }
        scoreSongID = song.id
        scheduler = nil
        stopPlayers()
        scoreTask?.cancel()
        guard let url = song.url, url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        if let score = hapticScoreCached(path: path) {
            // The Haptics Brain's corrections (learned per track and globally).
            scheduler = HapticScheduler(score: hapticBrainApply(score: score))
            prewarmNext()
            return
        }
        let songID = song.id
        scoreTask = Task { [weak self] in
            let score = await Self.analyze(url: url)
            guard let self, !Task.isCancelled, self.scoreSongID == songID else { return }
            if let score {
                self.scheduler = HapticScheduler(score: hapticBrainApply(score: score))
                let s = score.stats()
                appLog(String(format: "Music Haptics: \"%@\" — %d hits (%d low / %d mid / %d high), %.0fs rumble, analysed at %.0fx",
                              url.lastPathComponent, s.transients, s.lowHits, s.midHits, s.highHits, s.continuousSecs, s.analysisXRealtime),
                       category: "audio")
            } else {
                appWarn("Music Haptics: could not analyse \"\(url.lastPathComponent)\"", category: "audio")
            }
            self.prewarmNext()
        }
    }

    /// Analyse the next queued track ahead of time (cached on disk).
    private func prewarmNext() {
        guard let next = AudioPlayerManager.shared?.peekNextSong(), next.id != prewarmedSongID,
              let url = next.url, url.isFileURL else { return }
        prewarmedSongID = next.id
        guard hapticScoreCached(path: url.standardizedFileURL.path) == nil else { return }
        Task.detached(priority: .utility) { _ = await Self.analyze(url: url) }
    }

    /// Core decode where it can; AVFoundation PCM for the rest (Opus in WebM).
    private nonisolated static func analyze(url: URL) async -> HapticScore? {
        let path = url.standardizedFileURL.path
        if CoreAudio.canDecode(path: path) {
            return await Task.detached(priority: .utility) { hapticScore(path: path, pcm: nil) }.value
        }
        guard let pcm = await BPMAnalyzerService.decodeMonoAV(url: url, sampleRate: 22_050, maxSeconds: 1_200) else { return nil }
        return await Task.detached(priority: .utility) { hapticScore(path: path, pcm: pcm) }.value
    }

    // MARK: Playback

    private func tick() {
        guard isRunning, let player = AudioPlayerManager.shared, player.isPlaying, !player.isUsingOpusPlayer else {
            stop()
            return
        }
        if player.currentSong?.id != scoreSongID { loadScore(for: player.currentSong) }
        pruneFinishedPlayers()
        guard let scheduler, let engine else { return }
        let session = AVAudioSession.sharedInstance()
        let latency = session.outputLatency + session.ioBufferDuration
        let batch = scheduler.next(position: player.preciseRenderedPosition(), outputLatency: latency,
                                   speed: Double(player.audioSettings.speed), lookahead: Self.lookahead,
                                   strength: Self.strength.scale)
        if batch.reset { stopPlayers() }
        guard !batch.cues.isEmpty else { return }
        var events: [CHHapticEvent] = []
        var curves: [CHHapticParameterCurve] = []
        var end: TimeInterval = 0
        for cue in batch.cues {
            let at = max(0, cue.at)
            let params = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: cue.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: cue.sharpness),
            ]
            if cue.continuous {
                events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: params, relativeTime: at, duration: cue.duration))
                // Core Haptics curves take at most 16 points (the core sends ≤ 16).
                let points = cue.envelope.prefix(16).enumerated().map { i, v in
                    CHHapticParameterCurve.ControlPoint(relativeTime: Double(i) * cue.envelopeStep, value: v)
                }
                if points.count > 1 {
                    curves.append(CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: points, relativeTime: at))
                }
                end = max(end, at + cue.duration)
            } else {
                events.append(CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: at))
                end = max(end, at + 0.05)
            }
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            let p = try engine.makePlayer(with: pattern)
            try p.start(atTime: CHHapticTimeImmediate)
            players.append((p, Date().addingTimeInterval(end)))
        } catch {
            appLog("Music Haptics: pattern failed (\(error.localizedDescription))", category: "audio")
        }
    }

    private func pruneFinishedPlayers() {
        let now = Date()
        players.removeAll { $0.endsAt < now }
    }

    /// Cancel cues already handed over (seek, pause, track change).
    private func stopPlayers() {
        for p in players { try? p.player.stop(atTime: CHHapticTimeImmediate) }
        players.removeAll()
    }
}
