import Combine
import Foundation
import UIKit

// MARK: - ListenRoomService
//
// The client half of the bridge's shared-listening rooms. The server side existed
// for a long time with no client at all — every /rooms endpoint, three tables, and
// zero references from this app — so this is the first thing that makes the
// feature reachable.
//
// Deliberately push-first. The bridge fans room state, chat, queue changes,
// membership and closure over the same /ws/live socket `LiveUpdateService` already
// holds open (see `_push_room_event`), so the common case costs no polling at all.
// The heartbeat below is not a poll for state — it is this device telling the
// server it is still present, which is what keeps it in the member list and in the
// push audience. Its response carries the member list back only because it is
// already a round trip.
@MainActor
final class ListenRoomService: ObservableObject {

    static let shared = ListenRoomService()

    /// The room this device is currently in, if any.
    @Published private(set) var state: RoomState?
    @Published private(set) var participants: [RoomParticipant] = []
    @Published private(set) var events: [RoomEvent] = []
    @Published private(set) var queue: [RoomQueueItem] = []
    @Published private(set) var isHost = false
    @Published var errorMessage: String?
    /// Set when the host ends the room, so a follower's UI can say why it closed
    /// rather than silently emptying.
    @Published private(set) var closedByHost = false

    /// Listeners follow the host's playback (track, play/pause, position)
    /// with the Lumisound sync engine (rust/core/src/together.rs). Off lets
    /// a listener stay in the room (chat, queue) and play their own thing.
    @Published var followHost = true {
        didSet {
            if followHost { applyHost() } else { player?.setTogetherRate(1); sync.reset() }
        }
    }
    /// How far this device is from the host (seconds, + = ahead), nil when not following.
    @Published private(set) var syncDrift: Double?
    /// Live reactions: (emoji, who sent it).
    let reactions = PassthroughSubject<(emoji: String, from: String), Never>()

    nonisolated let sync = TogetherSync()
    private weak var player: AudioPlayerManager?
    private var followTimer: Timer?
    /// The host track being resolved / loaded right now (don't start it twice).
    private var loadingKey: String?
    /// What the host last published, to spot seeks between timer ticks.
    private var lastSent: (key: String, position: Double, playing: Bool, at: Date)?

    var roomCode: String? { state?.roomCode }
    var isInRoom: Bool { state != nil }

    /// Shorter than the server's 90s presence TTL by enough that one dropped
    /// request doesn't blink this device out of the room.
    private static let heartbeatInterval: TimeInterval = 30

    /// How often the host republishes its playback position.
    ///
    /// Followers compute their own position from `updated_at` plus elapsed time
    /// (see `RoomState.resolvedPosition`), so they do not need frequent updates to
    /// stay in sync — they need *recent enough* ones to survive a seek or a pause
    /// they missed. Every 15s keeps a late joiner within a few seconds without
    /// making a listening session a write-heavy workload on a shared bridge.
    private static let hostBroadcastInterval: TimeInterval = 10

    private var heartbeatTimer: Timer?
    private var hostBroadcastTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Decoding

