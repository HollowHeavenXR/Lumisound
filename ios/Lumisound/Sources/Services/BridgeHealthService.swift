import Foundation
import SwiftUI
import UIKit

// MARK: - BridgeHealthService

@MainActor
final class BridgeHealthService: ObservableObject {
    @Published private(set) var isHealthy: Bool? = nil   // nil = unchecked
    @Published private(set) var isAPIKeyValid: Bool? = nil
    @Published var showToast = false
    @Published var toastMessage = ""
    @Published var toastIsSuccess = false

    /// Mirrors `AccountService.shared`/`LibraryManager.shared` — gives
    /// non-view code (e.g. `DiagnosticsSnapshotService`) a way to reach the
    /// live instance without needing it threaded through as a parameter.
    static weak var shared: BridgeHealthService?

    init() {
        Self.shared = self
    }

    private var checkTimer: Timer?

    /// Timestamp of the last *completed* bridge health check (success or failure).
    /// Paired with `consecutiveFailures` to gate both the healthy-state cooldown
    /// and the failure backoff below.
    private var lastCheckTime: Date = .distantPast

    /// Consecutive failed checks. Drives an exponential backoff (60s, 120s,
    /// 240s... capped at 10 minutes) so a genuinely-offline bridge doesn't get
    /// hit by the 60-second timer on every single tick — a watchdog that just
    /// keeps re-triggering the same failure wastes battery/network for no
    /// benefit and was indistinguishable from a hang to the user. Resets to 0
    /// the moment a check succeeds, so recovery is detected within one minute.
    private var consecutiveFailures = 0

    func startPeriodicChecks(streaming: StreamingService) {
        stopPeriodicChecks()
        appLog("startPeriodicChecks: bridge=\(streaming.bridgeURL)", category: "network")
        checkTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // The health indicator is only meaningful while the user is in the
                // app — skip the network probe when backgrounded to save radio/
                // battery during background audio playback. The immediate check on
                // the next foreground `startPeriodicChecks` re-establishes status.
                guard UIApplication.shared.applicationState == .active else { return }
                await self?.check(streaming: streaming)
            }
        }
        // Lets iOS batch this wake-up with others (battery).
        checkTimer?.tolerance = (60) * 0.1
        Task { await check(streaming: streaming) }  // immediate first check
    }

    func stopPeriodicChecks() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    func check(streaming: StreamingService) async {
        let prevHealthy = isHealthy
        let now = Date()

        if prevHealthy == true {
            // Healthy cooldown — skip the round-trip if we checked within 30s.
            if now.timeIntervalSince(lastCheckTime) < 30.0 {
                appLog("BridgeHealth: skipping check (cooldown active)", category: "network")
                return
            }
        } else if consecutiveFailures > 0 {
            // Failure backoff — space consecutive retries out exponentially
            // instead of hammering a dead server every 60s indefinitely.
            let backoff = min(60.0 * pow(2.0, Double(consecutiveFailures - 1)), 600.0)
            if now.timeIntervalSince(lastCheckTime) < backoff {
                appLog("BridgeHealth: skipping check (backoff \(Int(backoff))s after \(consecutiveFailures) failure(s))", category: "network")
                return
            }
        }

        let healthy = await streaming.checkHealth()
        lastCheckTime = now
        consecutiveFailures = healthy ? 0 : consecutiveFailures + 1
        isHealthy = healthy

        if healthy && !streaming.apiKey.isEmpty {
            do {
                isAPIKeyValid = try await checkAPIKey(streaming: streaming)
                if isAPIKeyValid == false {
                    appWarn("checkAPIKey: key rejected by server", category: "network")
                }
            } catch {
                appWarn("checkAPIKey: error \(error.localizedDescription)", category: "network")
                isAPIKeyValid = false
            }
        } else if healthy {
            isAPIKeyValid = nil  // No key configured — open access
        }

        // Log status changes (not every routine check)
        if prevHealthy != healthy {
            if healthy {
                appLog("Bridge server connected (\(streaming.bridgeURL))", category: "network")
            } else {
                appWarn("Bridge server offline (\(streaming.bridgeURL))", category: "network")
            }
        }

        // Show toast on status change
        if prevHealthy != nil && prevHealthy != healthy {
            toastMessage = healthy ? "✓ Streaming connected" : "⚠ Streaming unavailable"
            toastIsSuccess = healthy
            showToast = true
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            showToast = false
        }
    }

    private func checkAPIKey(streaming: StreamingService) async throws -> Bool {
        // Simple check: hit /health with the API key header already applied by makePublicRequest
        guard let req = streaming.makePublicRequest("/health") else { return false }
        let (_, resp) = try await Core.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: - ToastView

struct ToastView: View {
    let message: String
    let isSuccess: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isSuccess ? AppTheme.success : AppTheme.warning)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .adaptiveGlass(in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}
