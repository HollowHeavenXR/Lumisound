import AVFoundation
import Foundation
import UIKit

/// Guardrails that keep the Lumisound Audio Engine's output alive.
///
/// iOS stops an app's audio output when another app takes the session, when
/// the route changes (Bluetooth drops / reconnects, AirPlay), and when media
/// services reset. The engine's output stream doesn't come back on its own:
/// before this, playback "continued" (position frozen, controls dead) or a
/// reconnected Bluetooth device stayed silent until the user paused and
/// played again. The engine now reports whether its output callback is
/// running (`outputAlive`); the app restarts the stream:
///
/// * when an interruption ends, on every route change and on media-services
///   reset (iOS told us);
/// * when the app returns to the foreground;
/// * from a 1 s watchdog while playing — the backstop for anything iOS
///   doesn't announce (a silent route rebind, a stream that just stops);
/// * right before every play.
///
/// Each restart is reported (`audio_engine/output_restarted`) with its reason.
extension AudioPlayerManager {
    private static var guardTimer: Timer?
    private static var guardObservers: [NSObjectProtocol] = []
    private static var recentRestarts: [Date] = []

    /// Starts the watchdog and lifecycle observers (idempotent).
    func startEngineGuard() {
        guard Self.guardTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkRustOutput(reason: "watchdog") }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        Self.guardTimer = t
        let nc = NotificationCenter.default
        Self.guardObservers = [
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkRustOutput(reason: "foreground") }
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartRustOutput(reason: "media_services_reset", force: true) }
            },
        ]
    }

    /// Restart the output if the engine is in use, should be making sound,
    /// and its callback hasn't run for 1.5 s.
    func checkRustOutput(reason: String) {
        guard isUsingRustEngine, rustOutputStarted, isPlaying else { return }
        if !Self.rust.outputAlive(maxAgeMs: 1500) {
            restartRustOutput(reason: reason, force: true)
        }
    }

    /// Re-activates the session and reopens the engine's output on the
    /// current route. `force` = even if the callback looks alive (route
    /// changes: a live stream may be bound to the old device).
    func restartRustOutput(reason: String, force: Bool) {
        guard isUsingRustEngine, rustOutputStarted else { return }
        if !force, Self.rust.outputAlive(maxAgeMs: 1500) { return }
        // A restart storm means something deeper is wrong: back off to every
        // 5 s instead of hammering CoreAudio, and say so in telemetry.
        let now = Date()
        Self.recentRestarts = Self.recentRestarts.filter { now.timeIntervalSince($0) < 30 }
        if Self.recentRestarts.count >= 4, let last = Self.recentRestarts.last, now.timeIntervalSince(last) < 5 {
            return
        }
        Self.recentRestarts.append(now)
        let wasAlive = Self.rust.outputAlive(maxAgeMs: 1500)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            appWarn("Engine guard (\(reason)): session not available yet — \(error.localizedDescription)", category: "audio")
        }
        var ok = true
        var failure: String?
        do {
            try Self.rust.restartOutput()
        } catch {
            ok = false
            failure = error.localizedDescription
        }
        appLog("Engine guard: output restarted (\(reason))\(ok ? "" : " — failed: \(failure ?? "?")")", category: "audio")
        var detail = engineContext()
        detail["reason"] = reason
        detail["callbackWasAlive"] = wasAlive
        detail["ok"] = ok
        detail["restartsLast30s"] = Self.recentRestarts.count
        if let failure { detail["error"] = failure }
        RemoteLogger.log(category: "audio_engine", event: "output_restarted", level: ok ? "info" : "error",
                         message: "\(reason)\(ok ? "" : ": \(failure ?? "")")", detail: detail)
    }
}
