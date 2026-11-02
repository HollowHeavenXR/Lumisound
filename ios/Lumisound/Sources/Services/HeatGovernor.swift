import Foundation
import UIKit

/// Swift shell around the Rust core's heat governor (rust/core/src/thermal.rs).
/// The core owns the state, the policy (what may animate, analyzer rates,
/// which jobs wait), the per-buffer analyzer rate limit, headroom waits and
/// statistics. This only feeds it the system signals (ProcessInfo thermal
/// state, Low Power Mode, foreground/background), mirrors the policy for
/// SwiftUI, and attaches app context to the telemetry event it asks for.
/// Playback is never throttled.
@MainActor
final class HeatGovernor: ObservableObject {
    static let shared = HeatGovernor()
    /// The core governor, for the audio tap thread (lock-free `wantsSample`).
    nonisolated(unsafe) static let core = thermalGovernor()

    @Published private(set) var policy: ThermalPolicy
    private var foreground = true

    private init() {
        let info = ProcessInfo.processInfo
        _ = Self.core.update(thermalRaw: Int64(info.thermalState.rawValue), lowPower: info.isLowPowerModeEnabled, foreground: true)
        policy = Self.core.policy()
        let nc = NotificationCenter.default
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HeatGovernor.shared.refresh(trigger: "thermal") }
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HeatGovernor.shared.refresh(trigger: "power") }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HeatGovernor.shared.foreground = false; HeatGovernor.shared.refresh(trigger: "background") }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HeatGovernor.shared.foreground = true; HeatGovernor.shared.refresh(trigger: "foreground") }
        }
    }

    var deferHeavyWork: Bool { Self.core.deferHeavyWork() }

    /// For deferrable heavy jobs (decision and waiting in the core). False =
    /// still hot after `maxWait`: skip this round.
    nonisolated static func waitForHeadroom(job: String, maxWait: TimeInterval = 0) async -> Bool {
        await core.waitForHeadroom(job: job, maxWaitSecs: maxWait)
    }

    private func refresh(trigger: String) {
        let info = ProcessInfo.processInfo
        guard let change = Self.core.update(thermalRaw: Int64(info.thermalState.rawValue),
                                            lowPower: info.isLowPowerModeEnabled, foreground: foreground) else { return }
        policy = change.policy
        appLog("HeatGovernor: \(change.previousLabel) → \(change.policy.label) (\(trigger))", category: "performance")
        if change.shouldReport { report(change, trigger: trigger) }
    }

    /// What was running when the device heated up or cooled down.
    private func report(_ change: ThermalChange, trigger: String) {
        let stats = Self.core.stats()
        var detail: [String: Any] = [
            "policy": change.policy.label,
            "previous": change.previousLabel,
            "trigger": trigger,
            "thermalRaw": stats.thermalRaw,
            "lowPower": stats.lowPower,
            "foreground": stats.foreground,
            "secondsByLevel": stats.secondsByLevel.map { Int($0) },
            "policyChanges": stats.policyChanges,
            "analyzerHz": stats.analyzerHz,
            "analysisReasons": stats.analysisReasons,
            "deferrals": stats.deferrals.map { ["job": $0.job, "deferred": $0.deferred, "skipped": $0.skipped] },
        ]
        if let player = AudioPlayerManager.shared {
            detail["isPlaying"] = player.isPlaying
            detail["engine"] = player.isUsingRustEngine ? "lumisound" : "avaudioengine"
            detail["playback"] = player.engineContext()
            if player.isUsingRustEngine { detail["engineHealth"] = AudioPlayerManager.engineHealthSnapshot() }
        }
        if let bg = BackgroundService.shared {
            detail["galleryBackground"] = [
                "enabled": bg.isEnabled,
                "source": UserDefaults.standard.string(forKey: GalleryBackgroundSource.storageKey) ?? "photos",
                "kenBurns": bg.kenBurnsEnabled,
                "imageCount": bg.images.count,
            ]
        }
        if let library = LibraryManager.shared {
            detail["libraryScanning"] = library.isScanning
            detail["songCount"] = library.allSongs.count
        }
        detail["moodAnalyzing"] = MoodPlaylistService.shared?.isAnalyzing ?? false
        RemoteLogger.log(category: "performance", event: "thermal_state_changed", level: change.level,
                         message: "\(change.previousLabel) → \(change.policy.label) (\(trigger))", detail: detail)
    }
}
