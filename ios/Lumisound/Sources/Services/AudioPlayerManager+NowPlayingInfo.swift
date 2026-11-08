@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Now Playing / Remote Commands

    /// Publishes the current track to the system Now Playing surfaces (lock
    /// screen, Control Center, Dynamic Island, CarPlay, Siri).
    ///
    /// Called from every state change AND from the 0.5s position tick, so it
    /// only writes when the system's picture would otherwise be wrong. It used
    /// to rewrite the whole dictionary twice a second, which fits both lock
    /// screen bugs reported against it:
    ///
    ///   * Seeking from the lock screen did not take: each rewrite reset the
    ///     elapsed time while the scrubber was being dragged.
    ///   * Pause looked ignored: the system shows the paused state
    ///     optimistically, and a tick landing around the command could
    ///     re-assert a playback rate of 1.
    ///
    /// The system extrapolates elapsed time from the rate on its own, which is
    /// what Apple documents this property pair for. Republishing is only needed
    /// when the track, rate or duration changes, or when real playback has
    /// drifted from that extrapolation (a seek, a stall, a slow start). Each
    /// write is also a cross-process call into the media daemon, so cutting
    /// two a second to a handful a track is a battery saving in its own right.
    func updateNowPlaying() {
        guard let song = currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            nowPlayingArtworkSongID = nil
            lastNowPlayingPublish = nil
            return
        }

        let rate = isPlaying ? Double(audioSettings.speed) : 0
        let now = Date()
        if let last = lastNowPlayingPublish,
           last.songID == song.id,
           last.rate == rate,
           abs(last.duration - duration) < 0.5,
           last.shuffleEnabled == shuffleEnabled,
           last.repeatMode == repeatMode {
            let expected = last.position + now.timeIntervalSince(last.publishedAt) * last.rate
            if abs(expected - position) < 1.0 { return }
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.displayName,
            MPMediaItemPropertyArtist: song.artistName,
            MPMediaItemPropertyAlbumTitle: song.albumName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(audioSettings.speed),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]

        // Preserve artwork during position updates, but never carry artwork
        // over from a different track while the new track's artwork loads.
        if nowPlayingArtworkSongID == song.id,
           let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo,
           let existingArtwork = existing[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existingArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastNowPlayingPublish = NowPlayingPublish(
            songID: song.id, rate: rate, duration: duration, position: position,
            publishedAt: now, shuffleEnabled: shuffleEnabled, repeatMode: repeatMode
        )

        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = shuffleEnabled ? .items : .off
        switch repeatMode {
        case .off: center.changeRepeatModeCommand.currentRepeatType = .off
        case .all: center.changeRepeatModeCommand.currentRepeatType = .all
        case .one: center.changeRepeatModeCommand.currentRepeatType = .one
        }
    }

    /// Forces the next `updateNowPlaying()` to write, for changes it cannot
    /// see from its own comparison (artwork, title edits).
    func invalidateNowPlaying() {
        lastNowPlayingPublish = nil
    }

    /// Fetches artwork asynchronously and injects it into the Now Playing info center
    /// and the WidgetKit shared container.
    func updateNowPlayingArtwork(for song: Song?) async {
        guard let song else {
            nowPlayingArtworkSongID = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            WidgetDataService.shared.update(song: nil, isPlaying: false, artwork: nil)
            PhoneWatchSync.shared.update(song: nil, isPlaying: false, artwork: nil)
            return
        }
        let image = await ArtworkService.shared.loadArtwork(for: song)
        // Artwork loads can finish out of order when tracks change quickly.
        // Do not let an older request overwrite the current system controls
        // or shared widget state.
        guard currentSong?.id == song.id else { return }
        if let image {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            nowPlayingArtworkSongID = song.id
        } else {
            nowPlayingArtworkSongID = nil
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        WidgetDataService.shared.update(
            song: song, isPlaying: isPlaying, artwork: image, position: position, duration: duration,
            isFavorite: LibraryManager.shared?.isFavorite(songID: song.id) ?? false
        )
        PhoneWatchSync.shared.update(song: song, isPlaying: isPlaying, artwork: image)
    }

    /// Wires the system transport controls: lock screen, Control Center, the
    /// Dynamic Island, headphone buttons, CarPlay, and Siri's built-in media
    /// commands ("pause", "next song", "turn on shuffle"), which are delivered
    /// to the Now Playing app through these same commands.
    ///
    /// Handlers run synchronously. MediaPlayer calls them on the main thread,
    /// and they used to hop through `Task { @MainActor in ... }` and report
    /// success before anything had happened. The command then ran on a later
    /// turn of the run loop, after the system had already read back a Now
    /// Playing state that still said "playing", so a pause from the lock
    /// screen could look ignored. Running in place means the state the
    /// handler returns with is the state the system sees.
    func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        // Shuffle and repeat put no extra buttons on the iPhone lock screen;
        // they are what Siri's "turn on shuffle" / "repeat this song" and
        // CarPlay's controls send. Without them those requests failed with
        // "Lumisound doesn't support that".
        center.changeShuffleModeCommand.isEnabled = true
        center.changeRepeatModeCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            Self.onMain {
                guard let self, self.currentSong != nil || !self.queue.isEmpty else {
                    return .noActionableNowPlayingItem
                }
                self.resume()
                self.updateNowPlaying()
                return .success
            }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Self.onMain {
                guard let self, self.currentSong != nil else { return .noActionableNowPlayingItem }
                self.pause()
                return .success
            }
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Self.onMain {
                guard let self, self.currentSong != nil || !self.queue.isEmpty else {
                    return .noActionableNowPlayingItem
                }
                self.togglePlayPause()
                self.updateNowPlaying()
                return .success
            }
        }
        center.stopCommand.addTarget { [weak self] _ in
            Self.onMain {
                guard let self, self.currentSong != nil else { return .noActionableNowPlayingItem }
                self.pause()
                return .success
            }
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Self.onMain {
                guard let self, !self.queue.isEmpty else { return .noActionableNowPlayingItem }
                self.userSkipToNext()
                return .success
            }
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Self.onMain {
                guard let self, !self.queue.isEmpty else { return .noActionableNowPlayingItem }
                self.skipToPrevious()
                return .success
            }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = e.positionTime
            return Self.onMain {
                guard let self, self.currentSong != nil else { return .noActionableNowPlayingItem }
                self.seek(to: target)
                return .success
            }
        }
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let wantsShuffle = e.shuffleType != .off
            return Self.onMain {
                guard let self else { return .noActionableNowPlayingItem }
                if self.shuffleEnabled != wantsShuffle { self.toggleShuffle() }
                return .success
            }
        }
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let wanted: RepeatMode
            switch e.repeatType {
            case .one: wanted = .one
            case .all: wanted = .all
            default: wanted = .off
            }
            return Self.onMain {
                guard let self else { return .noActionableNowPlayingItem }
                self.repeatMode = wanted
                self.updateNowPlaying()
                return .success
            }
        }
    }

    /// Runs a remote command handler on the main actor and returns its real
    /// status. MediaPlayer delivers commands on the main thread, so this is
    /// normally a direct call; the fallback covers a delivery from elsewhere,
    /// where the best that can honestly be reported is that it was accepted.
    nonisolated static func onMain(
        _ body: @MainActor () -> MPRemoteCommandHandlerStatus
    ) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        appWarn("Remote command delivered off the main thread", category: "audio")
        return .commandFailed
    }
}

/// What `updateNowPlaying()` last published, used to skip redundant writes.
struct NowPlayingPublish {
    let songID: String
    let rate: Double
    let duration: TimeInterval
    let position: TimeInterval
    let publishedAt: Date
    let shuffleEnabled: Bool
    let repeatMode: RepeatMode
}
