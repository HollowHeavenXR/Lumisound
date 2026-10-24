@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Audio Effects

    func applyEffect(_ effect: AudioEffect) {
        appLog("Effect applied: \(effect.name) (id: \(effect.id))", category: "audio")
        // Stops only the exclusive-picker-driven special modes. 8D Audio is
        // no longer one of them (see `eightDAudioEnabled`'s doc comment) —
        // it's independently toggled and must keep running across an
        // unrelated exclusive-effect switch, not get silently stopped by one.
        stopTremolo()
        stopVibrato()

        // Apply static EQ / speed / pitch settings.
        var s = AudioEffectsService.apply(effect: effect, to: audioSettings)
        s.activeEffectID = effect.id
        audioSettings = s   // triggers didSet → applyAudioSettings()

        // Start the special mode for this effect. `.rotation` is only
        // reachable here via a custom Lua-scripted effect now — 8D Audio
        // itself was removed from `AudioEffectsService.allEffects` — and
        // even then, only if the independent toggle isn't already running
        // it (avoids stopping and immediately restarting the same
        // CADisplayLink, which would reset its phase for no reason).
        switch effect.specialMode.type {
        case .rotation:
            if !is8DActive { start8DRotation(hz: effect.specialMode.hz) }
        case .tremolo:
            startTremolo(frequency: effect.specialMode.freq, depth: effect.specialMode.depth)
        case .vibrato:
            startVibrato(frequency: effect.specialMode.freq, depth: effect.specialMode.pitchDepth)
        case .none:
            break
        }
    }

    /// Re-starts any dynamic effect (8D, tremolo, vibrato) that was active before
    /// playback began. Called after the engine starts so CADisplayLink effects actually run.
    func reapplyActiveEffect() {
        // Independent 8D toggle — see `eightDAudioEnabled`'s doc comment.
        // Checked unconditionally (unlike the exclusive effect below, this
        // doesn't depend on `activeEffectID` at all), so it resumes
        // alongside whichever exclusive effect (if any) is also active.
        if audioSettings.eightDAudioEnabled ?? false, !is8DActive {
            start8DRotation(hz: rotationHz)
        }

        let effectID = audioSettings.activeEffectID
        guard !effectID.isEmpty, effectID != "none" else { return }
        let effect: AudioEffect?
        if let ref = LuaEffectEngine.scriptRef(forEffectID: effectID) {
            effect = try? LuaEffectEngine.resolve(ref, track: currentSong)
        } else {
            effect = AudioEffectsService.allEffects.first(where: { $0.id == effectID })
        }
        guard let effect else { return }
        switch effect.specialMode.type {
        case .rotation:
            if !is8DActive { start8DRotation(hz: effect.specialMode.hz) }
        case .tremolo:
            if !isTremoloActive { startTremolo(frequency: effect.specialMode.freq, depth: effect.specialMode.depth) }
        case .vibrato:
            if !isVibratoActive { startVibrato(frequency: effect.specialMode.freq, depth: effect.specialMode.pitchDepth) }
        case .none:
            break
        }
    }

    // MARK: - EQ Presets

    func applyEQPreset(_ preset: EQPreset) {
        var settings = audioSettings
        settings.eqPreset = preset
        if preset != .custom {
            settings.eqBands = preset.bands
        }
        settings.equalizerEnabled = preset != .flat
        audioSettings = settings   // triggers didSet → applyAudioSettings()
    }
}
