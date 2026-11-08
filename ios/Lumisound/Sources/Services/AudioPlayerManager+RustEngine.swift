import AVFoundation
import Foundation
import UIKit

/// Bridges Rust engine callbacks (any thread) onto the main actor.
final class RustEngineRelay: EngineListener, @unchecked Sendable {
    weak var player: AudioPlayerManager?

    func onTrackEnded(id: UInt64) {
        Task { @MainActor [weak self] in self?.player?.rustTrackEnded(id: id) }
    }

    func onTrackStarted(id: UInt64) {
        Task { @MainActor [weak self] in self?.player?.rustTrackStarted(id: id) }
    }

    func onTrackFailed(id: UInt64) {
        Task { @MainActor [weak self] in self?.player?.rustTrackFailed(id: id) }
    }
}

/// Playback through the Rust audio engine (rust/core/src/engine): decoding
/// (locked `.lms` files in place), gapless hand-over, crossfades, speed/pitch,
/// EQ, reverb, 8D/tremolo/vibrato, spatial, mono, night mode and volume all
/// run in Rust; this file only maps the player's state onto it. The engine is
/// on by default; the system engine is used only when the listener turns it
/// off in Settings, or for a file the core genuinely can't open (reported as
/// `engine_fallback`). Engine-exclusive tracks never use the system engine.
extension AudioPlayerManager {
    static let rustRelay = RustEngineRelay()
    static let rust = AudioEngine(listener: rustRelay)
    static let rustEngineKey = "rust_audio_engine"

    var isUsingRustEngine: Bool { rustDeckID != nil }

    static var rustEngineEnabled: Bool {
        UserDefaults.standard.object(forKey: rustEngineKey) as? Bool ?? true
    }

    func rustEligible(for url: URL) -> Bool {
        // Engine-exclusive tracks always use the Lumisound engine, whatever
        // the Settings toggle says.
        let exclusive = currentSong.map { EngineExclusiveService.shared.isExclusive($0) } ?? false
        guard (Self.rustEngineEnabled && !rustBypassOnce) || exclusive else { return false }
        // Effects map onto settings + a modulation (8D, tremolo, vibrato),
        // all of which the engine does.
        // The core decodes locked `.lms` files in place — no unlocked copy.
        let ok = CoreAudio.canDecode(path: url.path)
        if !ok { reportEngineFallback(reason: "unsupported_format", url: url) }
        return ok
    }

    private func ensureRustOutput() -> Bool {
        if rustOutputStarted { return true }
        // Starting the output from the background (resume from the lock
        // screen / headphones after the output was released while paused)
        // fails with a CoreAudio error unless the session is (re)claimed
        // first — every "output_start_failed" in telemetry was backgrounded.
        // Re-assert the playback category, activate, and retry a few times
        // with a short pause before giving up.
        let session = AVAudioSession.sharedInstance()
        var lastError: Error?
        for attempt in 0..<4 {
            if attempt > 0 {
                configureAudioSession()
                usleep(UInt32(40_000 * attempt))
            }
            do {
                try session.setActive(true)
            } catch {
                lastError = error
            }
            do {
                try Self.rust.startOutput()
                rustOutputStarted = true
                startEngineTelemetry()
                startEngineGuard()
                if attempt > 0 {
                    appLog("Rust audio output started on attempt \(attempt + 1)", category: "audio")
                    RemoteLogger.log(category: "audio_engine", event: "output_start_retried", level: "info",
                                     message: "attempt \(attempt + 1)",
                                     detail: ["background": UIApplication.shared.applicationState != .active])
                }
                return true
            } catch {
                lastError = error
            }
        }
        let message = lastError?.localizedDescription ?? "unknown"
        appWarn("Rust audio output failed to start: \(message)", category: "audio")
        reportEngineFallback(reason: "output_start_failed", url: currentSong?.url, error: message)
        return false
    }

