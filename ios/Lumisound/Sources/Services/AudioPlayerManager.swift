@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

// MARK: - PlaybackProgress

/// Holds just the high-frequency playback position/duration values, observed
/// separately from the rest of `AudioPlayerManager`'s `@Published` state. Any
/// `@Published` change on an `ObservableObject` fires `objectWillChange` for the
/// WHOLE object, forcing every view holding it (e.g. via `@EnvironmentObject`) to
/// re-evaluate its `body` — regardless of which property that view actually reads.
/// Position/duration tick every 0.25–0.5s while playing, and `MiniPlayerBar` (which
/// only needs `currentSong`/`isPlaying`) is mounted on most screens simultaneously,
/// so publishing them directly on `AudioPlayerManager` was cascading re-renders
/// app-wide. Views that need live progress (the mini-player's progress bar, the
/// Now Playing scrubbers, the lyrics sync editor) observe this lightweight object
/// instead, so the high-frequency updates stay scoped to just those views.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0
}


// MARK: - AudioPlayerManager

@MainActor
final class AudioPlayerManager: ObservableObject {

    // MARK: Published State

    @Published var currentSong: Song? {
        didSet {
            if currentSong?.id != oldValue?.id {
                nowPlayingArtworkSongID = nil
                updateNowPlaying()
                let isFavoriteNow = currentSong.flatMap { LibraryManager.shared?.isFavorite(songID: $0.id) } ?? false
                // Push the Live Activity's title/artist/anchorDate right away
                // rather than waiting on `updateNowPlayingArtwork`'s async
                // artwork load below — that load is a real disk/decode op
                // that can take long enough to be visible as "the Live
                // Activity is a few seconds behind the actual track". The
                // Live Activity's `ContentState` doesn't carry artwork at all
                // (read straight off the shared App Group file instead — see
                // LumisoundActivityAttributes), so there's nothing it needs
                // to wait on here; the artwork file gets written moments
                // later by the same `WidgetDataService.update` call inside
                // `updateNowPlayingArtwork`.
                if #available(iOS 16.1, *) {
                    LiveActivityManager.update(song: currentSong, isPlaying: isPlaying, position: position, duration: duration, isFavorite: isFavoriteNow)
                }
                Task { await updateNowPlayingArtwork(for: currentSong) }
                applyTrackAudioSettings(previousID: oldValue?.id)
                pushPlaybackStateToBridge()
                scheduleHistoryLog()
                // Keep the widget's heart badge in sync with the new track
                // immediately, rather than waiting for the next play/pause
                // toggle or backgrounding event to catch up.
                WidgetDataService.shared.updateFavoriteState(isFavorite: isFavoriteNow)
                // If a SharePlay "listen together" session is active, let the
                // other participants know the track changed — no-ops when no
                // session is active or when this change came FROM applying a
                // remote participant's message (see SharePlayCoordinator).
                SharePlayCoordinator.shared?.broadcastTrackChange(song: currentSong, isPlaying: isPlaying, position: position)
            } else if currentSong?.displayName != oldValue?.displayName
                        || currentSong?.artistName != oldValue?.artistName {
                // Same track, corrected metadata. `updateNowPlaying()` only
                // republishes on playback changes now, so tell it this counts.
                invalidateNowPlaying()
                updateNowPlaying()
            }
        }
    }
    /// Identifies the artwork currently installed in the system Now Playing
    /// card, preventing an older asynchronous artwork load from being reused
    /// for a newer track.
    var nowPlayingArtworkSongID: String?
    @Published var queue: [Song] = [] {
        didSet {
            // Keep `currentIndex` pointing inside the queue whenever it
            // shrinks, so the many `queue[currentIndex]` reads (skip,
            // repeat-one peek, restore) can never index past the end. Code
            // that then sets `currentIndex` itself still wins.
            if !queue.isEmpty, !queue.indices.contains(currentIndex) {
                currentIndex = min(max(currentIndex, 0), queue.count - 1)
            }
            pushQueueToBridge()
        }
    }

    /// True if `songID` is anywhere in the active queue — not just the
    /// single `currentSong`. Background maintenance passes (the
    /// exclusive-extension conversion pass, duplicate merging) that touch
    /// on-disk files snapshot `currentSong?.id` ONCE before iterating
    /// potentially dozens of songs; each iteration does real async I/O, so
    /// by the time a later song in the batch is reached, playback may have
    /// auto-advanced past that one stale snapshot to a DIFFERENT song still
    /// in the same queue — one the batch would otherwise treat as safe to
    /// delete/replace despite it being about to play (or already playing)
    /// by the time the file operation actually runs. Call this fresh at
    /// each per-song guard instead of trusting a single snapshot for the
    /// whole batch.
    func isInActiveQueue(songID: String) -> Bool {
        queue.contains { $0.id == songID }
    }
    @Published var currentIndex = 0
    /// Which playlist (if any) the current queue was started from — lets
    /// Now Playing auto-apply that playlist's remembered artwork style.
    /// Cleared whenever a queue is set without a playlist context (Library,
    /// search results, a single song tapped outside a playlist, etc.).
    @Published var currentPlaylistID: UUID?
    @Published var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            MusicHapticsService.shared.updatePlayback(
                enabled: audioSettings.musicHapticsEnabled ?? false,
                isPlaying: isPlaying,
                engineAvailable: !isUsingOpusPlayer
            )
            WidgetDataService.shared.updatePlayState(isPlaying: isPlaying, position: position, duration: duration)
            pushPlaybackStateToBridge()
            SharePlayCoordinator.shared?.broadcastPlayState(isPlaying: isPlaying, position: position)
        }
    }
    /// Backing store for `position`/`duration` — see `PlaybackProgress` for why
    /// these are split out instead of `@Published` directly on this object. Every
    /// internal read/write site (`position = 0`, `duration > 0`, etc.) keeps
    /// working unchanged since these remain plain gettable/settable properties.
    let progress = PlaybackProgress()

    /// The true playback position. `progress.position` mirrors it for views,
    /// except while the app is in the background — see
    /// `isProgressPublishingPaused`.
    private var positionValue: TimeInterval = 0

    var position: TimeInterval {
        get { positionValue }
        set {
            positionValue = newValue
            if !isProgressPublishingPaused { progress.position = newValue }
        }
    }

    /// True while the app is backgrounded. The position tick runs twice a
    /// second for as long as music plays, and every publish re-evaluates each
    /// view observing `progress` — the mini player, the Now Playing scrubber,
    /// synced lyrics. SwiftUI keeps doing that work in the background even
    /// though nothing is drawn, so hours of locked-screen listening paid for
    /// thousands of invisible view updates. Paused while backgrounded and
    /// caught up in one publish on return.
    var isProgressPublishingPaused = false {
        didSet {
            if !isProgressPublishingPaused, progress.position != positionValue {
                progress.position = positionValue
            }
        }
    }
    var duration: TimeInterval {
        get { progress.duration }
        set { progress.duration = newValue }
    }
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffleEnabled = false
    /// Queue order captured before shuffle was enabled, so it can be restored
    /// when shuffle is turned off again.
    var preShuffleQueue: [Song]?
    @Published var audioSettings = AudioSettings() {
        didSet {
            logAudioSettingsToggleChanges(from: oldValue, to: audioSettings)
            applyAudioSettings()
            guard !isSwitchingTrack else { return }
            if isUsingTrackAudioSettings, let id = currentSong?.id {
                perTrackAudioSettings[id] = audioSettings
                PersistenceService.shared.saveTrackAudioSettings(perTrackAudioSettings)
                onTrackAudioSettingsChanged?()
            } else {
                defaultAudioSettings = audioSettings
            }
        }
    }

    /// The user's global/default audio settings — applied to any track that
    /// doesn't have its own saved per-track override. Mirrors `audioSettings`
    /// except while a per-track override (or a programmatic track switch) is active.
    var defaultAudioSettings = AudioSettings()

    /// Per-track audio settings overrides, keyed by `Song.id`. Loaded from disk
    /// at init and kept in sync with `PersistenceService` on every change.
    @Published var perTrackAudioSettings: [String: AudioSettings] = PersistenceService.shared.loadTrackAudioSettings()

    /// Whether the currently playing track has a saved per-track override active
    /// (i.e. `audioSettings` reflects that track's own settings, not the global default).
    @Published var isUsingTrackAudioSettings = false

    /// "Why this pick" for the current Auto EQ selection — see
    /// `applyAutoEQIfNeeded`. `nil` when Auto EQ is off or hasn't picked
    /// anything for the current track yet.
    @Published var autoEQReason: String?

    /// Suppresses the `audioSettings` didSet's save-as-default/save-per-track logic
    /// while `applyTrackAudioSettings` is itself assigning `audioSettings` during a
    /// track switch — that assignment reflects a *recall* of previously saved
    /// settings, not a new user edit, and must not overwrite the saved values.
    var isSwitchingTrack = false

    /// Notifies observers (used by `LumisoundApp` to push to the backend)
    /// whenever the per-track settings map changes.
    var onTrackAudioSettingsChanged: (() -> Void)?

    /// Wired up by `LumisoundApp` at launch so the player can resolve BPM for
    /// the current/next track (via `LibraryManager.bpm(for:)`) to drive
    /// beat-aware crossfades. `weak` since `LibraryManager` owns the player's
    /// environment lifetime, not the other way around.
    weak var libraryManager: LibraryManager?

    @Published var errorMessage: String?

    // Auto-Radio
    @Published var autoRadioEnabled: Bool = UserDefaults.standard.bool(forKey: "autoRadio_enabled") {
        didSet { UserDefaults.standard.set(autoRadioEnabled, forKey: "autoRadio_enabled") }
    }
    @Published var autoRadioSeed: Song? = nil

    // AB Repeat
    @Published var abRepeatEnabled: Bool = false
    @Published var abRepeatStart: TimeInterval? = nil
    @Published var abRepeatEnd: TimeInterval? = nil

    // MARK: Private — Engine

    let engine = AVAudioEngine()

    let primaryNode = AVAudioPlayerNode()
    let secondaryNode = AVAudioPlayerNode()
    // Per-node pitch-preserving time stretchers, sitting between each player
    // node and `crossfadeMixer`. `.rate` is 1.0 (transparent passthrough)
    // outside of crossfades; `beginCrossfade` nudges these toward each
    // other's tempo for "beatmatched" overlaps. Separate from the shared
    // `timePitch` below, which applies the user's global speed/pitch settings
    // to the final mixed output.
    let primaryBeatMatch = AVAudioUnitTimePitch()
    let secondaryBeatMatch = AVAudioUnitTimePitch()
    // Dedicated mixer so both player nodes can connect to a single effects chain.
    let crossfadeMixer = AVAudioMixerNode()

    let timePitch = AVAudioUnitTimePitch()
    let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    // Real-room reverb in a PARALLEL (send/return) topology, not an insert.
    //
    // AVAudioUnitReverb's only blend control is `wetDryMix`, wired inline that
    // quietly degrades the direct signal whenever reverb is on — and it's on
    // by default — which reads as "reverb lowers audio quality". Instead the
    // EQ output fans out to two paths: a dry path through `reverbDryMixer`
    // straight into `reverbMixer`, and a wet path through `reverb` (wetDryMix
    // pinned at 100 = pure tail) scaled by `reverbWetMixer`, summed back in.
    // When reverb is off (0% mix) the dry path is untouched/bit-perfect and
    // the wet bus is silent, same as before — `reverbDryMixer.outputVolume`
    // and `reverbWetMixer.outputVolume` only start diverging from
    // dry=1/wet=0 once the mix slider actually moves off zero (see
    // `applyAudioSettings`), crossfading the two as the mix increases so the
    // effect is audible across the WHOLE 0-100% range instead of only near
    // the top of it.
    let reverb = AVAudioUnitReverb()
    // Sums the dry path (bus 0) and the scaled wet path (bus 1) before the limiter.
    let reverbMixer = AVAudioMixerNode()
    // Single-input gain stage on the wet path; its outputVolume is the reverb
    // amount (reverbWetDryMix / 100), or 0 when reverb is disabled.
    let reverbWetMixer = AVAudioMixerNode()
    // Single-input gain stage on the DRY path, mirroring `reverbWetMixer` —
    // needed because the dry path's source (`nightModeCompressor`, an
    // AVAudioUnitEffect) doesn't conform to AVAudioMixing and so has no
    // per-destination `.destination(forMixer:bus:)` volume of its own; this
    // node exists purely to give the dry path an independently-controllable
    // gain the same way the wet path already has one.
    let reverbDryMixer = AVAudioMixerNode()
    // Tracks which factory preset is currently loaded on `reverb` so
    // `applyAudioSettings` only calls `loadFactoryPreset` (a relatively heavy
    // call) when the user's chosen preset actually changes.
    var loadedReverbPreset: ReverbRoomPreset?
    // Brick-wall peak limiter placed at the very end of the chain. Lets
    // `audioSettings.volume` boost gain above 100% (up to `maxVolume`) without
    // the boosted signal clipping — the limiter clamps transient peaks instead
    // of letting them hard-clip in `mainMixerNode`.
    let limiter: AVAudioUnitEffect = {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitEffect(audioComponentDescription: description)
    }()

    // Night Mode: gentle, always-in-chain dynamic range compressor — unlike
    // `limiter` (a fast brick-wall peak limiter placed after this, right
    // before the output), this engages much earlier (see
    // `configureNightModeCompressor`) to even out quiet vs. loud passages for
    // late-night listening. Always attached and connected (see
    // `configureEngine`); toggled purely via `.bypass` in `applyAudioSettings`,
    // so enabling/disabling it never touches the engine graph's connections.
    let nightModeCompressor: AVAudioUnitEffect = {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitEffect(audioComponentDescription: description)
    }()

    // Spatial Audio (opt-in): HRTF-binaural rendering of the final mix as a
    // single anchored source, head-tracked on compatible headphones. Both
    // nodes are always attached (harmless if unused) but only wired into the
    // signal path when `audioSettings.spatialAudioEnabled` is true — see
    // `setSpatialAudioRouting`. `limiter` connects straight to
    // `mainMixerNode` otherwise, exactly as before this feature existed.
    let environmentNode = AVAudioEnvironmentNode()
    // AVAudioEnvironmentNode requires an AVAudioMixing-conforming input to get
    // per-source 3D positioning; `limiter` (AVAudioUnitEffect) doesn't conform,
    // so this mixer sits between them purely to be that positionable source.
    let spatialSourceMixer = AVAudioMixerNode()
    var isSpatialAudioRouted = false
    // Mono downmix routing state — see `setSpatialAudioRouting`'s mono
    // handling. Mutually exclusive with spatial routing (mono is ignored
    // while spatial audio is on); tracked separately so toggling mono on/off
    // doesn't trigger a reconnect when spatial routing already covers it.
    var isMonoAudioRouted = false

    // MARK: Private — Spatial / Special-Effect Nodes

    var rotationAngle: Double = 0
    /// The 8D rotation speed in Hz. Persisted across sessions. Published so EffectsView can bind to it.
    @Published var rotationHz: Double = UserDefaults.standard.double(forKey: "8d_rotation_hz") > 0
        ? UserDefaults.standard.double(forKey: "8d_rotation_hz") : 0.18
    var rotationLink: CADisplayLink?
    var is8DActive = false

    // Tremolo
    var tremoloLink: CADisplayLink?
    var tremoloPhase: Double = 0
    var tremoloFrequency: Double = 4.0
    var tremoloDepth: Float = 0.45
    var isTremoloActive = false

    // Vibrato
    var vibratoLink: CADisplayLink?
    var vibratoPhase: Double = 0
    var vibratoFrequency: Double = 4.5
    var vibratoDepth: Double = 0.35  // semitones
    var isVibratoActive = false
    var vibratoBasePitch: Float = 0  // captures audioSettings.pitchSemitones at start

    // Tracks which player node currently owns the active song.
    // Flips after each crossfade so the two nodes alternate roles.
    var usingPrimaryNode = true

    // The node playing (or scheduled for) the current song. `usingPrimaryNode` flips
    // to the incoming node the instant a crossfade begins (see beginCrossfade) — at
    // the same moment currentSong/duration/audioFile switch — so this can resolve
    // the same way regardless of crossfade state and never disagrees with "now playing".
    var activeNode: AVAudioPlayerNode {
        usingPrimaryNode ? primaryNode : secondaryNode
    }

    // MARK: Private — Playback Bookkeeping

    var audioFile: AVAudioFile?
    var fileStartFrame: AVAudioFramePosition = 0
    var timer: Timer?
    var isEngineConfigured = false
    /// The sample rate last requested via `ensureSampleRate(matching:)` — starts
    /// at the same 48kHz `configureAudioSession()` requests at launch, so a
    /// session spent entirely on YouTube-sourced/48kHz-or-lower audio never
    /// touches the engine again after the first track (the common case).
    var lastRequestedSampleRate: Double = 48000

    /// The AVAudioFile pre-scheduled by `scheduleGaplessNext` for the next
    /// gapless hand-off, stashed so `handleTrackEnded` can adopt it as the new
    /// `audioFile` the instant that track starts playing (otherwise position/
    /// duration would keep reflecting the track that just ended).
    var pendingGaplessFile: AVAudioFile?

    /// The active node's render-clock sample time at the moment the current
    /// gapless segment began. A gapless hand-off appends the next file to the
    /// SAME continuously-playing node, so `playerTime.sampleTime` keeps
    /// accumulating across tracks instead of resetting to 0 — without
    /// subtracting this baseline, `updatePositionFromPlayer` would compute the
    /// new track's position from the cumulative frame count (clamped to the new
    /// duration), freezing the Now Playing scrubber/MiniPlayer progress. Reset
    /// to 0 on every fresh (stop()+play()) schedule, where the node's clock
    /// really does restart at 0.
    var gaplessBaseFrame: Double = 0

    // ReplayGain: linear gain factor derived from the current track's metadata/RMS analysis
    // (see the `replayGainEnabled` block in scheduleCurrent/transcodeAndSchedule). Reset to
    // neutral (1.0) whenever a new track is scheduled, then refined once analysis completes.
    // `applyAudioSettings` reads this — rather than applying its own separate formula — so a
    // mid-track volume/EQ/speed tweak (which re-invokes applyAudioSettings via the
    // `audioSettings` didSet) recombines the SAME per-track gain with the new volume instead
    // of clobbering it with an unrelated flat value, which previously made ReplayGain's
    // effective loudness depend on the race between the analysis Task and settings changes.
    var replayGainLinearGain: Float = 1.0

    // Crossfade state
    var isCrossfading = false
    var crossfadeTimer: Timer?

    /// Ramps the active node's volume back up after a hard seek-triggered
    /// reschedule — see `rampNodeVolumeAfterSeek` in AudioPlayerManager+Scheduling.swift.
    var seekFadeTimer: Timer?
    /// In-flight click-free pause (see `softPauseNodes`).
    var softPauseTask: Task<Void, Never>?

    /// Set by `playCurrent`'s streamed-track branch, right before silencing
    /// `activeNode`, when a seek/rewind/track-switch is reseeking a track
    /// that was ALREADY playing — the volume to ramp back up to once
    /// `downloadAndSchedule`/`transcodeAndSchedule` actually calls
    /// `node.play()` on the freshly-scheduled segment. `nil` for a genuinely
    /// fresh track start, where snapping straight to full volume is correct
    /// (nothing was audible before it to click against). Consumed (and
    /// cleared) at the one `node.play()` call site that ends up firing;
    /// every call site that can give up without playing (the `catch` blocks'
    /// fallback to `scheduleWithOpusPlayer`) also clears it, so a stale
    /// target can't bleed into an unrelated later play. See
    /// `rampNodeVolumeAfterSeek`'s doc comment for why this exists at all —
    /// without it, every reseek of a STREAMED track (the common case for
    /// this YouTube-sourced-library app) hit a hard `node.stop()` +
    /// full-volume `node.play()` with no silence-then-fade step, audible as
    /// a click/stutter on every rewind or track switch.
    var pendingSeekRampTarget: Float?

    /// Ramps `crossfadeMixer.outputVolume`/`equalizer.globalGain` toward a new
    /// target instead of snapping — see `applyOutputGainRamped` in
    /// AudioPlayerManager+ApplySettings.swift.
    var outputGainRampTimer: Timer?

    /// Playback position (in seconds, in the current track's own timeline) at
    /// which the crossfade into the next track should begin. `nil` when no
    /// crossfade is pending. Evaluated on the 0.5s playback tick — see
    /// `checkCrossfadeTrigger()`.
    ///
    /// This used to be a `Timer` armed for "crossfadeDuration seconds before the
    /// track ends", and that was the cause of a long-standing bug: pausing for a
    /// while and then resuming would jump to the next song.
    ///
    /// A `Timer` measures WALL CLOCK time, and a track's remaining playtime is
    /// not wall-clock time — pausing stops the music but not the clock. While the
    /// app was merely paused in the foreground, the timer fired on schedule and
    /// its `isPlaying` guard discarded it (so that track then silently lost its
    /// crossfade — the quieter half of the same bug). The skip came from pausing
    /// and letting the app suspend: a suspended run loop doesn't fire timers, so
    /// the timer sat overdue, and the instant the run loop came back it fired —
    /// by which point `resume()` had already set `isPlaying = true`, so the guard
    /// passed and a crossfade began seconds into a track that had minutes left.
    /// From the outside, hitting resume skipped the song.
    ///
    /// A position threshold cannot drift from the audio, because `position` is
    /// derived from frames the engine has actually rendered (see
    /// `updatePositionFromPlayer`) and the tick that checks it only runs while
    /// playing. It also fixes seeking for free: the old timer was invalidated on
    /// seek but never re-armed against the new position, so a seek backwards left
    /// the fade to fire early on wall-clock time.
    var crossfadeTriggerPosition: Double?

    /// Grace-period timer armed by `pause()` — see `teardownEngineIfIdle()`.
    /// Lets a quick pause->resume avoid paying an engine restart, while a
    /// pause left sitting releases the audio engine/session instead of
    /// running forever with nothing playing ("ghost audio engine").
    var idleTeardownTimer: Timer?

    /// True once `teardownEngineIfIdle()` has stopped the engine for being
    /// paused too long. A stopped engine does not keep what was scheduled on
    /// its player nodes, so the next resume has to schedule the track again
    /// rather than just pressing play on a node with nothing queued — see
    /// `resume()`.
    var engineReleasedWhileIdle = false

    /// What `updateNowPlaying()` last handed the system, so the 0.5s position
    /// tick only republishes when the lock screen would otherwise be wrong.
    var lastNowPlayingPublish: NowPlayingPublish?

    /// BPM lookups resolved via `libraryManager?.bpm(for:)`, keyed by song ID.
    /// Populated ahead of time by `prewarmBPM` so `beginCrossfade` can read a
    /// tempo synchronously without blocking the fade on analysis.
    var bpmCache: [String: Double] = [:]

    // Gapless: the next file pre-loaded and scheduled on the active node.
    var gaplessScheduled = false

    // The queue index resolved by `peekNextSong()` at the moment a gapless file
    // was scheduled or a crossfade began — captured so `advanceIndex()` lands on
    // the SAME song that's actually already playing. Without this, shuffle mode
    // would independently re-roll a random index when the track transition
    // completes, landing on a different song than the one that was scheduled —
    // which is exactly what showed up as "Now Playing doesn't correctly switch
    // to the next song" / "Next Up doesn't update properly" (currentIndex and
    // currentSong would point at two different songs).
    var pendingNextIndex: Int?

    // Set to true while an async HTTP download + schedule is in progress.
    // Prevents updatePositionFromPlayer() from overwriting `position` with a
    // stale value from the AVAudioPlayerNode before it has actually started.
    var isSchedulingAsync = false

    // Circuit breaker for AVPlayer load/playback failures. Without this, a track
    // with a stale/expired stream URL fails near-instantly, skipToNext() is
    // called, repeatMode == .one replays the SAME track (or .all/.off cycles
    // through an entire queue of equally-stale URLs), and the failure repeats
    // in a tight loop — observed as ~3,000 "AVPlayer failed to load" errors/minute.
    // If failures happen too fast for too long, stop playback instead of retrying.
    var recentLoadFailureTimestamps: [Date] = []

    // Set once `handleLoadFailure` has already retried the *current* track's
    // load once — a corrupt local file fails identically every time (retrying
    // is pointless), but a remote stream (bridge stream-proxy hiccup,
    // transient yt-dlp extraction error, brief concurrency-slot contention)
    // often succeeds seconds later. Reset in `resetReplayGainForNewTrack`
    // (i.e. only when a genuinely new track starts, not by the retry itself).
    var opusRetriedThisLoad = false

    // How many automatic retries the *current* track's load has already used.
    // Separate from `opusRetriedThisLoad` (which stays the one-shot gate for
    // ordinary remote failures) because a bridge "no stream URL found" 404 —
    // surfacing to AVFoundation as NSURLErrorDomain -1100 — is a different
    // animal: it means server-side extraction produced nothing AT THAT MOMENT,
    // typically because the YouTube cookie jar had just gone stale, a yt-dlp
    // concurrency slot was contended, or a POT fetch timed out. All of those
    // clear on their own in seconds-to-minutes, but the old single 1.5s replay
    // was far too eager to outlast any of them, so the track was skipped and
    // the user saw "Couldn't play". 681 of these hit 42 distinct users.
    // Reset alongside `opusRetriedThisLoad` when a genuinely new track starts.
    var opusTransientRetryCount = 0

    // AVPlayer fallback for containers (e.g. .opus) that AVAssetReader cannot decode.
    // When active, this player owns audio output instead of the AVAudioEngine nodes.
    var opusPlayer: AVPlayer?
    var opusTimeObserver: Any?
    var opusStatusObserver: NSKeyValueObservation?
    var opusEndObserver: NSObjectProtocol?
    var opusFailObserver: NSObjectProtocol?

    // Closure-based `addObserver(forName:object:queue:using:)` registers an internal
    // proxy as "the observer" — `removeObserver(self, name:object:)` in `deinit`
    // never matches it (see the `tearDownOpusPlayer` comment for the full
    // explanation). These three must be removed by their captured tokens too.
    var backgroundObserver: NSObjectProtocol?
    var foregroundObserver: NSObjectProtocol?
    var interruptionObserver: NSObjectProtocol?
    var routeChangeObserver: NSObjectProtocol?
    var engineConfigChangeObserver: NSObjectProtocol?
    var isUsingOpusPlayer: Bool { opusPlayer != nil }

    // Schedule generation counter — incremented before every node stop/reschedule.
    // Completion blocks capture the generation at registration time and bail out if it
    // has changed, preventing ghost completions from firing after a seek or skip.
    var scheduleGeneration: UInt64 = 0

    // Bumped every time scheduleAnalyzerEQCorrection() runs — lets its delayed
    // (analyzer-needs-a-couple-seconds-to-settle) correction bail out if the
    // track has since changed, instead of applying a stale track's correction
    // to whatever's playing by the time the delay elapses.
    var eqCorrectionGeneration: UInt64 = 0

    // Audio interruption / route change
    var wasInterrupted = false

    // MARK: Stall detection
    //
    // Position as of the previous tick, and how many consecutive ticks it has
    // failed to move while we believed audio was playing. See
    // `checkForPlaybackStall()`.
    var lastStallCheckPosition: TimeInterval = 0
    var stalledTickCount = 0
    // Where the last stall-recovery reschedule resumed from, and how many
    // times in a row a recovery has landed back in a stall at essentially
    // that same spot — distinct from `stalledTickCount` above, which resets
    // on every successful recovery and so can't see this by itself. See
    // `checkForPlaybackStall()`'s escalation past a dead spot in the file.
    var lastStallRecoveryPosition: TimeInterval?
    var consecutiveStallRecoveriesAtSamePosition = 0
    // Same shape as the pair above, for the AVPlayer (opus/webm/ogg/
    // ipod-library) fallback path — see `checkForOpusPlayerStall()`. Kept
    // separate from the AVAudioEngine counters even though the two paths
    // are mutually exclusive at any given moment, so the two recovery
    // strategies can never be confused for each other while reading this code.
    var lastOpusStallCheckPosition: TimeInterval = 0
    var opusStalledTickCount = 0
    var lastOpusStallRecoveryPosition: TimeInterval?
    var consecutiveOpusStallRecoveriesAtSamePosition = 0
    // Throttles `startEngineIfNeeded()`'s rebuild-and-retry path — see that
    // function's doc comment for why an unthrottled retry here is a real,
    // observed production incident, not a theoretical one.
    var lastEngineStartFailureAt: Date?
    // True when playback was auto-paused because the active output route
    // disappeared (e.g. Bluetooth disconnect) — used to auto-resume when a
    // route becomes available again.
    var pausedByRouteChange = false
    // Armed by `handleRouteChange`'s `.oldDeviceUnavailable` case for the
    // grace period before actually pausing — see that function for why.
    // Cancelled (and the pause never happens) if `.newDeviceAvailable`
    // arrives first, or if anything else calls `pause()` in the meantime.
    var pendingRouteLossPauseTask: Task<Void, Never>?

    // Mirrors `LibraryManager.shared` — gives App Intents (invoked directly
    // by iOS/Siri via the AppIntents framework, with no SwiftUI environment
    // access) a way to reach the live player instance.
    static weak var shared: AudioPlayerManager?

    // MARK: Internal — State Used By Extensions (must be stored on the type
    // itself; extensions in AudioPlayerManager+*.swift cannot hold stored
    // properties, so anything they need to persist across calls lives here)

    let playbackStateKey = "playback_state_v1"
    var visualizerTapInstalled = false
    /// Counts 0.5s timer ticks so `pushPlaybackStateToBridge()` runs roughly
    /// every 5s during playback, instead of on every tick.
    var bridgePushTickCounter = 0
    /// Cancelled/rescheduled on every track change; the in-flight task for the
    /// previous track.
    var historyLogTask: Task<Void, Never>?
    var queuePushTask: Task<Void, Never>?

    // MARK: Init / Deinit

    init() {
        Self.shared = self
        configureAudioSession()
        configureEngine()
        configureEqualizer()
        configureRemoteCommands()
        restorePlaybackState()

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isProgressPublishingPaused = false }
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isProgressPublishingPaused = true }
            Task { @MainActor in
                self?.savePlaybackState()
                // Backgrounded while paused: no grace period needed (unlike
                // `pause()`'s own timer — the user isn't about to resume
                // mid-interaction with the app not even visible), so release
                // the engine/session immediately rather than waiting for the
                // grace-period timer — see `teardownEngineIfIdle()`.
                if self?.isPlaying == false {
                    self?.teardownEngineIfIdle()
                }
                // Reconcile the widget's favorite badge right before the app
                // (and its Home Screen widgets) are the only thing visible —
                // covers a favorite toggled from in-app UI while paused,
                // which the position timer wouldn't otherwise catch since it
                // doesn't run when not playing.
                if let song = self?.currentSong {
                    WidgetDataService.shared.updateFavoriteState(
                        isFavorite: LibraryManager.shared?.isFavorite(songID: song.id) ?? false
                    )
                }
            }
        }

        // Widget and Live Activity buttons run their intents in this process
        // (see LumisoundPlaybackIntents.swift) and arrive here directly.
        LumisoundPlaybackCommandRouter.handler = { [weak self] command in
            guard let self else { return false }
            switch command {
            case .togglePlayback: self.togglePlayPause()
            case .skipNext:       self.skipToNext()
            case .skipPrevious:   self.skipToPrevious()
            case .toggleFavorite: self.toggleFavoriteFromWidget()
            }
            return true
        }

        // Fallback: commands posted from the WidgetKit extension when the
        // intent ran there instead.
        DarwinWidgetBridge.shared.addObserver(name: DarwinWidgetBridge.togglePlayback) { [weak self] in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
        }
        DarwinWidgetBridge.shared.addObserver(name: DarwinWidgetBridge.skipNext) { [weak self] in
            Task { @MainActor [weak self] in self?.skipToNext() }
        }
        DarwinWidgetBridge.shared.addObserver(name: DarwinWidgetBridge.skipPrevious) { [weak self] in
            Task { @MainActor [weak self] in self?.skipToPrevious() }
        }
        // "com.lumisound.ios.widget.toggleFavorite" — kept as a literal here
        // rather than a `DarwinWidgetBridge` static (unlike the three above)
        // since this name is only used by the widget-favorite feature; see
        // `WidgetNotificationNames.toggleFavorite` in the widget extension
        // for the matching definition.
        DarwinWidgetBridge.shared.addObserver(name: "com.lumisound.ios.widget.toggleFavorite") { [weak self] in
            Task { @MainActor [weak self] in self?.toggleFavoriteFromWidget() }
        }
    }

    /// Invoked when the widget's `ToggleFavoriteIntent` posts its Darwin
    /// notification while this app process is alive. The widget extension
    /// can't reach `LibraryManager` directly (it runs in its own process),
    /// so it already wrote an optimistic guess straight to the shared App
    /// Group — here we perform the real toggle and push the authoritative
    /// result back, overwriting that guess. If the app is fully suspended
    /// or not running when the button is tapped, this never runs and the
    /// widget's optimistic value is all the user gets until they next open
    /// the app — iOS does not allow a widget `AppIntent` to launch the app
    /// silently in the background.
    func toggleFavoriteFromWidget() {
        guard let song = currentSong else { return }
        LibraryManager.shared?.toggleFavorite(songID: song.id)
        WidgetDataService.shared.updateFavoriteState(
            isFavorite: LibraryManager.shared?.isFavorite(songID: song.id) ?? false
        )
    }

    deinit {
        timer?.invalidate()
        crossfadeTimer?.invalidate()
        rotationLink?.invalidate()
        tremoloLink?.invalidate()
        vibratoLink?.invalidate()
        // `removeObserver(self)` is a no-op for closure-based registrations below
        // (they're keyed on an internal proxy, not `self`) — must remove by token.
        for token in [backgroundObserver, foregroundObserver, interruptionObserver, routeChangeObserver, engineConfigChangeObserver, opusEndObserver, opusFailObserver] {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)
        center.changeShuffleModeCommand.removeTarget(nil)
        center.changeRepeatModeCommand.removeTarget(nil)
    }

}


// MARK: - AVAudioFile Convenience

extension AVAudioFile {
    var duration: TimeInterval {
        Double(length) / processingFormat.sampleRate
    }
}
