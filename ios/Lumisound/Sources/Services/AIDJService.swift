import Foundation
import AVFoundation
import Combine

/// AI DJ Mode — when enabled, briefly ducks playback volume after each
/// track change and speaks a short Aria Lumi-written transition line
/// on-device (AVSpeechSynthesizer), then restores volume and lets playback
/// continue as normal. The transition text itself comes from the bridge's
/// POST /user/ai-dj/transition (same `call_intelligence`/Gemini pipeline
/// Aria Lumi's metadata matching uses — see intelligence.py) so it stays
/// server-side and never needs an on-device model; only the speaking
/// happens locally, same reasoning as everywhere else in the app that
/// avoids sending audio anywhere.
///
/// Deliberately narrow in scope: this reacts to `AudioPlayerManager`
/// finishing a track change, the same signal `NowPlayingView` etc. already
/// observe, rather than reaching into the crossfade engine itself — no
/// changes to `AudioPlayerManager+Crossfade.swift`'s actual mixing logic.
/// Volume ducking reuses `audioSettings.volume`, the exact same knob
/// `SleepTimerService`'s fade-out already drives (see that type's
/// `getVolume`/`setVolume` closures, wired the same way from
/// `LumisoundApp.swift`), so the two features can never fight over two
/// different volume paths.
@MainActor
final class AIDJService: NSObject, ObservableObject {
    private static let enabledKey = "aiDJMode.enabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { stopSpeaking() }
        }
    }

    private static let voiceIdentifierKey = "aiDJMode.voiceIdentifier"
    private static let pitchMultiplierKey = "aiDJMode.pitchMultiplier"
    /// Slightly above neutral (1.0) by default — a flat-pitched DJ handoff
    /// read noticeably less like a live personality than one with a touch
    /// more lift, without the user needing to find and tune this value
    /// themselves. Still fully overridable per the Settings slider.
    private static let defaultPitchMultiplier: Float = 1.08

    /// `nil` = the device's default voice for the current language (the
    /// previous, only, behavior). Persisted so a choice made in Settings
    /// survives a relaunch.
    @Published var voiceIdentifier: String? {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceIdentifierKey) }
    }
    @Published var pitchMultiplier: Float {
        didSet { UserDefaults.standard.set(pitchMultiplier, forKey: Self.pitchMultiplierKey) }
    }
    @Published private(set) var isSpeaking = false
    /// The most recent transition line spoken, kept only for a small
    /// "Aria just said…" caption on the Now Playing screen while
    /// `isSpeaking` is true.
    @Published private(set) var lastBlurb: String?

    /// Rolling log of this session's tracks and spoken transitions, in
    /// order — what `AIDJSessionExportService` turns into a downloadable set.
    /// The log (and its 16-entry cap) lives in the Rust core's `DjSession`;
    /// this mirror maps its song ids back to `Song`s for the views.
    @Published private(set) var sessionLog: [AIDJSessionEntry] = []
    private let session = DjSession()
    private var loggedSongs: [String: Song] = [:]

    private func refreshSessionLog() {
        let entries = session.log()
        let ids = Set(entries.compactMap(\.songId))
        loggedSongs = loggedSongs.filter { ids.contains($0.key) }
        sessionLog = entries.compactMap { e in
            if let id = e.songId { return loggedSongs[id].map(AIDJSessionEntry.track) }
            return e.text.map(AIDJSessionEntry.transition)
        }
    }

    func clearSessionLog() {
        session.clearLog()
        loggedSongs.removeAll()
        sessionLog.removeAll()
    }

    weak var player: AudioPlayerManager?
    weak var account: AccountService?

    /// Same read/write-volume closure pattern as `SleepTimerService`, wired
    /// from `LumisoundApp.swift` — lets this service duck/restore playback
    /// volume without needing a direct `AudioPlayerManager` dependency.
    var getVolume: (() -> Float)?
    var setVolume: ((Float) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var cancellable: AnyCancellable?
    private var duckFadeTimer: Timer?

    /// Mirrors `AccountService.shared`/`LibraryManager.shared` — gives
    /// non-view code (e.g. `DiagnosticsSnapshotService`) a way to reach the
    /// live instance without needing it threaded through as a parameter.
    static weak var shared: AIDJService?

    override init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        voiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceIdentifierKey)
        pitchMultiplier = UserDefaults.standard.object(forKey: Self.pitchMultiplierKey) != nil
            ? UserDefaults.standard.float(forKey: Self.pitchMultiplierKey)
            : Self.defaultPitchMultiplier
        super.init()
        synthesizer.delegate = self
        Self.shared = self
    }

    /// Starts observing track changes. Call once at launch after `player`
    /// and `account` are constructed (same timing as the other weak-singleton wiring
    /// in `LumisoundApp.swift`'s `.task`).
    func attach(player: AudioPlayerManager, account: AccountService) {
        self.player = player
        self.account = account
        cancellable = player.$currentSong
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] song in
                self?.handleTrackChange(to: song)
            }
    }

    private func handleTrackChange(to song: Song?) {
        guard let song else { return }
        let songID = song.id
        guard let cue = session.trackChanged(songId: songID, title: song.title, artist: song.artist,
                                             enabled: isEnabled, playing: player?.isPlaying ?? false) else { return }
        loggedSongs[songID] = song
        refreshSessionLog()
        Task { [weak self] in
            guard let self, let account = self.account, account.isLoggedIn else { return }
            guard let blurb = await djTransitionBlurb(client: Core.api, nextTitle: song.title,
                                                      nextArtist: song.artist, cue: cue) else { return }
            // The track may have changed again (skip) while the request was
            // in flight — a stale blurb about the wrong song is worse than
            // silence, so bail if `currentSong` has since moved on.
            guard self.player?.currentSong?.id == song.id else { return }
            self.speak(blurb)
        }
    }

    private func speak(_ text: String) {
        guard let getVolume, setVolume != nil else { return }
        // One duck/restore pair in flight at a time (the core drops an
        // overlapping announcement), so the restore baseline is always the
        // real pre-duck volume and never ratchets down across quick skips.
        let baseline = getVolume()
        guard let ducked = session.beginSpeaking(text: text, currentVolume: baseline) else { return }
        isSpeaking = true
        lastBlurb = text
        refreshSessionLog()

        // Fade rather than snap — matches how every other transient volume
        // change in this app (crossfade, seek-click prevention, output-gain
        // correction) avoids an instant jump, and reads as a deliberate
        // "ducking for the DJ" rather than the audio abruptly cutting out.
        fadeVolume(from: baseline, to: ducked) { [weak self] in
            guard let self else { return }
            let utterance = AVSpeechUtterance(string: text)
            // Falls back to the device's default language voice if the user
            // never picked one, or if a previously-picked voice was removed
            // (e.g. an enhanced/premium voice pack deleted to save space) —
            // `AVSpeechSynthesisVoice(identifier:)` returns nil in that case.
            utterance.voice = self.voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
                ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = self.pitchMultiplier
            utterance.postUtteranceDelay = 0.2
            self.synthesizer.speak(utterance)
        }
    }

    /// Ramps the player's volume from `from` to `to` over a short fade
    /// instead of snapping it, used for both the pre-speech duck and the
    /// post-speech restore. `isSpeaking` stays true for the full duck ->
    /// speak -> restore-fade span (see callers) so a new announcement can
    /// never start while a previous duck is still being restored — that
    /// window is exactly where the compounding-duck bug above could still
    /// slip in even with the `!isSpeaking` guard alone.
    private func fadeVolume(from: Float, to: Float, duration: TimeInterval = 0.2, completion: (() -> Void)? = nil) {
        duckFadeTimer?.invalidate()
        guard let setVolume else { completion?(); return }
        let ramp = djVolumeRamp(from: from, to: to, steps: 8)
        let interval = duration / Double(ramp.count)
        var step = 0
        duckFadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { t.invalidate(); return }
                setVolume(ramp[min(step, ramp.count - 1)])
                step += 1
                if step >= ramp.count {
                    t.invalidate()
                    self.duckFadeTimer = nil
                    completion?()
                }
            }
        }
    }

    /// Fades back to the pre-duck volume and only then clears `isSpeaking` —
    /// shared by both the normal "finished speaking" and the "cancelled
    /// mid-speech" delegate callbacks below.
    private func restoreVolumeAfterSpeaking() {
        let target = session.restoreVolume()
        fadeVolume(from: getVolume?() ?? target, to: target) { [weak self] in
            self?.session.finishedSpeaking()
            self?.isSpeaking = false
        }
    }

    /// Immediately stops any in-progress announcement and restores volume —
    /// called when the user turns AI DJ Mode off mid-speech.
    func stopSpeaking() {
        guard isSpeaking else { return }
        if synthesizer.isSpeaking {
            // Triggers `didCancel` below, which restores volume.
            synthesizer.stopSpeaking(at: .immediate)
        } else {
            // `isSpeaking` can be true before the synthesizer actually has
            // anything queued — `speak(_:)` sets it at the start of the
            // pre-speech duck fade, before `synthesizer.speak()` is called
            // once that fade completes. Toggling AI DJ Mode off inside that
            // window would otherwise fail this function's old
            // `synthesizer.isSpeaking` guard and return having done nothing
            // — leaving the player ducked at 25% with no delegate callback
            // ever going to fire to undo it. Restore directly instead.
            restoreVolumeAfterSpeaking()
        }
    }
}

