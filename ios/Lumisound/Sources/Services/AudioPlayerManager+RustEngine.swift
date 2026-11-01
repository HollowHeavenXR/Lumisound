import AVFoundation
import Foundation

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

/// Playback through the Rust audio engine (rust/core/src/engine): decoding,
/// gapless hand-over, EQ, reverb, mono, night mode and volume run in Rust;
/// this file only maps the player's state onto it. Tracks or settings the
/// engine doesn't cover yet (streams still downloading, Opus/WebM, speed/
/// pitch, crossfade, spatial/8D/special effects) keep the AVAudioEngine path.
extension AudioPlayerManager {
    static let rustRelay = RustEngineRelay()
    static let rust = AudioEngine(listener: rustRelay)
    static let rustEngineKey = "rust_audio_engine"

    var isUsingRustEngine: Bool { rustDeckID != nil }

    static var rustEngineEnabled: Bool {
        UserDefaults.standard.object(forKey: rustEngineKey) as? Bool ?? true
    }

    func rustEligible(for url: URL) -> Bool {
        guard Self.rustEngineEnabled, !rustBypassOnce else { return false }
        let s = audioSettings
        if s.speed != 1 || s.pitchSemitones != 0 { return false }
        if s.spatialAudioEnabled == true { return false }
        // Effects map onto settings + an optional modulation; the engine does
        // 8D rotation and tremolo, vibrato (pitch LFO) stays on AVAudioEngine.
        if activeEffectNeedsPitchModulation() { return false }
        return CoreAudio.canDecode(path: LumisoundExclusiveExtensionService.playableURL(for: url).path)
    }

