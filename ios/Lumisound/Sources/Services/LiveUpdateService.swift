import Foundation
import UIKit

/// The account's live event socket (`/ws/live`). Connection, ping,
/// reconnect/backoff and event parsing run in the Rust core (`LiveSocket`);
/// this forwards typed events to the app on the main actor.
@MainActor
final class LiveUpdateService: NSObject {
    static let shared = LiveUpdateService()

    var onPresenceEvent: ((SocialPresence) -> Void)?
    var onNotificationEvent: (() -> Void)?
    var onSyncChangedEvent: (() -> Void)?
    var onRoomEvent: (([String: Any]) -> Void)?

    private let socket = LiveSocket()
    private lazy var relay = Relay(owner: self)

    private override init() { super.init() }

    func start(bridgeURL: String, token: String) {
        socket.start(bridgeUrl: bridgeURL, token: token, listener: relay)
        appLog("LiveUpdateService: connecting", category: "network")
    }

    func stop() {
        socket.stop()
    }

    fileprivate func handle(_ event: LiveEvent) {
        switch event {
        case .presence(let p):
            onPresenceEvent?(SocialPresence(
                userId: p.userId, online: p.online, isPlaying: p.isPlaying,
                nowPlayingTitle: p.nowPlayingTitle, nowPlayingArtist: p.nowPlayingArtist,
                nowPlayingArtworkURL: p.nowPlayingArtworkUrl, lastSeenAt: nil))
        case .notification:
            onNotificationEvent?()
        case .syncChanged:
            onSyncChangedEvent?()
        case .room(_, let json):
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                onRoomEvent?(obj)
            }
        case .appearance(let style, let density):
            let d: Density = density == "compact" ? .compact : (density == "roomy" ? .roomy : .regular)
            Appearance.shared.apply(style: style, density: d, push: false)
        case .other:
            break
        }
    }

    /// Bridges core callbacks (any thread) onto the main actor.
    private final class Relay: LiveEventListener, @unchecked Sendable {
        weak var owner: LiveUpdateService?
        init(owner: LiveUpdateService) { self.owner = owner }

        func onEvent(event: LiveEvent) {
            Task { @MainActor [weak self] in self?.owner?.handle(event) }
        }

        func onConnection(connected: Bool) {
            if !connected {
                Task { @MainActor in appLog("LiveUpdateService: disconnected, reconnecting", category: "network") }
            }
        }
    }
}
