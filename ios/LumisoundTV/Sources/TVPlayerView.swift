import SwiftUI
import AVFoundation

// MARK: - TVPlayContext (queue + where to start)

struct TVPlayContext: Hashable {
    let queue: [TVPlayable]
    let startID: String
}

enum TVRepeatMode {
    case off, all, one

    /// Cycles off → all → one → off, driven by a single button tap.
    var next: TVRepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbol: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

// MARK: - TVPlayerModel

@MainActor
final class TVPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var isBuffering = false
    /// True while the full Now Playing screen is on screen.
    ///
    /// The mini-player bar is pinned to the app shell, which the pushed player
    /// sits inside — so without this it would render over the bottom of the
    /// full player, duplicating what that screen already shows and stealing a
    /// focus target from its transport controls.
    @Published var isShowingFullPlayer = false
    @Published var currentIndex = 0
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var queue: [TVPlayable] = []
    @Published private(set) var isShuffled = false
    @Published var repeatMode: TVRepeatMode = .off
    @Published private(set) var sleepTimerEndDate: Date?
    @Published private(set) var lyrics: [TVLyricLine] = []
    @Published private(set) var isLoadingLyrics = false
    @Published var crossfadeEnabled: Bool = UserDefaults.standard.bool(forKey: "tv.player.crossfadeEnabled") {
        didSet { UserDefaults.standard.set(crossfadeEnabled, forKey: "tv.player.crossfadeEnabled") }
    }

    // A real app-wide singleton (not per-screen) — same pattern as
    // `TVAccount.shared`/`TVBridgeClient.shared`, and constructed the same
    // way at the app root (see `TVContentView`'s `@StateObject private var
    // player = TVPlayerModel.shared`). This used to be a plain
    // `@StateObject` owned by `TVPlayerView` itself, torn down (`stop()`
    // on `.onDisappear`) the moment the user navigated away from Now
    // Playing — which meant a Siri/App Intent (TVAppIntents.swift, which
    // runs outside the normal SwiftUI environment the same way a BGTask
    // does on iOS) had nothing reachable to START playback with, only to
    // control an already-open Now Playing screen. Promoting it here is
    // what actually lets Siri start playback from cold, and as a side
    // effect also means playback now keeps going while browsing elsewhere
    // in the app instead of stopping the instant Now Playing closes —
    // matching how the iOS app's `AudioPlayerManager` already behaves.
    static let shared = TVPlayerModel()

    // MARK: Dual-player crossfade
    //
    // Two fixed AVPlayer instances rather than one — crossfading means the
    // outgoing track's player and the incoming track's player must both be
    // audible and advancing at once for `crossfadeDuration` seconds, which a
    // single `replaceCurrentItem` swap can't do. `player` always means
    // "whichever one is currently the audible/active track"; observers (time/
    // status/end) are attached to BOTH once, each self-filtering to only act
    // when it's the currently-active instance — simpler and safer than tearing
    // down and reattaching observers every time the active player changes.
    private let playerA = AVPlayer()
    private let playerB = AVPlayer()
    private var activeIsA = true
    var player: AVPlayer { activeIsA ? playerA : playerB }
    private var inactivePlayer: AVPlayer { activeIsA ? playerB : playerA }
    /// Base overlap. With Auto Crossfade on, `TVAutoCrossfade` picks a length
    /// per transition from this starting point; with it off this is used as-is.
    private let crossfadeDuration: TimeInterval = TVAutoCrossfade.baseDuration
    /// The length chosen for the transition currently in flight. Computed once
    /// when the crossfade begins, not per step — the fade must run at a constant
    /// rate, and recomputing mid-fade would make it speed up or stall.
    private var activeCrossfadeDuration: TimeInterval = TVAutoCrossfade.baseDuration
    private var crossfadeTask: Task<Void, Never>?
    private var hasCrossfadedForCurrentTrack = false

    // MARK: Stall watchdog state — see `checkForPlaybackStall()`.
    private var lastStallCheckPosition: Double = 0
    private var stalledTickCount = 0
    private var lastStallRecoveryPosition: Double?
    private var consecutiveStallRecoveriesAtSamePosition = 0

    /// Queue order before shuffling — restored when shuffle is toggled off.
    private var originalQueue: [TVPlayable] = []
    private var endObservers: [NSObjectProtocol] = []
    private var failureObservers: [NSObjectProtocol] = []
    private var timeObservers: [(AVPlayer, Any)] = []
    private var statusObservations: [NSKeyValueObservation] = []
    private var sleepTimerTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    /// The track Aria is handing over FROM — see TVAria.requestTransition.
    private var previousTrack: TVPlayable?
    var audioSessionObservers: [NSObjectProtocol] = []

