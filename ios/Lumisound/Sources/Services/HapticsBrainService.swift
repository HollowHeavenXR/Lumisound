import Combine
import Foundation
import UIKit

/// Haptics Brain, app side (core rust/core/src/haptic_brain.rs; bridge
/// routes/haptics.rs). Every track that plays is observed in the background
/// — whether or not Music Haptics is switched on — so the brain keeps
/// learning beats for everyone; what this device learns goes to the bridge,
/// which merges it with every other listener's and sends back the global
/// model. MusicHapticsService plays `hapticBrainApply(score:)`.
@MainActor
final class HapticsBrainService {
    static let shared = HapticsBrainService()

    private var songObserver: AnyCancellable?
    private var syncTimer: Timer?
    private var observing = false
    private var observed = Set<String>()
    private weak var account: AccountService?

    private init() {}

    func start(player: AudioPlayerManager, account: AccountService) {
        guard songObserver == nil else { return }
        self.account = account
        songObserver = player.$currentSong
            .compactMap { $0 }
            .removeDuplicates(by: { $0.id == $1.id })
            .sink { [weak self] song in
                Task { @MainActor [weak self] in self?.observe(song) }
            }
        let t = Timer(timeInterval: 20 * 60, repeats: true) { _ in
            Task { @MainActor in await HapticsBrainService.shared.sync() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        syncTimer = t
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await HapticsBrainService.shared.sync() }
        }
        Task { await fetchModel() }
    }

    /// Learn from a track in the background (once per song per launch;
    /// analysis is cached, so later observations are cheap).
    private func observe(_ song: Song) {
        guard !observing, !observed.contains(song.id), let url = song.url, url.isFileURL else { return }
        observing = true
        observed.insert(song.id)
        let path = url.standardizedFileURL.path
        let key = "\(song.title)|\(song.artist)|\(Int(song.duration.rounded()))"
        Task.detached(priority: .background) {
            // Never compete with a hot phone: wait for headroom, else skip.
            if await HeatGovernor.waitForHeadroom(job: "hapticsBrain", maxWait: 30) {
                // Give the playing track's own work (start, haptics, analysis) a head start.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let l = hapticBrainObserve(path: path, trackKey: key) {
                    await MainActor.run {
                        appLog(String(format: "Haptics Brain: learned \"%@\" — %.0f BPM, confidence %.2f, offset %+.0f ms, groove F1 %.2f → %.2f",
                                      song.displayName, l.period > 0 ? 60 / l.period : 0, l.confidence, l.offset * 1000,
                                      l.gridF1Before, l.gridF1After), category: "audio")
                    }
                }
            }
            await MainActor.run { HapticsBrainService.shared.observing = false }
        }
    }

    /// Send what was learned; adopt the global model and consensus back.
    func sync() async {
        guard let account, account.isLoggedIn, let body = hapticBrainOutbox() else { return }
        do {
            let data = try await account._makeRequest("/user/haptics/learn", method: "POST", bodyData: body, timeout: 30)
            hapticBrainOutboxSent(response: data)
        } catch {
            appWarn("Haptics Brain sync failed: \(error.localizedDescription)", category: "network")
        }
    }

    private func fetchModel() async {
        guard let account, account.isLoggedIn else { return }
        guard let data = try? await account.makeRequest("/user/haptics/model"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = obj["model"], let json = try? JSONSerialization.data(withJSONObject: model) else { return }
        _ = hapticBrainSetModel(json: json)
    }
}
