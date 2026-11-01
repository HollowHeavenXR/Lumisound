import Foundation
import UIKit

extension StreamingService {

    // MARK: - Health Check

    /// A single dropped packet or momentary DNS hiccup (a wifi/cellular
    /// handoff, the phone waking from a long suspension with a stale network
    /// path, etc.) used to fail this check outright with zero retries —
    /// `BridgeHealthService` treated that one failed request as "the bridge
    /// is down" and immediately surfaced the alarming "Streaming unavailable"
    /// toast, even though the exact same request a moment later would have
    /// succeeded. Routing through `NetworkRetry` (already used everywhere
    /// else in the app for exactly this class of transient failure) means a
    /// real outage still gets reported — just not a one-off blip.
    func checkHealth() async -> Bool {
        guard isConfigured, let request = makeRequest("/health") else { return false }
        do {
            return try await NetworkRetry.withRetry(maxAttempts: 3, baseDelay: 0.5) {
                let (_, response) = try await Core.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw StreamingError.httpError(httpResponse.statusCode)
                }
                return true
            }
        } catch {
            return false
        }
    }
}
