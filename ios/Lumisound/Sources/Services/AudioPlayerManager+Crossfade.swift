@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Crossfade

    /// Sets a beatmatch node's rate and bypasses it whenever that rate is
    /// unity. `primaryBeatMatch`/`secondaryBeatMatch` sit permanently wired
    /// into the signal path for whichever player node is active — not just
    /// during the few seconds of an actual crossfade — and
    /// `AVAudioUnitTimePitch` is one of the heavier stock AudioUnits
    /// (phase-vocoder-style processing), categorically more expensive than
    /// a passthrough. Outside a beatmatched crossfade, both nodes sat at
    /// rate 1.0 but kept running full DSP to produce output identical to
    /// bypass. Every call site that touches either node's `.rate` goes
    /// through this one function so the bypass flag can never drift out of
    /// sync with the rate it should track.
    private func setBeatMatchRate(_ node: AVAudioUnitTimePitch, _ rate: Float) {
        node.rate = rate
        node.bypass = (rate == 1.0)
    }

    /// The plan for the transition out of the current track.
    ///
    /// Computed from the same inputs wherever it is needed — the scheduling
    /// timer and the fade itself — so when the fade starts and how long it runs
    /// cannot disagree.
    func transitionPlan(into nextSong: Song?) -> SmartCrossfade.Plan {
        let base = audioSettings.crossfadeDuration
        guard audioSettings.smartCrossfadeEnabled else {
            return SmartCrossfade.Plan(duration: base, startBefore: base, reason: "smart-off")
        }
        // Only consulted when the server has not profiled the outgoing track —
        // the profile supersedes it, since a level cannot separate a cold stop
        // from a sustained ending.
        let level: Double? = currentSong?.transitionProfile == nil
            ? Double(AudioVisualizerService.shared.overallLevel)
            : nil
        return SmartCrossfade.plan(
            base: base,
            outgoingDuration: currentSong?.duration ?? 0,
            incomingDuration: nextSong?.duration ?? 0,
            outgoing: currentSong?.transitionProfile,
            incoming: nextSong?.transitionProfile,
            outgoingBPM: currentSong.flatMap { bpmCache[$0.id] ?? $0.bpm },
            incomingBPM: nextSong.flatMap { bpmCache[$0.id] ?? $0.bpm },
            measuredLevel: level
        )
    }

    /// How far before the end of the file the fade should begin.
    func transitionLead() -> TimeInterval {
        transitionPlan(into: peekNextSong()).startBefore
    }

    func beginCrossfade() {
        guard let nextSong = peekNextSong(), let nextURL = nextSong.url else {
            skipToNext(); return
        }
        // See LumisoundExclusiveExtensionService.playableURL's doc comment —
        // without this, a `.lms`-converted next track would fail to open
        // here for a pure extension-recognition reason, silently degrading
        // every crossfade into a plain skip instead of an actual fade.
        //
        // An Opus/WebM/OGG source (the common case for this app's YouTube-
        // sourced library) fails this direct open too — AVAudioFile can't
        // read those containers at all, only the transcoded copy
        // AudioEncoderService produces (same as `scheduleCurrent`'s
        // `transcodeAndSchedule` branch). Awaiting that transcode here would
        // stall mid-fade, so fall back to whatever `prewarmTranscode` already
        // finished for this track instead of giving up immediately — without
        // this, every such transition silently degraded to a plain skip
        // (no fade, no error, nothing in the logs) even with Smart/manual
        // Crossfade on.
        let directFile = try? AVAudioFile(forReading: LumisoundExclusiveExtensionService.playableURL(for: nextURL))
        let transcodedFile = directFile == nil
            ? AudioEncoderService.shared.cachedPlaybackURL(for: nextURL).flatMap { try? AVAudioFile(forReading: $0) }
            : nil
        guard let nextFile = directFile ?? transcodedFile else {
            skipToNext(); return
        }

        isCrossfading = true
        // Smart Auto Crossfade (when enabled): snap the fade to the outgoing
        // track's beat grid (if its tempo is known) so it starts and ends on a
        // downbeat instead of an arbitrary fraction of a second. With Smart
        // Crossfade off, use the fixed user-set duration verbatim.
        let smartCrossfade = audioSettings.smartCrossfadeEnabled
        let smartPlan = smartCrossfade ? transitionPlan(into: nextSong) : nil
        let fadeDuration = smartPlan?.duration ?? audioSettings.crossfadeDuration

        // Telemetry: this is the ONLY place the executed plan (as opposed to
        // the trigger-arming estimate in `transitionLead()`) is known, and
        // until now nothing logged WHY a fade ran the length it did — only
        // the raw "trigger reached at Xs of Ys" line downstream in
        // `checkCrossfadeTrigger()`. Reported as "tracks randomly skip or
        // fade into the next track" — with no reason logged, a fade that
        // SmartCrossfade had shrunk to barely more than its 1.5s floor
        // (e.g. a false `cold-stop` read off a track's natural last-note
        // decay, which sits right at this analyzer's silence threshold on
        // almost any real ending) was indistinguishable in the logs from an
        // intentional short fade, or from an outright bug. Log it so a
        // pattern of suspiciously-short fades across unrelated tracks is
        // actually visible instead of inferred after the fact from gaps
        // between "Crossfade trigger reached" timestamps.
        if let smartPlan {
            appLog(
                String(format: "beginCrossfade: smart plan duration=%.2fs (base=%.2fs) reason=%@ — \"%@\" -> \"%@\"",
                       smartPlan.duration, audioSettings.crossfadeDuration, smartPlan.reason,
                       currentSong?.displayName ?? "?", nextSong.displayName),
                category: "audio"
            )
        }

        // The outgoing node is the one currently playing; incoming is the opposite.
        // Captured as `let` — the upcoming `usingPrimaryNode` flip changes what
        // `activeNode` resolves to, but these bindings keep pointing at the
        // correct physical nodes for the rest of this function and the timer below.
        let outgoing = usingPrimaryNode ? primaryNode : secondaryNode
        let incoming = usingPrimaryNode ? secondaryNode : primaryNode
        let outgoingBeatMatch = usingPrimaryNode ? primaryBeatMatch : secondaryBeatMatch
        let incomingBeatMatch = usingPrimaryNode ? secondaryBeatMatch : primaryBeatMatch

        // True beatmatching (Smart Auto Crossfade only): nudge both tracks'
        // tempos toward their midpoint for the duration of the overlap, then
        // ease the incoming track back to its native tempo as the fade
        // completes. Only attempted when Smart Crossfade is on, both BPMs are
        // known, and the required adjustment is modest (±8%) — outside that
        // range (or with Smart Crossfade off) both rates stay at 1.0 for a
        // plain volume crossfade.
        let outgoingBPM = currentSong.flatMap { bpmCache[$0.id] }
        let incomingBPM = bpmCache[nextSong.id]
        var incomingRate: Float = 1.0
        if smartCrossfade, let oBPM = outgoingBPM, let iBPM = incomingBPM, oBPM > 0, iBPM > 0 {
            let target = (oBPM + iBPM) / 2
            let oRatio = target / oBPM
            let iRatio = target / iBPM
            if (0.92...1.08).contains(oRatio), (0.92...1.08).contains(iRatio) {
                setBeatMatchRate(outgoingBeatMatch, Float(oRatio))
                incomingRate = Float(iRatio)
            } else {
                setBeatMatchRate(outgoingBeatMatch, 1.0)
            }
        } else {
            setBeatMatchRate(outgoingBeatMatch, 1.0)
        }
        setBeatMatchRate(incomingBeatMatch, incomingRate)

        incoming.volume = 0
        let gen = scheduleGeneration &+ 1
        scheduleGeneration = gen
        incoming.scheduleFile(nextFile, at: nil) { [weak self] in
            Task { @MainActor in
                // Incoming finished its full file — drive normal track-end logic.
                guard let self, self.scheduleGeneration == gen else { return }
                self.handleTrackEnded()
            }
        }
        startEngineIfNeeded()
        incoming.play()

        // Switch every "what's playing" property to the incoming track THE INSTANT
        // it starts audibly — not after the multi-second fade finishes. `activeNode`
        // is a plain `usingPrimaryNode` lookup that we flip right here, so position
        // tracking immediately reads frames from `incoming`. Previously these stayed
        // pointed at the outgoing track for the whole fade: `updatePositionFromPlayer`
        // combined the OLD track's fileStartFrame/duration with the NEW node's
        // elapsed time (the position briefly snapping toward zero against the old
        // track's duration), while Now Playing, the miniplayer, and "Up Next" kept
        // showing the outgoing track's title/artwork/queue position until the fade
        // ended — exactly the "miniplayer freaks out, Now Playing/Up Next don't
        // live-update" glitch reported during crossfades. Flipping here keeps every
        // published property in lockstep with the audio from the first frame.
        usingPrimaryNode.toggle()
        advanceIndex()
        currentSong = nextSong
        audioFile = nextFile
        fileStartFrame = 0
        position = 0
        duration = nextFile.duration
        gaplessScheduled = false
        pendingNextIndex = nil
        // Crossfade schedules `nextFile` directly rather than through scheduleCurrent,
        // so start at neutral rather than carrying over the outgoing track's (likely
        // mismatched) computed gain — then kick off this track's own analysis
        // (see `analyzeReplayGain`) so it doesn't just stay at neutral for its
        // entire playback the way it used to before that call was added here.
        resetReplayGainForNewTrack(ramped: true)
        analyzeReplayGain(for: nextURL)
        updateNowPlaying()
        applyAutoEQIfNeeded(bpm: incomingBPM ?? nextSong.bpm)

        // The track that just became current was prewarmed before this fade
        // started; warm the one after it now so its tempo is ready for the
        // next crossfade.
        prewarmBPM(for: peekNextSong())
        prewarmPlayableCache(for: peekNextSong())
        prewarmTranscode(for: peekNextSong())

        // Arm the crossfade trigger for the track that just became current —
        // mirroring the setup `scheduleCurrent` does for the very first track.
        // Without this, `handleTrackEnded` only ever calls `beginCrossfade` again
        // at the natural end of `nextFile`'s full playback (zero seconds of
        // overlap), so every transition after the first one in a session degrades
        // from an actual crossfade into the new track simply fading in from
        // silence once the old one has already finished. Re-arming here keeps
        // the whole queue crossfading with consistent overlap.
        //
        // A position rather than a countdown — see `crossfadeTriggerPosition`.
        // The incoming track begins at 0, so its own duration is the origin.
        let nextTrigger = nextFile.duration - fadeDuration
        crossfadeTriggerPosition = (fadeDuration > 0 && nextTrigger > 0) ? nextTrigger : nil

        // When crossfadeDuration == 0, steps clamps to 1 (instantaneous swap). Intentional.
        let steps = max(1, Int(fadeDuration * 30))
        let interval = fadeDuration / Double(steps)
        var step = 0

        crossfadeTimer?.invalidate()
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { t.invalidate(); return }
                // Freeze the ramp while paused instead of advancing it.
                //
                // `pause()` pauses BOTH nodes, so no audio moves — but this ramp
                // is wall-clock, so it used to keep advancing through silence and
                // run the fade to completion, calling `finishCrossfade` and
                // stopping the outgoing track. Pausing anywhere inside the few
                // seconds of an overlap therefore meant resuming on the NEXT
                // track, with the one you paused already stopped. Same visible
                // symptom as the overdue crossfade-start timer this commit
                // replaces (see `crossfadeTriggerPosition`), just a narrower
                // window to land in.
                //
                // Returning without invalidating leaves the timer live, so the
                // fade simply picks up where it left off on resume — which is
                // exactly what the audio does.
                guard self.isPlaying else { return }
                step += 1
                let progress = Float(step) / Float(steps)
                let clipped = min(max(progress, 0), 1)
                let (outgoingGain, incomingGain) = self.crossfadeGains(atProgress: clipped)
                outgoing.volume = outgoingGain * self.audioSettings.volume
                incoming.volume = incomingGain * self.audioSettings.volume
                // Ease the incoming track from its beatmatched rate back to its
                // native tempo (1.0) over the course of the fade, so by the time
                // the outgoing track is fully silent, the new track is playing
                // at its own correct speed.
                setBeatMatchRate(incomingBeatMatch, incomingRate + (1.0 - incomingRate) * clipped)
                if step >= steps {
                    t.invalidate()
                    self.crossfadeTimer = nil
                    self.finishCrossfade(outgoing: outgoing)
                }
            }
        }
    }

    /// Called when the volume-ramp timer completes. All "now playing" state already
    /// switched to the incoming track at the moment the fade began (see
    /// beginCrossfade) — this just silences and stops the now-abandoned outgoing node.
    func finishCrossfade(outgoing: AVAudioPlayerNode) {
        outgoing.stop()
        outgoing.volume = audioSettings.volume
        // Reset the abandoned node's beatmatch rate to neutral so it's ready
        // for reuse on the next crossfade.
        setBeatMatchRate(outgoing === primaryNode ? primaryBeatMatch : secondaryBeatMatch, 1.0)
        isCrossfading = false
    }

    func cancelCrossfade() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTriggerPosition = nil
        if isCrossfading {
            // `usingPrimaryNode`/`activeNode` already point at the track that's
            // becoming current (flipped at the start of the fade — see
            // beginCrossfade) — that node keeps playing and gets reused/
            // rescheduled by the caller. The other node is the abandoned
            // fade-out track: silence and stop it so it doesn't keep sounding.
            let abandoned = usingPrimaryNode ? secondaryNode : primaryNode
            abandoned.stop()
            abandoned.volume = audioSettings.volume
            setBeatMatchRate(abandoned === primaryNode ? primaryBeatMatch : secondaryBeatMatch, 1.0)
            setBeatMatchRate(activeNode === primaryNode ? primaryBeatMatch : secondaryBeatMatch, 1.0)
            activeNode.volume = audioSettings.volume
            isCrossfading = false
        }
    }

    /// Splits a 0...1 crossfade progress value into (outgoing, incoming) linear
    /// gain multipliers, per `audioSettings.crossfadeCurve`. Equal-power uses a
    /// quarter-cosine/sine pair so the combined perceived loudness stays
    /// constant through the overlap (`cos²+sin²=1`) — a plain linear fade
    /// noticeably dips in the middle, since `(1-x)+x=1` is constant in
    /// *amplitude*, not perceived (roughly power/energy) loudness.
    func crossfadeGains(atProgress progress: Float) -> (outgoing: Float, incoming: Float) {
        switch audioSettings.crossfadeCurve ?? .equalPower {
        case .linear:
            return (1 - progress, progress)
        case .equalPower:
            let theta = Double(progress) * Double.pi / 2
            return (Float(cos(theta)), Float(sin(theta)))
        }
    }

    /// Adjusts `base` (the user's configured crossfade duration) to the nearest
    /// whole number of beats at `bpm`, so the fade starts and ends on a
    /// downbeat instead of an arbitrary fraction of a second. Falls back to
    /// `base` unchanged if `bpm` isn't known yet, and clamps the result to
    /// within ±50% of `base` so a very slow track doesn't balloon a short
    /// crossfade into a multi-second one (or vice versa for a fast track).
    func smartFadeDuration(base: TimeInterval, bpm: Double?) -> TimeInterval {
        // Live-analyzer nudge: a track still at full energy this close to
        // its end reads as an abrupt cut — lean shorter/tighter so the
        // overlap doesn't smear two loud passages together. Deliberately
        // one-directional (never LONGER than the base) — `overallLevel`
        // reads as `0` both for genuine silence and for "the analyzer
        // tap hasn't had time to settle yet" (e.g. a very short track), and
        // there's no way to tell those apart from a single reading; erring
        // toward "no change" for the ambiguous case is safer than guessing
        // it means an intentional quiet fade-out and stretching the
        // duration on a measurement that might not be real yet.
        let level = Double(min(1, max(0, AudioVisualizerService.shared.overallLevel)))
        let levelMultiplier = 1.0 - level * 0.3 // 1.0x at level 0/unmeasured, 0.7x at full energy
        let adjustedBase = base * levelMultiplier

        guard adjustedBase > 0, let bpm, bpm > 0 else {
            let result = adjustedBase > 0 ? adjustedBase : base
            appLog(
                String(format: "smartFadeDuration: measuredLevel=%.2f multiplier=%.2f base=%.2fs -> %.2fs (no BPM, beat-snap skipped)", level, levelMultiplier, base, result),
                category: "audio"
            )
            return result
        }
        let beatLength = 60.0 / bpm
        let beats = max(1, (adjustedBase / beatLength).rounded())
        let snapped = beats * beatLength
        let result = min(max(snapped, base * 0.5), base * 1.5)
        appLog(
            String(format: "smartFadeDuration: measuredLevel=%.2f multiplier=%.2f base=%.2fs adjusted=%.2fs bpm=%.1f -> snapped=%.2fs -> clamped=%.2fs", level, levelMultiplier, base, adjustedBase, bpm, snapped, result),
            category: "audio"
        )
        return result
    }

    /// Kicks off (cached) BPM analysis for `song` so its tempo is available by
    /// the time `beginCrossfade` needs it. Fire-and-forget — `bpmCache` is
    /// populated asynchronously and read synchronously from `beginCrossfade`.
    func prewarmBPM(for song: Song?) {
        guard let song, bpmCache[song.id] == nil, song.url != nil else { return }
        Task { [weak self] in
            guard let self, let library = self.libraryManager,
                  let bpm = await library.bpm(for: song)
            else { return }
            await MainActor.run {
                self.bpmCache[song.id] = bpm
                // Surface the result on `currentSong` too, so the Now Playing
                // UI can display tempo once it's known.
                if self.currentSong?.id == song.id {
                    self.currentSong?.bpm = bpm
                    self.applyAutoEQIfNeeded(bpm: bpm)
                }
            }
        }
    }

    /// Same shape/reasoning as `prewarmBPM` — unlocks a locked (.lms) song's
    /// playable cache off-thread ahead of time, so when gapless/crossfade
    /// (or the next `scheduleCurrent` once this song becomes current) needs
    /// it, the synchronous `playableURL(for:)` call is guaranteed to hit
    /// the already-warm fast path instead of doing the full unlock inline.
    /// Fire-and-forget, no-op if already warm or not a locked track.
    func prewarmPlayableCache(for song: Song?) {
        guard let song, let url = song.url else { return }
        Task { await LumisoundExclusiveExtensionService.prewarmPlayableURL(for: url) }
    }

    /// Same shape/reasoning as `prewarmPlayableCache`, for the OTHER thing
    /// that can make a next track fail to open directly: an Opus/WebM/OGG
    /// container AVAudioFile can't read until AudioEncoderService transcodes
    /// it. Populates that service's on-disk cache ahead of time so
    /// `beginCrossfade`'s synchronous `cachedPlaybackURL` lookup has
    /// something to find instead of giving up and calling `skipToNext()`.
    /// Fire-and-forget, no-op for a native format (checked cheaply inside
    /// `transcodeForPlayback` itself) or an already-cached file.
    func prewarmTranscode(for song: Song?) {
        guard let song, let url = song.url else { return }
        let ext = LumisoundExclusiveExtensionService.effectiveExtension(for: url)
        guard ["opus", "webm", "ogg"].contains(ext) else { return }
        Task { _ = await AudioEncoderService.shared.transcodeForPlayback(url) }
    }

    /// If "Auto EQ" is enabled, switches the EQ preset to match the current
    /// track's genre (preferred) or tempo (fallback) — see
    /// `EQPreset.auto(forBPM:genre:)` — then schedules a small analyzer-driven
    /// correction on top of it. No-op if Auto EQ is off or neither genre nor
    /// tempo is usable.
    func applyAutoEQIfNeeded(bpm: Double?) {
        guard audioSettings.autoEQEnabled else {
            appLog("applyAutoEQIfNeeded: Auto EQ disabled, skipping", category: "audio")
            return
        }
        // Measurement first, tags only as a fallback.
        //
        // The old path chose from the genre STRING, falling back to a tempo
        // band. Neither describes how a track sounds: a genre tag is frequently
        // missing or wrong on a downloaded track, two songs sharing one are
        // routinely mastered nothing alike, and tempo is a rate rather than a
        // tonal balance. So the curve had no relationship to whether the track
        // was already bass-heavy — where a bass boost only makes it muddy — or
        // genuinely thin. See SpectralEQMatcher.
        if let spectrum = currentSong?.spectralProfile,
           let target = AudioSettings.libraryEQTarget {
            let matched = SpectralEQMatcher.preset(for: spectrum, target: target)
            let gain = SpectralEQMatcher.improvement(for: spectrum, preset: matched, target: target)
            appLog(String(format: "applyAutoEQIfNeeded: measured -> %@ (%.0f%% closer to library target) for \"%@\"",
                          matched.rawValue, gain * 100, currentSong?.title ?? "?"),
                   category: "audio")
            // "Why this pick" (see NowPlayingView+Equalizer's reason row) —
            // this gain% was already being computed for the log line above;
            // just not thrown away before now.
            autoEQReason = String(format: "Measured from this track's own mix — %@ gets it %.0f%% closer to your library's typical tone", matched.rawValue, gain * 100)
            if audioSettings.eqPreset != matched {
                applyEQPreset(matched)
            }
            return
        }

        let genre = currentSong?.genre
        guard let preset = EQPreset.auto(forBPM: bpm, genre: genre) else {
            appLog("applyAutoEQIfNeeded: no usable genre/BPM for \"\(currentSong?.title ?? "?")\" (genre=\(genre ?? "nil"), bpm=\(bpm.map { String($0) } ?? "nil")) — skipping", category: "audio")
            autoEQReason = nil
            return
        }
        appLog("applyAutoEQIfNeeded: preset \(audioSettings.eqPreset) -> \(preset) for \"\(currentSong?.title ?? "?")\" (genre=\(genre ?? "nil"), bpm=\(bpm.map { String($0) } ?? "nil"))", category: "audio")
        if let genre, !genre.isEmpty {
            autoEQReason = "Picked for this track's genre (\(genre))"
        } else if let bpm {
            autoEQReason = "Picked from this track's tempo (~\(Int(bpm)) BPM) — no genre tag to go on"
        } else {
            autoEQReason = nil
        }
        if audioSettings.eqPreset != preset {
            applyEQPreset(preset)
        }
        scheduleAnalyzerEQCorrection()
    }

    /// Genre/BPM alone can't see how THIS specific recording actually
    /// sounds — a "Rock" preset picked for a quieter, bass-light-mixed rock
    /// track still leaves it under-boosted down low, and an already
    /// bass-heavy mix gets over-boosted further by the same preset. A couple
    /// of seconds into the track (enough for the live analyzer's smoothing
    /// to settle past the previous track's tail), nudge the preset's bass/
    /// treble bands by a small amount based on the actually-measured
    /// balance. This is Auto EQ using the app's one real "audio listener and
    /// analyzer" (`AudioVisualizerService`) instead of only a static
    /// genre/tempo lookup table.
    private func scheduleAnalyzerEQCorrection() {
        let generation = eqCorrectionGeneration &+ 1
        eqCorrectionGeneration = generation
        AudioVisualizerService.shared.start(for: .autoEQ)
        appLog("scheduleAnalyzerEQCorrection: generation \(generation) armed, measuring in 2.5s", category: "audio")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.eqCorrectionGeneration == generation else {
                    appLog("scheduleAnalyzerEQCorrection: generation \(generation) superseded (now \(self.eqCorrectionGeneration)) — discarding", category: "audio")
                    return
                }
                guard self.audioSettings.autoEQEnabled else {
                    appLog("scheduleAnalyzerEQCorrection: generation \(generation) fired but Auto EQ was disabled meanwhile — discarding", category: "audio")
                    return
                }
                // BUGFIX (reported: the phone runs warm during ordinary
                // playback — confirmed as a real, continuous cost, not a
                // one-off): nothing below this point ever stopped the
                // analyzer tap, so once Auto EQ measured one track it
                // just kept running a full FFT pass on every single audio
                // buffer for the rest of the session — the ONLY thing that
                // ever turned it off was the user explicitly flipping the
                // Auto EQ setting itself back off. The real need for live
                // analysis is exactly the 2.5s window this function already
                // waits out per track; stop it the moment that measurement
                // is read below, same as every other caller of `start(for:)`
                // already pairs with its own `stop(for:)`. Deferred (not
                // called immediately) because the correction logic just
                // below still needs the live `analyzer.bassLevel`/
                // `trebleLevel` values — `stop(for:)` zeroes them out the
                // instant the tap actually comes down.
                defer { AudioVisualizerService.shared.stop(for: .autoEQ) }
                let analyzer = AudioVisualizerService.shared
                // Bass vs. treble balance, roughly -1...1 (negative = measured
                // bass-light, positive = measured bass-heavy relative to
                // treble). Only correct on a real, clearly-measured imbalance —
                // small differences are just normal spectral variation between
                // tracks, not something to "fix".
                let balance = analyzer.bassLevel - analyzer.trebleLevel
                guard abs(balance) > 0.15 else {
                    appLog(String(format: "scheduleAnalyzerEQCorrection: generation \(generation) measured bass=%.2f treble=%.2f (balance=%.2f) — within tolerance, no correction", analyzer.bassLevel, analyzer.trebleLevel, balance), category: "audio")
                    return
                }
                let correction = max(-3.0, min(3.0, Double(-balance) * 6))
                var bands = self.audioSettings.eqBands
                guard bands.indices.contains(1) else { return }
                let oldBand0 = bands[0], oldBand1 = bands[1]
                bands[0] = Float(min(max(Double(bands[0]) + correction, -12), 12))
                bands[1] = Float(min(max(Double(bands[1]) + correction * 0.7, -12), 12))
                self.audioSettings.eqBands = bands
                appLog(
                    String(format: "scheduleAnalyzerEQCorrection: generation \(generation) measured balance=%.2f -> correction=%.2fdB — band0 %.1f->%.1f, band1 %.1f->%.1f", balance, correction, oldBand0, bands[0], oldBand1, bands[1]),
                    category: "audio"
                )
            }
        }
    }
}
