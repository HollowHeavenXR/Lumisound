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

    // MARK: Engine
    //
    // Playback runs on the Lumisound engine (TVLumisoundEngine: the Rust core,
    // the same engine as the iPhone app). Every track is a local file
    // (TVTrackFiles downloads it; locked tracks are decoded in place), the
    // engine does gapless hand-over and crossfades itself, and reports
    // track start / end / failure by deck id.
    private var engine: TVLumisoundEngine { TVLumisoundEngine.shared }
    private var core: AudioEngine { TVLumisoundEngine.shared.core }
    /// Deck id of the playing track.
    private var currentDeck: UInt64 = 0
    /// The queued / crossfading next track, once the engine has it.
    private var pendingNext: (deck: UInt64, index: Int, crossfade: Bool)?
    /// The next transition has been set up (or is being) for this track.
    private var transitionArmed = false
    /// Local file of the playing track.
    private var currentFile: URL?
    /// Bumped on every load, so a slow download can't start a track the
    /// listener already skipped.
    private var loadGeneration = 0
    private var ticker: Timer?
    /// Base overlap. With Auto Crossfade on, `TVAutoCrossfade` picks a length
    /// per transition from this starting point; with it off this is used as-is.
    private let crossfadeDuration: TimeInterval = TVAutoCrossfade.baseDuration
    /// Queue a gapless next track this long before the end.
    private let gaplessLead: TimeInterval = 20

    /// Queue order before shuffling — restored when shuffle is toggled off.
    private var originalQueue: [TVPlayable] = []
    private var sleepTimerTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    /// The track Aria is handing over FROM — see TVAria.requestTransition.
    private var previousTrack: TVPlayable?
    var audioSessionObservers: [NSObjectProtocol] = []

    var current: TVPlayable? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }

    /// The queue/start-point `start(context:)` most recently actually
    /// adopted — repeat calls with the SAME context (navigating back to Now
    /// Playing without picking a new track) resume in place.
    private var currentContext: TVPlayContext?

    func start(context: TVPlayContext) {
        guard currentContext != context else { return }
        currentContext = context
        cancelTransition()
        isShuffled = false
        queue = context.queue
        originalQueue = context.queue
        currentIndex = queue.firstIndex(where: { $0.id == context.startID }) ?? 0
        engine.relay.player = self
        engine.start()
        startTicker()
        setupAudioSessionObservers()
        configureRemoteCommands()
        loadCurrent()
    }

    /// Seeks within the current track, clamped to `[0, duration]`.
    func seek(to newPosition: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(newPosition, duration - 0.25))
        position = target
        // A seek reopens the track; anything queued after it is dropped.
        cancelTransition()
        if let id = try? core.seek(secs: target) { currentDeck = id }
    }

    func resumePlayback() {
        engine.restartIfNeeded()
        core.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pausePlayback() {
        core.pause(fadeSecs: 0.12)
        isPlaying = false
        updateNowPlayingInfo()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        // 0.2 s: drives the scrubber, the lyric highlight and the transition
        // trigger (at 0.5 s the lit lyric line lagged the audio noticeably).
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard currentDeck != 0 else { return }
        position = core.position()
        let d = core.duration()
        if d > 0 { duration = d }
        let playing = core.isPlaying()
        if playing != isPlaying { isPlaying = playing }
        if playing { engine.restartIfNeeded() }
        checkTransition()
        updateNowPlayingInfo()
    }

    private func loadCurrent() {
        guard let item = current else { return }
        cancelTransition()
        loadGeneration += 1
        let generation = loadGeneration
        position = 0
        duration = item.durationSeconds
        isBuffering = true
        loadLyrics(for: item)
        // Single chokepoint for every track transition (initial start, skip,
        // repeat-all wrap, Up Next jump).
        tvBreadcrumb("Playing: \(item.title)")
        TVRemoteLogger.log(category: "playback", event: "track_started",
                            detail: ["title": item.title, "artist": item.artist, "engine": "lumisound"])
        updateNowPlayingInfo()
        updateNowPlayingArtwork()
        // Aria's handover into this track. Fire-and-forget: never gates playback.
        if let token = TVAccount.shared.token {
            TVAria.shared.requestTransition(from: previousTrack, to: item, token: token)
        }
        previousTrack = item

        Task { [weak self] in
            guard let self else { return }
            guard let file = await TVTrackFiles.shared.file(for: item) else {
                guard self.loadGeneration == generation else { return }
                self.isBuffering = false
                tvError("Couldn't fetch \(item.title)", category: "playback")
                // Don't loop forever on a queue of unplayable tracks.
                if self.queue.count > 1 { self.next() }
                return
            }
            guard self.loadGeneration == generation, self.current?.id == item.id else { return }
            self.currentFile = file
            // Leading-silence trim (skips dead air before the music).
            var start: Double = 0
            if TVAudioSettings.shared.skipSilentIntros, !item.isLocked {
                start = await TVSilenceTrim.analyze(url: file, trackID: item.id)
                guard self.loadGeneration == generation else { return }
            }
            do {
                self.applyEngineSettings()
                self.currentDeck = try self.core.load(path: file.path, startSecs: start, gainDb: 0)
                self.core.play()
                self.isPlaying = true
                if start > 0 {
                    TVRemoteLogger.log(category: "audio", event: "silent_intro_skipped",
                                       detail: ["title": item.title, "seconds": round(start * 100) / 100])
                }
            } catch {
                tvError("Engine couldn't open \(item.title): \(error)", category: "playback")
                TVRemoteLogger.logError(category: "playback", event: "playback_failed", message: "\(error)")
                if self.queue.count > 1 { self.next() }
            }
            self.isBuffering = false
            // Get the next file in early so the hand-over never waits on the network.
            if let n = self.nextIndexForTransition(), self.queue.indices.contains(n) {
                await TVTrackFiles.shared.prefetch(self.queue[n])
            }
        }
    }

    /// Engine settings the TV exposes (see TVAudioSettings).
    func applyEngineSettings() {
        let s = TVAudioSettings.shared
        core.setEqWith(gainsDb: s.eqBands, enabled: s.eqEnabled, loudnessMatch: true)
        core.setEffects(reverbWet: s.reverbWet, reverbPreset: "mediumRoom", mono: false, nightMode: s.nightMode)
    }

    // MARK: Transitions (gapless / crossfade, done by the engine)

    /// The plan for the transition out of the current track.
    private func currentTransitionPlan(into nextItem: TVPlayable) -> TVAutoCrossfade.Plan {
        guard TVAudioSettings.shared.autoCrossfade else {
            return TVAutoCrossfade.Plan(duration: crossfadeDuration,
                                        startBefore: crossfadeDuration,
                                        reason: "auto-off")
        }
        // Only measured locally when the server has not profiled this track yet.
        let tail: Double? = (current?.transitionProfile == nil && current?.isLocked == false)
            ? currentFile.flatMap { TVTailLevel.measure(url: $0, duration: duration) }
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

    /// The track that plays after this one on its own (repeat-one: itself).
    private func nextIndexForTransition() -> Int? {
        guard !queue.isEmpty else { return nil }
        if repeatMode == .one { return currentIndex }
        if currentIndex + 1 < queue.count { return currentIndex + 1 }
        if repeatMode == .all { return 0 }
        return nil
    }

    private func checkTransition() {
        guard !transitionArmed, duration > 1, let nextIndex = nextIndexForTransition(),
              queue.indices.contains(nextIndex) else { return }
        let nextItem = queue[nextIndex]
        let remaining = duration - position
        let crossfade = crossfadeEnabled && queue.count > 1 && repeatMode != .one
        let plan = crossfade ? currentTransitionPlan(into: nextItem) : nil
        let lead = plan.map { $0.startBefore } ?? gaplessLead
        guard remaining <= lead, duration > lead else { return }
        transitionArmed = true
        let deck = currentDeck
        Task { [weak self] in
            guard let self else { return }
            guard let file = await TVTrackFiles.shared.file(for: nextItem),
                  self.currentDeck == deck, self.transitionArmed else { return }
            do {
                if let plan {
                    let id = try self.core.crossfadeTo(path: file.path, secs: plan.duration, startSecs: 0,
                                                       gainDb: 0, equalPower: true, tempoMatch: 0)
                    self.pendingNext = (id, nextIndex, true)
                    tvLog("Crossfade started into: \(nextItem.title)", category: "playback")
                    TVRemoteLogger.log(category: "playback", event: "crossfade_started",
                                       detail: ["into": nextItem.title, "seconds": round(plan.duration * 10) / 10,
                                                "startBefore": round(plan.startBefore * 10) / 10,
                                                "reason": plan.reason, "auto": TVAudioSettings.shared.autoCrossfade])
                } else {
                    let id = try self.core.queueNext(path: file.path, gainDb: 0)
                    self.pendingNext = (id, nextIndex, false)
                }
            } catch {
                tvWarn("Couldn't queue \(nextItem.title): \(error)", category: "playback")
            }
        }
    }

    /// Drops a queued / pending transition (skip, seek, queue edits).
    private func cancelTransition() {
        if pendingNext != nil, pendingNext?.crossfade == false { core.clearNext() }
        pendingNext = nil
        transitionArmed = false
    }

    // MARK: Engine events

    func engineTrackStarted(id: UInt64) {
        guard let next = pendingNext, next.deck == id, queue.indices.contains(next.index) else { return }
        logPlayForCurrentTrackIfNeeded()
        currentIndex = next.index
        currentDeck = id
        pendingNext = nil
        transitionArmed = false
        position = 0
        duration = queue[next.index].durationSeconds
        let item = queue[next.index]
        previousTrack = item
        loadLyrics(for: item)
        tvBreadcrumb("\(next.crossfade ? "Crossfaded" : "Gapless") to: \(item.title)")
        TVRemoteLogger.log(category: "playback", event: "track_started",
                            detail: ["title": item.title, "artist": item.artist, "via": next.crossfade ? "crossfade" : "gapless"])
        updateNowPlayingInfo()
        updateNowPlayingArtwork()
        if let n = nextIndexForTransition(), queue.indices.contains(n) {
            Task { await TVTrackFiles.shared.prefetch(queue[n]) }
        }
    }

    func engineTrackEnded(id: UInt64) {
        guard id == currentDeck else { return }
        isPlaying = false
        advanceOnEnd()
    }

    func engineTrackFailed(id: UInt64) {
        guard id == currentDeck || id == pendingNext?.deck else { return }
        tvError("Playback failed: \(current?.title ?? "?")", category: "playback")
        TVRemoteLogger.logError(category: "playback", event: "playback_failed", message: "engine decode failure")
        if id == pendingNext?.deck { pendingNext = nil; transitionArmed = false } else { next() }
    }

    // MARK: Play history

    /// Reports the currently-loaded track's play to the bridge — called
    /// right before advancing/stopping, while `current`/`position` still
    /// describe the track that's ending. Skips near-instant skips (<2s).
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

    /// Waits briefly for the real duration (used to reject a same-titled but
    /// wrong recording — see TVLyricsService) before fetching; re-checks the
    /// current track after every suspension point.
    private func loadLyrics(for item: TVPlayable) {
        lyricsTask?.cancel()
        lyrics = []
        isLoadingLyrics = true
        lyricsTask = Task { [weak self] in
            guard let self else { return }
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
        if core.isPlaying() { pausePlayback() } else { resumePlayback() }
    }

    /// Manual "skip forward" — always advances (or stops at the end of a
    /// non-repeating queue), regardless of repeat mode.
    func next() {
        cancelTransition()
        logPlayForCurrentTrackIfNeeded()
        guard currentIndex + 1 < queue.count else {
            if repeatMode == .all, !queue.isEmpty {
                currentIndex = 0
                loadCurrent()
            } else {
                pausePlayback()
            }
            return
        }
        currentIndex += 1
        loadCurrent()
    }

    /// Called when the current track finished and nothing was queued after it.
    private func advanceOnEnd() {
        if repeatMode == .one {
            logPlayForCurrentTrackIfNeeded()
            loadCurrent()
            return
        }
        next()
    }

    /// Jumps directly to a track elsewhere in the queue (Up Next panel).
    func jump(to index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        cancelTransition()
        logPlayForCurrentTrackIfNeeded()
        currentIndex = index
        loadCurrent()
    }

    func previous() {
        // More than 3 s in: back to the start of this track.
        if position > 3 || currentIndex == 0 {
            seek(to: 0)
            return
        }
        cancelTransition()
        logPlayForCurrentTrackIfNeeded()
        currentIndex -= 1
        loadCurrent()
    }

    /// Removes a queued-up track (not the playing one).
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        cancelTransition()
        let removedID = queue[index].id
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        originalQueue.removeAll { $0.id == removedID }
    }

    /// Shuffles everything, keeping the playing track where it is in time.
    func toggleShuffle() {
        cancelTransition()
        isShuffled.toggle()
        let currentID = current?.id
        queue = isShuffled ? originalQueue.shuffled() : originalQueue
        if let currentID {
            currentIndex = queue.firstIndex(where: { $0.id == currentID }) ?? 0
        }
        TVRemoteLogger.log(category: "playback", event: "shuffle_toggled", detail: ["enabled": isShuffled])
    }

    func cycleRepeatMode() {
        cancelTransition()
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
                if end.timeIntervalSinceNow <= 0 {
                    // A slow fade out rather than a hard stop.
                    self.core.pause(fadeSecs: 4)
                    self.isPlaying = false
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
        guard sleepTimerEndDate != nil else { return }
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
        TVRemoteLogger.log(category: "playback", event: "sleep_timer_cancelled")
    }

    func stop() {
        logPlayForCurrentTrackIfNeeded()
        cancelTransition()
        loadGeneration += 1
        core.stop()
        currentDeck = 0
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
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
