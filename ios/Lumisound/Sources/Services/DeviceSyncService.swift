import Foundation

/// Keeps playback synced across this ACCOUNT'S OWN devices — start playback
/// on your phone, have your iPad in another room pick it up and stay
/// roughly in step. Distinct from `SharePlayCoordinator`'s "Listen
/// Together": that one needs an active FaceTime/Messages `GroupSession`,
/// which is the wrong fit for "my own second device sitting in another
/// room with nobody calling anybody." This instead reuses the bridge's
/// Shared Listening Room mechanism (`/rooms/{code}`) under the hood, just
/// self-scoped and auto-joined with no room code ever shown — see
/// `/user/device-sync/*` in main.py.
///
/// Not sample-accurate, and not trying to be: like `PlaybackSyncMessage.
/// adjustedPosition` (SharePlayCoordinator.swift), this corrects for
/// message/poll transit time but is fundamentally a cloud-relay-based sync,
/// perceptually "in step" (low single-digit seconds) rather than
/// Sonos-grade sample sync — the honest ceiling for this architecture.
@MainActor
final class DeviceSyncService: ObservableObject {
    static weak var shared: DeviceSyncService?

    @Published private(set) var isHosting = false
    @Published private(set) var isFollowing = false
    @Published private(set) var roomCode: String?

    /// Opt-in, per device, OFF by default. Without this, starting playback
    /// on one device would silently start audio playing out loud on every
    /// OTHER device signed into the same account that happens to have the
    /// app open — a real surprise (and in a shared-device/roommate
    /// situation, a real privacy issue), not just a UX nicety. A device
    /// only ever auto-joins a sync session if someone has explicitly
    /// turned this on, on THAT device.
    ///
    /// Plain UserDefaults rather than `@AppStorage` — this type is a plain
    /// `ObservableObject`, not a View, and `@AppStorage`'s change tracking
    /// isn't guaranteed to propagate through `objectWillChange` outside a
    /// View's own `body`.
    @Published var autoJoinEnabled: Bool = UserDefaults.standard.bool(forKey: "deviceSyncAutoJoinEnabled") {
        didSet { UserDefaults.standard.set(autoJoinEnabled, forKey: "deviceSyncAutoJoinEnabled") }
    }

    weak var player: AudioPlayerManager?
    weak var streaming: StreamingService?

    /// Set while applying an incoming sync update, so the resulting
    /// player-state change doesn't get mistaken for a local user action.
    private var isApplyingRemote = false
    private var lastAppliedTrackURL: String?
    /// The song this device put in the player to follow the room.
    private var appliedSongID: String?
    /// A room the listener left by picking their own music; not rejoined.
    private var dismissedRoomCode: String?

    init() {
        Self.shared = self
    }

    // MARK: - Hosting

    func startHosting() async {
        guard let account = AccountService.shared, account.isLoggedIn else { return }
        guard let code = try? await postStart(account: account) else { return }
        roomCode = code
        isHosting = true
        isFollowing = false
        if let player, let song = player.currentSong {
            await pushHostState(song: song, isPlaying: player.isPlaying, position: player.position)
        }
    }

    func stopHosting() async {
        guard let account = AccountService.shared else { return }
        _ = try? await postStop(account: account)
        isHosting = false
        roomCode = nil
    }

    /// Called from `AudioPlayerManager+PositionTracking.pushPlaybackStateToBridge()`'s
    /// existing ~5s tick — piggybacking on an already-correct, already-running
    /// timer rather than adding a second one for this.
    func hostTick(song: Song?, isPlaying: Bool, position: TimeInterval) {
        guard isHosting, !isApplyingRemote else { return }
        Task { await pushHostState(song: song, isPlaying: isPlaying, position: position) }
    }

    private func pushHostState(song: Song?, isPlaying: Bool, position: TimeInterval) async {
        guard let account = AccountService.shared, let code = roomCode else { return }
        struct Body: Encodable {
            let track_url: String?
            let title: String?
            let artist: String?
            let position_seconds: Double
            let is_playing: Bool
        }
        let body = Body(
            track_url: song?.sourceTrackID,
            title: song?.title,
            artist: song?.artist,
            position_seconds: position,
            is_playing: isPlaying
        )
        _ = try? await account.makeRequest("/rooms/\(code)", method: "PUT", body: body)
    }

    // MARK: - Following

    /// Called periodically (same ~5s tick, when not hosting) to discover a
    /// device-sync session started from another of this account's devices
    /// and follow it — or stop following if it's gone.
    func checkForActiveSyncAndJoin() {
        guard autoJoinEnabled, !isHosting, let account = AccountService.shared, account.isLoggedIn else { return }
        Task {
            guard let code = try? await getActive(account: account) else {
                if isFollowing { stopFollowing() }
                return
            }
            guard code != dismissedRoomCode else { return }
            if code != roomCode {
                roomCode = code
                isFollowing = true
                lastAppliedTrackURL = nil
            }
            if isFollowing {
                await pollOnce(code: code, account: account)
            }
        }
    }

