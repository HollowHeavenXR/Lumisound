@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Position Tracking

    func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.timerTick()
            }
        }
        // Lets iOS batch this wake-up with others (battery).
        timer?.tolerance = 0.05
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func timerTick() {
        updatePositionFromPlayer()

        // Checked immediately after the position refresh, and before anything
        // that might change tracks, so the fade is judged against the freshest
        // reading of where the audio actually is.
        checkCrossfadeTrigger()

        // Keeps widgets and the Live Activity on the player's real timeline
        // (engine details are rechecked every 5 s, with the bridge push).
        WidgetDataService.shared.resync(isPlaying: isPlaying, position: position, duration: duration,
                                        detail: bridgePushTickCounter == 0 ? engineSummary : nil)

        bridgePushTickCounter += 1
        if bridgePushTickCounter >= 10 {
            bridgePushTickCounter = 0
            pushPlaybackStateToBridge()
        }

        // Belt-and-braces recovery: if we think we're playing but the engine has
        // silently stopped (and no interruption/route/config-change notification
        // fired to tell us), restart it here. Without this, `isPlaying` stays true
        // forever with no audio and no track advance — the "music randomly stops"
        // bug — until the user manually pauses/resumes.
        if isPlaying, !isUsingOpusPlayer, !isUsingRustEngine, !engine.isRunning {
            handleEngineConfigurationChange()
        }

        checkForPlaybackStall()
        checkForOpusPlayerStall()

        // AB Repeat enforcement
        if abRepeatEnabled,
           let start = abRepeatStart,
           let end = abRepeatEnd,
           position >= end {
            seek(to: start)
        }

        // Keep the lock screen / Apple Watch / CarPlay "Now Playing" elapsed time and
        // playback-rate in sync with actual position — without this, those surfaces
        // only refresh on play/pause/track-change events and can visibly drift from
        // (or briefly disagree with) the in-app scrubber.
        updateNowPlaying()
    }

    /// Catches the case where the engine is running, we believe we are playing,
    /// and yet no audio is being rendered.
    ///
    /// The existing recovery above only notices a STOPPED engine. It cannot see the
    /// worse version: an engine that is running perfectly with nothing scheduled on
    /// its player node, which renders silence indefinitely while `isPlaying` stays
    /// true. Two real paths lead there, and both were live:
    ///
    ///   * `AVAudioEngineConfigurationChange` (logged 252 times across 27 accounts)
    ///     restarts the engine and calls `play()` again, but never re-schedules the
    ///     track — and a configuration change can invalidate the graph, taking the
    ///     scheduled segment with it.
    ///   * The rebuild inside `startEngineIfNeeded` calls `engine.reset()`, which
    ///     detaches every node and clears what was scheduled on them. `play()` on a
    ///     node with nothing left to play is silent.
    ///
    /// Rather than guess which happened, this watches the only thing that actually
    /// settles it: `position` is derived from frames the engine has RENDERED, so if
    /// it is not moving then audio is not flowing, whatever the engine claims. The
    /// track is then re-scheduled from where it had got to, which is the one repair
    /// that works for both causes.
    func checkForPlaybackStall() {
        // Every condition here is a state where position legitimately does not
        // advance, and treating any of them as a stall would restart playback on
        // top of itself.
        guard isPlaying, !isUsingOpusPlayer, engine.isRunning,
              !isCrossfading, !isSchedulingAsync,
              currentSong != nil,
              duration > 0, position < duration - 1.0
        else {
            stalledTickCount = 0
            lastStallCheckPosition = position
            return
        }

        // A tick is 0.5s, so anything genuinely playing moves well beyond this.
        if position > lastStallCheckPosition + 0.05 {
            stalledTickCount = 0
            lastStallCheckPosition = position
            // Confirms a past recovery actually stuck — played cleanly for
            // several seconds past the spot it resumed from — rather than
            // just coasting through the handful of ticks it takes for the
            // SAME dead spot to stall out again. Only then forget it, so a
            // fresh, unrelated hiccup later in the same track still gets its
            // own full escalation budget below instead of inheriting a
            // count left over from an old, already-resolved one.
            if let recoveredAt = lastStallRecoveryPosition, position > recoveredAt + 3 {
                lastStallRecoveryPosition = nil
                consecutiveStallRecoveriesAtSamePosition = 0
            }
            return
        }

        stalledTickCount += 1
        // Six ticks — three seconds of believing we play while rendering nothing.
        // Deliberately not shorter: a brief hitch under load can stall the render
        // for a tick or two, and restarting playback over that would be worse than
        // the hitch.
        guard stalledTickCount >= 6 else { return }

        let resumeAt = position
        stalledTickCount = 0
        lastStallCheckPosition = resumeAt

        // Simply rescheduling from the exact frozen position (the only thing
        // this used to do) is the right fix for a transient engine/graph
        // hiccup, but does nothing for a genuinely dead spot in the file
        // itself (e.g. a corrupt run of bytes) — that reschedule hits the
        // identical bytes, stalls again a few seconds later at essentially
        // the same position, "recovers" again, and repeats forever: audibly
        // "this one track freezes and keeps looping every few seconds,"
        // reported as rare because it only happens for whatever specific
        // track has the bad spot. Escalate instead of repeating the same
        // fix once it's clearly not working.
        if let lastPosition = lastStallRecoveryPosition, abs(resumeAt - lastPosition) < 1.5 {
            consecutiveStallRecoveriesAtSamePosition += 1
        } else {
            consecutiveStallRecoveriesAtSamePosition = 1
        }
        lastStallRecoveryPosition = resumeAt

        if consecutiveStallRecoveriesAtSamePosition >= 5 {
            // Nudging past it didn't help either — stop chasing this track.
            appError("Playback stall at \(String(format: "%.1f", resumeAt))s recurred \(consecutiveStallRecoveriesAtSamePosition)x despite nudging — giving up on \"\(currentSong?.displayName ?? "?")\" and skipping", category: "audio")
            RemoteLogger.logError(category: "audio", event: "playback_stall_unrecoverable",
                                  message: "position frozen at \(Int(resumeAt))s, \(consecutiveStallRecoveriesAtSamePosition) recovery attempts",
                                  detail: ["position": Int(resumeAt), "duration": Int(duration)])
            lastStallRecoveryPosition = nil
            consecutiveStallRecoveriesAtSamePosition = 0
            ToastCenter.shared.show("Couldn't play past a bad spot in \"\(currentSong?.displayName ?? "this track")\" — skipping", category: .error, icon: "exclamationmark.triangle.fill")
            skipToNext()
            return
        }

        // First attempt: a cheap pause/play "kick" on the node that already
        // has this exact segment scheduled — no file reopen, no reschedule,
        // near-instant. This is deliberately the SAME two calls a user makes
        // by manually hitting pause then play, which telemetry shows is how
        // people were actually clearing this stall (`playback_stall_recovered`
        // fired ~4.8k times in 30 days — far too often for the heavier fix
        // below to be the right first move every single time). A node that's
        // merely stuck in a non-rendering "playing" state resumes cleanly off
        // a pause/play cycle alone; only a genuinely dead spot in the file
        // itself survives this and needs the real reschedule, which still
        // happens below once this kick fails to get `position` moving again.
        if consecutiveStallRecoveriesAtSamePosition == 1 {
            appWarn("Playback stalled — engine running but position frozen at \(String(format: "%.1f", resumeAt))s for 3s; kicking node \"\(currentSong?.displayName ?? "?")\"", category: "audio")
            RemoteLogger.logError(category: "audio", event: "playback_stall_recovered",
                                  message: "position frozen at \(Int(resumeAt))s",
                                  detail: ["position": Int(resumeAt), "duration": Int(duration), "attempt": consecutiveStallRecoveriesAtSamePosition, "kicked": true])
            activeNode.pause()
            activeNode.play()
            return
        }

        // The kick above didn't get it moving — three identical-position
        // recoveries in a row means even a real reschedule of the exact same
        // bytes keeps failing — jump a few seconds past the dead spot rather
        // than trying it a fourth time verbatim.
        let nudging = consecutiveStallRecoveriesAtSamePosition >= 3
        let target = nudging ? min(resumeAt + 5, max(0, duration - 0.5)) : resumeAt
        appWarn("Playback stalled — engine running but position frozen at \(String(format: "%.1f", resumeAt))s for 3s; \(nudging ? "nudging to \(String(format: "%.1f", target))s" : "rescheduling") \"\(currentSong?.displayName ?? "?")\" (attempt \(consecutiveStallRecoveriesAtSamePosition))", category: "audio")
        RemoteLogger.logError(category: "audio", event: "playback_stall_recovered",
                              message: "position frozen at \(Int(resumeAt))s",
                              detail: ["position": Int(resumeAt), "duration": Int(duration), "attempt": consecutiveStallRecoveriesAtSamePosition, "nudged": nudging])
        playCurrent(from: target)
    }

    /// Same stall watchdog as `checkForPlaybackStall()`, for the AVPlayer
    /// (opus/webm/ogg/ipod-library) fallback path — which that function
    /// explicitly excludes (`!isUsingOpusPlayer`) because it watches
    /// AVAudioEngine-specific state (`engine.isRunning`, `activeNode`) that
    /// doesn't apply here.
    ///
    /// Without this, an AVPlayer-backed stream that stalls — buffering
    /// indefinitely on a flaky connection, or just getting stuck internally,
    /// both real AVPlayer failure modes — had NO recovery at all: `isPlaying`
    /// stays true, nothing is audible, and nothing ever retries. Reported as
    /// "plays but nothing can be heard, and the phone runs warm" — AVPlayer's
    /// own buffering/retry machinery kept working (real, if moderate, CPU
    /// use: re-requesting segments, re-attempting to fill its buffer) while
    /// never actually getting unstuck, which is a very different shape from
    /// the AVAudioEngine stall this manager already recovers from (that one
    /// is a dead render graph doing nothing at all).
    ///
    /// Opus/webm/ogg is the common case for this app's YouTube-sourced
    /// library (anything AVAudioFile can't decode natively, or a corrupted/
    /// mismatched download `scheduleCurrent`'s own fallbacks route here) —
    /// this isn't a rare corner, it's the path most streamed tracks are one
    /// network hiccup away from landing on.
    func checkForOpusPlayerStall() {
        guard isPlaying, isUsingOpusPlayer, let player = opusPlayer,
              currentSong != nil,
              duration > 0, position < duration - 1.0
        else {
            opusStalledTickCount = 0
            lastOpusStallCheckPosition = position
            return
        }

        if position > lastOpusStallCheckPosition + 0.05 {
            opusStalledTickCount = 0
            lastOpusStallCheckPosition = position
            if let recoveredAt = lastOpusStallRecoveryPosition, position > recoveredAt + 3 {
                lastOpusStallRecoveryPosition = nil
                consecutiveOpusStallRecoveriesAtSamePosition = 0
            }
            return
        }

        opusStalledTickCount += 1
        guard opusStalledTickCount >= 6 else { return }

        let resumeAt = position
        opusStalledTickCount = 0
        lastOpusStallCheckPosition = resumeAt

        if let lastPosition = lastOpusStallRecoveryPosition, abs(resumeAt - lastPosition) < 1.5 {
            consecutiveOpusStallRecoveriesAtSamePosition += 1
        } else {
            consecutiveOpusStallRecoveriesAtSamePosition = 1
        }
        lastOpusStallRecoveryPosition = resumeAt

        if consecutiveOpusStallRecoveriesAtSamePosition >= 5 {
            appError("AVPlayer stall at \(String(format: "%.1f", resumeAt))s recurred \(consecutiveOpusStallRecoveriesAtSamePosition)x — giving up on \"\(currentSong?.displayName ?? "?")\" and skipping", category: "audio")
            RemoteLogger.logError(category: "audio", event: "opus_playback_stall_unrecoverable",
                                  message: "position frozen at \(Int(resumeAt))s, \(consecutiveOpusStallRecoveriesAtSamePosition) recovery attempts",
                                  detail: ["position": Int(resumeAt), "duration": Int(duration)])
            lastOpusStallRecoveryPosition = nil
            consecutiveOpusStallRecoveriesAtSamePosition = 0
            ToastCenter.shared.show("Couldn't play past a bad spot in \"\(currentSong?.displayName ?? "this track")\" — skipping", category: .error, icon: "exclamationmark.triangle.fill")
            skipToNext()
            return
        }

        // First attempt: a cheap pause/play kick, same reasoning as
        // checkForPlaybackStall's. Only escalate to a real re-seek (which
        // forces AVPlayer to drop and refill its buffer from scratch — a
        // real fix for a stuck buffer, unlike the kick above) once that's
        // confirmed not to be enough.
        if consecutiveOpusStallRecoveriesAtSamePosition == 1 {
            appWarn("AVPlayer stalled — reports playing but position frozen at \(String(format: "%.1f", resumeAt))s for 3s; kicking \"\(currentSong?.displayName ?? "?")\"", category: "audio")
            RemoteLogger.logError(category: "audio", event: "opus_playback_stall_recovered",
                                  message: "position frozen at \(Int(resumeAt))s",
                                  detail: ["position": Int(resumeAt), "duration": Int(duration), "attempt": consecutiveOpusStallRecoveriesAtSamePosition, "kicked": true])
            player.pause()
            player.play()
            return
        }

        let nudging = consecutiveOpusStallRecoveriesAtSamePosition >= 3
        let target = nudging ? min(resumeAt + 5, max(0, duration - 0.5)) : resumeAt
        appWarn("AVPlayer stalled — reports playing but position frozen at \(String(format: "%.1f", resumeAt))s for 3s; re-seeking \(nudging ? "(nudging) " : "")\"\(currentSong?.displayName ?? "?")\" (attempt \(consecutiveOpusStallRecoveriesAtSamePosition))", category: "audio")
        RemoteLogger.logError(category: "audio", event: "opus_playback_stall_recovered",
                              message: "position frozen at \(Int(resumeAt))s",
                              detail: ["position": Int(resumeAt), "duration": Int(duration), "attempt": consecutiveOpusStallRecoveriesAtSamePosition, "nudged": nudging])
        // A fresh seek forces AVPlayer to drop whatever it had buffered and
        // refill from the new position — unlike the kick above, this
        // actually recovers a genuinely stuck internal buffer, not just a
        // paused-looking timebase.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            self?.opusPlayer?.play()
        }
    }

    /// Starts the crossfade once playback actually reaches
    /// `crossfadeTriggerPosition`.
    ///
    /// This replaced a wall-clock `Timer` — see `crossfadeTriggerPosition` for
    /// what that timer did wrong (pausing, then resuming, skipped the song).
    /// Running on the existing 0.5s tick means the check is driven by rendered
    /// audio and cannot fire while paused, because `pause()` stops the tick.
    ///
    /// 0.5s of granularity is immaterial here: the fade it starts runs for
    /// seconds, and the trigger point is itself an estimate of where the music
    /// stops (see `transitionLead`).
    func checkCrossfadeTrigger() {
        guard let trigger = crossfadeTriggerPosition else { return }
        guard isPlaying, !isCrossfading, !isUsingOpusPlayer else { return }
        // Smart Crossfade reads the analyzer at the fade: warm it up shortly
        // before rather than for the whole track (idempotent while armed).
        if audioSettings.smartCrossfadeEnabled, position >= trigger - 20,
           !AudioVisualizerService.shared.isActive(for: .smartCrossfade) {
            AudioVisualizerService.shared.start(for: .smartCrossfade)
        }
        // A zero/unknown duration means the track isn't really loaded yet;
        // triggering against a position of 0 would fade out of a track that has
        // not started.
        guard duration > 0, position >= trigger else { return }
        // Cleared BEFORE beginning, so a fade that somehow takes longer than one
        // tick cannot be started twice. `beginCrossfade` re-arms it for whatever
        // track becomes current.
        crossfadeTriggerPosition = nil
        appLog("Crossfade trigger reached at \(String(format: "%.1f", position))s of \(String(format: "%.1f", duration))s — \(currentSong?.displayName ?? "?")", category: "audio")
        beginCrossfade()
    }

    /// Mirrors the current track/position to the bridge (`/user/playback-state`)
    /// so other surfaces — e.g. the local Discord Rich Presence daemon — can
    /// show what this account is currently playing. Fires on play/pause/track
    /// changes and roughly every 5s during playback; no-ops if not logged in.
    func pushPlaybackStateToBridge() {
        AccountService.shared?.pushPlaybackState(
            song: currentSong,
            position: position,
            duration: duration,
            isPlaying: isPlaying,
            bpm: currentSong.flatMap { $0.bpm ?? bpmCache[$0.id] },
            engine: engineSummary
        )
        pushPodcastProgressIfNeeded()

        // Sync My Devices (see DeviceSyncService) — piggybacks on this
        // already-running ~5s tick rather than running its own timer.
        // Exactly one of these two calls does anything on a given device:
        // hostTick() no-ops unless this device started hosting, and
        // checkForActiveSyncAndJoin() no-ops while hosting.
        DeviceSyncService.shared?.hostTick(song: currentSong, isPlaying: isPlaying, position: position)
        DeviceSyncService.shared?.checkForActiveSyncAndJoin()
    }

    /// Podcast episodes (see PodcastEpisodesView) are constructed as a plain
    /// `Song` with `genre = "Podcast"` and `album` repurposed to carry the
    /// episode's feed URL — `Song` has no dedicated podcast fields, and
    /// adding one would touch every `Song` call site/decoder for a value
    /// only this one flow needs. `id` is the episode's stable RSS guid.
    /// Same 5s-during-playback cadence as the music playback-state push
    /// above, piggybacking on the same timer tick rather than a second one.
    private func pushPodcastProgressIfNeeded() {
        guard let song = currentSong, song.genre == "Podcast", !song.album.isEmpty else { return }
        let completed = duration > 0 && position >= duration - 5
        Task {
            await AccountService.shared?.updatePodcastEpisodeProgress(
                feedURL: song.album,
                episodeGuid: song.id,
                title: song.title,
                position: position,
                duration: duration,
                completed: completed
            )
        }
    }

    /// Logs the current track to `/user/history` (`AccountService.logPlay`)
    /// ~5s after it starts playing — long enough to filter out rapid skips,
    /// but soon enough that a linked Discord "Now Playing" webhook and any
    /// Last.fm/ListenBrainz scrobble reflect the track the user is actually
    /// listening to. Without this, play history was never recorded and those
    /// integrations silently never fired.
    func scheduleHistoryLog() {
        historyLogTask?.cancel()
        guard let song = currentSong else { return }
        historyLogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.currentSong?.id == song.id else { return }
            // Local play-history for the on-device Smart Playlists/Stats
            // features — same "still on this track 5s later" threshold as
            // the server-bound log below, so an instant skip doesn't count.
            PlayHistoryStore.shared.recordPlay(songID: song.id)
            await AccountService.shared?.logPlay(
                song: song,
                listenSeconds: Int(self.position),
                bpm: song.bpm ?? self.bpmCache[song.id]
            )
        }
    }

    /// Mirrors the "up next" queue to the bridge (`/user/queue`), debounced so
    /// rapid changes (drag-reorder, batch removals) don't fire a request per
    /// edit. No-ops if not logged in.
    func pushQueueToBridge() {
        queuePushTask?.cancel()
        let snapshot = queue
        queuePushTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await AccountService.shared?.pushQueue(snapshot)
        }
    }

    /// Exact playback position right now (track seconds rendered), without
    /// publishing it: for Music Haptics, which reads it several times a second.
    func preciseRenderedPosition() -> TimeInterval {
        if isUsingRustEngine { return max(0, Self.rust.position()) }
        guard !isUsingOpusPlayer, !isSchedulingAsync,
              let nodeTime = activeNode.lastRenderTime,
              let playerTime = activeNode.playerTime(forNodeTime: nodeTime),
              let file = audioFile else { return position }
        let elapsed = Double(playerTime.sampleTime) - gaplessBaseFrame
        return max(0, Double(fileStartFrame) / file.processingFormat.sampleRate + elapsed / playerTime.sampleRate)
    }

    func updatePositionFromPlayer() {
        guard !isUsingOpusPlayer else { return }
        if isUsingRustEngine {
            updatePositionFromRustEngine()
            return
        }
        // Do not overwrite `position` while an async download is in progress.
        // The position was already set to the seek target in seek()/downloadAndSchedule();
        // letting the timer fire here would clobber it with a stale node time.
        guard !isSchedulingAsync else { return }

        let node = activeNode
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              let file = audioFile
        else { return }

        // Subtract `gaplessBaseFrame` so elapsed time is measured from the start
        // of the CURRENT segment, not the cumulative frame count of every
        // gapless segment played on this node since the last fresh schedule.
        let elapsedFrames = Double(playerTime.sampleTime) - gaplessBaseFrame
        let computed = Double(fileStartFrame) / file.processingFormat.sampleRate
            + elapsedFrames / playerTime.sampleRate
        position = min(duration, max(0, computed))
    }

    // MARK: - Engine summary

    /// How the current track is being played, e.g. "Rust engine · LMS OPUS ·
    /// 48 kHz" — shown on the widgets, the Live Activity and the Discord Rich
    /// Presence card.
    var engineSummary: String? {
        guard let song = currentSong else { return nil }
        var parts: [String] = []
        parts.append(isUsingRustEngine ? "Rust engine" : isUsingOpusPlayer ? "Compatibility player" : "System engine")
        if let tag = song.formatTag {
            parts.append(tag)
        } else if song.sourceTrackID?.hasPrefix("youtube:") == true {
            parts.append("Stream")
        }
        if song.sampleRate > 0 {
            let khz = Double(song.sampleRate) / 1000
            parts.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        }
        let speed = Double(audioSettings.speed)
        if speed.isFinite, abs(speed - 1) > 0.01 {
            parts.append(NowPlayingFormat.rate(speed))
        }
        return parts.joined(separator: " · ")
    }
}
