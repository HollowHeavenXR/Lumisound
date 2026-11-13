import AVFoundation
import Foundation
import MediaPlayer
import UIKit

// MARK: - TVPlayerModel Now Playing / Remote Commands / Audio Session
//
// tvOS counterpart to the iOS target's AudioPlayerManager+NowPlayingInfo.swift.
// Without this, the app had no MPNowPlayingInfoCenter/MPRemoteCommandCenter
// integration at all — the Siri Remote's transport buttons did nothing while
// the app wasn't focused, and there was no system Now Playing surface. It
// also had no AVAudioSession interruption/route-change handling, so a
// transient interruption (Siri, a system sound) left `isPlaying` out of sync
// with the actual player state with no way to recover.
extension TVPlayerModel {

    // MARK: Now Playing info

    func updateNowPlayingInfo() {
        guard let item = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        // Preserve existing artwork across position/rate-only updates (avoid
        // re-fetching/flickering every 0.5s time-observer tick).
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo,
           let existingArtwork = existing[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existingArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Fetches artwork for the current track and injects it into the Now
    /// Playing info center. Re-checks `current?.id` after the network hop so
    /// a fast skip while this is in flight doesn't stomp a newer track's info.
    func updateNowPlayingArtwork() {
        guard let item = current, let url = item.artworkURL else { return }
        let expectedID = item.id
        Task { [weak self] in
            var req = URLRequest(url: url)
            if let token = item.authToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let (data, response) = try? await Core.data(for: req),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data)
            else { return }
            guard let self, self.current?.id == expectedID else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    // MARK: Remote commands

    /// Registers Siri Remote / system transport-control targets. Safe to
    /// call more than once — clears any previously-registered target first
    /// so repeated calls (e.g. re-entering the player view) never stack
    /// duplicate handlers for the same command.
    func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.resumePlayback()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.pausePlayback()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime)
            return .success
        }
    }

    /// Clears remote-command targets — called from `stop()` alongside the
    /// rest of the observer teardown so a dismissed player view doesn't
    /// leave stale targets calling into a `TVPlayerModel` that's gone away.
    func teardownRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Audio session interruption / route change

    /// Keeps `isPlaying` truthful across interruptions (Siri, a system
    /// sound) and route changes (AirPlay connect/disconnect) — previously
    /// unhandled entirely, so the UI's play/pause icon and the actual
    /// AVPlayer state could silently disagree with no way to recover short
    /// of leaving and re-entering the player.
    func setupAudioSessionObservers() {
        guard audioSessionObservers.isEmpty else { return }

        let center = NotificationCenter.default
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
                else { return }
                switch type {
                case .began:
                    self.pausePlayback()
                case .ended:
                    let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.resumePlayback()
                    }
                @unknown default:
                    break
                }
            }
        }
        audioSessionObservers.append(interruption)

        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
                else { return }
                // Old device (e.g. AirPlay) became unavailable — mirror the
                // system convention of pausing rather than continuing on
                // whatever device was implicitly switched to.
                if reason == .oldDeviceUnavailable {
                    self.pausePlayback()
                }
            }
        }
        audioSessionObservers.append(routeChange)
    }

    func teardownAudioSessionObservers() {
        audioSessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        audioSessionObservers.removeAll()
    }
}