    /// Takes over the current track; false = caller uses the AVAudioEngine path.
    func scheduleWithRustEngine(url: URL, startTime requested: TimeInterval) -> Bool {
        // Locked tracks play straight from the `.lms` file (unmasked on the
        // fly by the core): no whole-file unlock before a cold start.
        let playable = url
        // From the top: open where the music starts (Skip Silent Intros).
        let startTime = requested > 0 ? requested : SilenceTrimService.openingOffset(for: url)
        // One backend at a time.
        primaryNode.stop()
        secondaryNode.stop()
        if engine.isRunning { engine.stop() }
        // Only open the audio output when playback actually starts (`rustPlay`).
        // Preparing a track while paused — notably restoring the last track
        // when iOS relaunches the app in the background — used to start it
        // here, where iOS refuses (no active session in the background):
        // the track was handed to the system engine and played there later.
        // The engine loads and decodes without a running output.
        if isPlaying { guard ensureRustOutput() else { return false } }
        Self.rustRelay.player = self
        // Speed/pitch apply to every deck the engine opens.
        _ = try? Self.rust.setSpeedPitch(speed: Double(audioSettings.speed), pitchSemitones: Double(audioSettings.pitchSemitones))
        do {
            let id = try Self.rust.load(path: playable.path, startSecs: max(0, startTime), gainDb: 0)
            rustDeckID = id
            rustNextDeckID = nil
            rustNextPath = nil
        } catch {
            appWarn("Rust engine could not open \(url.lastPathComponent): \(error.localizedDescription)", category: "audio")
            reportEngineFallback(reason: "open_failed", url: url, error: error.localizedDescription)
            return false
        }
        audioFile = nil
        resetReplayGainForNewTrack()
        analyzeReplayGain(for: url)
        let probed = probeDuration(path: playable.path, cacheDir: CoreAudio.unlockDir)
        duration = probed > 0 ? probed : (currentSong?.duration ?? 0)
        position = startTime
        gaplessScheduled = false
        pendingNextIndex = nil
        setRustCrossfadeTrigger()
        applyRustSettings()
        prewarmBPM(for: currentSong)
        prewarmBPM(for: peekNextSong())
        queueRustGaplessNext()
        if let song = currentSong { EngineExclusiveService.shared.trackStartedOnEngine(song) }
        appLog("Rust engine: loaded \(currentSong?.displayName ?? "?") at \(String(format: "%.1f", startTime))s", category: "audio")
        return true
    }

    func queueRustGaplessNext() {
        guard isUsingRustEngine, audioSettings.gaplessEnabled, !audioSettings.crossfadeActive, rustNextDeckID == nil,
              let next = peekNextSong(), let url = next.url, url.isFileURL else { return }
        // Locked tracks are read in place by the core: nothing to prewarm.
        let path = url.path
        let start = SilenceTrimService.openingOffset(for: url)
        guard CoreAudio.canDecode(path: path), let id = try? Self.rust.queueNextAt(path: path, startSecs: start, gainDb: 0) else { return }
        rustNextDeckID = id
        rustNextPath = path
        rustNextStart = start
    }

    func applyRustSettings() {
        let s = audioSettings
        Self.rust.setVolume(volume: s.volume)
        // Pitch-preserving speed + pitch shift (WSOLA) — re-opens the deck at
        // the current position when they change.
        if let newID = try? Self.rust.setSpeedPitch(speed: Double(s.speed), pitchSemitones: Double(s.pitchSemitones)) {
            rustDeckID = newID
            rustNextDeckID = nil
            rustNextPath = nil
            queueRustGaplessNext()
        }
        Self.rust.setEq(gainsDb: effectiveEqGains(bands: s.eqBands, eqEnabled: s.equalizerEnabled,
                                                   bassBoostEnabled: s.bassBoostEnabled, bassBoostGain: s.bassBoostGain),
                        enabled: s.equalizerEnabled || s.bassBoostEnabled)
        let wet = s.reverbEnabled ? min(max(s.reverbWetDryMix, 0), 100) / 100 : 0
        Self.rust.setEffects(reverbWet: wet, reverbPreset: s.reverbPreset.rawValue,
                             mono: s.monoAudioEnabled == true, nightMode: s.nightModeEnabled == true)
        applyRustModulation()
        applyRustSpatial()
    }

