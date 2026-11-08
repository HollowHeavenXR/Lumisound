import Foundation

/// Smart Shuffle's skip history across the account's devices
/// (`POST /user/skip-history`). Changes made here go up, changes made on
/// other devices come down; batching and the merge (newer change wins per
/// song) live in the Rust core (rust/core/src/stores.rs). Quiet on failure:
/// unsent changes stay marked and go with the next sync.
extension AccountService {
    @MainActor private static var skipSyncInFlight = false

    func syncSkipHistory() async {
        guard isLoggedIn, !Self.skipSyncInFlight else { return }
        Self.skipSyncInFlight = true
        defer { Self.skipSyncInFlight = false }
        let batch = skipSyncBatch()
        do {
            // Safe to retry: the server keeps the newer entry, so a repeat is a no-op.
            let reply = try await _makeRequest("/user/skip-history", method: "POST",
                                               bodyData: batch.body, timeout: 20, maxAttempts: 2)
            let changed = skipSyncApply(response: reply, token: batch.token)
            if changed > 0 {
                appLog("Skip history: \(changed) song(s) updated from other devices", category: "account")
            }
        } catch {
            appLog("syncSkipHistory failed: \(error.localizedDescription)", category: "account")
        }
    }
}
