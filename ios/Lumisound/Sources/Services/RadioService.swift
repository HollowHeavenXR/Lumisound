import Combine
import Foundation

/// Lumisound Radio (Auto-Radio): thin Swift side of the core `RadioSession`
/// (rust/core/src/radio.rs) and the bridge's `/user/radio/*` engine.
///
/// Starts a station when the queue runs out, tells the session what the
/// listener did with each station song (skipped early, finished, played
/// part of it) and refills the queue before it runs dry, so the station
/// keeps going and steers by those signals. All of the decisions — which
/// songs, in what order, how feedback moves the station — are made in Rust.
@MainActor
final class RadioService {
    static let shared = RadioService()

    private var session: RadioSession?
    private weak var player: AudioPlayerManager?
    private weak var library: LibraryManager?
    private weak var streaming: StreamingService?
    private weak var account: AccountService?
    private var observer: AnyCancellable?
    /// The station song that was playing, and how far it got.
    private var previous: (id: String, duration: TimeInterval)?
    private var lastPosition: TimeInterval = 0

    private init() {}

    var isActive: Bool { session?.sessionId() != nil }

    /// Start a station from `seed` and append its first songs.
    func start(seed: Song, bpm: Double?, player: AudioPlayerManager, library: LibraryManager,
               streaming: StreamingService, account: AccountService) async -> Int {
        self.player = player
        self.library = library
        self.streaming = streaming
        self.account = account
        let mode = UserDefaults.standard.string(forKey: "radio_mode") ?? "balanced"
        let s = RadioSession(mode: mode)
        session = s
        observe(player)
        let hour = Int64(Calendar.current.component(.hour, from: Date()))
        let body = s.startBody(seed: RadioSeed(title: seed.title, artist: seed.artist, album: seed.album.isEmpty ? nil : seed.album,
                                               genre: seed.genre.isEmpty ? nil : seed.genre, bpm: bpm,
                                               sourceTrackId: seed.id, localHour: hour), count: 8)
        do {
            let data = try await account._makeRequest("/user/radio/start", method: "POST", bodyData: body, timeout: 75)
            let batch = s.applyResponse(body: data)
            let added = await append(batch.tracks)
            appLog("Radio: \"\(batch.title)\" started with \(added) song(s)", category: "audio")
            return added
        } catch {
            s.requestFailed()
            appWarn("Radio start failed: \(error.localizedDescription)", category: "network")
            return 0
        }
    }

    func stop() {
        session = nil
        observer = nil
        previous = nil
    }

    private func observe(_ player: AudioPlayerManager) {
        observer = player.$currentSong
            .removeDuplicates(by: { $0?.id == $1?.id })
            .sink { [weak self] song in
                Task { @MainActor [weak self] in self?.songChanged(to: song) }
            }
    }

    /// Called on every track change: feedback for the song that just left,
    /// refill when the station is nearly out of songs.
    private func songChanged(to song: Song?) {
        guard let s = session, let player else { return }
        if let prev = previous {
            let listened = lastPosition
            let skippedByUser = Date().timeIntervalSince(player.lastUserSkipAt) < 2
            let event: RadioEvent
            if skippedByUser {
                event = .skipped
            } else if prev.duration > 0, listened >= prev.duration * 0.8 {
                event = .completed
            } else {
                event = .played
            }
            s.record(trackId: prev.id, event: event, listenedSecs: listened)
        }
        if let song, s.isRadioTrack(trackId: song.id) {
            previous = (song.id, song.duration > 0 ? song.duration : player.duration)
        } else {
            previous = nil
        }
        lastPosition = 0
        let ahead = player.queue.dropFirst(player.currentIndex + 1).filter { s.isRadioTrack(trackId: $0.id) }.count
        if s.needsRefill(radioTracksAhead: UInt32(ahead)) {
            Task { await refill() }
        }
    }

    /// Track the furthest position reached in the current station song
    /// (called from the player's position setter; works in the background).
    func positionTick(_ position: TimeInterval) {
        if previous != nil { lastPosition = max(lastPosition, position) }
    }

    private func refill() async {
        guard let s = session, let account, let body = s.nextBody(count: 6) else { return }
        do {
            let data = try await account._makeRequest("/user/radio/next", method: "POST", bodyData: body, timeout: 75)
            let batch = s.applyResponse(body: data)
            let added = await append(batch.tracks)
            appLog("Radio: refilled \(added) song(s)", category: "audio")
        } catch {
            s.requestFailed()
            appWarn("Radio refill failed: \(error.localizedDescription)", category: "network")
        }
    }

    /// Library songs play from the library; the rest stream.
    private func append(_ tracks: [RadioTrack]) async -> Int {
        guard let player, let streaming else { return 0 }
        var added = 0
        for t in tracks {
            if let local = t.localSongId, let song = library?.allSongs.first(where: { $0.id == local }) {
                player.appendToQueue(song: song, source: .autoContinuation)
                added += 1
                continue
            }
            guard !t.id.isEmpty else { continue }
            let track = StreamTrack(id: t.id, title: t.title, artist: t.artist, durationSeconds: Int(t.durationSeconds),
                                    thumbnailURL: t.thumbnailUrl, source: "youtube", youtubeURL: t.youtubeUrl)
            guard let url = try? await streaming.streamURL(for: track) else { continue }
            player.appendToQueue(song: streaming.toSong(track: track, streamURL: url), source: .autoContinuation)
            added += 1
        }
        return added
    }
}