    /// Binaural spatial audio in the engine, steered by headphone head tracking.
    func applyRustSpatial() {
        guard isUsingRustEngine else { return }
        let on = audioSettings.spatialAudioEnabled == true
        Self.rust.setSpatial(enabled: on, yawDegrees: 0)
        let tracker = SpatialAudioService.shared
        if on, tracker.isHeadTrackingAvailable {
            tracker.onOrientationUpdate = { orientation in
                Self.rust.setSpatial(enabled: true, yawDegrees: orientation.yaw)
            }
            tracker.startTracking()
        } else if !on, rustSpatialTracking {
            tracker.stopTracking()
            tracker.onOrientationUpdate = nil
        }
        rustSpatialTracking = on
    }

    /// ReplayGain (tags or measured) applied inside the engine; volume is separate.
    func applyRustTrackGain() {
        let linear: Float = audioSettings.replayGainEnabled ? replayGainLinearGain : 1.0
        Self.rust.setTrackGain(gainDb: 20 * log10(max(linear, 0.0001)))
    }

    /// 8D rotation / tremolo state -> engine modulation.
    func applyRustModulation() {
        guard isUsingRustEngine else { return }
        let pan = (is8DActive || audioSettings.eightDAudioEnabled == true) ? Float(rotationHz) : 0
        let trem = isTremoloActive ? Float(tremoloFrequency) : 0
        Self.rust.setModulation(panHz: pan, tremoloHz: trem, tremoloDepth: isTremoloActive ? tremoloDepth : 0,
                                vibratoHz: isVibratoActive ? Float(vibratoFrequency) : 0,
                                vibratoSemitones: isVibratoActive ? Float(vibratoDepth) : 0)
    }

    func rustPlay() {
        let wasStarted = rustOutputStarted
        guard ensureRustOutput() else {
            // No output even after retries: never sit there silently "playing".
            if let song = currentSong, EngineExclusiveService.shared.isExclusive(song) {
                refuseSystemEngine(for: song, reason: "output_start_failed")
            } else {
                tearDownRustEngine()
                rustBypassOnce = true
                playCurrent(from: position)
                rustBypassOnce = false
            }
            return
        }
        // Play on a stream iOS has stopped does nothing audible: restart it.
        // (A stream started just now hasn't called back yet — skip that one.)
        if wasStarted, !Self.rust.outputAlive(maxAgeMs: 1500) { restartRustOutput(reason: "play", force: true) }
        Self.rust.play()
    }

    func rustPause() {
        Self.rust.pause(fadeSecs: 0.06)
    }

    func rustSeek(to target: TimeInterval) {
        rustNextDeckID = nil
        rustNextPath = nil
        Self.rust.clearNext()
        if let id = try? Self.rust.seek(secs: target) { rustDeckID = id }
        position = target
        queueRustGaplessNext()
    }

    func tearDownRustEngine() {
        guard isUsingRustEngine else { return }
        Self.rust.stop()
        rustDeckID = nil
        rustNextDeckID = nil
        rustNextPath = nil
    }

    func releaseRustOutputIfIdle() {
        guard rustOutputStarted, !isPlaying else { return }
        Self.rust.stopOutput()
        rustOutputStarted = false
    }

    func updatePositionFromRustEngine() {
        guard isUsingRustEngine, !isSchedulingAsync else { return }
        let p = Self.rust.position()
        position = min(duration > 0 ? duration : p, max(0, p))
    }

    private func setRustCrossfadeTrigger() {
        if audioSettings.crossfadeActive && audioSettings.crossfadeDuration > 0 {
            let trigger = duration - transitionLead()
            crossfadeTriggerPosition = trigger > 0 ? trigger : nil
        } else {
            crossfadeTriggerPosition = nil
        }
    }