    private func ensureRustOutput() -> Bool {
        if rustOutputStarted { return true }
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try Self.rust.startOutput()
            rustOutputStarted = true
            return true
        } catch {
            appWarn("Rust audio output failed to start: \(error.localizedDescription)", category: "audio")
            return false
        }
    }

    /// Takes over the current track; false = caller uses the AVAudioEngine path.
    func scheduleWithRustEngine(url: URL, startTime: TimeInterval) -> Bool {
        let playable = LumisoundExclusiveExtensionService.playableURL(for: url)
        // One backend at a time.
        primaryNode.stop()
        secondaryNode.stop()
        if engine.isRunning { engine.stop() }
        guard ensureRustOutput() else { return false }
        Self.rustRelay.player = self
        do {
            let id = try Self.rust.load(path: playable.path, startSecs: max(0, startTime), gainDb: 0)
            rustDeckID = id
            rustNextDeckID = nil
            rustNextPath = nil
        } catch {
            appWarn("Rust engine could not open \(url.lastPathComponent): \(error.localizedDescription)", category: "audio")
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
        prewarmPlayableCache(for: peekNextSong())
        queueRustGaplessNext()
        appLog("Rust engine: loaded \(currentSong?.displayName ?? "?") at \(String(format: "%.1f", startTime))s", category: "audio")
        return true
    }

    func queueRustGaplessNext() {
        guard isUsingRustEngine, audioSettings.gaplessEnabled, !audioSettings.crossfadeActive, rustNextDeckID == nil,
              let next = peekNextSong(), let url = next.url, url.isFileURL else { return }
        if LumisoundExclusiveExtensionService.isConverted(url),
           !LumisoundExclusiveExtensionService.hasWarmPlayableCache(for: url) {
            Task { [weak self] in
                await LumisoundExclusiveExtensionService.prewarmPlayableURL(for: url)
                self?.queueRustGaplessNext()
            }
            return
        }
        let path = LumisoundExclusiveExtensionService.playableURL(for: url).path
        guard CoreAudio.canDecode(path: path), let id = try? Self.rust.queueNext(path: path, gainDb: 0) else { return }
        rustNextDeckID = id
        rustNextPath = path
    }

    func applyRustSettings() {
        let s = audioSettings
        Self.rust.setVolume(volume: s.volume)
        Self.rust.setEq(gainsDb: effectiveEqGains(bands: s.eqBands, eqEnabled: s.equalizerEnabled,
                                                   bassBoostEnabled: s.bassBoostEnabled, bassBoostGain: s.bassBoostGain),
                        enabled: s.equalizerEnabled || s.bassBoostEnabled)
        let wet = s.reverbEnabled ? min(max(s.reverbWetDryMix, 0), 100) / 100 : 0
        Self.rust.setEffects(reverbWet: wet, reverbPreset: s.reverbPreset.rawValue,
                             mono: s.monoAudioEnabled == true, nightMode: s.nightModeEnabled == true)
        applyRustModulation()
    }

    /// ReplayGain (tags or measured) applied inside the engine; volume is separate.
    func applyRustTrackGain() {
        let linear: Float = audioSettings.replayGainEnabled ? replayGainLinearGain : 1.0
        Self.rust.setTrackGain(gainDb: 20 * log10(max(linear, 0.0001)))
    }

    func activeEffectNeedsPitchModulation() -> Bool {
        let id = audioSettings.activeEffectID
        guard !id.isEmpty, id != "none" else { return false }
        let effect: AudioEffect?
        if let ref = LuaEffectEngine.scriptRef(forEffectID: id) {
            effect = try? LuaEffectEngine.resolve(ref, track: currentSong)
        } else {
            effect = AudioEffectsService.allEffects.first(where: { $0.id == id })
        }
        return effect?.specialMode.type == .vibrato
    }

    /// 8D rotation / tremolo state -> engine modulation.
    func applyRustModulation() {
        guard isUsingRustEngine else { return }
        let pan = (is8DActive || audioSettings.eightDAudioEnabled == true) ? Float(rotationHz) : 0
        let trem = isTremoloActive ? Float(tremoloFrequency) : 0
        Self.rust.setModulation(panHz: pan, tremoloHz: trem, tremoloDepth: isTremoloActive ? tremoloDepth : 0)
    }

    func rustPlay() {
        guard ensureRustOutput() else { return }
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
        let path = LumisoundExclusiveExtensionService.playableURL(for: nextURL).path
        guard CoreAudio.canDecode(path: path) else { skipToNext(); return }
        let plan = audioSettings.smartCrossfadeEnabled ? transitionPlan(into: nextSong) : nil
        let fade = max(0.1, plan?.duration ?? audioSettings.crossfadeDuration)
        Self.rust.clearNext()
        rustNextDeckID = nil
        rustNextPath = nil
        let equalPower = (audioSettings.crossfadeCurve ?? .equalPower) == .equalPower
        guard let id = try? Self.rust.crossfadeTo(path: path, secs: fade, startSecs: 0, gainDb: 0, equalPower: equalPower) else {
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
        position = 0
        updateNowPlaying()
        applyAutoEQIfNeeded(bpm: bpmCache[nextSong.id] ?? nextSong.bpm)
        prewarmBPM(for: peekNextSong())
        prewarmPlayableCache(for: peekNextSong())
        let nextTrigger = duration - fade
        crossfadeTriggerPosition = nextTrigger > 0 ? nextTrigger : nil
        let gen = scheduleGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(fade * 1_000_000_000))
            guard let self, self.scheduleGeneration == gen else { return }
            self.isCrossfading = false
        }
        appLog(String(format: "Rust engine: crossfade %.1fs → %@", fade, nextSong.displayName), category: "audio")
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
        position = 0
        updateNowPlaying()
        prewarmBPM(for: peekNextSong())
        prewarmPlayableCache(for: peekNextSong())
        queueRustGaplessNext()
        appLog("Rust engine: gapless → \(currentSong?.displayName ?? "?")", category: "audio")
    }

    func rustTrackEnded(id: UInt64) {
        guard id == rustDeckID else { return }
        handleTrackEnded()
    }

    func rustTrackFailed(id: UInt64) {
        guard id == rustDeckID else { return }
        appWarn("Rust engine failed to decode \(currentSong?.displayName ?? "?") — using AVAudioEngine", category: "audio")
        tearDownRustEngine()
        rustBypassOnce = true
        playCurrent(from: position)
        rustBypassOnce = false
    }
}