    private func stopFollowing() {
        isFollowing = false
        roomCode = nil
        lastAppliedTrackURL = nil
        appliedSongID = nil
    }

    private func pollOnce(code: String, account: AccountService) async {
        guard let room = try? await getRoom(code: code, account: account) else { return }
        await apply(room: room)
    }

    private struct RoomState: Decodable {
        let track_url: String?
        let title: String?
        let artist: String?
        let position_seconds: Double
        let is_playing: Bool
        let updated_at: String?
        let server_time: String?
    }

    private func apply(room: RoomState) async {
        guard let player, let streaming else { return }
        // The listener chose something else on this device: that ends
        // following. Re-applying the room here forced the room's track back
        // over their pick every ~5 s ("skips to a song that isn't even
        // downloaded, and going back keeps switching to it").
        if let applied = appliedSongID, player.currentSong?.id != applied {
            appLog("DeviceSync: listener picked another song — leaving sync room \(roomCode ?? "?")", category: "audio")
            dismissedRoomCode = roomCode
            stopFollowing()
            return
        }
        isApplyingRemote = true
        defer { isApplyingRemote = false }

        // Drift-corrected position: how long ago the host's own report
        // actually was, measured against the BRIDGE's clock (server_time),
        // not this device's own — the two devices' clocks aren't assumed
        // to agree. Mirrors PlaybackSyncMessage.adjustedPosition's intent
        // with a real clock-offset source instead of trusting sentAt alone.
        var position = room.position_seconds
        if room.is_playing,
           let updatedAt = room.updated_at.flatMap(Self.parseISO8601),
           let serverTime = room.server_time.flatMap(Self.parseISO8601) {
            let elapsedSinceReport = serverTime.timeIntervalSince(updatedAt)
            position += max(0, elapsedSinceReport)
        }

        guard let trackURL = room.track_url, !trackURL.isEmpty else { return }

        if trackURL != lastAppliedTrackURL || player.currentSong?.sourceTrackID != trackURL {
            // sourceTrackID is "source:id" — same re-resolution approach as
            // SharePlayCoordinator.apply(), and the same Bandcamp caveat
            // (its stream lookup needs the original webpage URL, which
            // isn't carried by sourceTrackID alone).
            let parts = trackURL.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0] != "bandcamp" else { return }
            let track = StreamTrack(
                id: String(parts[1]), title: room.title ?? "", artist: room.artist ?? "",
                durationSeconds: 0, thumbnailURL: "", source: String(parts[0]), youtubeURL: ""
            )
            guard let url = try? await streaming.streamURL(for: track) else { return }
            let song = streaming.toSong(track: track, streamURL: url)
            player.setQueue([song], startIndex: 0, autoplay: room.is_playing)
            if room.is_playing { player.seek(to: position) }
            lastAppliedTrackURL = trackURL
            appliedSongID = player.currentSong?.id
            return
        }

        if player.isPlaying != room.is_playing {
            player.togglePlayPause()
        }
        if abs(player.position - position) > 2 {
            player.seek(to: position)
        }
    }

    private static func parseISO8601(_ string: String) -> Date? {
        ISO8601DateFormatter.lumisoundFractional.date(from: string) ?? ISO8601DateFormatter.lumisoundPlain.date(from: string)
    }

    // MARK: - Networking

    private func postStart(account: AccountService) async throws -> String {
        struct Body: Encodable { let track_url: String?; let title: String?; let artist: String?; let position_seconds: Double; let is_playing: Bool }
        let body = Body(track_url: player?.currentSong?.sourceTrackID, title: player?.currentSong?.title,
                         artist: player?.currentSong?.artist, position_seconds: player?.position ?? 0,
                         is_playing: player?.isPlaying ?? false)
        let data = try await account.makeRequest("/user/device-sync/start", method: "POST", body: body)
        struct Response: Decodable { let room_code: String }
        return try JSONDecoder().decode(Response.self, from: data).room_code
    }

    private func postStop(account: AccountService) async throws {
        _ = try await account.makeRequest("/user/device-sync/stop", method: "POST")
    }

    private func getActive(account: AccountService) async throws -> String? {
        let data = try await account.makeRequest("/user/device-sync/active")
        struct Response: Decodable { let room_code: String? }
        return try JSONDecoder().decode(Response.self, from: data).room_code
    }

    private func getRoom(code: String, account: AccountService) async throws -> RoomState {
        let data = try await account.makeRequest("/rooms/\(code)")
        return try JSONDecoder().decode(RoomState.self, from: data)
    }
}

private extension ISO8601DateFormatter {
    static let lumisoundFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let lumisoundPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
