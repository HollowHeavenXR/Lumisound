import SwiftUI

// MARK: - TVListenTogether
//
// Listen Together on Apple TV: join a friend's Lumisound room with its code
// and the TV follows the host — same rooms (bridge `/rooms/*`) and the same
// Rust sync engine (`TogetherSync`, rust/core/src/together.rs) as the phone.
// tvOS has no live socket here, so the room is polled once a second; each
// reply's `server_time` also feeds the clock estimate.

struct TVRoomState: Decodable {
    let room_code: String
    let track_url: String?
    let title: String?
    let artist: String?
    let position_seconds: Double?
    let is_playing: Bool?
    let updated_at: String?
    let server_time: String?
    let participants: [Participant]?

    struct Participant: Decodable, Hashable {
        let user_id: String?
        let username: String?
        let display_name: String?
        var name: String { display_name ?? username ?? "Listener" }
    }
}

@MainActor
final class TVListenTogether: ObservableObject {
    static let shared = TVListenTogether()

    @Published private(set) var room: TVRoomState?
    @Published private(set) var drift: Double?
    @Published var errorMessage: String?
    @Published var followHost = true {
        didSet { if !followHost { TVPlayerModel.shared.setTogetherRate(1); sync.reset() } }
    }

    private let sync = TogetherSync()
    private var poll: Task<Void, Never>?
    private var loadingKey: String?
    private var client: TVBridgeClient?
    private var token: String?

    var isInRoom: Bool { room != nil }

    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private func request(_ path: String, method: String = "GET") async throws -> Data {
        guard let client, let token, let url = URL(string: client.baseURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let sent = Date().timeIntervalSince1970
        let (data, response) = try await Core.data(for: req)
        let received = Date().timeIntervalSince1970
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse, userInfo: ["status": status]) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let server = Self.date(obj["server_time"] as? String) {
            sync.addClockSample(sent: sent, server: server.timeIntervalSince1970, received: received)
        }
        return data
    }

    func join(code raw: String, client: TVBridgeClient, token: String) async {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6 else { errorMessage = "A room code is six characters."; return }
        self.client = client
        self.token = token
        do {
            let data = try await request("/rooms/\(code)/join", method: "POST")
            room = try JSONDecoder().decode(TVRoomState.self, from: data)
            errorMessage = nil
            followHost = true
            TVRemoteLogger.log(category: "rooms", event: "tv_room_joined", detail: ["code": code])
            startPolling(code: code)
        } catch {
            errorMessage = "Couldn't join \(code). Check the code and that the room is still open."
        }
    }

    func leave() async {
        poll?.cancel()
        poll = nil
        if let code = room?.room_code { _ = try? await request("/rooms/\(code)/leave", method: "POST") }
        room = nil
        drift = nil
        loadingKey = nil
        sync.reset()
        TVPlayerModel.shared.setTogetherRate(1)
    }

    func react(_ emoji: String) {
        guard let code = room?.room_code, let client, let token,
              let url = URL(string: client.baseURL + "/rooms/\(code)/react") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["emoji": emoji])
        Task { _ = try? await Core.data(for: req) }
    }

    private func startPolling(code: String) {
        poll?.cancel()
        poll = Task { [weak self] in
            var beats = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let data = try? await self.request("/rooms/\(code)"),
                   let fresh = try? JSONDecoder().decode(TVRoomState.self, from: data) {
                    self.room = fresh
                } else if beats > 3, self.room != nil {
                    // Room closed (404) or gone: stop following.
                    if (try? await self.request("/rooms/\(code)")) == nil {
                        self.errorMessage = "The room has ended."
                        await self.leave()
                        return
                    }
                }
                beats += 1
                if beats % 30 == 0 { _ = try? await self.request("/rooms/\(code)/heartbeat", method: "POST") }
                self.follow()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// One follow step: the sync engine decides, the player does it.
    private func follow() {
        guard followHost, let r = room else { drift = nil; return }
        let player = TVPlayerModel.shared
        let now = Date().timeIntervalSince1970
        let key = r.track_url ?? ""
        let host = TogetherHost(trackKey: key, position: r.position_seconds ?? 0, playing: r.is_playing ?? false,
                                asOfServer: Self.date(r.updated_at)?.timeIntervalSince1970 ?? now + sync.clockOffset())
        let local = TogetherLocal(trackKey: player.togetherKey, position: player.position, playing: player.isPlaying, now: now)
        let action = sync.decide(host: host, local: local)
        drift = local.trackKey == key ? action.drift : nil
        switch action.kind {
        case .hold: break
        case .load:
            guard loadingKey != key, let item = resolve(key: key, title: r.title ?? "", artist: r.artist ?? "") else {
                if loadingKey != key { errorMessage = "The host is playing “\(r.title ?? "a track")”, which this TV can't find." }
                return
            }
            loadingKey = key
            player.playForRoom(item, key: key, at: action.position)
        case .seek: player.seek(to: action.position)
        case .play:
            player.seek(to: action.position)
            player.resumePlayback()
        case .pause: player.pausePlayback()
        case .nudge: player.setTogetherRate(action.rate)
        }
    }

    /// The host's track for this TV: a cloud-library copy, else the stream.
    private func resolve(key: String, title: String, artist: String) -> TVPlayable? {
        guard let client, let token else { return nil }
        if let t = client.library.first(where: { togetherTrackKey(sourceTrackId: nil, title: $0.title, artist: $0.artist) == key
                                                 || togetherTrackKey(sourceTrackId: nil, title: $0.title, artist: $0.artist) == togetherTrackKey(sourceTrackId: nil, title: title, artist: artist) }),
           let p = client.playable(from: t, token: token) {
            return p
        }
        guard !key.hasPrefix("lumi:") else { return nil }
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] != "bandcamp" else { return nil }
        let track = TVTrack(id: String(parts[1]), title: title, artist: artist, durationSeconds: 0,
                            thumbnailURL: "", source: String(parts[0]), youtubeURL: "")
        return client.playable(from: track)
    }
}

