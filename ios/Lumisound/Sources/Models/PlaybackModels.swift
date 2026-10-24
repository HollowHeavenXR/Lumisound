import Foundation

enum RepeatMode: String, CaseIterable, Codable, Identifiable {
    case off
    case all
    case one

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }
}

struct PlaybackSnapshot: Codable, Equatable {
    static let currentVersion = 2

    var version: Int
    var currentSongID: Song.ID?
    var queue: [Song]
    var currentIndex: Int
    var position: TimeInterval
    var repeatMode: RepeatMode
    var shuffleEnabled: Bool

    init(
        version: Int = PlaybackSnapshot.currentVersion,
        currentSongID: Song.ID? = nil,
        queue: [Song],
        currentIndex: Int,
        position: TimeInterval,
        repeatMode: RepeatMode,
        shuffleEnabled: Bool
    ) {
        self.version = version
        self.currentSongID = currentSongID
        self.queue = queue
        self.currentIndex = currentIndex
        self.position = position
        self.repeatMode = repeatMode
        self.shuffleEnabled = shuffleEnabled
    }

    // CodingKeys to support missing `version` in older snapshots (default to 1).
    enum CodingKeys: String, CodingKey {
        case version, currentSongID, queue, currentIndex, position, repeatMode, shuffleEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        currentSongID = try? container.decode(Song.ID.self, forKey: .currentSongID)
        queue = try container.decode([Song].self, forKey: .queue)
        currentIndex = try container.decode(Int.self, forKey: .currentIndex)
        position = try container.decode(TimeInterval.self, forKey: .position)
        repeatMode = try container.decode(RepeatMode.self, forKey: .repeatMode)
        shuffleEnabled = try container.decode(Bool.self, forKey: .shuffleEnabled)
    }
}

struct AudioSettings: Codable, Equatable, Hashable {
    /// Median tonal shape of the user's library, supplied by the server — what
    /// Auto EQ corrects toward. See SpectralEQMatcher.
    ///
    /// Static rather than an instance field: it describes the LIBRARY, not this
    /// playback session's settings, and storing it per-settings-object would
    /// mean every copy carried a stale snapshot of it. Persisted so the first
    /// track after launch can be matched before the library has been refetched.
    static var libraryEQTarget: [Double]? {
        get {
            guard let raw = UserDefaults.standard.array(forKey: "audio.libraryEQTarget") as? [Double],
                  raw.count == 10 else { return nil }
            return raw
        }
        set {
            guard let newValue, newValue.count == 10 else { return }
            UserDefaults.standard.set(newValue, forKey: "audio.libraryEQTarget")
        }
    }

    /// Upper bound for `volume`. Values above 1.0 (100%) drive the signal
    /// chain's gain stages hotter than unity — the output limiter in
    /// `AudioPlayerManager` prevents this from clipping.
    ///
    /// `AVAudioMixerNode.outputVolume` and `AVAudioPlayerNode.volume` are both
    /// hard-clamped to `0...1` by AVFoundation, so any boost above unity is
    /// realised separately via `AVAudioUnitEQ.globalGain` (in dB). `4.0` here
    /// corresponds to `20*log10(4) ≈ +12 dB` of boost headroom — the widest
    /// range the slider exposes.
    static let maxVolume: Float = 4.0

    /// Maximum boost, in dB, applied via `AVAudioUnitEQ.globalGain` when
    /// `volume` exceeds `1.0`. Matches `20*log10(maxVolume)`.
    static let maxBoostDB: Float = 12.0

