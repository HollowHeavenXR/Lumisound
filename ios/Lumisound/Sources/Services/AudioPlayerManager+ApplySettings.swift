@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Audit logging for discrete settings toggles
    //
    // `audioSettings`'s `didSet` fires on every mutation — including every
    // single tick of a Volume/Speed/Pitch/EQ-band slider drag, which would
    // make an unconditional "settings changed" log call there wildly noisy
    // (hundreds of entries per drag gesture). Diffing specifically the
    // discrete Bool toggle fields (not the continuous Float/Double ones)
    // naturally filters that out for free — a slider drag never touches any
    // of these fields, so the diff below produces nothing to log for one,
    // while still catching every toggle flip centrally, in one place,
    // instead of needing an `.onChange` added by hand to every individual
    // `Toggle` across every Settings screen (many, and easy to miss one).
    // Part of the app's audit-log push to the bridge (see AppLogger).
    func logAudioSettingsToggleChanges(from old: AudioSettings, to new: AudioSettings) {
        let toggles: [(String, Bool, Bool)] = [
            ("equalizerEnabled", old.equalizerEnabled, new.equalizerEnabled),
            ("crossfadeEnabled", old.crossfadeEnabled, new.crossfadeEnabled),
            ("smartCrossfadeEnabled", old.smartCrossfadeEnabled, new.smartCrossfadeEnabled),
            ("gaplessEnabled", old.gaplessEnabled, new.gaplessEnabled),
            ("replayGainEnabled", old.replayGainEnabled, new.replayGainEnabled),
            ("bassBoostEnabled", old.bassBoostEnabled, new.bassBoostEnabled),
            ("eightDAudioEnabled", old.eightDAudioEnabled ?? false, new.eightDAudioEnabled ?? false),
            ("autoEQEnabled", old.autoEQEnabled, new.autoEQEnabled),
            ("reverbEnabled", old.reverbEnabled, new.reverbEnabled),
            ("spatialAudioEnabled", old.spatialAudioEnabled ?? false, new.spatialAudioEnabled ?? false),
            ("monoAudioEnabled", old.monoAudioEnabled ?? false, new.monoAudioEnabled ?? false),
            ("nightModeEnabled", old.nightModeEnabled ?? false, new.nightModeEnabled ?? false),
            ("musicHapticsEnabled", old.musicHapticsEnabled ?? false, new.musicHapticsEnabled ?? false),
        ]
        for (name, wasOn, isOn) in toggles where wasOn != isOn {
            appLog("Setting changed: \(name) -> \(isOn)", category: "settings")
        }
        if old.eqPreset != new.eqPreset {
            appLog("Setting changed: eqPreset -> \(new.eqPreset)", category: "settings")
        }
        if old.activeEffectID != new.activeEffectID {
            appLog("Setting changed: activeEffectID -> \(new.activeEffectID)", category: "settings")
        }
    }

    // MARK: - Apply Audio Settings

    func applyAudioSettings() {
        MusicHapticsService.shared.updatePlayback(
            enabled: audioSettings.musicHapticsEnabled ?? false,
            isPlaying: isPlaying,
            engineAvailable: !isUsingOpusPlayer
        )

        // AVPlayer fallback path (opus/webm/ogg streams) — only Speed can be
        // mapped onto AVPlayer's API (EQ/pitch/crossfade/gapless/ReplayGain need
        // the AVAudioEngine graph below, which this path bypasses entirely).
        // Re-apply `.rate` directly so dragging the Speed slider mid-playback
        // takes effect immediately instead of silently doing nothing.
        if isUsingOpusPlayer {
            // AVPlayer.volume is hard-clamped to 0...1 by AVFoundation and this
            // path bypasses the AVAudioEngine graph entirely (no `equalizer`/
            // `limiter` available here to realise a boost above unity). Clamp
            // explicitly so values above 1.0 don't silently no-op — boost beyond
            // 100% simply isn't available for opus/webm/ogg streams played via
            // this fallback.
            opusPlayer?.volume = min(audioSettings.volume, 1.0)
            if isPlaying { opusPlayer?.rate = Float(audioSettings.speed) }
            return
        }

        // Volume — apply to both nodes (secondary will be 0 unless crossfading).
        primaryNode.volume = isCrossfading ? primaryNode.volume : audioSettings.volume
        if !isCrossfading { secondaryNode.volume = audioSettings.volume }

        // Speed / pitch — `AVAudioUnitTimePitch` is one of the heavier stock
        // AudioUnits (phase-vocoder-style processing), run on every buffer
        // for the life of every playback session regardless of whether
        // anything is actually being shifted. Most listening happens at the
        // 1.0x/0-semitone defaults, where this node's output is identical
        // to passthrough — bypass it then and only pay the real DSP cost
        // when speed or pitch is actually changed from default. Same
        // "zero reconnect cost, just a bypass flip" shape already used for
        // nightModeCompressor/reverb below.
        timePitch.bypass = audioSettings.speed == 1.0 && audioSettings.pitchSemitones == 0
        timePitch.rate = audioSettings.speed
        timePitch.pitch = audioSettings.pitchSemitones * 100

        // EQ bands
        let eqEnabled = audioSettings.equalizerEnabled
        for (index, band) in equalizer.bands.enumerated() {
            band.bypass = !eqEnabled
            if audioSettings.eqBands.indices.contains(index) {
                var gain = eqEnabled ? audioSettings.eqBands[index] : 0
                // Apply bass boost on top of EQ gains for bands 0 (32Hz) and 1 (64Hz).
                if audioSettings.bassBoostEnabled && eqEnabled {
                    if index == 0 || index == 1 {
                        let boost = min(max(audioSettings.bassBoostGain, 0), 15)
                        gain += boost
                    }
                }
                // AVAudioUnitEQ clamps band gain to -96...24 dB internally — combining a
                // +12 dB EQ slider with a +15 dB bass boost (27 dB) silently hit that
                // ceiling, so the boost had less audible effect than its displayed value
                // implied. Clamp explicitly so the applied gain matches what's shown.
                band.gain = min(max(gain, -96), 24)
            }
        }

        // If bass boost is enabled but EQ is disabled, enable EQ bands 0 & 1 for bass
        // boost only. This block is mutually exclusive with the EQ block above (which
        // already adds boost to bands 0/1 when both EQ and bass boost are on), so there
        // is no double-application.
        if audioSettings.bassBoostEnabled && !audioSettings.equalizerEnabled {
            for (index, band) in equalizer.bands.enumerated() {
                band.bypass = false
                if index == 0 || index == 1 {
                    band.gain = min(max(audioSettings.bassBoostGain, 0), 15)
                } else {
                    band.gain = 0
                }
            }
        }

        // Reverb — live amount and room preset. Only reload the factory preset
        // when it actually changed (loadFactoryPreset is the heavy call, and it
        // resets wetDryMix, so re-pin it to 100 after). Applied on every pass so
        // toggling reverb or dragging the mix slider takes effect instantly on
        // whatever is playing.
        if loadedReverbPreset != audioSettings.reverbPreset {
            reverb.loadFactoryPreset(avReverbPreset(for: audioSettings.reverbPreset))
            reverb.wetDryMix = 100
            loadedReverbPreset = audioSettings.reverbPreset
        }
        let reverbWet = min(max(audioSettings.reverbWetDryMix, 0), 100) / 100.0
        let wetFraction = Double(audioSettings.reverbEnabled ? reverbWet : 0)
        // Equal-power crossfade between the dry bus (reverbDryMixer -> reverbMixer
        // bus 0) and the wet/reverb bus (reverbWetMixer -> reverbMixer bus 1) —
        // previously the dry bus had no gain control at all and stayed at its
        // implicit unity level regardless of the slider, so raising "wet mix"
        // only ever added a reverb tail on top of an unchanged, always-dominant
        // dry signal. A reverb tail's own energy is naturally much lower than
        // the direct sound, so that made the effect barely audible until the
        // wet gain was pushed close to its 100% ceiling — reported as "can't
        // hear a difference until ~80%". Now both buses ramp in a proper
        // crossfade (cos/sin keeps perceived loudness constant through the
        // middle of the range, unlike a naive linear blend), so every point on
        // the slider produces an audible change, and 100% is a true full-wet signal.
        let wetGain = sin(wetFraction * .pi / 2)
        let dryGain = cos(wetFraction * .pi / 2)
        reverbWetMixer.outputVolume = Float(wetGain)
        reverbDryMixer.outputVolume = Float(dryGain)
        // `reverb` itself (the actual AVAudioUnitReverb doing the feedback-
        // delay-network tail generation — one of the heavier stock AudioUnits,
        // in the same cost class as timePitch above) used to run on every
        // buffer even with Reverb off, since the wet bus's gain already being
        // zeroed above makes its output inaudible but not free to compute.
        // Reverb defaults to off, so most users paid this continuously for
        // zero audible benefit. Bypassing is safe even mid-wet-signal: the
        // wet bus volume already governs how much of its (now unprocessed,
        // dry-passthrough) output reaches the mix, so a bypass at the exact
        // moment wetFraction is 0 changes nothing audible either way.
        reverb.bypass = !audioSettings.reverbEnabled

        setSpatialAudioRouting(audioSettings.spatialAudioEnabled ?? false, monoEnabled: audioSettings.monoAudioEnabled ?? false)

        // Night Mode compressor is always attached/connected (see
        // configureEngine) — enabling/disabling it is just a bypass flip, so
        // it's safe to set on every settings pass with no reconnect cost.
        nightModeCompressor.bypass = !(audioSettings.nightModeEnabled ?? false)

        // 8D Audio — independent of `activeEffectID` now (see
        // `eightDAudioEnabled`'s doc comment), so it's driven declaratively
        // from this settings pass the same way Bass Boost/Night Mode are,
        // rather than only from `applyEffect`'s one-shot picker action. The
        // `is8DActive`/`isPlaying` guards make this a no-op on every OTHER
        // settings pass once it's already in the state it should be in —
        // only a real on/off flip actually starts or stops the
        // CADisplayLink. Only started while actually playing; `playCurrent`/
        // `reapplyActiveEffect` starts it once playback resumes if it's
        // still enabled from a paused state.
        if audioSettings.eightDAudioEnabled ?? false {
            if !is8DActive, isPlaying { start8DRotation(hz: rotationHz) }
        } else if is8DActive {
            stop8DRotation()
        }

        // ReplayGain + master volume/boost: re-combine the current track's analysed
        // gain (replayGainLinearGain, computed asynchronously in scheduleCurrent/
        // transcodeAndSchedule from embedded REPLAYGAIN_TRACK_GAIN metadata or RMS
        // analysis) with the live volume. Using the SAME formula here as the analysis
        // callback — rather than a separate flat-cap value — means a mid-track
        // volume/EQ/speed tweak (which re-invokes this via the `audioSettings` didSet)
        // refreshes the output level without clobbering the per-track gain the
        // analysis already computed.
        applyOutputGain()

        // Do NOT call updateNowPlaying() here — this runs on every EQ slider drag.
    }

    /// Applies the ReplayGain correction (if enabled) and any volume boost above
    /// 100% to the output stage. The 0...100% portion of `audioSettings.volume`
    /// is applied separately, directly to the player node(s) — see
    /// `applyAudioSettings()` and the crossfade/tremolo helpers — since
    /// `AVAudioPlayerNode.volume` already handles that range correctly.
    ///
    /// `AVAudioMixerNode.outputVolume` is hard-clamped by AVFoundation to `0...1`,
    /// so it (and the player nodes) can only ever *attenuate* — neither can express
    /// the boost above unity that `audioSettings.volume` allows (up to
    /// `AudioSettings.maxVolume`, i.e. up to +12 dB), nor a ReplayGain correction
    /// greater than 1.0x for a quiet track. To realise gain beyond what those
    /// attenuation-only stages contribute, the *remaining* portion of the desired
    /// total gain is applied as positive dB on `equalizer.globalGain`, which is NOT
    /// clamped to unity. The brick-wall `limiter` further down the chain (see
    /// `configureLimiter`) catches any peaks this boost would otherwise clip.
    func applyOutputGain() {
        let rgGain: Float = audioSettings.replayGainEnabled ? replayGainLinearGain : 1.0
        let userVol = audioSettings.volume

        // Desired total linear gain across the whole chain.
        let totalLinear = max(0, rgGain * userVol)

        // What the player-node volume (set in applyAudioSettings/crossfade/tremolo
        // to `min(userVol, 1.0)`) and the mixer's outputVolume can each contribute
        // on their own, attenuation-only (0...1).
        let nodeContribution = min(max(userVol, 0), 1.0)
        let mixerContribution = min(max(rgGain, 0), 1.0)
        crossfadeMixer.outputVolume = mixerContribution

        // Whatever's left over — i.e. gain the node+mixer pair can't express
        // because both are capped at 1.0x — is made up as positive dB via the
        // EQ's global gain.
        let attenuationApplied = nodeContribution * mixerContribution
        if totalLinear > attenuationApplied, attenuationApplied > 0 {
            let boostLinear = totalLinear / attenuationApplied
            let boostDB = 20 * log10(boostLinear)
            equalizer.globalGain = min(max(boostDB, 0), AudioSettings.maxBoostDB)
        } else {
            equalizer.globalGain = 0
        }

        // Hearing Health correlation signal (see HearingHealthService) —
        // specifically the user's own Volume Boost slider above 100%, not
        // ReplayGain's makeup gain for a quiet track, and only while
        // actually playing (this runs on every settings pass, including
        // ones that happen while paused/on a settings screen).
        if isPlaying, userVol > 1.0 {
            HearingHealthService.markBoostActiveToday()
        }
    }

    /// Same target computation as `applyOutputGain()`, but ramped smoothly
    /// over `duration` instead of snapped instantly.
    ///
    /// `crossfadeMixer`/`equalizer` are SHARED downstream of both player
    /// nodes (see `configureEngine`) — an instant snap on either one is
    /// audible on whatever's currently playing, not just "the track this
    /// change is about." `applyOutputGain()`'s instant snap is fine for a
    /// direct user action (dragging the Volume/EQ slider expects immediate
    /// feedback), but `analyzeReplayGain`'s async completion resolves at an
    /// unpredictable delay after a track already started — confirmed in the
    /// field as "audio flickers... when playing or switching tracks,"
    /// landing minutes into playback with no user interaction at all. Use
    /// this instead of `applyOutputGain()` for any call site whose target
    /// isn't the direct, immediate result of the user's own gesture.
    func applyOutputGainRamped(duration: TimeInterval = 0.15) {
        let rgGain: Float = audioSettings.replayGainEnabled ? replayGainLinearGain : 1.0
        let userVol = audioSettings.volume
        let totalLinear = max(0, rgGain * userVol)
        let nodeContribution = min(max(userVol, 0), 1.0)
        let mixerContribution = min(max(rgGain, 0), 1.0)
        let attenuationApplied = nodeContribution * mixerContribution
        let eqTarget: Float
        if totalLinear > attenuationApplied, attenuationApplied > 0 {
            let boostLinear = totalLinear / attenuationApplied
            let boostDB = 20 * log10(boostLinear)
            eqTarget = min(max(boostDB, 0), AudioSettings.maxBoostDB)
        } else {
            eqTarget = 0
        }
        let mixerTarget = mixerContribution

        let mixerStart = crossfadeMixer.outputVolume
        let eqStart = equalizer.globalGain
        outputGainRampTimer?.invalidate()
        let steps = max(1, Int(duration * 30))
        let interval = duration / Double(steps)
        var step = 0
        outputGainRampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { t.invalidate(); return }
                step += 1
                let progress = Float(step) / Float(steps)
                self.crossfadeMixer.outputVolume = mixerStart + (mixerTarget - mixerStart) * progress
                self.equalizer.globalGain = eqStart + (eqTarget - eqStart) * progress
                if step >= steps {
                    t.invalidate()
                    self.outputGainRampTimer = nil
                }
            }
        }

        if isPlaying, userVol > 1.0 {
            HearingHealthService.markBoostActiveToday()
        }
    }
}
