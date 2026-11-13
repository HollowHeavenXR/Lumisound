import Foundation

// MARK: - AudioEffectSpecialMode

/// Flat, Codable representation of a DSP oscillator or spatial mode.
/// Uses a tagged-union style struct so Swift can synthesise Codable automatically.
struct AudioEffectSpecialMode: Codable, Equatable {

    enum ModeType: String, Codable {
        case none, rotation, tremolo, vibrato
    }

    var type: ModeType = .none

    // Parameters for each mode — zero/default when mode is not active.
    var hz: Double      = 0          // rotation: cycles-per-second
    var freq: Double    = 0          // tremolo / vibrato: LFO frequency
    var depth: Float    = 0          // tremolo: depth [0–1]
    var pitchDepth: Double = 0       // vibrato: semitone deviation

    // MARK: Factory helpers (mirror the original enum cases)

    static let none = AudioEffectSpecialMode(type: .none)

    static func rotation(hz: Double) -> AudioEffectSpecialMode {
        AudioEffectSpecialMode(type: .rotation, hz: hz)
    }

    static func tremolo(freq: Double, depth: Float) -> AudioEffectSpecialMode {
        AudioEffectSpecialMode(type: .tremolo, freq: freq, depth: depth)
    }

    static func vibrato(freq: Double, depth: Double) -> AudioEffectSpecialMode {
        AudioEffectSpecialMode(type: .vibrato, freq: freq, pitchDepth: depth)
    }
}

// MARK: - AudioEffect

struct AudioEffect: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let icon: String           // SF Symbol name
    var eqBands: [Float]       // 10 values in dB (32Hz–16kHz)
    var eqEnabled: Bool        // whether EQ should be active
    var speed: Float           // 1.0 = normal playback speed
    var pitchSemitones: Float  // 0.0 = no pitch shift
    var specialMode: AudioEffectSpecialMode = .none
    /// LumiFX catalogue grouping and one-line description (nil for Lua effects).
    var category: String? = nil
    var story: String? = nil
}

// MARK: - AudioEffectsService

enum AudioEffectsService {

    // MARK: Catalogue (LumiFX, rust/core/src/engine/fx.rs)

    /// The engine's effect catalogue, read once.
    nonisolated(unsafe) static let catalogue: [FxPreset] = fxCatalogue()

    /// Every built-in effect, in display order.
    static let allEffects: [AudioEffect] = catalogue.map { p in
        let mode: AudioEffectSpecialMode
        if p.tremoloHz > 0 {
            mode = .tremolo(freq: Double(p.tremoloHz), depth: p.tremoloDepth)
        } else if p.vibratoHz > 0 {
            mode = .vibrato(freq: Double(p.vibratoHz), depth: Double(p.vibratoSemitones))
        } else {
            mode = .none
        }
        return AudioEffect(id: p.id, name: p.name, icon: p.icon,
                           eqBands: p.eq.isEmpty ? Array(repeating: 0, count: 10) : p.eq,
                           eqEnabled: !p.eq.isEmpty, speed: p.speed, pitchSemitones: p.pitchSemitones,
                           specialMode: mode, category: p.category, story: p.story)
    }

    /// Categories in display order with their effects.
    static var grouped: [(category: String, effects: [AudioEffect])] {
        var order: [String] = []
        var map: [String: [AudioEffect]] = [:]
        for e in allEffects {
            let c = e.category ?? "Other"
            if map[c] == nil { order.append(c) }
            map[c, default: []].append(e)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    /// The engine recipe for a built-in effect id.
    static func fx(_ id: String) -> FxPreset? {
        catalogue.first { $0.id == id }
    }

    static let neutralCharacter = FxCharacter(highpassHz: 0, lowpassHz: 0, drive: 0, bits: 0, crushRateHz: 0, width: 1)

    // MARK: Lookup

    /// Returns the effect matching the given id, or nil if not found.
    static func effect(id: String) -> AudioEffect? {
        allEffects.first { $0.id == id }
    }

    /// One-time migration for settings saved before Bass Boost and 8D Audio
    /// became independent toggles. A saved `activeEffectID` of "bassboost"
    /// or "8d" used to be the only way either was ever turned on; neither id
    /// is in `allEffects` any more, so silently leaving it as-is would look
    /// up nothing and leave both sounding off for anyone who had either
    /// selected. Carries it forward into the matching toggle instead — idempotent,
    /// safe to run on every load (a settings value already migrated, or one
    /// that never had either id, passes through unchanged).
    static func migratingLegacyExclusiveEffect(_ settings: AudioSettings) -> AudioSettings {
        var s = settings
        switch s.activeEffectID {
        case "bassboost":
            s.bassBoostEnabled = true
            s.activeEffectID = "none"
        case "8d":
            s.eightDAudioEnabled = true
            s.activeEffectID = "none"
        default:
            // Effects retired with LumiFX (the genre EQ curves now live in
            // LumiEQ presets) fall back to Clean.
            if !s.activeEffectID.hasPrefix("lua:"), fx(s.activeEffectID) == nil {
                s.activeEffectID = "none"
            }
        }
        return s
    }

    // MARK: Apply

    /// Copies `settings`, applies the effect's speed/pitch (and EQ curve, only
    /// for EQ-defining effects), and stamps `activeEffectID`. The caller should
    /// assign the return value back to `AudioPlayerManager.audioSettings`.
    ///
    /// EQ, audio effects, and reverb are designed to LAYER: reverb is a separate
    /// node (untouched here), and a speed/pitch/special effect (Nightcore, 8D,
    /// Tremolo…) or "None" leaves the user's manual equalizer settings intact
    /// instead of wiping them. Only effects that actually define an EQ curve
    /// (`eqEnabled`, e.g. Bass Boost / Rock / Lo-Fi) overwrite the equalizer.
    static func apply(effect: AudioEffect, to settings: AudioSettings) -> AudioSettings {
        var s = settings
        // Only override the user's speed/pitch when this effect actually
        // defines a deliberate tempo/pitch change (nightcore, vaporwave,
        // slowmo, doubletime, pitchUp/Down, ...) — most effects (EQ curves,
        // spatial/reverb-only modes, and "None") declare the neutral values
        // (1.0 / 0.0) simply because every AudioEffect must set *some*
        // speed/pitchSemitones, not because they mean to reset whatever the
        // user already dialed in on the Speed/Pitch sliders. Applying (or
        // clearing, via the "None" effect) one of those neutral effects used
        // to silently snap speed/pitch back to default — this mirrors the
        // same "only touch it if this effect actually defines it" rule the
        // EQ branch below already uses.
        if effect.speed != 1.0 {
            s.speed = effect.speed
        }
        if effect.pitchSemitones != 0.0 {
            s.pitchSemitones = effect.pitchSemitones
        }
        s.activeEffectID = effect.id
        if effect.eqEnabled {
            s.equalizerEnabled = true
            s.eqBands = effect.eqBands
            // Mark the preset as custom so the EQ chip strip doesn't highlight a
            // mismatched preset while an EQ-based audio effect is active.
            s.eqPreset = .custom
        }
        // Non-EQ effects (and "None") preserve the user's existing EQ so the
        // equalizer keeps working alongside the effect + reverb.
        return s
    }
}