    var volume: Float = 1.0
    var speed: Float = 1.0
    var pitchSemitones: Float = 0.0
    var equalizerEnabled: Bool = false
    var eqBands: [Float] = Array(repeating: 0, count: 10)
    var eqPreset: EQPreset = .flat
    var crossfadeEnabled: Bool = false
    var crossfadeDuration: TimeInterval = 2.0
    var gaplessEnabled: Bool = true
    var replayGainEnabled: Bool = false
    var bassBoostEnabled: Bool = false
    var bassBoostGain: Float = 0.0  // 0–15 dB extra on 32 Hz and 64 Hz bands
    /// Independent of `activeEffectID` — same shape as `bassBoostEnabled`
    /// above. 8D Audio used to only exist as one of the mutually-exclusive
    /// entries in `AudioEffectsService.allEffects`, so picking it meant
    /// giving up whatever other effect (Nightcore, Tremolo, …) was already
    /// active, the same limitation Bass Boost had before IT was pulled out
    /// into its own toggle. Pulled out the same way, so 8D Audio, Bass
    /// Boost, and one exclusive effect can now all run at once — the three
    /// mechanisms touch different engine parameters (stereo pan, EQ bands,
    /// and whatever the exclusive effect defines) with no shared resource
    /// to conflict over.
    ///
    /// BUGFIX (confirmed live via telemetry — `persistence` category,
    /// "loadAudioSettings decode failed: ... Key 'eightDAudioEnabled' not
    /// found"): this field shipped as a plain non-optional `Bool`, not
    /// following the `Bool?`-for-new-fields convention every sibling toggle
    /// below it uses. Swift's synthesized `Decodable` decodes a struct
    /// atomically — one missing required key fails the ENTIRE decode, not
    /// just this field — so every settings blob saved before this field
    /// existed, and never re-saved since, has been failing to decode on
    /// every single launch. `PersistenceService.loadAudioSettings()` returns
    /// `nil` on that failure, and the caller falls back to `AudioSettings()`
    /// (all defaults) — silently wiping EQ bands, crossfade, gapless,
    /// ReplayGain, bass boost, and reverb preferences for anyone who hadn't
    /// touched an audio setting (and so re-saved the blob) since 8D Audio
    /// shipped. Optional, like `spatialAudioEnabled`/`monoAudioEnabled`/
    /// `nightModeEnabled` above, so a missing key decodes to `nil`/off
    /// instead of failing the whole struct. Read via `?? false`.
    var eightDAudioEnabled: Bool? = false
    var activeEffectID: String = "none"
    /// When true, the EQ preset automatically switches to match each track's
    /// tempo (see `EQPreset.auto(forBPM:)`) instead of staying on whatever
    /// preset the user last picked manually.
    var autoEQEnabled: Bool = false
    /// When true, the BPM-aware crossfade engine beatmatches and beat-aligns
    /// the overlap using each track's analysed tempo instead of a fixed
    /// duration (see `AudioPlayerManager.beginCrossfade`). Opt-in.
    var smartCrossfadeEnabled: Bool = false
    /// True when EITHER crossfade mode is on. Manual and Smart crossfade are
    /// mutually exclusive in the UI, and either one must drive an actual
    /// crossfade transition — previously only `crossfadeEnabled` was checked at
    /// the trigger sites, so turning on Smart Crossfade alone did nothing.
    var crossfadeActive: Bool { crossfadeEnabled || smartCrossfadeEnabled }
    /// Real-room reverb, applied via `AVAudioUnitReverb` on the main signal
    /// chain. On by default per product requirement — gives every track a
    /// subtle sense of space rather than a perfectly dry signal.
    var reverbEnabled: Bool = true
    /// Wet/dry mix, 0–100. Maps directly to `AVAudioUnitReverb.wetDryMix`.
    var reverbWetDryMix: Float = 18.0
    var reverbPreset: ReverbRoomPreset = .mediumRoom
    /// Generates an audio-reactive haptic accompaniment for engine playback
    /// using Core Haptics. This is an approximation of Apple Music's Music
    /// Haptics feature; the private Apple Music pattern catalog is not exposed
    /// to third-party apps. Optional so settings saved before this feature was
    /// added continue to decode safely.
    var musicHapticsEnabled: Bool? = false
    /// Routes the final mix through `AVAudioEnvironmentNode` (HRTF binaural
    /// rendering), externalizing the stereo image as a single anchored source
    /// in front of the listener. Head-tracked (via `CMHeadphoneMotionManager`)
    /// on compatible Apple headphones; a static anchor otherwise. Off by
    /// default — opt-in, since HRTF rendering meaningfully changes the tonal
    /// balance and only makes sense on headphones.
    ///
    /// Optional (unlike its sibling `Bool` settings) so decoding an
    /// `AudioSettings` blob saved before this field existed defaults it to
    /// `nil`/off instead of failing the whole decode — Swift's synthesized
    /// `Decodable` only does that automatically for `Optional` properties, not
    /// ones with a plain default value (see `PlaybackSnapshot`'s custom
    /// decoder for the same issue with `version`). Read via `?? false`.
    var spatialAudioEnabled: Bool? = false

