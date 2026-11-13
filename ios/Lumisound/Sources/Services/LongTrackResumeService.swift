import Foundation
import Combine

/// Drives `LongTrackResumeStore` during actual playback — auto-seeks to a
/// saved position when a long track starts (silently, same as podcasts'
/// continue-listening, no prompt), and periodically saves the position
/// while one plays. Observes `AudioPlayerManager` from the outside rather
/// than being wired into the crossfade/queue-advance engine itself, same
/// reasoning as `AIDJService`/`SilenceTrimService`. No UI-facing published
/// state, so a plain singleton rather than an `ObservableObject`.
@MainActor
final class LongTrackResumeService {
    static let shared = LongTrackResumeService()

    private static let saveInterval: TimeInterval = 5
    private static let nearEndMargin: TimeInterval = 30

    private weak var player: AudioPlayerManager?
    private var cancellable: AnyCancellable?
    private var saveTimer: Timer?
    private var lastHandledSongID: Song.ID?

    private init() {}

    func attach(player: AudioPlayerManager) {
        self.player = player
        cancellable = player.$currentSong
            .compactMap { $0 }
            .removeDuplicates { $0.id == $1.id }
            .sink { [weak self] song in
                self?.handleTrackChange(to: song)
            }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.periodicSave() }
        }
        // Lets iOS batch this wake-up with others (battery).
        saveTimer?.tolerance = (Self.saveInterval) * 0.1
    }

    private func handleTrackChange(to song: Song) {
        guard lastHandledSongID != song.id else { return }
        lastHandledSongID = song.id
        guard let resumePosition = LongTrackResumeStore.shared.resumePosition(for: song) else { return }
        Task { [weak self] in
            // Give AVFoundation a beat to actually start playback before
            // seeking into it — same reasoning as AIDJService/
            // the same kind of short waits used elsewhere
            // before their own post-track-change seeks.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, let player = self.player, player.currentSong?.id == song.id else { return }
            player.seek(to: resumePosition)
            ToastCenter.shared.show("Resumed from \(Self.formattedTime(resumePosition))", category: .info, icon: "gobackward")
        }
    }

    private func periodicSave() {
        guard let player, let song = player.currentSong, player.isPlaying,
              song.duration >= LongTrackResumeStore.minimumDuration else { return }
        if player.position >= song.duration - Self.nearEndMargin {
            LongTrackResumeStore.shared.clear(for: song.id)
        } else {
            LongTrackResumeStore.shared.recordPosition(player.position, for: song)
        }
    }

    private static func formattedTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