    var current: TVPlayable? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }

    /// The queue/start-point `start(context:)` most recently actually
    /// adopted — lets repeat calls with the SAME context (e.g. navigating
    /// back to Now Playing without picking a new track, now that this is a
    /// persistent singleton instead of a fresh-per-screen instance) resume
    /// in place rather than restarting, while a genuinely different
    /// context still replaces the queue as before.
    private var currentContext: TVPlayContext?

    func start(context: TVPlayContext) {
        guard currentContext != context else { return }
        currentContext = context
        cancelCrossfade()
        isShuffled = false
        queue = context.queue
        originalQueue = context.queue
        currentIndex = queue.firstIndex(where: { $0.id == context.startID }) ?? 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        setupObservers()
        setupAudioSessionObservers()
        configureRemoteCommands()
        loadCurrent()
    }

    /// Seeks within the current track, clamped to `[0, duration]` — used by
    /// the "skip forward/back N seconds" Siri intents (TVAppIntents.swift).
    /// `position` is updated immediately rather than waiting for the next
    /// periodic time-observer tick, so a seek doesn't visibly lag.
    func seek(to newPosition: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(newPosition, duration))
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// Watches for the AVPlayer-reports-playing-but-position-frozen stall —
    /// buffering indefinitely on a flaky connection, or AVPlayer just
    /// getting internally stuck, both real AVPlayer failure modes. Without
    /// this, tvOS had NO recovery at all for a hung stream: `isPlaying`
    /// stays true, nothing is audible, and nothing ever retries — the main
    /// iOS app's AVPlayer fallback path already had to fix this exact gap
    /// (`checkForOpusPlayerStall`, `AudioPlayerManager+PositionTracking.swift`)
    /// after it showed up in production; this mirrors that fix for tvOS's
    /// own AVPlayer-only playback path, which never got it. Called every
    /// 0.2s from the periodic time observer above, so the tick counts below
    /// are scaled from that function's 0.5s-tick thresholds to the same
    /// wall-clock durations.
    private func checkForPlaybackStall() {
        // Every condition here is a state where position legitimately does
        // not advance — treating any of them as a stall would restart
        // playback on top of itself.
        guard isPlaying, !isBuffering, crossfadeTask == nil,
              duration > 0, position < duration - 1.0
        else {
            stalledTickCount = 0
            lastStallCheckPosition = position
            return
        }

        // A tick is 0.2s, so anything genuinely playing moves well beyond this.
        if position > lastStallCheckPosition + 0.02 {
            stalledTickCount = 0
            lastStallCheckPosition = position
            if let recoveredAt = lastStallRecoveryPosition, position > recoveredAt + 3 {
                lastStallRecoveryPosition = nil
                consecutiveStallRecoveriesAtSamePosition = 0
            }
            return
        }

        stalledTickCount += 1
        // 15 ticks at 0.2s = 3 seconds of believing we play while rendering
        // nothing — same 3s budget as the main app's 6 ticks at 0.5s.
        guard stalledTickCount >= 15 else { return }

        let resumeAt = position
        stalledTickCount = 0
        lastStallCheckPosition = resumeAt

        if let lastPosition = lastStallRecoveryPosition, abs(resumeAt - lastPosition) < 1.5 {
            consecutiveStallRecoveriesAtSamePosition += 1
        } else {
            consecutiveStallRecoveriesAtSamePosition = 1
        }
        lastStallRecoveryPosition = resumeAt

        if consecutiveStallRecoveriesAtSamePosition >= 5 {
            tvWarn("Playback stall at \(String(format: "%.1f", resumeAt))s recurred \(consecutiveStallRecoveriesAtSamePosition)x — giving up and skipping", category: "playback")
            TVRemoteLogger.logError(category: "playback", event: "playback_stall_unrecoverable",
                                     message: "position frozen at \(Int(resumeAt))s, \(consecutiveStallRecoveriesAtSamePosition) recovery attempts")
            lastStallRecoveryPosition = nil
            consecutiveStallRecoveriesAtSamePosition = 0
            next()
            return
        }

        // First attempt: a cheap pause/play "kick" — no reseek, near-
        // instant. Only escalate to a real re-seek (which forces AVPlayer
        // to drop and refill its buffer from scratch) once that's confirmed
        // not to be enough; and only nudge a few seconds past the dead spot
        // once even a same-position re-seek has failed repeatedly, same
        // escalation shape as the main app's version.
        if consecutiveStallRecoveriesAtSamePosition == 1 {
            tvWarn("Playback stalled — reports playing but position frozen at \(String(format: "%.1f", resumeAt))s for 3s; kicking", category: "playback")
            TVRemoteLogger.log(category: "playback", event: "playback_stall_recovered",
                                detail: ["position": Int(resumeAt), "attempt": consecutiveStallRecoveriesAtSamePosition, "kicked": true])
            player.pause()
            player.play()
            return
        }

        let nudging = consecutiveStallRecoveriesAtSamePosition >= 3
        let target = nudging ? min(resumeAt + 5, max(0, duration - 0.5)) : resumeAt
        tvWarn("Playback stalled — reports playing but position frozen at \(String(format: "%.1f", resumeAt))s for 3s; \(nudging ? "nudging to \(String(format: "%.1f", target))s" : "re-seeking") (attempt \(consecutiveStallRecoveriesAtSamePosition))", category: "playback")
        TVRemoteLogger.log(category: "playback", event: "playback_stall_recovered",
                            detail: ["position": Int(resumeAt), "attempt": consecutiveStallRecoveriesAtSamePosition, "nudged": nudging])
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            self?.player.play()
        }
    }

    private func setupObservers() {
        guard endObservers.isEmpty else { return }  // set up once, on both players

        for p in [playerA, playerB] {
            // Only reacts when `p` is the currently-active player AND the item
            // that ended is still that player's current item — guards against
            // a stale notification from a player that's since been reused/
            // reset (e.g. a cancelled crossfade's incoming player).
            let endObs = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
            ) { [weak self, weak p] note in
                Task { @MainActor in
                    guard let self, let p, self.player === p,
                          let endedItem = note.object as? AVPlayerItem, endedItem === p.currentItem
                    else { return }
                    self.handleNaturalEnd()
                }
            }
            endObservers.append(endObs)

            // Playback failures (bad stream, dropped connection mid-track)
            // previously went completely unlogged — the UI would just spin
            // forever with nothing surfaced anywhere, client or server.
            let failureObs = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
            ) { [weak self, weak p] note in
                Task { @MainActor in
                    guard let self, let p, self.player === p,
                          let failedItem = note.object as? AVPlayerItem, failedItem === p.currentItem
                    else { return }
                    let underlying = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                        ?? p.currentItem?.error?.localizedDescription ?? "unknown error"
                    tvError("Playback failed: \(underlying)", category: "playback",
                            extra: ["title": self.current?.title ?? "?"])
                    TVRemoteLogger.logError(category: "playback", event: "playback_failed", message: underlying)
                }
            }
            failureObservers.append(failureObs)

            // Drives the scrubber + elapsed/remaining time, and the crossfade trigger.
            // 0.2s, not 0.5s: this timer is what advances the lyric
            // highlight, and at 0.5s the lit line lagged the audio by up to
            // half a second, which reads as lyrics simply being out of sync.
            let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
            let timeObs = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak p] time in
                Task { @MainActor in
                    guard let self, let p, self.player === p else { return }
                    self.position = time.seconds.isFinite ? time.seconds : 0
                    if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 {
                        self.duration = d
                    }
                    self.checkCrossfadeTrigger()
                    self.checkForPlaybackStall()
                    self.updateNowPlayingInfo()
                }
            }
            timeObservers.append((p, timeObs))

            // Keeps play/pause + the loading spinner in sync with real playback.
            let statusObs = p.observe(\.timeControlStatus, options: [.new]) { [weak self, weak p] observed, _ in
                Task { @MainActor in
                    guard let self, let p, self.player === p else { return }
                    self.isPlaying = observed.timeControlStatus == .playing
                    self.isBuffering = observed.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    self.updateNowPlayingInfo()
                }
            }
            statusObservations.append(statusObs)
        }
    }

    private func asset(for item: TVPlayable) -> AVURLAsset {
        // /api/stream/proxy is check_auth()-gated (needs "Authorization: Bearer
        // <IOS_BRIDGE_API_KEY>") and separately reads the user's personal
        // YouTube key off the raw "X-Account-Token" header; it never reads
        // Authorization for its own business logic, so putting the API key
        // there doesn't collide with anything. /user/music/stream instead
        // checks "Authorization: Bearer <user token>" and ignores
        // X-Account-Token. Both headers are always sent — each endpoint
        // ignores the one it doesn't recognize — except Authorization itself,
        // which has to pick the right value for whichever endpoint this
        // particular item's streamURL actually targets.
        let isStreamProxy = item.streamURL.path == "/api/stream/proxy"
        let authorization = isStreamProxy
            ? "Bearer \(TVBridgeClient.officialBridgeAPIKey)"
            : item.authToken.map { "Bearer \($0)" }
        var headers: [String: String] = [:]
        if let authorization { headers["Authorization"] = authorization }
        if let token = item.authToken { headers["X-Account-Token"] = token }
        guard !headers.isEmpty else { return AVURLAsset(url: item.streamURL) }
        return AVURLAsset(url: item.streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    /// Locked-aware version of `asset(for:)` — a non-locked item resolves
    /// instantly via the same URL/header construction as before. A
    /// Lumisound-locked Personal Cloud Library item (`item.isLocked`) is
    /// downloaded in full and unlocked to a local temp file first, via
    /// `TVLockedTrackCache` — its bytes aren't a decodable audio container
    /// to AVFoundation until that transform is reversed (see
    /// `TVLockFormat`'s header comment). Falls back to the raw (undecoded)
    /// stream on a download/unlock failure, matching this app's "never leave
    /// playback silently stuck" pattern elsewhere — the player's existing
    /// failure observer surfaces that the same way it would any other
    /// unplayable item, rather than hanging forever on a resolution that
    /// already failed.
    private func resolvedAsset(for item: TVPlayable) async -> AVURLAsset {
        guard item.isLocked else { return asset(for: item) }
        if let localURL = await TVLockedTrackCache.shared.playableURL(for: item) {
            return AVURLAsset(url: localURL)
        }
        return asset(for: item)
    }

    private func loadCurrent() {
        guard let item = current else { return }
        cancelCrossfade()
        position = 0
        duration = 0
        isBuffering = true
        player.volume = 1
        loadLyrics(for: item)
        // Single chokepoint for every track transition (initial start, skip,
        // repeat-all wrap, Up Next jump) — logging once here instead of at
        // each caller avoids duplicating this at four call sites.
        tvBreadcrumb("Playing: \(item.title)")
        TVRemoteLogger.log(category: "playback", event: "track_started",
                            detail: ["title": item.title, "artist": item.artist])
        updateNowPlayingInfo()
        updateNowPlayingArtwork()
        // Aria's handover into this track. Fire-and-forget: it never gates
        // playback, so a slow or absent answer costs nothing but a missing line.
        if let token = TVAccount.shared.token {
            TVAria.shared.requestTransition(from: previousTrack, to: item, token: token)
        }
        previousTrack = item

        Task { [weak self] in
            guard let self else { return }
            let resolved = await self.resolvedAsset(for: item)
            // The user may have skipped again while a locked track was
            // downloading — don't stomp over whatever's playing now.
            guard self.current?.id == item.id else { return }
            let playerItem = AVPlayerItem(asset: resolved)

            // Stop the system widening stereo music into a virtual surround
            // field. On by default on an Apple TV, and it smears the stereo
            // image — the most likely reason the same file sounds less direct
            // here than on a phone, which never takes this path at all.
            playerItem.allowedAudioSpatializationFormats =
                TVAudioSettings.shared.allowSpatialization ? .monoStereoAndMultichannel : .monoAndStereo

            self.player.replaceCurrentItem(with: playerItem)
            self.player.play()

            // Leading-silence trim, AFTER the item is attached so the seek
            // lands on a real asset. Analysis decodes the head of the file, so
            // it runs off the main actor and only applies if this is still the
            // track playing when it finishes.
            guard TVAudioSettings.shared.skipSilentIntros,
                  let assetURL = (resolved as? AVURLAsset)?.url else { return }
            let trim = await TVSilenceTrim.analyze(url: assetURL, trackID: item.id)
            guard trim > 0, self.current?.id == item.id else { return }
            // `await`: inside an async context Swift resolves seek(to:) to the
            // async overload, which must be awaited rather than fired and
            // forgotten.
            await self.player.seek(to: CMTime(seconds: trim, preferredTimescale: 600))
            TVRemoteLogger.log(category: "audio", event: "silent_intro_skipped",
                               detail: ["title": item.title, "seconds": round(trim * 100) / 100])
        }
    }

    // MARK: Crossfade

    /// Only the natural end of the *active* player's item reaches here — if
    /// a crossfade already claimed this transition (`hasCrossfadedForCurrentTrack`),
    /// `completeCrossfade` handles advancing instead, so this no-ops to avoid
    /// double-advancing.
    private func handleNaturalEnd() {
        guard !hasCrossfadedForCurrentTrack else { return }
        advanceOnEnd()
    }

    /// The plan for the transition out of the current track.
    ///
    /// Computed from the same inputs in both places it is needed — the trigger
    /// and the fade itself — so the moment the fade starts and how long it runs
    /// can never disagree.
    private func currentTransitionPlan(into nextItem: TVPlayable) -> TVAutoCrossfade.Plan {
        guard TVAudioSettings.shared.autoCrossfade else {
            return TVAutoCrossfade.Plan(duration: crossfadeDuration,
                                        startBefore: crossfadeDuration,
                                        reason: "auto-off")
        }
        // Only measured locally when the server has not profiled this track yet.
        let tail: Double? = current?.transitionProfile == nil
            ? (player.currentItem?.asset as? AVURLAsset).flatMap {
                TVTailLevel.measure(url: $0.url, duration: duration)
              }
            : nil
        return TVAutoCrossfade.plan(
            outgoingDuration: duration,
            incomingDuration: nextItem.durationSeconds,
            outgoing: current?.transitionProfile,
            incoming: nextItem.transitionProfile,
            outgoingBPM: current?.bpm,
            incomingBPM: nextItem.bpm,
            tailLevel: tail
        )
    }

    /// How far before the end of the file the fade should begin.
    private func pendingTransitionLead() -> TimeInterval {
        guard let nextIndex = nextIndexForCrossfade(), queue.indices.contains(nextIndex) else {
            return crossfadeDuration
        }
        return currentTransitionPlan(into: queue[nextIndex]).startBefore
    }

    private func nextIndexForCrossfade() -> Int? {
        guard crossfadeEnabled, queue.count > 1, repeatMode != .one else { return nil }
        if currentIndex + 1 < queue.count { return currentIndex + 1 }
        if repeatMode == .all { return 0 }
        return nil
    }

    private func checkCrossfadeTrigger() {
        // The window now includes the outgoing track's TRAILING SILENCE.
        //
        // Triggering at `duration - fade` assumes the track is still playing
        // that close to the end. Measured across a real library it often is not:
        // a third of tracks carry more than 1.5s of dead air and one had
        // thirty-eight seconds, so the "crossfade" was partly or entirely the
        // next track fading up over nothing. Starting earlier by exactly the
        // amount of silence puts the overlap back on music.
        let lead = pendingTransitionLead()
        guard !hasCrossfadedForCurrentTrack, duration > lead,
              duration - position <= lead,
              nextIndexForCrossfade() != nil
        else { return }
        hasCrossfadedForCurrentTrack = true
        beginCrossfade()
    }

    private func beginCrossfade() {
        guard let nextIndex = nextIndexForCrossfade(), queue.indices.contains(nextIndex) else { return }
        let nextItem = queue[nextIndex]
        let outgoing = player
        let incoming = inactivePlayer

        incoming.pause()
        incoming.volume = 0

        activeCrossfadeDuration = currentTransitionPlan(into: nextItem).duration

        tvLog("Crossfade started into: \(nextItem.title)", category: "playback")
        let plan = currentTransitionPlan(into: nextItem)
        TVRemoteLogger.log(
            category: "playback", event: "crossfade_started",
            detail: ["into": nextItem.title,
                     "seconds": round(plan.duration * 10) / 10,
                     "startBefore": round(plan.startBefore * 10) / 10,
                     // Why this length — a transition that sounds wrong is very
                     // hard to reason about after the fact without it.
                     "reason": plan.reason,
                     "auto": TVAudioSettings.shared.autoCrossfade]
        )

        let steps = 30
        let stepNanoseconds = UInt64(activeCrossfadeDuration / Double(steps) * 1_000_000_000)
        crossfadeTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await self.resolvedAsset(for: nextItem)
            guard !Task.isCancelled else { return }
            incoming.replaceCurrentItem(with: AVPlayerItem(asset: resolved))
            incoming.play()
            for i in 0...steps {
                guard !Task.isCancelled else { return }
                let t = Double(i) / Double(steps)
                // Equal-power curve so the perceived combined loudness stays
                // roughly constant through the fade, rather than dipping in
                // the middle the way a plain linear crossfade would.
                outgoing.volume = Float(cos(t * .pi / 2))
                incoming.volume = Float(sin(t * .pi / 2))
                try? await Task.sleep(nanoseconds: stepNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self.completeCrossfade(to: nextIndex)
        }
    }

    private func completeCrossfade(to index: Int) {
        logPlayForCurrentTrackIfNeeded()
        let finishedOutgoing = player
        activeIsA.toggle()
        currentIndex = index
        position = 0
        duration = 0
        isBuffering = false
        hasCrossfadedForCurrentTrack = false
        crossfadeTask = nil
        player.volume = 1
        finishedOutgoing.pause()
        finishedOutgoing.replaceCurrentItem(with: nil)
        loadLyrics(for: queue[index])
        let newItem = queue[index]
        tvBreadcrumb("Crossfaded to: \(newItem.title)")
        TVRemoteLogger.log(category: "playback", event: "track_started",
                            detail: ["title": newItem.title, "artist": newItem.artist, "via": "crossfade"])
        updateNowPlayingInfo()
        updateNowPlayingArtwork()
    }

    /// Stops and silences an in-flight crossfade (the not-yet-promoted
    /// incoming player is fully paused/cleared, not just volume-reset —
    /// leaving it playing at any nonzero volume would mean two tracks
    /// audible at once until something else resolved it). Safe to call any
    /// time; a no-op when no crossfade is in flight.
    private func cancelCrossfade() {
        guard crossfadeTask != nil else { return }
        crossfadeTask?.cancel()
        crossfadeTask = nil
        hasCrossfadedForCurrentTrack = false
        player.volume = 1
        inactivePlayer.pause()
        inactivePlayer.replaceCurrentItem(with: nil)
        inactivePlayer.volume = 1
    }

    // MARK: Play history

    /// Reports the currently-loaded track's play to the bridge — called
    /// right before advancing/stopping, while `current`/`position` still
    /// describe the track that's ending. Skips near-instant skips (<2s of
    /// real listening) so scrubbing through a queue doesn't inflate stats;
    /// requires a signed-in token (always true in practice — the player is
    /// only reachable from behind TVAccount's login gate).
    private func logPlayForCurrentTrackIfNeeded() {
        guard let item = current, position > 2, let token = TVAccount.shared.token else { return }
        let listenSeconds = Int(position)
        Task {
            await TVBridgeClient.shared.logPlay(
                title: item.title, artist: item.artist,
                trackURL: item.streamURL.absoluteString,
                listenSeconds: listenSeconds, token: token
            )
        }
    }

    // MARK: Lyrics

    /// Waits briefly for the asset's real duration to load (used to reject a
    /// same-titled-but-wrong recording/song — see TVLyricsService) before
    /// fetching, falling back to an undisambiguated search if it takes too
    /// long. Re-checks `current?.id == item.id` after every suspension point
    /// since the user may have skipped tracks while this was waiting/in flight.
    private func loadLyrics(for item: TVPlayable) {
        lyricsTask?.cancel()
        lyrics = []
        isLoadingLyrics = true
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            // Cleared on EVERY exit. It was only cleared on the success path, so
            // any of the three early returns below — the user skipping tracks
            // while the duration probe waited, or while the fetch was in flight,
            // or the task being cancelled outright — left the flag stuck true
            // for the rest of the session. The UI then showed "loading lyrics"
            // forever for a track whose fetch had long since been abandoned,
            // which is indistinguishable from a hung request.
            defer { self.isLoadingLyrics = false }

            var waited = 0.0
            while self.duration <= 0, waited < 5, !Task.isCancelled, self.current?.id == item.id {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
            guard !Task.isCancelled, self.current?.id == item.id else { return }
            let started = Date()
            let fetched = await TVLyricsService.fetch(title: item.title, artist: item.artist, duration: self.duration)
            guard !Task.isCancelled, self.current?.id == item.id else { return }
            self.lyrics = fetched ?? []

            // Whether a lookup MATCHED is the only way to tell "this track has
            // no lyrics published" from "our query never had a chance" — a
            // title like "How It's Done (from the Netflix film KPop Demon
            // Hunters)" carries a parenthetical the lyrics database does not
            // have. Logging the title we actually searched with, and the
            // outcome, is what makes that difference measurable instead of a
            // guess about why the panel is empty.
            TVRemoteLogger.log(
                category: "lyrics",
                event: fetched?.isEmpty == false ? "lyrics_matched" : "lyrics_not_found",
                detail: [
                    "title": item.title,
                    "artist": item.artist,
                    "hasParenthetical": item.title.contains("("),
                    "titleLength": item.title.count,
                    "durationKnown": self.duration > 0,
                    "lineCount": fetched?.count ?? 0,
                    "elapsedMs": Int(Date().timeIntervalSince(started) * 1000),
                ]
            )
        }
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    /// Manual "skip forward" — always advances (or stops at the end of a
    /// non-repeating queue), regardless of repeat mode. Repeat-one only
    /// affects what happens when a track ends on its own; see `advanceOnEnd`.
    func next() {
        cancelCrossfade()
        guard currentIndex + 1 < queue.count else {
            if repeatMode == .all, !queue.isEmpty {
                logPlayForCurrentTrackIfNeeded()
                currentIndex = 0
                loadCurrent()
            } else {
                logPlayForCurrentTrackIfNeeded()
                player.pause()
            }
            return
        }
        logPlayForCurrentTrackIfNeeded()
        currentIndex += 1
        loadCurrent()
    }

    /// Called when the current item finishes playing on its own.
    private func advanceOnEnd() {
        if repeatMode == .one {
            logPlayForCurrentTrackIfNeeded()
            player.seek(to: .zero)
            player.play()
            return
        }
        next()
    }

    /// Jumps directly to a track elsewhere in the queue — used by the "Up
    /// Next" panel so picking a track doesn't require stepping through
    /// `next()` one at a time.
    func jump(to index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        cancelCrossfade()
        logPlayForCurrentTrackIfNeeded()
        currentIndex = index
        loadCurrent()
    }

    func previous() {
        cancelCrossfade()
        // If we're more than 3s in, restart the track instead of skipping back.
        if position > 3 {
            player.seek(to: .zero); return
        }
        guard currentIndex > 0 else { player.seek(to: .zero); return }
        logPlayForCurrentTrackIfNeeded()
        currentIndex -= 1
        loadCurrent()
    }

    /// Removes a queued-up track. The currently-playing track can't be
    /// removed this way — skip to another track first.
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        // A removal could invalidate the index an in-flight crossfade is
        // ramping toward — simplest safe response is to cancel it; the
        // transition falls back to an instant swap when this track ends.
        cancelCrossfade()
        let removedID = queue[index].id
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        originalQueue.removeAll { $0.id == removedID }
    }

    /// Shuffles everything except leaves the currently-playing track findable
    /// by id afterward (rather than resetting to index 0), so toggling
    /// shuffle mid-playback doesn't yank the listener to a different track.
    func toggleShuffle() {
        isShuffled.toggle()
        let currentID = current?.id
        queue = isShuffled ? originalQueue.shuffled() : originalQueue
        if let currentID {
            currentIndex = queue.firstIndex(where: { $0.id == currentID }) ?? 0
        }
        TVRemoteLogger.log(category: "playback", event: "shuffle_toggled", detail: ["enabled": isShuffled])
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
        TVRemoteLogger.log(category: "playback", event: "repeat_mode_changed", detail: ["mode": "\(repeatMode)"])
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerEndDate = end
        tvLog("Sleep timer set for \(minutes) minutes", category: "playback")
        TVRemoteLogger.log(category: "playback", event: "sleep_timer_set", detail: ["minutes": minutes])
        sleepTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = end.timeIntervalSinceNow
                if remaining <= 0 {
                    self.player.pause()
                    self.sleepTimerEndDate = nil
                    tvBreadcrumb("Sleep timer paused playback")
                    TVRemoteLogger.log(category: "playback", event: "sleep_timer_fired")
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func cancelSleepTimer() {
        // `sleepTimerEndDate` (not `sleepTimerTask`) is the accurate "is a
        // timer genuinely pending" check — the task reference itself stays
        // non-nil even after firing naturally, which would otherwise log a
        // misleading "cancelled" event for a timer that already fired.
        guard sleepTimerEndDate != nil else { return }
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
        TVRemoteLogger.log(category: "playback", event: "sleep_timer_cancelled")
    }

    func stop() {
        logPlayForCurrentTrackIfNeeded()
        crossfadeTask?.cancel()
        crossfadeTask = nil
        for p in [playerA, playerB] {
            p.pause()
            p.replaceCurrentItem(with: nil)
        }
        for (p, observer) in timeObservers { p.removeTimeObserver(observer) }
        timeObservers.removeAll()
        statusObservations.forEach { $0.invalidate() }
        statusObservations.removeAll()
        endObservers.forEach { NotificationCenter.default.removeObserver($0) }
        endObservers.removeAll()
        failureObservers.forEach { NotificationCenter.default.removeObserver($0) }
        failureObservers.removeAll()
        cancelSleepTimer()
        lyricsTask?.cancel()
        lyricsTask = nil
        teardownAudioSessionObservers()
        teardownRemoteCommands()
    }
}

// MARK: - TVPlayerView

private enum TVSidePanel: Equatable { case none, upNext, lyrics }

struct TVPlayerView: View {
    /// The queue to START when this screen appears — nil when Now Playing is
    /// opened from the mini-player bar rather than by picking a track.
    ///
    /// Previously required, which meant the full player was reachable ONLY as
    /// a NavigationLink destination from a list: once you navigated away there
    /// was no route back to what was playing. `TVPlayerModel.shared` already
    /// holds the live queue and current track, so with no context this screen
    /// simply renders that instead of starting anything.
    var context: TVPlayContext? = nil
    @ObservedObject var client: TVBridgeClient
    let token: String
    // `@StateObject` still (not `@ObservedObject`) even though the instance
    // now comes from `.shared` rather than being constructed here — SwiftUI
    // needs `@StateObject` semantics (never re-created across this view's
    // own re-renders) for its lifecycle management, and `init(_:)` taking
    // an already-live instance is exactly `@StateObject`'s documented way
    // to adopt an externally-owned object, same as `TVContentView`'s own
    // `@StateObject private var client = TVBridgeClient.shared`.
    @StateObject private var model = TVPlayerModel.shared
    @State private var sidePanel: TVSidePanel = .none
    // tvOS never automatically moves focus into a view that appears over
    // already-focused content — `upNextPanel` is drawn in the same ZStack
    // as the transport controls, not a real `.sheet`, so without this the
    // panel shows up but the Siri Remote's focus silently stays on
    // whatever utility button opened it. Forced onto the panel's close
    // button in `.onChange(of: sidePanel)` below the instant it opens.
    // (TVLyricsPanel does the same thing internally for itself.)
    @FocusState private var upNextCloseFocused: Bool
    @State private var showSleepTimerSheet = false
    @State private var showArtworkStyleSheet = false
    @AppStorage("tv.nowPlaying.artworkStyle") private var artworkStyleRaw = TVArtworkStyle.classic.rawValue
    /// Drives the ambient glow's "breathing" pulse behind the artwork —
    /// toggled once on appear rather than animating a constant, since a
    /// `repeatForever` animation needs an actual value change to attach to.
    @State private var breathe = false
    /// Drives default focus onto play/pause when this screen appears.
    @FocusState private var playPauseFocused: Bool

    private var artworkStyle: TVArtworkStyle { TVArtworkStyle(rawValue: artworkStyleRaw) ?? .classic }

    private var displayed: TVPlayable? {
        model.current ?? context.flatMap { ctx in ctx.queue.first(where: { $0.id == ctx.startID }) }
    }

    var body: some View {
        ZStack {
            backdrop

            // Two bands rather than one glass slab: the stage (cover, title,
            // lyrics) fills the screen, and every control lives in one dock
            // along the bottom. The slab put the controls in three different
            // places — utilities in the text column, the style picker under
            // the cover, transport in a capsule below — so finding a control
            // meant remembering which of the three it lived in.
            VStack(spacing: 34) {
                stage
                    .frame(maxHeight: .infinity)
                dock
                    .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.top, 60)
            .padding(.bottom, 50)

            if sidePanel == .upNext {
                upNextPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if sidePanel == .lyrics {
                TVLyricsPanel(
                    lines: model.lyrics,
                    currentPosition: model.position,
                    isPlaying: model.isPlaying,
                    isLoading: model.isLoadingLyrics,
                    onClose: { withAnimation(.easeInOut(duration: 0.25)) { sidePanel = .none } }
                )
                .transition(.opacity)
            }
        }
        .onDisappear { model.isShowingFullPlayer = false }
        .onAppear {
            // No context = opened from the now-playing column; whatever is
            // already playing stays playing.
            if let context { model.start(context: context) }
            model.isShowingFullPlayer = true
            breathe = true
            // tvOS doesn't move focus into a newly pushed screen on its own, so
            // without this the remote's first press lands on whatever the focus
            // engine happens to pick — usually a utility button rather than
            // play/pause.
            playPauseFocused = true
        }
        .onChange(of: sidePanel) { newValue in
            // Forces focus into the panel the instant it opens — see
            // `upNextCloseFocused`'s doc comment. TVLyricsPanel does the
            // same thing for itself internally.
            guard newValue == .upNext else { return }
            upNextCloseFocused = true
        }
        // No `.onDisappear { model.stop() }` — `model` is the app-wide
        // `TVPlayerModel.shared`, so navigating away from Now Playing leaves
        // playback running.
    }

    // MARK: Stage

    /// Cover on the left, the track and its lyrics on the right. Nothing here
    /// is focusable: it is what you look at, and the dock is what you use.
    private var stage: some View {
        HStack(alignment: .center, spacing: 80) {
            artwork

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    TVPlayingMeter(isAnimating: model.isPlaying && !model.isBuffering)
                    Text(statusLine)
                        .font(TVType.eyebrow)
                        .tracking(2.6)
                        .foregroundStyle(TVPalette.neonAlt)
                }
                .padding(.bottom, 18)

                Text(displayed?.title ?? "")
                    .font(.system(size: 66, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .id(displayed?.id)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                Text((displayed?.artist.isEmpty ?? true) ? "Unknown Artist" : (displayed?.artist ?? ""))
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .foregroundStyle(TVPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 6)
                    .id(displayed?.id)
                    .transition(.opacity)

                // Lyrics follow the song on the stage itself. They are the one
                // thing on this screen that changes second to second; the
                // overlay panel stays for reading a whole song.
                inlineLyrics
                    .padding(.top, 40)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.4), value: displayed?.id)
        }
    }

    private var statusLine: String {
        let state = model.isBuffering ? "LOADING" : (model.isPlaying ? "NOW PLAYING" : "PAUSED")
        guard model.queue.count > 1 else { return state }
        return "\(state) · \(model.currentIndex + 1) OF \(model.queue.count)"
    }

    /// Four lines around the current one, the active line large and white, the
    /// rest fading with distance. Non-focusable on purpose: it is a readout.
    @ViewBuilder
    private var inlineLyrics: some View {
        let idx = currentLyricIndex
        VStack(alignment: .leading, spacing: 16) {
            if model.isLoadingLyrics {
                HStack(spacing: 16) {
                    TVLoadingBars(height: 26)
                    Text("Looking for lyrics…")
                        .font(TVType.rowDetail)
                        .foregroundStyle(TVPalette.textTertiary)
                }
            } else if model.lyrics.isEmpty {
                Label("No synced lyrics for this track", systemImage: "text.badge.xmark")
                    .font(TVType.rowDetail)
                    .foregroundStyle(TVPalette.textTertiary)
            } else {
                ForEach(visibleLyricRange(around: idx), id: \.self) { i in
                    Text(model.lyrics[i].text.isEmpty ? "♪" : model.lyrics[i].text)
                        .font(.system(size: i == idx ? 36 : 28,
                                      weight: i == idx ? .bold : .semibold,
                                      design: .rounded))
                        .foregroundStyle(i == idx ? Color.white
                                         : Color.white.opacity(i < idx ? 0.22 : 0.4))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // A FIXED height, clipped: the window is a `ForEach` over changing
        // indices, so lines animate in and out, and with nothing clipping the
        // container they were drawn outside it mid-transition. Fixed so the
        // title above doesn't move as wrapped lines come and go.
        .frame(height: 250, alignment: .top)
        .clipped()
        .animation(.easeOut(duration: 0.3), value: idx)
    }

    /// Index of the last lyric line whose timestamp has passed, or -1 before the
    /// first. Linear scan: a few hundred lines at most, once per render.
    private var currentLyricIndex: Int {
        var result = -1
        for (i, line) in model.lyrics.enumerated() {
            if line.time <= model.position { result = i } else { break }
        }
        return result
    }

    private func visibleLyricRange(around index: Int) -> [Int] {
        let count = model.lyrics.count
        guard count > 0 else { return [] }
        let window = min(4, count)
        let centre = max(0, index)
        let start = max(0, min(centre - 1, count - window))
        return Array(start..<(start + window))
    }

    // MARK: Dock

    /// Progress across the full width, then one row: personal toggles on the
    /// left, transport dead centre, views and timers on the right.
    private var dock: some View {
        VStack(spacing: 26) {
            progressBar

            ZStack {
                transport

                HStack(spacing: 22) {
                    if let songID = displayed?.favoriteSongID {
                        favoriteButton(songID: songID)
                    }
                    toggleIconButton("shuffle", isOn: model.isShuffled) { model.toggleShuffle() }
                    toggleIconButton(model.repeatMode.symbol, isOn: model.repeatMode != .off) {
                        model.cycleRepeatMode()
                    }
                    toggleIconButton("arrow.triangle.merge", isOn: model.crossfadeEnabled) {
                        model.crossfadeEnabled.toggle()
                        TVRemoteLogger.log(category: "playback", event: "crossfade_toggled",
                                            detail: ["enabled": model.crossfadeEnabled])
                    }

                    Spacer(minLength: 40)

                    sleepTimerMenu
                    toggleIconButton("quote.bubble", isOn: sidePanel == .lyrics) { togglePanel(.lyrics) }
                    artworkStyleMenu
                    if model.queue.count > 1 {
                        toggleIconButton("list.bullet", isOn: sidePanel == .upNext) { togglePanel(.upNext) }
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 26)
        .tvGlassPanel(cornerRadius: 40)
    }

    private var transport: some View {
        HStack(spacing: 26) {
            // Seeking, as explicit jump buttons rather than a scrubbable bar.
            // A scrub bar on tvOS has to claim left/right while focused, and a
            // view that consumes directional input is a view focus can get
            // stuck inside — the failure mode that made an earlier build
            // unusable.
            controlButton("gobackward.15") { model.seek(to: model.position - 15) }
            controlButton("backward.fill") { model.previous() }
            controlButton(model.isPlaying ? "pause.fill" : "play.fill", big: true) {
                model.togglePlayPause()
            }
            .focused($playPauseFocused)
            controlButton("forward.fill") { model.next() }
            controlButton("goforward.15") { model.seek(to: model.position + 15) }
        }
    }

    private func togglePanel(_ panel: TVSidePanel) {
        withAnimation(.easeInOut(duration: 0.25)) {
            sidePanel = sidePanel == panel ? .none : panel
        }
    }

    private func toggleIconButton(_ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TVIconButtonLabel(systemImage: symbol, isOn: isOn)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func favoriteButton(songID: String) -> some View {
        Button {
            Task {
                guard let track = client.library.first(where: { $0.id == songID }) else { return }
                await client.toggleFavorite(track: track, token: token)
            }
        } label: {
            TVIconButtonLabel(systemImage: client.isFavorite(songID) ? "star.fill" : "star",
                              isOn: client.isFavorite(songID),
                              tint: Color(red: 1.0, green: 0.80, blue: 0.32))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var sleepTimerMenu: some View {
        Button {
            showSleepTimerSheet = true
        } label: {
            TVIconButtonLabel(systemImage: model.sleepTimerEndDate != nil ? "moon.fill" : "moon",
                              isOn: model.sleepTimerEndDate != nil)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .sheet(isPresented: $showSleepTimerSheet) {
            TVSleepTimerSheet(hasActiveTimer: model.sleepTimerEndDate != nil) { minutes in
                if let minutes {
                    model.setSleepTimer(minutes: minutes)
                } else {
                    model.cancelSleepTimer()
                }
            }
        }
    }

    private var artworkStyleMenu: some View {
        Button {
            showArtworkStyleSheet = true
        } label: {
            TVIconButtonLabel(systemImage: "paintpalette", isOn: artworkStyle != .classic)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .sheet(isPresented: $showArtworkStyleSheet) {
            TVArtworkStyleSheet(current: artworkStyle) { style in
                artworkStyleRaw = style.rawValue
                TVRemoteLogger.log(category: "playback", event: "artwork_style_changed",
                                    detail: ["style": style.rawValue])
            }
        }
    }

    // MARK: Up Next panel
    //
    // Slides over the stage rather than using `.sheet` — tvOS's focus engine
    // handles an in-place overlay more predictably than a modal here.
    //
    // One focusable element per row (removing a track lives in the row's
    // long-press menu): a queue is something you move THROUGH far more often
    // than you edit, so the common action gets the press.
    private var upNextPanel: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UP NEXT")
                            .font(TVType.eyebrow)
                            .tracking(2.4)
                            .foregroundStyle(TVPalette.neonAlt)
                        Text("\(max(0, model.queue.count - model.currentIndex - 1)) songs after this")
                            .font(TVType.section)
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { sidePanel = .none }
                    } label: {
                        TVIconButtonLabel(systemImage: "xmark")
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .focused($upNextCloseFocused)
                }
                .padding(.horizontal, 40)
                .padding(.top, 56)
                .padding(.bottom, 26)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TVMetrics.row) {
                        ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                            Button {
                                model.jump(to: index)
                            } label: {
                                TVUpNextRow(
                                    item: item,
                                    position: index + 1,
                                    isCurrent: index == model.currentIndex,
                                    isPlayed: index < model.currentIndex,
                                    isPlaying: model.isPlaying
                                )
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .contextMenu {
                                if index != model.currentIndex {
                                    Button(role: .destructive) {
                                        model.removeFromQueue(at: index)
                                    } label: {
                                        Label("Remove from Queue", systemImage: "minus.circle")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .padding(.bottom, 40)
                }
            }
            .frame(width: 700, alignment: .top)
            .frame(maxHeight: .infinity)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(TVPalette.ground.opacity(0.7))
                }
                .overlay(alignment: .leading) {
                    TVPalette.brandVertical.frame(width: 2)
                }
                .shadow(color: .black.opacity(0.6), radius: 40, x: -10)
            }
        }
        .ignoresSafeArea()
        .focusSection()
    }

    /// The playing artwork, much less dimmed than the shell's backdrop — here
    /// the artwork IS the subject — over the same Prism floor, so pushing into
    /// the player is a continuation of the shell rather than a jump.
    @ViewBuilder private var backdrop: some View {
        ZStack {
            TVAmbientBackground()
            TVAuthImage(url: displayed?.artworkURL, token: displayed?.authToken) { Color.clear }
                .scaleEffect(1.5)
                .blur(radius: 90)
                .saturation(1.5)
                .overlay(TVPalette.ground.opacity(0.5))
            LinearGradient(colors: [TVPalette.ground.opacity(0.2), TVPalette.ground.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    /// Soft, slowly "breathing" halo behind the artwork, using the artwork
    /// itself — light cast off the cover rather than a generic glow. Dims and
    /// stops on pause, a quiet second readout of play state.
    @ViewBuilder private var artworkGlow: some View {
        TVAuthImage(url: displayed?.artworkURL, token: displayed?.authToken) { Color.clear }
            .blur(radius: 80)
            .saturation(1.6)
            .opacity(model.isPlaying ? 0.9 : 0.3)
            .scaleEffect(breathe ? 1.1 : 0.94)
            .animation(
                .easeInOut(duration: 3.2).repeatForever(autoreverses: true),
                value: breathe
            )
            .animation(.easeInOut(duration: 0.6), value: model.isPlaying)
    }

    @ViewBuilder private var artwork: some View {
        ZStack {
            artworkGlow
                .frame(width: 500, height: 500)

            switch artworkStyle {
            case .classic:
                classicArtwork
            case .circuitPulse:
                TVCircuitPulseArtworkView(artworkURL: displayed?.artworkURL, authToken: displayed?.authToken, isPlaying: model.isPlaying)
            case .radarSweep:
                TVRadarSweepArtworkView(artworkURL: displayed?.artworkURL, authToken: displayed?.authToken, isPlaying: model.isPlaying)
            case .chalkboardSketch:
                TVChalkboardSketchArtworkView(artworkURL: displayed?.artworkURL, authToken: displayed?.authToken, isPlaying: model.isPlaying)
            case .shadowPuppetSilhouette:
                TVShadowPuppetSilhouetteArtworkView(artworkURL: displayed?.artworkURL, authToken: displayed?.authToken, isPlaying: model.isPlaying)
            }

            if model.isBuffering {
                ZStack {
                    Color.black.opacity(0.45)
                    VStack(spacing: 18) {
                        TVLoadingBars(height: 60)
                        Text("Loading…").font(.system(size: 22, weight: .semibold, design: .rounded))
                    }
                }
                .frame(width: 500, height: 500)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            }
        }
        .frame(width: 500, height: 500)
    }

    private var classicArtwork: some View {
        TVAuthImage(url: displayed?.artworkURL, token: displayed?.authToken) {
            TVArtPlaceholder(systemImage: "music.note", iconScale: 2.2)
        }
        .frame(width: 500, height: 500)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        // Shrinks slightly on pause, the way Apple's own players do — a third,
        // ambient readout of play state you can see from across the room.
        .scaleEffect(model.isPlaying ? 1 : 0.92)
        .shadow(color: .black.opacity(0.55), radius: 40, y: 24)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: model.isPlaying)
    }

    private var progressBar: some View {
        HStack(spacing: 24) {
            Text(timeString(model.position))
                .frame(width: 90, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule()
                        .fill(TVPalette.brandHorizontal)
                        .frame(width: max(0, geo.size.width * fraction))
                        .shadow(color: TVPalette.violet.opacity(0.7), radius: 10)
                    // Playhead — pulses gently while playing so the bar doesn't
                    // read as a static, dead-looking track marker.
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: TVPalette.violet.opacity(model.isPlaying ? 0.9 : 0), radius: 10)
                        .scaleEffect(breathe && model.isPlaying ? 1.15 : 1.0)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathe)
                        .offset(x: geo.size.width * fraction - 9)
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            Text(model.duration > 0 ? "-" + timeString(max(0, model.duration - model.position)) : "")
                .frame(width: 90, alignment: .leading)
        }
        .font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(TVPalette.textSecondary)
    }

    private var fraction: Double {
        model.duration > 0 ? min(1, max(0, model.position / model.duration)) : 0
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    private func controlButton(_ symbol: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TVTransportButtonLabel(symbol: symbol, big: big)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// Focus-reactive label for the main transport. Play/pause is the brand
/// gradient at rest — the one primary action on the screen — and every button
/// inverts to white when focused, the strongest tvOS focus signal.
private struct TVTransportButtonLabel: View {
    let symbol: String
    let big: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let size: CGFloat = big ? 112 : 80
        Image(systemName: symbol)
            .font(.system(size: big ? 42 : 28, weight: .bold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background {
                if isFocused {
                    Circle().fill(Color.white)
                } else if big {
                    Circle().fill(TVPalette.brand)
                } else {
                    Circle().fill(Color.white.opacity(0.06))
                }
            }
            .shadow(color: isFocused ? .white.opacity(0.35)
                        : (big ? TVPalette.violet.opacity(0.55) : .clear),
                    radius: isFocused ? 24 : 18, y: 8)
            .scaleEffect(isFocused ? 1.14 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
    }
}

// MARK: - Sleep timer / artwork style pickers
//
// `Menu` needs tvOS 17 — this project's deployment target is tvOS 16 (see
// project.yml) — so these use the same `.sheet` + `List` picker pattern
// already proven elsewhere (TVAddToPlaylistSheet, TVPlaylistNameSheet)
// instead.

private struct TVSleepTimerSheet: View {
    let hasActiveTimer: Bool
    /// `nil` selection means "cancel the active timer".
    let onSelect: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if hasActiveTimer {
                    Button(role: .destructive) {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        Label("Cancel Sleep Timer", systemImage: "moon.slash")
                    }
                }
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") {
                        onSelect(minutes)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Sleep Timer")
        }
    }
}

private struct TVArtworkStyleSheet: View {
    let current: TVArtworkStyle
    let onSelect: (TVArtworkStyle) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(TVArtworkStyle.allCases) { style in
                    Button {
                        onSelect(style)
                        dismiss()
                    } label: {
                        HStack {
                            Text(style.displayName)
                            if style == current {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Artwork Style")
        }
    }
}