    /// Downmixes the final stereo mix to mono — for single-earbud listening
    /// or one-sided hearing loss. Mutually exclusive with Spatial Audio in
    /// the UI (HRTF binaural rendering assumes real stereo output); when both
    /// are somehow set, `AudioPlayerManager` gives Spatial Audio priority.
    /// Optional for the same missing-key-safety reason as `spatialAudioEnabled`.
    var monoAudioEnabled: Bool? = false

    /// Gentle, always-tuned dynamic range compression (distinct from the
    /// brick-wall peak `limiter` already in the chain) — evens out quiet vs.
    /// loud passages for late-night listening at low volume. Optional for the
    /// same missing-key-safety reason as `spatialAudioEnabled`.
    var nightModeEnabled: Bool? = false

    /// Volume curve used during a crossfade's overlap. Optional so old saved
    /// blobs decode with `.equalPower` (the recommended default — avoids the
    /// perceived-loudness dip a linear fade has at the midpoint — rather than
    /// silently failing to decode). Read via `?? .equalPower`.
    var crossfadeCurve: CrossfadeCurve? = .equalPower
}

extension AudioSettings {
    /// These settings with every field that Auto EQ rewrites per track reset
    /// to a fixed value, so two values compare equal when the only difference
    /// is the preset Auto EQ picked.
    ///
    /// With Auto EQ on, `eqPreset`/`eqBands`/`equalizerEnabled` change on most
    /// track changes, and each of those changes looked to the app like the
    /// listener editing their settings: it re-saved them and pushed a full
    /// account sync plus the whole library inventory to the server, once per
    /// song. None of that is information worth syncing; the choice to use Auto
    /// EQ is, and that is still compared.
    var syncComparable: AudioSettings {
        guard autoEQEnabled else { return self }
        var copy = self
        copy.eqPreset = .flat
        copy.eqBands = Array(repeating: 0, count: eqBands.count)
        copy.equalizerEnabled = false
        return copy
    }
}

/// Volume curve applied across a crossfade's overlap window. See
/// `AudioPlayerManager.beginCrossfade`'s per-tick volume ramp.
enum CrossfadeCurve: String, CaseIterable, Codable, Identifiable, Equatable {
    case linear
    case equalPower

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear:     return "Linear"
        case .equalPower: return "Equal-Power"
        }
    }

    var subtitle: String {
        switch self {
        case .linear:     return "Straight fade — perceived volume dips slightly midway."
        case .equalPower: return "Constant perceived loudness through the whole transition."
        }
    }
}

/// Room/space presets for the live reverb effect. Mirrors a subset of
/// `AVAudioUnitReverbPreset` — kept as our own String enum (rather than using
/// AVFoundation's type directly) so the Models layer doesn't need to import
/// AVFoundation; `AudioPlayerManager` maps this to the real preset.
enum ReverbRoomPreset: String, CaseIterable, Codable, Identifiable {
    case smallRoom
    case mediumRoom
    case largeRoom
    case mediumHall
    case largeHall
    case plate
    case cathedral

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smallRoom: return "Small Room"
        case .mediumRoom: return "Medium Room"
        case .largeRoom: return "Large Room"
        case .mediumHall: return "Medium Hall"
        case .largeHall: return "Large Hall"
        case .plate: return "Plate"
        case .cathedral: return "Cathedral"
        }
    }
}