// MARK: - TVListenTogetherView

struct TVListenTogetherView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    @ObservedObject private var rooms = TVListenTogether.shared
    @ObservedObject private var player = TVPlayerModel.shared
    @State private var code = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVMetrics.section) {
                TVScreenTitle(title: "Listen Together", eyebrow: "With friends")
                if let room = rooms.room {
                    inRoom(room)
                } else {
                    joinPanel
                }
                if let error = rooms.errorMessage {
                    Text(error)
                        .font(TVType.rowDetail)
                        .foregroundStyle(TVPalette.neonAlt)
                        .padding(.horizontal, TVMetrics.margin)
                }
            }
            .padding(.bottom, 80)
        }
        .tvAmbientBackground()
    }

    private var joinPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Enter the six-letter code a friend shared from Now Playing on their iPhone. This TV then plays along with them — same track, same moment.")
                .font(TVType.rowDetail)
                .foregroundStyle(TVPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 24) {
                TextField("Room code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .frame(width: 420)
                Button("Join") {
                    Task { await rooms.join(code: code, client: client, token: token) }
                }
                .disabled(code.trimmingCharacters(in: .whitespaces).count != 6)
            }
        }
        .padding(30)
        .frame(maxWidth: 1300, alignment: .leading)
        .tvGlassPanel(cornerRadius: 30)
        .padding(.horizontal, TVMetrics.margin)
    }

    private func inRoom(_ room: TVRoomState) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ROOM \(room.room_code)")
                    .font(TVType.eyebrow)
                    .tracking(2.4)
                    .foregroundStyle(TVPalette.neonAlt)
                Text(room.title ?? "Waiting for the host")
                    .font(TVType.display)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let artist = room.artist, !artist.isEmpty {
                    Text(artist).font(.system(size: 30, weight: .medium)).foregroundStyle(TVPalette.textSecondary)
                }
                Text(syncLabel)
                    .font(TVType.rowDetail)
                    .foregroundStyle(TVPalette.textTertiary)
            }
            HStack(spacing: 20) {
                Button(rooms.followHost ? "Following the host" : "Not following") { rooms.followHost.toggle() }
                ForEach(["🔥", "❤️", "🎉", "👏", "😮"], id: \.self) { e in
                    Button(e) { rooms.react(e) }
                }
                Button("Leave") { Task { await rooms.leave() } }
            }
            if let people = room.participants, !people.isEmpty {
                Text("Listening: " + people.map(\.name).joined(separator: ", "))
                    .font(TVType.rowDetail)
                    .foregroundStyle(TVPalette.textSecondary)
            }
        }
        .padding(30)
        .frame(maxWidth: 1500, alignment: .leading)
        .tvGlassPanel(cornerRadius: 30)
        .padding(.horizontal, TVMetrics.margin)
    }

    private var syncLabel: String {
        guard rooms.followHost else { return "Playing your own music — the room carries on without you." }
        guard let d = rooms.drift else { return "Starting the host's track…" }
        if abs(d) < 0.08 { return "In step with the host" }
        return String(format: "Catching up · %.1f s %@", abs(d), d > 0 ? "ahead" : "behind")
    }
}