    /// Shared decoder for room payloads.
    ///
    /// A custom date strategy because the bridge emits fractional seconds
    /// (`...874131+00:00`) and Foundation's `.iso8601` strategy rejects those
    /// outright — it would fail the whole decode, not just the date. Falls back to
    /// the non-fractional form, which is what a timestamp landing exactly on a
    /// second boundary serialises to.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: raw) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognised date: \(raw)"))
        }
        return d
    }()

    // MARK: - Track identity & clock

    /// A song's identity across devices (rust `together_track_key`): its
    /// source id ("youtube:abc") or folded "title|artist".
    static func trackKey(_ song: Song?) -> String {
        guard let song else { return "" }
        return togetherTrackKey(sourceTrackId: song.sourceTrackID, title: song.title, artist: song.artist)
    }

    /// A request whose reply carries `server_time`, timed for the clock
    /// estimate. Returns the reply.
    @discardableResult
    private func clocked(_ path: String, method: String = "GET") async throws -> Data {
        guard let account = AccountService.shared else { throw CancellationError() }
        let sent = Date().timeIntervalSince1970
        let data = try await account.makeRequest(path, method: method)
        let received = Date().timeIntervalSince1970
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let server = Self.parseDate(obj["server_time"] as? String) {
            sync.addClockSample(sent: sent, server: server.timeIntervalSince1970, received: received)
        }
        return data
    }

    // MARK: - Lifecycle

    /// Subscribes to live room pushes. Called once at launch.
    func attachLiveUpdates() {
        LiveUpdateService.shared.onRoomEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleLive(event) }
        }
    }

    /// Creates a room around whatever this device is playing and becomes its host.
    @discardableResult
    func createRoom(player: AudioPlayerManager) async -> String? {
        guard let account = AccountService.shared, account.isLoggedIn else {
            errorMessage = "Sign in to start a listening room."
            return nil
        }
        struct Body: Encodable {
            let track_url: String?
            let title: String?
            let artist: String?
            let position_seconds: Double
            let is_playing: Bool
        }
        let song = player.currentSong
        let body = Body(
            track_url: Self.trackKey(song),
            title: song?.title,
            artist: (song?.artist.isEmpty ?? true) ? nil : song?.artist,
            position_seconds: player.position,
            is_playing: player.isPlaying
        )
        do {
            let data = try await account.makeRequest("/rooms", method: "POST", body: body)
            struct Created: Decodable { let room_code: String }
            let created = try JSONDecoder().decode(Created.self, from: data)
            appLog("ListenRoom: created room \(created.room_code)", category: "rooms")
            // Joining its own room is what registers the host in the participant
            // table — without it the host is absent from the member list and, more
            // importantly, absent from the push audience for everyone else's chat.
            await join(code: created.room_code, player: player)
            return created.room_code
        } catch let err as AccountError {
            errorMessage = err.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Joins an existing room by code and starts following it.
    func join(code: String, player: AudioPlayerManager) async {
        guard let account = AccountService.shared, account.isLoggedIn else {
            errorMessage = "Sign in to join a listening room."
            return
        }
        let normalised = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalised.count == 6 else {
            errorMessage = "A room code is six characters."
            return
        }
        closedByHost = false
        do {
            let data = try await account.makeRequest("/rooms/\(normalised)/join", method: "POST")
            let joined = try Self.decoder.decode(RoomState.self, from: data)
            state = joined
            participants = joined.participants ?? []
            isHost = joined.isHost ?? false
            errorMessage = nil
            appLog("ListenRoom: joined \(normalised) (host: \(isHost))", category: "rooms")
            self.player = player
            await refreshEvents()
            await refreshQueue()
            startHeartbeat()
            if isHost {
                startHostBroadcast(player: player)
            } else {
                // A few quick round trips seed the clock estimate, then follow.
                for _ in 0..<3 {
                    if let data = try? await clocked("/rooms/\(normalised)"),
                       let fresh = try? Self.decoder.decode(RoomState.self, from: data) {
                        state = fresh
                    }
                }
                startFollowing()
            }
        } catch let err as AccountError {
            errorMessage = err.statusCode == 404 ? "No room with that code." : err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Leaves the room (or closes it, if hosting).
    func leave(close: Bool = false) async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        stopTimers()
        player?.setTogetherRate(1)
        sync.reset()
        loadingKey = nil
        lastSent = nil
        syncDrift = nil
        let shouldClose = close && isHost
        // Local state is cleared first, so the UI dismisses immediately rather
        // than waiting on a request that may be slow or fail. There is nothing to
        // roll back — presence times out server-side regardless.
        state = nil
        participants = []
        events = []
        queue = []
        isHost = false
        do {
            if shouldClose {
                _ = try await account.makeRequest("/rooms/\(code)", method: "DELETE")
            } else {
                _ = try await account.makeRequest("/rooms/\(code)/leave", method: "POST")
            }
        } catch {
            // Best-effort: the server drops this member on TTL anyway.
        }
    }

    // MARK: - Chat, queue, votes

    func sendChat(_ message: String) async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        struct Body: Encodable { let message: String }
        do {
            _ = try await account.makeRequest("/rooms/\(code)/chat", method: "POST", body: Body(message: trimmed))
            // The sender is excluded from the push (they already know what they
            // said), so their own message is appended locally rather than waiting
            // for a refresh that would never mention it.
            let mine = RoomEvent(
                eventType: "chat", title: nil, artist: nil, message: trimmed,
                createdAt: Date(), userId: AccountService.shared?.currentUser?.id,
                username: AccountService.shared?.currentUser?.username,
                displayName: AccountService.shared?.currentUser?.displayName
                    ?? AccountService.shared?.currentUser?.username)
            events.append(mine)
        } catch let err as AccountError {
            errorMessage = err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func suggest(song: Song) async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        struct Body: Encodable {
            let track_url: String?
            let title: String
            let artist: String?
        }
        do {
            _ = try await account.makeRequest(
                "/rooms/\(code)/queue", method: "POST",
                body: Body(track_url: Self.trackKey(song), title: song.title,
                           artist: song.artist.isEmpty ? nil : song.artist))
            await refreshQueue()
        } catch let err as AccountError {
            errorMessage = err.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggles this device's vote on a suggestion.
    func toggleVote(itemID: String) async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        do {
            let data = try await account.makeRequest("/rooms/\(code)/queue/\(itemID)/vote", method: "POST")
            struct VoteResult: Decodable { let status: String; let votes: Int }
            let result = try JSONDecoder().decode(VoteResult.self, from: data)
            // Applied from the server's authoritative count rather than adjusted
            // locally: the endpoint is a toggle, so guessing the direction would
            // drift out of step the moment two taps race.
            if let idx = queue.firstIndex(where: { $0.id == itemID }) {
                queue[idx].votes = result.votes
                // Most votes first, then alphabetical so equal-vote items have a
                // stable order instead of shuffling on every re-sort.
                queue.sort { lhs, rhs in
                    lhs.votes != rhs.votes ? lhs.votes > rhs.votes : lhs.title < rhs.title
                }
            }
        } catch {
            await refreshQueue()
        }
    }

    // MARK: - Refresh

    func refreshEvents() async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        do {
            let data = try await account.makeRequest("/rooms/\(code)/events")
            struct Wrapper: Decodable { let events: [RoomEvent] }
            events = try Self.decoder.decode(Wrapper.self, from: data).events
        } catch {
            // Non-fatal: the history is supplementary to the live stream.
        }
    }

    func refreshQueue() async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        do {
            let data = try await account.makeRequest("/rooms/\(code)/queue")
            struct Wrapper: Decodable { let queue: [RoomQueueItem] }
            queue = try Self.decoder.decode(Wrapper.self, from: data).queue
        } catch {
            // Non-fatal, as above.
        }
    }

    // MARK: - Live push handling

    private func handleLive(_ event: [String: Any]) {
        let type = event["type"] as? String
        // Guard on the room code: a stale push from a room this device already
        // left would otherwise overwrite the current one's state.
        if let code = event["room_code"] as? String, let mine = roomCode, code != mine { return }

        switch type {
        case "room_state":
            guard let current = state else { return }
            state = RoomState(
                roomCode: current.roomCode,
                trackURL: event["track_url"] as? String ?? current.trackURL,
                title: event["title"] as? String ?? current.title,
                artist: event["artist"] as? String ?? current.artist,
                positionSeconds: event["position_seconds"] as? Double ?? current.positionSeconds,
                isPlaying: event["is_playing"] as? Bool ?? current.isPlaying,
                // `as_of` is the server's own send time, so it replaces
                // `updatedAt` AND `serverTime` — the push has no round trip to
                // measure an offset from, and treating a fresh push as stale
                // would make a follower seek forward for no reason.
                updatedAt: Self.parseDate(event["as_of"] as? String) ?? Date(),
                serverTime: Self.parseDate(event["as_of"] as? String) ?? Date(),
                isHost: current.isHost,
                participants: current.participants
            )
            applyHost()
        case "room_reaction":
            if let emoji = event["emoji"] as? String {
                reactions.send((emoji, event["display_name"] as? String ?? "Someone"))
            }
        case "room_chat":
            let incoming = RoomEvent(
                eventType: "chat", title: nil, artist: nil,
                message: event["message"] as? String,
                createdAt: Self.parseDate(event["created_at"] as? String) ?? Date(),
                userId: event["user_id"] as? String,
                username: event["username"] as? String,
                displayName: event["display_name"] as? String)
            events.append(incoming)
        case "room_queue":
            Task { await refreshQueue() }
        case "room_members":
            Task { await refreshParticipants() }
        case "room_closed":
            closedByHost = true
            Task { await leave() }
        default:
            break
        }
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    private func refreshParticipants() async {
        guard AccountService.shared != nil, let code = roomCode else { return }
        do {
            let data = try await clocked("/rooms/\(code)/heartbeat", method: "POST")
            struct Wrapper: Decodable { let participants: [RoomParticipant] }
            participants = try Self.decoder.decode(Wrapper.self, from: data).participants
        } catch {
            // Non-fatal.
        }
    }

    // MARK: - Following the host

    private func startFollowing() {
        followTimer?.invalidate()
        // Twice a second: cheap (no network), and it's what lets a tempo
        // nudge end on time.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyHost() }
        }
        RunLoop.main.add(t, forMode: .common)
        followTimer = t
        applyHost()
    }

    /// One step of following: ask the sync engine what to do, do it.
    func applyHost() {
        guard followHost, !isHost, let st = state, let player else {
            syncDrift = nil
            return
        }
        let now = Date().timeIntervalSince1970
        let hostKey = st.trackURL ?? ""
        let host = TogetherHost(trackKey: hostKey, position: st.positionSeconds ?? 0, playing: st.isPlaying,
                                asOfServer: st.updatedAt?.timeIntervalSince1970 ?? (now + sync.clockOffset()))
        let local = TogetherLocal(trackKey: Self.trackKey(player.currentSong), position: player.position,
                                  playing: player.isPlaying, now: now)
        let action = sync.decide(host: host, local: local)
        syncDrift = local.trackKey == hostKey ? action.drift : nil
        switch action.kind {
        case .hold:
            break
        case .load:
            guard loadingKey != hostKey else { return }
            loadingKey = hostKey
            Task { await load(key: hostKey, title: st.title ?? "", artist: st.artist ?? "", host: host) }
        case .seek:
            player.seek(to: action.position)
        case .play:
            player.seek(to: action.position)
            player.resume()
        case .pause:
            player.pause()
        case .nudge:
            player.setTogetherRate(action.rate)
        }
    }

    /// Starts the host's track on this device: the library copy when there
    /// is one, else the stream for its source id.
    private func load(key: String, title: String, artist: String, host: TogetherHost) async {
        defer { if loadingKey == key { loadingKey = nil } }
        guard let player, let song = await resolve(key: key, title: title, artist: artist) else {
            errorMessage = "The host is playing “\(title)”, which isn't in your library or streamable here."
            return
        }
        player.setTogetherRate(1)
        sync.reset()
        player.play(song: song, in: [song], uiSource: "listen_together")
        // Land where the host is by the time the track has opened.
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard Self.trackKey(player.currentSong) == key else { return }
        let at = sync.hostPosition(host: host, now: Date().timeIntervalSince1970)
        if at > 0.5 { player.seek(to: at) }
        if !host.playing { player.pause() }
    }

    /// The song for a room track key.
    func resolve(key: String, title: String, artist: String) async -> Song? {
        let library = LibraryManager.shared
        if let songs = library?.allSongs {
            // Same track by identity, a local file first.
            let matches = songs.filter { Self.trackKey($0) == key }
            if let local = matches.first(where: { $0.url?.isFileURL == true }) ?? matches.first { return local }
        }
        guard !key.hasPrefix("lumi:"), let streaming = StreamingService.shared else { return nil }
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] != "bandcamp" else { return nil }
        let track = StreamTrack(id: String(parts[1]), title: title, artist: artist, durationSeconds: 0,
                                thumbnailURL: "", source: String(parts[0]), youtubeURL: "")
        guard let url = try? await streaming.streamURL(for: track) else { return nil }
        return streaming.toSong(track: track, streamURL: url)
    }

    // MARK: - Reactions & suggestions

    /// Sends a live reaction to everyone in the room (shown locally at once).
    func sendReaction(_ emoji: String) {
        guard let account = AccountService.shared, let code = roomCode else { return }
        reactions.send((emoji, "You"))
        struct Body: Encodable { let emoji: String }
        Task { _ = try? await account.makeRequest("/rooms/\(code)/react", method: "POST", body: Body(emoji: emoji)) }
    }

    /// Host: play a suggestion now and take it off the queue.
    func playSuggestion(_ item: RoomQueueItem) async {
        guard isHost, let player, let account = AccountService.shared, let code = roomCode else { return }
        guard let song = await resolve(key: item.trackURL ?? "", title: item.title, artist: item.artist ?? "") else {
            errorMessage = "Couldn't find “\(item.title)” to play."
            return
        }
        player.play(song: song, in: [song], uiSource: "listen_together")
        _ = try? await account.makeRequest("/rooms/\(code)/queue/\(item.id)", method: "DELETE")
        await refreshQueue()
    }

    // MARK: - Timers

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshParticipants() }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    private func startHostBroadcast(player: AudioPlayerManager) {
        hostBroadcastTimer?.invalidate()
        // Checked every second, published only when something a listener
        // must know changed: track, play/pause, a seek (the position moved
        // away from where it should be by now), or every 10 s as a refresh.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let last = self.lastSent else {
                    await self?.broadcast(player: player)
                    return
                }
                let key = Self.trackKey(player.currentSong)
                let projected = last.position + (last.playing ? Date().timeIntervalSince(last.at) * Double(player.audioSettings.speed) : 0)
                if key != last.key || player.isPlaying != last.playing
                    || abs(player.position - projected) > 0.75
                    || Date().timeIntervalSince(last.at) > Self.hostBroadcastInterval {
                    await self.broadcast(player: player)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        hostBroadcastTimer = t

        cancellables.removeAll()
        player.$currentSong
            .removeDuplicates { $0?.id == $1?.id }
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.broadcast(player: player) }
            }
            .store(in: &cancellables)
        player.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.broadcast(player: player) }
            }
            .store(in: &cancellables)
    }

    private func broadcast(player: AudioPlayerManager) async {
        guard isHost, let account = AccountService.shared, let code = roomCode else { return }
        struct Body: Encodable {
            let track_url: String?
            let title: String?
            let artist: String?
            let position_seconds: Double
            let is_playing: Bool
        }
        let song = player.currentSong
        lastSent = (Self.trackKey(song), player.position, player.isPlaying, Date())
        do {
            _ = try await account.makeRequest(
                "/rooms/\(code)", method: "PUT",
                body: Body(track_url: Self.trackKey(song),
                           title: song?.title,
                           artist: (song?.artist.isEmpty ?? true) ? nil : song?.artist,
                           position_seconds: player.position,
                           is_playing: player.isPlaying))
        } catch {
            // Silent, like PresenceService's heartbeat: this fires on a timer
            // regardless of network state and must never interrupt playback.
        }
    }

    private func stopTimers() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        hostBroadcastTimer?.invalidate(); hostBroadcastTimer = nil
        followTimer?.invalidate(); followTimer = nil
        cancellables.removeAll()
    }
}
