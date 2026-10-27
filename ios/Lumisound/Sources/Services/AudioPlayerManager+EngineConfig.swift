@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Audio Engine Configuration

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // Try with full options first; fall back gracefully if Bluetooth A2DP
        // is unavailable (causes -20 error on some devices/simulators).
        let fullOptions: AVAudioSession.CategoryOptions = [.allowAirPlay, .allowBluetoothA2DP]
        let fallbackOptions: AVAudioSession.CategoryOptions = [.allowAirPlay]
        if (try? session.setCategory(.playback, mode: .default, options: fullOptions)) == nil {
            try? session.setCategory(.playback, mode: .default, options: fallbackOptions)
        }
        // Request 48 kHz — the native rate for Opus and most modern audio,
        // i.e. every YouTube-sourced track. `ensureSampleRate(matching:)`
        // raises this per-track for a genuinely higher-rate file (a hi-res
        // FLAC in the Personal Cloud Library/local library); this is just
        // the floor every session starts at.
        try? session.setPreferredSampleRate(48000)
        // NOTE: deliberately do NOT activate the session here. Activating at
        // launch (before anything plays) made the app grab the audio system
        // immediately — ducking other apps, holding the route, and acting like
        // a running ("ghost") audio app with nothing playing. The session is
        // now activated only when playback actually starts (see
        // `startEngineIfNeeded`) and released on `stop()`.

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleAudioInterruption(notification) }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        }

        // The hardware can change sample rate / channel layout (e.g. switching to/from
        // AirPlay or certain Bluetooth devices) without firing an interruption or route
        // change with `.oldDeviceUnavailable` — `AVAudioEngine` just stops itself. Left
        // unhandled, `isPlaying` stays true but the engine is silent and never recovers,
        // which is exactly the "music randomly stops" symptom users hit.
        engineConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEngineConfigurationChange() }
        }
    }

    func handleEngineConfigurationChange() {
        guard !isUsingOpusPlayer, isPlaying else { return }
        appWarn("Audio engine configuration changed — restarting engine to resume playback", category: "audio")
        guard !engine.isRunning else { return }
        // A track that is still being downloaded/transcoded schedules itself
        // and starts the node once it lands.
        guard !isSchedulingAsync else { return }
        // Capture where playback was before the engine restart: the node's
        // render clock is gone once the engine has stopped.
        let resumeAt = position
        try? AVAudioSession.sharedInstance().setActive(true)
        startEngineIfNeeded()
        // The engine stopping drops whatever was scheduled on its player nodes
        // (see `resume()`'s engineReleasedWhileIdle case), so `play()` on the
        // old node would start it with nothing to render: silence with
        // `isPlaying` still true until the stall detector reschedules it
        // three seconds later. Schedule the track again from where it was.
        guard engine.isRunning, currentSong != nil else { return }
        appLog("Engine restarted after configuration change — rescheduling from \(String(format: "%.1f", resumeAt))s", category: "audio")
        playCurrent(from: resumeAt)
    }

    func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            appLog("Audio session interrupted", category: "audio")
            if isPlaying {
                pause()
                wasInterrupted = true
            }
        case .ended:
            // `wasInterrupted` is finally READ here, which is the fix.
            //
            // It was set on `.began` and cleared at the top of this case before
            // anything ever looked at it — written twice, read never. So the app
            // had no memory that it had paused because of an interruption rather
            // than because the listener chose to, and the decision to resume rested
            // entirely on `.shouldResume` being present.
            //
            // iOS leaves that option out routinely, and the logs show how often:
            // 16 interruptions ended "not resuming" against 11 that resumed, across
            // 7 accounts. So the majority of interruptions stopped the music for
            // good and waited for someone to press play — which is exactly the
            // "audio suddenly pauses" report. Worse, the `guard` below used to
            // `return` when the options key was missing entirely, so that case
            // stopped playback permanently AND logged nothing at all.
            //
            // `.shouldResume` is a hint, not a permission slip. What actually
            // decides whether playback can continue is whether the session can be
            // made active again, so that is what is tested — and only a real
            // failure there (another app holding audio) stops the resume.
            let resumeBecauseInterrupted = wasInterrupted
            wasInterrupted = false

            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            let systemSuggestsResume = options.contains(.shouldResume)

            guard resumeBecauseInterrupted || systemSuggestsResume else {
                // Nothing was playing when the interruption began, so there is
                // nothing to put back.
                appLog("Audio session interruption ended — nothing was playing", category: "audio")
                return
            }

            do {
                // The system deactivates the session when an interruption begins,
                // so it has to be reclaimed before the engine can start.
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                appWarn("Audio session interruption ended — session still unavailable (\(error.localizedDescription)); leaving playback paused", category: "audio")
                return
            }
            appLog("Audio session interruption ended — resuming"
                   + (systemSuggestsResume ? "" : " (no shouldResume hint, but we were interrupted mid-playback)"),
                   category: "audio")
            resume()
        @unknown default:
            break
        }
    }

    func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // Not paused immediately — see the grace period below. Nothing to
            // protect if playback wasn't even active.
            guard isPlaying else { return }
            // A Bluetooth A2DP connection can blip — a brief signal dropout, a
            // codec renegotiation, a momentary handoff between two paired
            // devices — and iOS reports every one of those as a full
            // oldDeviceUnavailable/newDeviceAvailable pair, often resolving
            // within a couple hundred ms. Pausing immediately on every one of
            // those (the old behavior here) meant a transient blip that never
            // actually left produced a full pause + engine stop/restart +
            // resume cycle anyway — audible as "music randomly cuts out" on
            // a route that, from the listener's perspective, never
            // disconnected at all. Give it a short grace period to reappear
            // before committing to a real pause: a genuine disconnect still
            // pauses almost immediately (200ms), but a blip that resolves
            // within that window now produces no audible interruption
            // whatsoever — nothing was ever paused, so there's nothing to
            // resume or rebind either. Not gated on the route actually being
            // Bluetooth, since the exact same blip shape could in principle
            // happen on AirPlay or a flaky wired connection too.
            pendingRouteLossPauseTask?.cancel()
            pendingRouteLossPauseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self, self.isPlaying else { return }
                appLog("Audio route changed — output device still unavailable after grace period, pausing", category: "audio")
                self.pause()
                // `pause()` just cleared this (see its own doc comment on
                // why) — set it again now that THIS pause is the one that
                // should arm the auto-resume-on-reconnect behavior below.
                self.pausedByRouteChange = true
            }
        case .newDeviceAvailable:
            // The route blipped and recovered before the grace period above
            // elapsed — playback was never actually paused, so there's
            // nothing to resume and no stale render-graph binding to fix.
            if pendingRouteLossPauseTask != nil {
                pendingRouteLossPauseTask?.cancel()
                pendingRouteLossPauseTask = nil
                appLog("Audio route changed — output device back before the grace period elapsed; no pause needed", category: "audio")
                return
            }
            // A Bluetooth device (or other output) just connected. If playback was
            // paused because the previous route disappeared (headphones unplugged,
            // Bluetooth dropped), resume now that audio has somewhere to go again —
            // otherwise the user has to manually hit play every time their
            // Bluetooth device reconnects.
            if pausedByRouteChange {
                pausedByRouteChange = false
                appLog("Audio route changed — output device available, resuming", category: "audio")
                // `pause()` only paused the player nodes — `engine.isRunning` never
                // went false while the old device was gone, so `resume()`'s
                // `startEngineIfNeeded()` guard (`!engine.isRunning`) would see the
                // engine as "already running" and skip restarting it. But the
                // render graph is still bound to the OLD hardware route; playing a
                // node against it produces no audible output even though `isPlaying`
                // flips true. Force a real stop+restart here so the engine rebinds
                // to the newly-connected device before we resume playback.
                if !isUsingOpusPlayer {
                    if engine.isRunning {
                        engine.stop()
                    }
                    try? AVAudioSession.sharedInstance().setActive(true)
                    startEngineIfNeeded()
                }
                // A plugged-back-in headphone/Bluetooth device routinely fires
                // its interruption `.began` within ~100ms of this very
                // notification (confirmed in production logs: "Audio session
                // interrupted" / "output device available, resuming" /
                // "interruption ended — resuming" / "engine configuration
                // changed" all within the same ~100ms burst) — three
                // independent handlers each stopping/restarting/playing the
                // SAME AVAudioEngine back-to-back is exactly the shape
                // AVAudioEngine is known to crash on. `wasInterrupted` being
                // true means `handleAudioInterruption`'s `.ended` case will
                // fire its own `setActive(true)` + `resume()` once the
                // interruption genuinely ends — defer to that one instead of
                // calling `resume()` (and `activeNode.play()`) here too while
                // the session may still be mid-interruption.
                guard !wasInterrupted else { return }
                resume()
            }
        default:
            break
        }
    }

    func configureEngine() {
        guard !isEngineConfigured else { return }
        engine.attach(primaryNode)
        engine.attach(secondaryNode)
        engine.attach(primaryBeatMatch)
        engine.attach(secondaryBeatMatch)
        engine.attach(crossfadeMixer)
        engine.attach(timePitch)
        engine.attach(equalizer)
        engine.attach(reverb)
        engine.attach(reverbMixer)
        engine.attach(reverbWetMixer)
        engine.attach(reverbDryMixer)
        engine.attach(nightModeCompressor)
        engine.attach(limiter)
        engine.attach(environmentNode)
        engine.attach(spatialSourceMixer)
        configureLimiter()
        configureNightModeCompressor()
        configureReverb()

        // Both player nodes connect to separate mixer inputs (via their own
        // beatmatch time-stretch units) so their volumes can be ramped
        // independently during a crossfade, and their tempos can be nudged
        // toward each other for a "beatmatched" overlap.
        engine.connect(primaryNode, to: primaryBeatMatch, format: nil)
        engine.connect(primaryBeatMatch, to: crossfadeMixer, fromBus: 0, toBus: 0, format: nil)
        engine.connect(secondaryNode, to: secondaryBeatMatch, format: nil)
        engine.connect(secondaryBeatMatch, to: crossfadeMixer, fromBus: 0, toBus: 1, format: nil)
        engine.connect(crossfadeMixer, to: timePitch, format: nil)
        engine.connect(timePitch, to: equalizer, format: nil)
        engine.connect(equalizer, to: nightModeCompressor, format: nil)
        // Parallel reverb: compressor output fans out to the dry gain stage AND the reverb send.
        engine.connect(nightModeCompressor, to: [
            AVAudioConnectionPoint(node: reverbDryMixer, bus: 0), // dry send
            AVAudioConnectionPoint(node: reverb, bus: 0)          // wet send
        ], fromBus: 0, format: nil)
        engine.connect(reverbDryMixer, to: reverbMixer, fromBus: 0, toBus: 0, format: nil)
        engine.connect(reverb, to: reverbWetMixer, format: nil)
        engine.connect(reverbWetMixer, to: reverbMixer, fromBus: 0, toBus: 1, format: nil)
        engine.connect(reverbMixer, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)

        isEngineConfigured = true
    }

    /// Loads the default factory preset and zeroes the wet/dry mix — the real
    /// mix level/preset is then applied immediately by `applyAudioSettings()`,
    /// which runs as soon as the engine starts (or `audioSettings` is restored
    /// from disk) so reverb never plays at a stale level after a rebuild.
    func configureReverb() {
        reverb.loadFactoryPreset(.mediumRoom)
        // The reverb node is always 100% wet — it only ever produces the tail;
        // the actual dry/wet blend happens at `reverbMixer`, crossfading its
        // two inputs: the dry bus (bus 0, gain via `reverbDryMixer.outputVolume`)
        // and the wet bus (bus 1, gain via `reverbWetMixer.outputVolume`). Both
        // are (re-)applied by `applyAudioSettings()` on every settings pass;
        // the values here are just a sane pre-first-pass default (0% wet /
        // full dry) so reverb never plays at a stale level after a rebuild.
        reverb.wetDryMix = 100
        reverbWetMixer.outputVolume = 0
        reverbDryMixer.outputVolume = 1
        reverbMixer.outputVolume = 1
        loadedReverbPreset = .mediumRoom
    }

    /// Maps our Codable `ReverbRoomPreset` (Models layer, no AVFoundation
    /// dependency) onto the real `AVAudioUnitReverbPreset`.
    func avReverbPreset(for preset: ReverbRoomPreset) -> AVAudioUnitReverbPreset {
        switch preset {
        case .smallRoom: return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .largeRoom: return .largeRoom
        case .mediumHall: return .mediumHall
        case .largeHall: return .largeHall
        case .plate: return .plate
        case .cathedral: return .cathedral
        }
    }
}