    /// Fade into the next track inside the engine (equal-power or linear,
    /// smart-crossfade length when enabled).
    func beginRustCrossfade() {
        guard let nextSong = peekNextSong(), let nextURL = nextSong.url, nextURL.isFileURL else {
            skipToNext(); return
        }
        let path = nextURL.path
        guard CoreAudio.canDecode(path: path) else { skipToNext(); return }
        let plan = audioSettings.smartCrossfadeEnabled ? transitionPlan(into: nextSong) : nil
        let fade = max(0.1, plan?.duration ?? audioSettings.crossfadeDuration)
        Self.rust.clearNext()
        rustNextDeckID = nil
        rustNextPath = nil
        let equalPower = (audioSettings.crossfadeCurve ?? .equalPower) == .equalPower
        // Smart crossfade beat-matches: the incoming track runs at the
        // outgoing tempo through the overlap, then eases to its own.
        var tempoMatch = 1.0
        if audioSettings.smartCrossfadeEnabled,
           let oBPM = currentSong.flatMap({ bpmCache[$0.id] }), let iBPM = bpmCache[nextSong.id] {
            tempoMatch = Lumisound.beatmatchRatio(outgoingBpm: oBPM, incomingBpm: iBPM)
        }
        let introStart = SilenceTrimService.openingOffset(for: nextURL)
        guard let id = try? Self.rust.crossfadeTo(path: path, secs: fade, startSecs: introStart, gainDb: 0,
                                                  equalPower: equalPower, tempoMatch: tempoMatch) else {
            skipToNext(); return
        }
        rustDeckID = id
        isCrossfading = true
        advanceIndex()
        currentSong = nextSong
        resetReplayGainForNewTrack(ramped: true)
        analyzeReplayGain(for: nextURL)
        let probed = probeDuration(path: path, cacheDir: CoreAudio.unlockDir)
        duration = probed > 0 ? probed : nextSong.duration
        position = introStart
        updateNowPlaying()
        applyAutoEQIfNeeded(bpm: bpmCache[nextSong.id] ?? nextSong.bpm)
        prewarmBPM(for: peekNextSong())
        let nextTrigger = duration - fade
        crossfadeTriggerPosition = nextTrigger > 0 ? nextTrigger : nil
        let gen = scheduleGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(fade * 1_000_000_000))
            guard let self, self.scheduleGeneration == gen else { return }
            self.isCrossfading = false
        }
        appLog(String(format: "Rust engine: crossfade %.1fs (tempo x%.3f) → %@", fade, tempoMatch, nextSong.displayName), category: "audio")
    }

    // MARK: Engine events

    func rustTrackStarted(id: UInt64) {
        guard id == rustNextDeckID, let path = rustNextPath else { return }
        advanceIndex()
        rustDeckID = id
        rustNextDeckID = nil
        rustNextPath = nil
        Self.rust.adoptCurrent(path: path, gainDb: 0)
        resetReplayGainForNewTrack(ramped: true)
        if let url = currentSong?.url { analyzeReplayGain(for: url) }
        let probed = probeDuration(path: path, cacheDir: CoreAudio.unlockDir)
        duration = probed > 0 ? probed : (currentSong?.duration ?? 0)
        position = rustNextStart
        rustNextStart = 0
        updateNowPlaying()
        prewarmBPM(for: peekNextSong())
        queueRustGaplessNext()
        appLog("Rust engine: gapless → \(currentSong?.displayName ?? "?")", category: "audio")
    }

    func rustTrackEnded(id: UInt64) {
        guard id == rustDeckID else { return }
        handleTrackEnded()
    }

    func rustTrackFailed(id: UInt64) {
        guard id == rustDeckID else { return }
        if let song = currentSong, EngineExclusiveService.shared.isExclusive(song) {
            refuseSystemEngine(for: song, reason: "decode_failed")
            return
        }
        appWarn("Rust engine failed to decode \(currentSong?.displayName ?? "?") — using AVAudioEngine", category: "audio")
        reportEngineFallback(reason: "decode_failed", url: currentSong?.url,
                             error: Self.rust.incidents().last(where: { $0.kind == .deckFailed })?.message)
        tearDownRustEngine()
        rustBypassOnce = true
        playCurrent(from: position)
        rustBypassOnce = false
    }

    /// An engine-exclusive track couldn't start on the Lumisound engine: it
    /// is never handed to the system engine. Tell the listener, report it,
    /// and move on.
    func refuseSystemEngine(for song: Song, reason: String) {
        appWarn("Engine-exclusive \(song.displayName): \(reason) — not falling back to the system engine", category: "audio")
        reportEngineFallback(reason: "exclusive_refused_\(reason)", url: song.url)
        ToastCenter.shared.show("\"\(song.displayName)\" plays only on the Lumisound engine and couldn't start", category: .warning)
        tearDownRustEngine()
        isPlaying = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.skipToNext()
        }
    }
}
