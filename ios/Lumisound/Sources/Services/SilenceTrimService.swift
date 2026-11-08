import Foundation
import Combine

/// Skip Silent Intros (Settings → Playback). The audio engine opens each
/// track at its analysed start (`openingOffset`), including gapless and
/// crossfaded starts, so there is no audible jump. This service keeps the
/// analysis one track ahead of playback, and covers a track's very first
/// play (not analysed yet) by skipping as soon as the result is in — only
/// while playback is still inside the silence.
@MainActor
final class SilenceTrimService: ObservableObject {
    private static let enabledKey = "silenceTrim.enabled"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private var cancellable: AnyCancellable?
    private weak var player: AudioPlayerManager?
    private var preparedSongID: String?

    /// Lets non-view code (the engine, diagnostics) reach the live instance.
    static weak var shared: SilenceTrimService?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        Self.shared = self
    }

    /// Where to open `url` when playing it from the top: its cached intro
    /// skip, or 0 (feature off, not analysed yet, nothing to skip). Instant.
    static func openingOffset(for url: URL) -> TimeInterval {
        guard shared?.isEnabled == true, url.isFileURL else { return 0 }
        return SilenceTrimAnalyzer.cachedStart(for: url) ?? 0
    }

    func attach(player: AudioPlayerManager) {
        self.player = player
        cancellable = player.$currentSong
            .compactMap { $0 }
            .removeDuplicates { $0.id == $1.id }
            .sink { [weak self] song in
                self?.handleTrackChange(to: song)
            }
    }

    private func handleTrackChange(to song: Song) {
        guard isEnabled, let url = song.url, url.isFileURL else { return }
        prepareNext()
        Task { [weak self] in
            let start = await SilenceTrimAnalyzer.start(for: url)
            guard start > 0, let self, let player = self.player,
                  player.currentSong?.id == song.id,
                  // Opened there already (cached), or past it: the listener is
                  // hearing music now, so never jump.
                  player.position + 0.05 < start
            else { return }
            player.seek(to: start)
            appLog(String(format: "Skip Silent Intros: \"%@\" → %.2fs (first play)", song.displayName, start), category: "audio")
        }
    }

    /// Analyse the next queued track ahead, so it opens at its music.
    private func prepareNext() {
        guard let next = player?.peekNextSong(), next.id != preparedSongID,
              let url = next.url, url.isFileURL else { return }
        preparedSongID = next.id
        guard SilenceTrimAnalyzer.cachedStart(for: url) == nil else { return }
        Task.detached(priority: .utility) { _ = await SilenceTrimAnalyzer.start(for: url) }
    }
}