enum AIDJSessionEntry {
    case track(Song)
    case transition(String)
}

/// One selectable system voice for AI DJ Mode's transition lines, shown in
/// Account → AI Features. Picks from this DEVICE's own installed voices —
/// there's no way (and, for a specific person's actual voice, no legal way)
/// to add a new one from here; download more under Settings app →
/// Accessibility → Spoken Content → Voices.
struct AIDJVoiceOption: Identifiable {
    let identifier: String
    let displayName: String
    var id: String { identifier }

    private static func priority(for quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium:  return 3
        case .enhanced: return 2
        case .default:  return 1
        @unknown default: return 0
        }
    }

    /// Every installed system voice matching the device's current language
    /// — not every language on the system, which would be dozens of
    /// irrelevant entries — sorted with higher-quality (Enhanced/Premium,
    /// if downloaded) voices first, since those sound noticeably more
    /// natural than the always-available default ones.
    static var available: [AIDJVoiceOption] {
        let languagePrefix = AVSpeechSynthesisVoice.currentLanguageCode().prefix(2)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.prefix(2) == languagePrefix }
            .sorted { lhs, rhs in
                let lp = priority(for: lhs.quality), rp = priority(for: rhs.quality)
                return lp != rp ? lp > rp : lhs.name < rhs.name
            }
            .map { AIDJVoiceOption(identifier: $0.identifier, displayName: $0.name) }
    }
}

extension AIDJService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.restoreVolumeAfterSpeaking()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.restoreVolumeAfterSpeaking()
        }
    }
}
