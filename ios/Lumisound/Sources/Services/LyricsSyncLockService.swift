import Foundation

/// Periodic lyrics lock: every so often (randomized, 20-45 min) one random
/// library track that has plain, untimed lyrics is locked and its lyrics
/// re-encoded as time-synced LRC by the Rust core (`lyrics_force_sync`,
/// which listens for where the vocals are). The result is saved where the
/// Now Playing lyrics loader looks first (`Documents/Lyrics/<id>.lrc`), and
/// locked `.lms` tracks also get the LYRICS_SYNCED flag in their header.
///
/// Tracks that already have an `.lrc` but no flag are just stamped (no
/// re-timing). Never touches the track that's playing, and waits for
/// thermal headroom (HeatGovernor) so it can't heat the phone.
@MainActor
final class LyricsSyncLockService {
    static let shared = LyricsSyncLockService()

    private weak var library: LibraryManager?
    private weak var player: AudioPlayerManager?
    private var task: Task<Void, Never>?
    /// Songs handled (or failed) this session.
    private var done: Set<String> = []

    private init() {}

    func start(library: LibraryManager, player: AudioPlayerManager) {
        self.library = library
        self.player = player
        guard task == nil else { return }
        task = Task { [weak self] in
            // First round a few minutes after launch, then randomized.
            try? await Task.sleep(nanoseconds: UInt64.random(in: 180...420) * 1_000_000_000)
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(nanoseconds: UInt64.random(in: 1200...2700) * 1_000_000_000)
            }
        }
    }

    private static func lyricsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
    }

    private static func fileStem(_ id: String) -> String {
        id.components(separatedBy: CharacterSet(charactersIn: "/:\\*?\"<>|")).joined(separator: "_")
    }

    private enum Job { case sync(plain: URL), stamp }

    /// Picks one random eligible track.
    private func pick() -> (Song, URL, Job)? {
        guard let songs = library?.allSongs, !songs.isEmpty else { return nil }
        let current = player?.currentSong?.id
        let dir = Self.lyricsDir()
        let fm = FileManager.default
        for song in songs.shuffled().prefix(400) {
            guard song.id != current, !done.contains(song.id),
                  !EngineExclusiveService.shared.isConverting(song.id),
                  let url = song.url, url.isFileURL, fm.fileExists(atPath: url.path) else { continue }
            let stem = Self.fileStem(song.id)
            let lrc = dir.appendingPathComponent(stem + ".lrc")
            let txt = dir.appendingPathComponent(stem + ".txt")
            let locked = LumisoundExclusiveExtensionService.isConverted(url)
            if fm.fileExists(atPath: txt.path), !fm.fileExists(atPath: lrc.path) {
                return (song, url, .sync(plain: txt))
            }
            if locked, fm.fileExists(atPath: lrc.path), !lmsInfo(path: url.path).lyricsSynced {
                return (song, url, .stamp)
            }
        }
        return nil
    }

    private func runOnce() async {
        guard let (song, url, job) = pick() else { return }
        done.insert(song.id)
        guard await HeatGovernor.waitForHeadroom(job: "lyrics_sync", maxWait: 120) else { return }
        // The listener may have started it while we waited.
        guard player?.currentSong?.id != song.id,
              EngineExclusiveService.shared.beginLock(song.id, label: "Syncing lyrics") else { return }
        defer { EngineExclusiveService.shared.endLock(song.id) }

        let started = Date()
        let lrcURL = Self.lyricsDir().appendingPathComponent(Self.fileStem(song.id) + ".lrc")
        let locked = LumisoundExclusiveExtensionService.isConverted(url)
        let tmp = FileManager.default.temporaryDirectory.path
        let result: (ok: Bool, lines: Int, singing: Double) = await Task.detached(priority: .utility) {
            var lines = 0
            var singing = 0.0
            if case .sync(let plain) = job {
                guard let text = try? String(contentsOf: plain, encoding: .utf8),
                      let synced = try? lyricsForceSync(path: url.path, lyrics: text),
                      (try? synced.lrc.write(to: lrcURL, atomically: true, encoding: .utf8)) != nil
                else { return (false, 0, 0) }
                lines = synced.lines.count
                singing = synced.singingSeconds
            }
            if locked {
                _ = lmsSetFlags(path: url.path, engineExclusive: nil, lyricsSynced: true, tmpDir: tmp,
                                verifier: AVFoundationAudioVerifier.shared)
            }
            return (true, lines, singing)
        }.value

        let secs = Date().timeIntervalSince(started)
        appLog("LyricsSync: \"\(song.displayName)\" \(result.ok ? "synced \(result.lines) lines" : "FAILED") in \(String(format: "%.1f", secs))s",
               category: "lyrics")
        RemoteLogger.log(category: "lyrics", event: result.ok ? "lyrics_force_synced" : "lyrics_force_sync_failed",
                         level: result.ok ? "info" : "warning", message: song.displayName,
                         detail: ["seconds": secs, "lines": result.lines, "singingSeconds": result.singing,
                                  "stampOnly": { if case .stamp = job { return true } else { return false } }()])
    }
}
