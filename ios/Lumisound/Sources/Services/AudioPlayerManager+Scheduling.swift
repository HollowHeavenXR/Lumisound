@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Private Helpers

    func prepareCurrent() {
        scheduleCurrent(from: position)
        updateNowPlaying()
    }

    func playCurrent(from startTime: TimeInterval) {
        // For the "what does the audio engine see" telemetry below — the
        // streamed/transcoded branches already log their own elapsed time
        // relative to when THEIR async work starts (see downloadAndSchedule's
        // `playbackStartedAt`); this covers the local-file synchronous path,
        // which previously had no success log of any kind.
        let scheduleStartedAt = Date()
        // Invalidate any pending completion callbacks BEFORE cancelCrossfade() or node.stop()
        // so that the stopped node's completion block never fires handleTrackEnded().
        scheduleGeneration &+= 1
        // Whatever the engine held before, this schedules the track afresh.
        engineReleasedWhileIdle = false
        crossfadeTriggerPosition = nil
        cancelCrossfade()
        // Clear before scheduling so failure can be detected below.
        errorMessage = nil

        // Best-effort: get the upcoming streamed track's audio onto disk while
        // this one plays, so its turn doesn't open with a multi-second download
        // stall (the audible "gap" streamed sources have that local files don't).
        prefetchUpcomingStreamIfNeeded()

        // For HTTP/HTTPS URLs the download is async — scheduleCurrent handles the full play
        // flow internally (including calling node.play() after the download completes).
        if let url = currentSong?.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            // Same "silence now, ramp back up once actually playing" treatment
            // as the local-file path below, and for the same reason — a
            // RESEEK of a track already playing (rewind/fast-forward/skip)
            // that reaches `downloadAndSchedule`'s already-cached-file fast
            // path does an immediate `node.stop()` + full-volume
            // `node.play()` on the new segment with no other gap, which is
            // audible as a click/stutter. Doesn't matter whether the stream
            // is cached (near-instant reschedule, where the click would
            // otherwise be audible) or genuinely downloading (silence is
            // already expected during the wait either way) — silencing up
            // front is harmless in both cases. See `pendingSeekRampTarget`'s
            // doc comment; consumed once `downloadAndSchedule`/
            // `transcodeAndSchedule` actually calls `node.play()`.
            let wasAlreadyPlaying = isPlaying
            let node = activeNode
            if wasAlreadyPlaying {
                pendingSeekRampTarget = node.volume
                node.volume = 0
            } else {
                pendingSeekRampTarget = nil
            }
            isPlaying = true  // optimistically set — confirmed once download finishes
            startTimer()
            updateNowPlaying()
            scheduleCurrent(from: startTime)  // kicks off async download path
            return
        }

        // Local file — synchronous path. `scheduleCurrent` below does a hard
        // `node.stop()` then schedules a brand-new segment at full volume —
        // the right behavior for a genuinely fresh track, but for a RESEEK
        // of the track already playing (rewind/fast-forward/scrub) that's an
        // audible click/"flicker" right as the new segment starts: the
        // previous sample and the new segment's first sample rarely land on
        // the same waveform position, so the discontinuity itself is the
        // artifact — same root cause `beginCrossfade` avoids for track
        // transitions by ramping `incoming.volume` up from 0 instead of
        // snapping straight to full. Silence the node up front and ramp
        // it back to its pre-seek volume once the new segment is actually
        // playing, below.
        let node = activeNode
        let wasAlreadyPlaying = isPlaying
        let resumeVolume = node.volume
        if wasAlreadyPlaying {
            node.volume = 0
        }
        scheduleCurrent(from: startTime)
        // scheduleCurrent sets errorMessage on failure; bail out here to avoid a zombie
        // state where isPlaying=true but no audio segment is scheduled on the node.
        guard errorMessage == nil else {
            node.volume = resumeVolume
            return
        }
        if isUsingRustEngine {
            node.volume = resumeVolume
            rustPlay()
            isPlaying = true
            startTimer()
            updateNowPlaying()
            return
        }
        startEngineIfNeeded()
        activeNode.play()
        isPlaying = true
        startTimer()
        updateNowPlaying()
        reapplyActiveEffect()
        startSmartCrossfadeAnalysisIfNeeded()
        appLog(
            "playCurrent: local file playing — \(currentSong?.displayName ?? "?") "
                + "(\(String(format: "%.0f", audioFile?.processingFormat.sampleRate ?? 0))Hz) "
                + "scheduled in \(String(format: "%.3f", Date().timeIntervalSince(scheduleStartedAt)))s",
            category: "audio"
        )
        if wasAlreadyPlaying {
            rampNodeVolumeAfterSeek(node, to: resumeVolume)
        }
    }

    /// Ramps `node.volume` from 0 back up to `target` over ~50ms — see the
    /// comment above this function's call site in `playCurrent`.
    private func rampNodeVolumeAfterSeek(_ node: AVAudioPlayerNode, to target: Float) {
        guard target > 0 else { return }
        seekFadeTimer?.invalidate()
        let steps = 6
        let interval = 0.05 / Double(steps)
        var step = 0
        seekFadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard self != nil else { t.invalidate(); return }
                step += 1
                node.volume = target * Float(step) / Float(steps)
                if step >= steps {
                    t.invalidate()
                    self?.seekFadeTimer = nil
                }
            }
        }
    }

    /// Smart Auto Crossfade reads the live analyzer's overallLevel the
    /// instant beginCrossfade() fires (see smartFadeDuration) to react to how
    /// the outgoing track's ending actually sounds — starting the tap here,
    /// for the track's whole run rather than only in beginCrossfade() itself,
    /// gives its smoothing time to settle instead of reading a
    /// freshly-(re)started, still-zeroed reading. Only called once playback
    /// is actually starting (not from prepareCurrent()'s restore-only path
    /// or a paused seek) — installing the analyzer tap while nothing is
    /// playing was spinning up engine activity on cold launch for no reason.
    func startSmartCrossfadeAnalysisIfNeeded() {
        if audioSettings.smartCrossfadeEnabled {
            AudioVisualizerService.shared.start(for: .smartCrossfade)
        }
    }

    /// Reads `url`'s embedded `REPLAYGAIN_TRACK_GAIN` tag (falling back to RMS
    /// analysis for files without one) and applies it as `replayGainLinearGain`.
    /// Runs off the main thread so the metadata/RMS read never blocks playback.
    /// Shared by every path that schedules a track directly — `scheduleCurrent`,
    /// `transcodeAndSchedule`, and `beginCrossfade` — so each one gets this
    /// track's real per-track gain instead of silently keeping whatever
    /// `resetReplayGainForNewTrack` left it at (neutral) for the rest of its
    /// playback. `beginCrossfade` schedules its incoming file directly rather
    /// than through `scheduleCurrent`, so before this was shared here, a
    /// crossfaded-in track never got this analysis at all — with ReplayGain
    /// on, a track that needed a positive dB boost played at neutral (quieter
    /// than it should) for its entire run, every time it arrived via a
    /// crossfade rather than a plain skip/seek. No-op if ReplayGain is off.
    func analyzeReplayGain(for url: URL) {
        guard audioSettings.replayGainEnabled else { return }
        // See LumisoundExclusiveExtensionService.playableURL's doc comment --
        // a downloaded track's on-disk `.lms` bytes are XOR-masked and
        // unreadable by AVURLAsset until unlocked; without this the
        // embedded-tag read AND the RMS fallback both silently no-op for
        // every locked track.
        let capturedURL = LumisoundExclusiveExtensionService.playableURL(for: url)
        let asset = AVURLAsset(url: capturedURL)
        Task.detached(priority: .utility) { [weak self] in
            let metadata = (try? await asset.load(.metadata)) ?? []
            var gainDB: Float? = nil
            for item in metadata {
                let id = item.identifier?.rawValue.lowercased() ?? ""
                if id.contains("replaygain_track_gain") || id.contains("replaygain") {
                    if let str = item.stringValue {
                        // Tag format: "+1.23 dB" or "-1.23 dB"
                        let numeric = str.components(
                            separatedBy: CharacterSet(
                                charactersIn: "-+0123456789."
                            ).inverted
                        ).joined()
                        gainDB = Float(numeric)
                    }
                }
            }
            // No embedded tag: compute RMS gain (returns 0 for unsupported formats).
            if gainDB == nil {
                let rms = await NormalizationService.shared.gain(for: capturedURL)
                if rms != 0 { gainDB = rms }
            }
            if let gain = gainDB {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // BUGFIX (reported: volume dips or jumps shortly after a
                    // track starts, then settles back to the regular/boosted
                    // level): this whole function runs off a detached Task
                    // (metadata load, or the RMS fallback's audio decode),
                    // with no bound on how long it takes. Skip ahead to a
                    // DIFFERENT track while this is still in flight — a
                    // perfectly normal thing to do while browsing a library
                    // — and there was nothing here checking that `url` is
                    // still the track actually playing. `resetReplayGainForNewTrack`
                    // had already set the NEW track's gain to neutral by the
                    // time this fired; without this guard, this stale result
                    // for the OLD track clobbered it, ramping the output to a
                    // gain computed for a song that isn't even playing
                    // anymore — then, once the new track's OWN (separately
                    // kicked-off) analysis eventually resolved, the sound
                    // ramped AGAIN to the actually-correct value. Two
                    // uncalled-for ramps per skip, in whichever direction the
                    // old track's tag happened to point.
                    guard self.currentSong?.url == url else { return }
                    let linear = pow(10.0, gain / 20.0)
                    self.replayGainLinearGain = linear
                    // Re-derive the output gain split (mixer attenuation +
                    // EQ globalGain boost) now that ReplayGain's contribution
                    // is known. Ramped, not snapped — this lands at an
                    // unpredictable delay after the track already started
                    // (this whole function runs off a detached Task), and
                    // crossfadeMixer/equalizer are shared downstream of both
                    // player nodes — an instant snap here was audible as a
                    // "flicker" on whatever's currently playing. See
                    // applyOutputGainRamped's doc comment.
                    self.applyOutputGainRamped()
                }
            }
        }
    }

    /// Resets ReplayGain to neutral at the start of a new track — before that track's own
    /// analysis (the `replayGainEnabled` block further down each scheduling path) computes
    /// its per-track gain — so the previous track's gain can't briefly bleed into this one.
    /// Called only once a file/stream has loaded successfully, so this also doubles as the
    /// reset point for the AVPlayer load-failure circuit breaker (see `handleLoadFailure`).
    /// - Parameter ramped: Pass `true` when the shared `crossfadeMixer`/
    ///   `equalizer` stage is currently driving audible output at the exact
    ///   moment this resets to neutral — crossfade (the outgoing track is
    ///   still fading out on that same shared stage) and gapless (audio
    ///   continues through the handoff with no stop/start gap) both qualify.
    ///   An instant snap there is audible as a flicker right at the
    ///   transition. Every other caller schedules from a stopped node with
    ///   nothing currently audible on the stage, where instant is correct
    ///   (and marginally cheaper) — that stays the default.
    func resetReplayGainForNewTrack(ramped: Bool = false) {
        recentLoadFailureTimestamps.removeAll()
        opusRetriedThisLoad = false
        opusTransientRetryCount = 0
        replayGainLinearGain = 1.0
        // A new track starting means any stall-recovery escalation in
        // progress (see `checkForPlaybackStall`) was about a DIFFERENT
        // track's dead spot — don't carry it over.
        lastStallRecoveryPosition = nil
        consecutiveStallRecoveriesAtSamePosition = 0
        // Every fresh (stop()+play()) schedule restarts the node's sample clock
        // at 0, so the gapless position baseline must reset too. The gapless
        // hand-off path also calls this, then immediately re-captures the
        // node's cumulative sample time (see `handleTrackEnded`).
        gaplessBaseFrame = 0
        // Re-apply the master volume/boost (and reset ReplayGain's contribution
        // to neutral) so a track change can't leave the previous track's
        // analysed ReplayGain — or a stale boost level — applied to the new one.
        if ramped {
            applyOutputGainRamped()
        } else {
            applyOutputGain()
        }
    }

    /// Core scheduler — loads the audio file, seeks to `startTime`, and arms the completion handler
    /// that drives crossfade / gapless / normal track-end logic.
    ///
    /// `fileStartFrame` is always set to the absolute frame corresponding to `startTime`.
    /// When `startTime == 0` this is explicitly 0, which keeps `updatePositionFromPlayer()`
    /// accurate from the very first rendered frame of a new track.
    ///
    /// For HTTP/HTTPS URLs this method returns early after launching an async Task;
    /// `downloadAndSchedule` completes the setup and starts the node once the file is cached.
    func scheduleCurrent(from startTime: TimeInterval) {
        guard let song = currentSong else { return }
        // A new schedule always stops the Rust engine's decks first; the local
        // file branch below re-loads into it when the track is eligible.
        tearDownRustEngine()
        guard let url = song.url else {
            // URL was cleared (e.g. stale ipod-library:// after app restore) — skip silently.
            // Do not set errorMessage; the user sees the track title with no playback.
            return
        }

        // HTTP URLs must be downloaded to a temp file before AVAudioFile can read them.
        // AVAudioFile only reads local filesystem paths, not HTTP streams.
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            Task {
                await downloadAndSchedule(url: url, startTime: startTime)
            }
            return
        }

        // `ipod-library://` URLs (a track downloaded via the Apple Music app
        // for offline playback, found by the media-library scan — see
        // Song.init(mediaItem:)) can be DRM-protected and are never a real
        // filesystem path either way: `AVAudioFile(forReading:)` below
        // cannot open them at all and — per field reports — an unsupported
        // URL scheme handed to the underlying ExtAudioFile call can surface
        // as an uncaught exception rather than the catchable Swift error the
        // `do/catch` around that call expects, terminating the process
        // instead of falling back. AVPlayer natively handles ipod-library://
        // playback, protected or not, via the system's own rights
        // management, so route there directly — same pattern as the
        // HTTP(S) and opus/webm/ogg branches below.
        if scheme == "ipod-library" {
            scheduleWithOpusPlayer(url: url, startTime: startTime)
            return
        }

        // Opus/WebM/OGG containers may not be natively supported by AVAudioFile.
        // Route through AudioEncoderService which tries native open first, then exports to M4A.
        // `effectiveExtension` (not raw `pathExtension`) so this still routes correctly
        // for a track already converted to the Lumisound-exclusive extension — its real
        // container format lives one level in, under the outer ".lms".
        // Opus/WebM decode natively in the Rust engine (pure-Rust Opus) — no
        // AVFoundation transcode first.
        if ["opus", "webm", "ogg"].contains(LumisoundExclusiveExtensionService.effectiveExtension(for: url)),
           !LumisoundExclusiveExtensionService.isConverted(url) || LumisoundExclusiveExtensionService.hasWarmPlayableCache(for: url),
           rustEligible(for: url) {
            tearDownOpusPlayer()
            let gen = scheduleGeneration &+ 1
            scheduleGeneration = gen
            if scheduleWithRustEngine(url: url, startTime: startTime) { return }
        }
        let fileExt = LumisoundExclusiveExtensionService.effectiveExtension(for: url)
        if ["opus", "webm", "ogg"].contains(fileExt) {
            Task { await transcodeAndSchedule(url: url, startTime: startTime) }
            return
        }

        // A locked (.lms) track whose playable cache isn't warm yet would
        // otherwise pay for the full unlock (read + XOR + write the WHOLE
        // file — hundreds of MB for a lossless track) synchronously inline
        // below, on whatever thread called scheduleCurrent — in practice
        // the main thread, confirmed in the field as a real freeze/crash
        // source. Warm it off-thread first and re-enter once ready; once
        // warm (the common case after the very first play, or once
        // gapless/crossfade's own next-track prewarm has already run) this
        // check is just a cheap stat and falls straight through to the
        // existing synchronous path unchanged.
        if LumisoundExclusiveExtensionService.isConverted(url),
           !LumisoundExclusiveExtensionService.hasWarmPlayableCache(for: url) {
            let gen = scheduleGeneration &+ 1
            scheduleGeneration = gen
            Task { [weak self] in
                await LumisoundExclusiveExtensionService.prewarmPlayableURL(for: url)
                guard let self, self.scheduleGeneration == gen else { return }
                self.scheduleCurrent(from: startTime)
            }
            return
        }

        // Local file — schedule directly (native format, no transcoding needed).
        tearDownOpusPlayer()
        if rustEligible(for: url) {
            let gen = scheduleGeneration &+ 1
            scheduleGeneration = gen
            if scheduleWithRustEngine(url: url, startTime: startTime) { return }
        }
        do {
            let node = activeNode
            // Increment generation before stopping so the old completion is invalidated.
            let gen = scheduleGeneration &+ 1
            scheduleGeneration = gen
            node.stop()
            // See LumisoundExclusiveExtensionService.playableURL's doc
            // comment — a `.lms`-marked URL handed to AVAudioFile directly
            // can fail outright even though the underlying bytes are fine.
            let file = try AVAudioFile(forReading: LumisoundExclusiveExtensionService.playableURL(for: url))
            audioFile = file
            duration = file.duration
            let sampleRate = file.processingFormat.sampleRate
            // A no-op for the overwhelming common case (every YouTube-sourced
            // track tops out at 48kHz) — only actually reconfigures anything
            // for a genuinely higher-rate local/Cloud Library file. Must
            // happen before playCurrent()'s startEngineIfNeeded() below.
            ensureSampleRate(matching: sampleRate)
            let startFrame = max(0, AVAudioFramePosition(startTime * sampleRate))
            // Skip Silent Intros (`SilenceTrimService`) nudges playback past any
            // detected leading dead air itself, via a `player.seek(to:)` right
            // after `currentSong` changes — see that type's doc comment for why
            // it lives outside this scheduling path instead of trimming
            // `startFrame` here directly (its detection is async/cached and
            // needs the track already scheduled and playing to seek against).
            let framesLeft = max(0, AVAudioFrameCount(file.length - startFrame))
            fileStartFrame = startFrame
            position = Double(startFrame) / sampleRate
            gaplessScheduled = false
            pendingNextIndex = nil
            resetReplayGainForNewTrack()

            node.scheduleSegment(file, startingFrame: startFrame, frameCount: framesLeft, at: nil) { [weak self] in
                Task { @MainActor in
                    guard let self, self.scheduleGeneration == gen else { return }
                    self.handleTrackEnded()
                }
            }

            // Warm the BPM cache for this track and the one queued after it so
            // `beginCrossfade` can read a tempo synchronously once it fires.
            prewarmBPM(for: currentSong)
            prewarmBPM(for: peekNextSong())
            prewarmPlayableCache(for: peekNextSong())
            prewarmTranscode(for: peekNextSong())

            // Schedule crossfade to begin crossfadeDuration seconds before the track ends,
            // so the incoming track fades in while the current track is still playing.
            if audioSettings.crossfadeActive && audioSettings.crossfadeDuration > 0 {
                // A POSITION in the track, not a countdown — see
                // `crossfadeTriggerPosition`. Expressed against the file's full
                // duration rather than the frames remaining from `startFrame`,
                // because `position` is likewise measured from the start of the
                // track; the two must share an origin or a mid-track start would
                // trigger at the wrong place.
                //
                // Measured from the end of the MUSIC, not the end of the file.
                //
                // Trailing dead air is common — 8 tracks in 25 across a real
                // cloud library carry over 1.5s of it, one had thirty-eight —
                // so a fade starting `crossfadeDuration` from the file's end was
                // often partly, sometimes entirely, the next track fading up
                // over nothing. See SmartCrossfade.
                let trigger = file.duration - transitionLead()
                crossfadeTriggerPosition = trigger > 0 ? trigger : nil
            } else {
                crossfadeTriggerPosition = nil
            }

            // Pre-schedule the next track for gapless playback 0.1 s after this segment
            // starts, giving the engine enough time to buffer it seamlessly.
            //
            // Gapless and crossfade are mutually-exclusive transition strategies:
            // crossfade starts the incoming track on the OTHER node a few seconds
            // early, while gapless queues it on THIS node to start the instant
            // this one ends. With both enabled, the crossfade fires AND the
            // gapless-queued segment also plays — two tracks at once (the
            // "current + next play together" bug). So only arm gapless when
            // crossfade is off.
            if audioSettings.gaplessEnabled && !audioSettings.crossfadeActive {
                Task { [weak self] in
                    guard let self else { return }
                    // For a streamed next track, `scheduleGaplessNext` only
                    // succeeds once `prefetchUpcomingStreamIfNeeded`'s
                    // background download has actually finished — which the
                    // very first 0.1s attempt usually beats. Keep retrying
                    // every second (instead of giving up after one try) so a
                    // slower prefetch still gets a chance to land gaplessly
                    // before this track ends; bounded by the track's own
                    // remaining length so it can't outlive the track.
                    let deadline = await MainActor.run { Date().addingTimeInterval(max(0, self.duration - 1)) }
                    var first = true
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: first ? 100_000_000 : 1_000_000_000)
                        first = false
                        let shouldStop = await MainActor.run { () -> Bool in
                            // scheduleGeneration only changes here on an explicit
                            // skip/seek/new-track schedule (a natural gapless
                            // handoff deliberately reuses it — see
                            // scheduleGaplessNext's doc comment) — so this bails
                            // cleanly if the user skipped/sought away instead of
                            // a stale loop from an earlier track misfiring later.
                            guard self.scheduleGeneration == gen,
                                  self.isPlaying,
                                  self.audioSettings.gaplessEnabled,
                                  !self.audioSettings.crossfadeActive,
                                  !self.gaplessScheduled
                            else { return true }
                            self.scheduleGaplessNext()
                            return self.gaplessScheduled
                        }
                        if shouldStop || Date() >= deadline { break }
                    }
                }
            }

            // ReplayGain: read embedded REPLAYGAIN_TRACK_GAIN tag; fall back to RMS analysis
            // for files without a tag. Runs off the main thread to avoid blocking playback.
            analyzeReplayGain(for: url)
        } catch {
            // AVAudioFile couldn't open this "native format" file — most often a
            // corrupted/truncated download (e.g. a track saved despite a failed
            // yt-dlp run) that AVAssetReader chokes on with a cryptic coreaudio
            // error. AVPlayer's codec pipeline is more tolerant and can often play
            // (or at least cleanly fail) these files, so fall back to it instead of
            // leaving playback stalled on a silent "errorMessage only" dead end.
            appWarn("AVAudioFile open failed for \"\(currentSong?.displayName ?? "?")\": \(error.localizedDescription) — falling back to AVPlayer", category: "audio")
            scheduleWithOpusPlayer(url: url, startTime: startTime)
        }
    }

    /// Converts an Opus/WebM/OGG file to a playable format via AudioEncoderService,
    /// then schedules the result for playback using the standard AVAudioFile pipeline.
    /// Called from `scheduleCurrent` when it detects an unsupported container extension.
    @MainActor
    func transcodeAndSchedule(url: URL, startTime: TimeInterval) async {
        isSchedulingAsync = true
        defer { isSchedulingAsync = false }
        errorMessage = nil

        // See downloadAndSchedule's identical guard for why — same race,
        // same fix: a seek/skip/track-change that lands while this track's
        // transcode is still in flight must not let this stale call go on
        // to touch activeNode/scheduleSegment once the transcode finishes.
        let entryGen = scheduleGeneration &+ 1
        scheduleGeneration = entryGen

        guard let transcodedURL = await AudioEncoderService.shared.transcodeForPlayback(url) else {
            // AVAssetReader/AVAssetExportSession cannot decode this container (e.g. Ogg/Opus).
            // Fall back to AVPlayer which has access to iOS's full codec pipeline.
            appLog("Transcoding unavailable for .\(url.pathExtension), falling back to AVPlayer — \"\(currentSong?.displayName ?? "?")\"", category: "audio")
            scheduleWithOpusPlayer(url: url, startTime: startTime)
            return
        }
        guard scheduleGeneration == entryGen else {
            appLog("transcodeAndSchedule: discarding stale transcode (superseded) for \"\(currentSong?.displayName ?? "?")\"", category: "audio")
            return
        }

        // The transcoded copy is a plain AAC file: play it on the Rust engine.
        if rustEligible(for: transcodedURL), scheduleWithRustEngine(url: transcodedURL, startTime: startTime) {
            if isPlaying {
                rustPlay()
                startTimer()
            }
            updateNowPlaying()
            return
        }

        do {
            let node = activeNode
            let gen  = scheduleGeneration &+ 1
            scheduleGeneration = gen
            node.stop()

            let file        = try AVAudioFile(forReading: transcodedURL)
            audioFile       = file
            duration        = file.duration
            let sampleRate  = file.processingFormat.sampleRate
            let startFrame  = max(0, AVAudioFramePosition(startTime * sampleRate))
            let framesLeft  = max(0, AVAudioFrameCount(file.length - startFrame))
            fileStartFrame  = startFrame
            position        = startTime
            gaplessScheduled = false
            pendingNextIndex = nil
            resetReplayGainForNewTrack()

            node.scheduleSegment(file, startingFrame: startFrame, frameCount: framesLeft, at: nil) { [weak self] in
                Task { @MainActor in
                    guard let self, self.scheduleGeneration == gen else { return }
                    self.handleTrackEnded()
                }
            }

            // Warm the BPM cache for this track and the one queued after it so
            // `beginCrossfade` can read a tempo synchronously once it fires.
            prewarmBPM(for: currentSong)
            prewarmBPM(for: peekNextSong())
            prewarmPlayableCache(for: peekNextSong())
            prewarmTranscode(for: peekNextSong())

            // Crossfade trigger — same logic as scheduleCurrent.
            if audioSettings.crossfadeActive && audioSettings.crossfadeDuration > 0 {
                // See scheduleCurrent — a position measured against the file's
                // full duration, from the end of the music rather than the end of
                // the file.
                let trigger = file.duration - transitionLead()
                crossfadeTriggerPosition = trigger > 0 ? trigger : nil
            } else {
                crossfadeTriggerPosition = nil
            }

            if isPlaying {
                startEngineIfNeeded()
                node.play()
                MusicHapticsService.shared.updatePlayback(
                    enabled: audioSettings.musicHapticsEnabled ?? false,
                    isPlaying: true,
                    engineAvailable: true
                )
                startTimer()
                reapplyActiveEffect()
                startSmartCrossfadeAnalysisIfNeeded()
            }
            updateNowPlaying()

            // ReplayGain from original file's metadata. See the matching
            // comment on the other ReplayGain block in this file -- `url`
            // here is the original (possibly `.lms`-locked) source, not the
            // transcoded playback file, so it needs the same unlock.
            analyzeReplayGain(for: url)

        } catch {
            errorMessage = "Playback error: \(error.localizedDescription)"
            isPlaying = false
            appError("Transcoded-file scheduling failed for \"\(currentSong?.displayName ?? "?")\": \(error.localizedDescription)", category: "audio")
            // errorMessage alone has no visible home outside StreamSearchView/
            // Settings → Audio — see handleLoadFailure's matching comment.
            // Neither skips nor retries here (unlike handleLoadFailure), so
            // without this a failure on this path stalls playback completely
            // with zero visible feedback from the Library/Playlists/Folders tabs.
            if let name = currentSong?.displayName {
                ToastCenter.shared.show("Couldn't play \"\(name)\"", category: .error, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Removes stream cache temp files older than 1 hour to prevent unbounded disk growth.
    func cleanOldStreamCache() {
        let tempDir = FileManager.default.temporaryDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)  // 1 hour
        for file in files where file.lastPathComponent.hasPrefix("stream_") {
            if let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
               created < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    @MainActor
    func downloadAndSchedule(url: URL, startTime: TimeInterval) async {
        let playbackStartedAt = Date()
        let playbackURL = url.absoluteString
        tearDownOpusPlayer()
        cleanOldStreamCache()
        isSchedulingAsync = true
        defer { isSchedulingAsync = false }

        errorMessage = nil

        // Captured BEFORE the download await below — every seek on a
        // streamed track starts a brand new downloadAndSchedule Task (see
        // scheduleCurrent's http branch), so rewinding/fast-forwarding a
        // still-buffering stream can leave an OLDER call of this same
        // function still in flight when a newer one (or a track change)
        // starts. Without checking this, the older call's download
        // eventually finishes and goes right on calling activeNode.stop()/
        // scheduleSegment for its now-stale startTime/track regardless of
        // what the newer seek/track-change already did to the node in the
        // meantime — a real crash matching this exact shape was seen in the
        // field (AVAudioPlayerNode.scheduleSegment throwing an uncaught
        // NSException from inside this function's async continuation).
        let entryGen = scheduleGeneration &+ 1
        scheduleGeneration = entryGen

        do {
            // Derive a stable cache filename from the URL string.
            let cacheKey: String = url.absoluteString.data(using: .utf8).map { bytes in
                var hash: UInt64 = 5381
                for byte in bytes { hash = hash &* 31 &+ UInt64(byte) }
                return String(hash, radix: 16)
            } ?? UUID().uuidString

            // Detect the actual audio container from the URL path before choosing an extension.
            // YouTube CDN URLs often include the itag/mime in the path or may serve webm/opus
            // even when we requested m4a. AVAudioFile reads magic bytes but uses the file
            // extension for format hints — a mismatch causes silent failure.
            // This app's own `/api/stream/proxy` URL (see StreamingService+
            // StreamURL.swift) carries the requested format as a QUERY
            // PARAM ("format=flac"/"opus"/"mp3"/...), not anywhere in the
            // path — so none of the path-suffix checks below ever matched
            // it, and every non-m4a stream through this app's own bridge
            // silently fell through to the "m4a" default regardless of the
            // user's actual preferred format. That mismatch (real bytes:
            // flac/opus/mp3; file written and opened as ".m4a") is exactly
            // what AVAudioFile's `kAudioFileUnsupportedFileTypeError`
            // ("typ?") failures in the field trace back to — this was the
            // "streaming doesn't work" report. Checked FIRST, before the
            // path-suffix heuristics below (which stay for any other
            // arbitrary/remote stream URL that isn't this app's own proxy).
            let urlPath = url.path.lowercased()
            let ext: String
            if let queryFormat = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "format" })?.value?.lowercased(),
                ["m4a", "opus", "mp3", "flac", "wav"].contains(queryFormat) {
                ext = queryFormat
            } else if urlPath.contains("audio/webm") || urlPath.hasSuffix(".webm") || urlPath.contains("mime=audio%2fwebm") {
                ext = "webm"
            } else if urlPath.hasSuffix(".opus") || urlPath.contains("mime=audio%2fogg") {
                ext = "opus"
            } else if urlPath.hasSuffix(".mp3") {
                ext = "mp3"
            } else if urlPath.hasSuffix(".flac") {
                ext = "flac"
            } else if urlPath.hasSuffix(".wav") {
                ext = "wav"
            } else {
                ext = "m4a"    // default; covers m4a, aac, mp4 audio
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("stream_\(cacheKey).\(ext)")

            if !FileManager.default.fileExists(atPath: tempURL.path) {
                // Build a request with a realistic browser UA so CDN servers don't reject it.
                var req = URLRequest(url: url)
                req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
                // This is a full-file fetch (the whole track downloads to a temp
                // cache file before AVAudioFile can read any of it — see this
                // function's header comment), same shape as the comparable
                // full-download paths elsewhere (StreamingService+DownloadToLibrary's
                // job result fetch and relay download use 120s/180s) — but this one
                // is the path EVERY direct-play/"streamed" track goes through, not
                // an occasional background download, so it's hit far more often.
                // 60s was tight enough to plausibly time out a larger track or a
                // slow/cellular connection well before the whole file arrived,
                // failing playback outright with no retry (unlike downloadToLibrary,
                // which retries transient failures 3x). Raised to match.
                req.timeoutInterval = 120
                // Apply any per-song headers (e.g. Authorization for user music / server tracks).
                if let headers = currentSong?.httpHeaders {
                    for (field, value) in headers { req.setValue(value, forHTTPHeaderField: field) }
                }
                let (downloaded, response) = try await Core.download(for: req)
                // See entryGen's doc comment above — a seek, skip, or track
                // change that happened while this download was in flight
                // already started its OWN downloadAndSchedule (or otherwise
                // moved the node on), so this one is stale and must not go
                // on to touch activeNode/scheduleSegment at all.
                guard scheduleGeneration == entryGen else {
                    try? FileManager.default.removeItem(at: downloaded)
                    appLog("downloadAndSchedule: discarding stale download (superseded) for \(playbackURL)", category: "audio")
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw StreamingError.httpError(status)
                }
                appLog("downloadAndSchedule: stream response \(http.statusCode) for \(playbackURL) in \(String(format: "%.2f", Date().timeIntervalSince(playbackStartedAt)))s", category: "audio")
                // Trust the response's Content-Type over what we ASKED for.
                //
                // This used to run only when `ext == "m4a"`, i.e. only when the
                // request hadn't already committed to a format — which meant the
                // one case that actually matters was skipped. The bridge
                // deliberately serves m4a for stream formats AVFoundation can't
                // demux (opus resolves to WebM), so a request for opus comes back
                // as AAC-in-MP4. With the old condition the bytes were still
                // written to a `.opus` file and AVAudioFile rejected them with
                // `kAudioFileInvalidFileError` ('dta?', 1685348671) — a valid
                // file, opened as the wrong type. Seen on every streamed track:
                // "AVAudioFile open failed ... avfaudio error 1685348671".
                //
                // Refining whenever the server disagrees is correct regardless
                // of what was requested: the server knows what it sent.
                if let ct = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") {
                    let refinedExt: String
                    if ct.contains("webm") { refinedExt = "webm" }
                    else if ct.contains("ogg") || ct.contains("opus") { refinedExt = "opus" }
                    else if ct.contains("mpeg") { refinedExt = "mp3" }
                    else if ct.contains("flac") { refinedExt = "flac" }
                    else if ct.contains("wav") { refinedExt = "wav" }
                    else if ct.contains("mp4") || ct.contains("m4a") || ct.contains("aac") { refinedExt = "m4a" }
                    else { refinedExt = ext }   // unrecognised — keep what we assumed
                    let refinedURL = tempURL.deletingPathExtension().appendingPathExtension(refinedExt)
                    try? FileManager.default.removeItem(at: refinedURL)
                    try FileManager.default.moveItem(at: downloaded, to: refinedURL)
                    // Re-enter with the corrected URL
                    let file2 = try AVAudioFile(forReading: refinedURL)
                    audioFile = file2
                    duration = file2.duration
                    let node = activeNode
                    let gen = scheduleGeneration &+ 1
                    scheduleGeneration = gen
                    node.stop()
                    let sr = file2.processingFormat.sampleRate
                    ensureSampleRate(matching: sr)
                    let sf = max(0, AVAudioFramePosition(startTime * sr))
                    let fl = max(0, AVAudioFrameCount(file2.length - sf))
                    fileStartFrame = sf; position = startTime; gaplessScheduled = false; pendingNextIndex = nil
                    resetReplayGainForNewTrack()
                    node.scheduleSegment(file2, startingFrame: sf, frameCount: fl, at: nil) { [weak self] in
                        Task { @MainActor in guard let self, self.scheduleGeneration == gen else { return }; self.handleTrackEnded() }
                    }
                    if isPlaying {
                        startEngineIfNeeded()
                        node.play()
                        if let target = pendingSeekRampTarget {
                            pendingSeekRampTarget = nil
                            rampNodeVolumeAfterSeek(node, to: target)
                        }
                        MusicHapticsService.shared.updatePlayback(
                            enabled: audioSettings.musicHapticsEnabled ?? false,
                            isPlaying: true,
                            engineAvailable: true
                        )
                        startTimer()
                        reapplyActiveEffect()
                        startSmartCrossfadeAnalysisIfNeeded()
                    }
                    updateNowPlaying()
                    appLog("downloadAndSchedule: playback scheduled after content-type correction in \(String(format: "%.2f", Date().timeIntervalSince(playbackStartedAt)))s", category: "audio")
                    return
                }
                try? FileManager.default.removeItem(at: tempURL)
                try FileManager.default.moveItem(at: downloaded, to: tempURL)
            }

            // Downloaded: the Rust engine plays the cached file like a local track.
            if rustEligible(for: tempURL), scheduleWithRustEngine(url: tempURL, startTime: startTime) {
                if isPlaying {
                    pendingSeekRampTarget = nil
                    activeNode.volume = audioSettings.volume
                    rustPlay()
                    startTimer()
                    startSmartCrossfadeAnalysisIfNeeded()
                }
                updateNowPlaying()
                appLog("downloadAndSchedule: Rust engine playback in \(String(format: "%.2f", Date().timeIntervalSince(playbackStartedAt)))s", category: "audio")
                return
            }

            // From here on this is identical to the local-file path in scheduleCurrent.
            let node = activeNode
            // Increment generation before stopping so the old completion is invalidated.
            let gen = scheduleGeneration &+ 1
            scheduleGeneration = gen
            node.stop()
            let file = try AVAudioFile(forReading: tempURL)
            audioFile = file
            duration = file.duration
            let sampleRate = file.processingFormat.sampleRate
            // The path a hi-res Personal Cloud Library FLAC actually takes —
            // Song.url for a cloud track is a remote /user/music/stream URL,
            // so it downloads through here like any other "streamed" track
            // rather than the local-file path in scheduleCurrent above.
            ensureSampleRate(matching: sampleRate)
            let startFrame = max(0, AVAudioFramePosition(startTime * sampleRate))
            let framesLeft = max(0, AVAudioFrameCount(file.length - startFrame))
            fileStartFrame = startFrame
            position = startTime
            gaplessScheduled = false
            pendingNextIndex = nil
            resetReplayGainForNewTrack()

            node.scheduleSegment(file, startingFrame: startFrame, frameCount: framesLeft, at: nil) { [weak self] in
                Task { @MainActor in
                    guard let self, self.scheduleGeneration == gen else { return }
                    self.handleTrackEnded()
                }
            }

            // Start playback — playCurrent already set isPlaying = true before the download.
            if isPlaying {
                startEngineIfNeeded()
                node.play()
                if let target = pendingSeekRampTarget {
                    pendingSeekRampTarget = nil
                    rampNodeVolumeAfterSeek(node, to: target)
                }
                MusicHapticsService.shared.updatePlayback(
                    enabled: audioSettings.musicHapticsEnabled ?? false,
                    isPlaying: true,
                    engineAvailable: true
                )
                startTimer()
                reapplyActiveEffect()
                startSmartCrossfadeAnalysisIfNeeded()
            }
            updateNowPlaying()
            appLog("downloadAndSchedule: playback scheduled in \(String(format: "%.2f", Date().timeIntervalSince(playbackStartedAt)))s", category: "audio")

        } catch {
            // AVAudioFile couldn't open the downloaded temp file — usually a
            // container it just doesn't support (raw Ogg/Opus, or a
            // format/extension mismatch the heuristics above didn't catch).
            // Previously this just gave up and showed an error, which is
            // most of what "streaming doesn't work" reports traced back to
            // — the very same class of failure the LOCAL-file path already
            // has a fallback for (`transcodeAndSchedule` -> AVPlayer via
            // `scheduleWithOpusPlayer`). AVPlayer has access to iOS's full
            // codec pipeline and can play directly from the ORIGINAL remote
            // URL without needing the temp-file download at all, so fall
            // back to it here too instead of only ever erroring out.
            appWarn("downloadAndSchedule: AVAudioFile open failed after \(String(format: "%.2f", Date().timeIntervalSince(playbackStartedAt)))s for \"\(currentSong?.displayName ?? "?")\" (\(error.localizedDescription)) — falling back to AVPlayer", category: "audio")
            // The fallback below plays through `opusPlayer` (AVPlayer), not
            // `activeNode` — if playCurrent silenced that node for a seek
            // ramp that's never going to happen now (see
            // `pendingSeekRampTarget`'s doc comment), restore it directly
            // rather than leaving it stuck at 0 for whatever this node next
            // gets reused for.
            if let target = pendingSeekRampTarget {
                pendingSeekRampTarget = nil
                activeNode.volume = target
            }
            scheduleWithOpusPlayer(url: url, startTime: startTime)
        }
    }

    /// Called by the AVAudioPlayerNode completion block when the current segment finishes.
    func handleTrackEnded() {
        guard isPlaying else { return }

        // If gapless already scheduled the next file on this node, advance the index and update UI.
        if gaplessScheduled {
            advanceIndex()
            gaplessScheduled = false
            pendingNextIndex = nil
            // Adopt the file that just began playing gaplessly so position,
            // duration, and the scrubber track the NEW track. Without this the
            // Now Playing UI/MiniPlayer keep showing the previous track's
            // duration and a frozen (clamped) progress bar — the "won't update
            // when crossfade is off" bug, since gapless is the default
            // crossfade-off transition path.
            if let nextFile = pendingGaplessFile {
                audioFile = nextFile
                duration = nextFile.duration
            }
            fileStartFrame = 0
            pendingGaplessFile = nil
            // Fresh track — reset ReplayGain to neutral, then kick off this
            // track's own analysis (see `analyzeReplayGain`). `scheduleGaplessNext`
            // appends its file straight onto the engine node rather than going
            // through `scheduleCurrent`, so without this call a gapless
            // auto-advance (the default crossfade-off transition) left every
            // track playing at neutral ReplayGain — audibly quieter than it
            // should be for the rest of its run, whenever ReplayGain is on and
            // the track needed a positive dB boost — for as long as the user
            // kept letting tracks play through rather than manually skipping.
            // This also zeroes `gaplessBaseFrame`, so capture the node's
            // CURRENT cumulative sample time as this segment's baseline
            // immediately afterward.
            // Ramped: audio is already playing continuously through this
            // handoff (that's what makes it "gapless") — an instant snap on
            // the shared crossfadeMixer/equalizer stage right at the
            // boundary is audible as a flicker exactly when the track
            // changes, same reasoning as beginCrossfade's identical call.
            resetReplayGainForNewTrack(ramped: true)
            if let url = currentSong?.url { analyzeReplayGain(for: url) }
            if let nodeTime = activeNode.lastRenderTime,
               let playerTime = activeNode.playerTime(forNodeTime: nodeTime) {
                gaplessBaseFrame = Double(playerTime.sampleTime)
            }
            position = 0
            reapplyActiveEffect()
            updateNowPlaying()
            // Schedule completion for the newly playing segment.
            scheduleGaplessNext()
            return
        }

        if audioSettings.crossfadeActive {
            // The crossfade trigger may have already started the crossfade;
            // don't trigger a second crossfade if we're already mid-fade.
            guard !isCrossfading else { return }
            beginCrossfade()
        } else {
            skipToNext()
        }
    }
}
