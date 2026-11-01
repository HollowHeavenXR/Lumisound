import Foundation

// MARK: - RemoteLogger

/// Fire-and-forget client for `POST /api/log-event` — the bridge's
/// general-purpose, structured, cross-system event log (see `db.log_event` /
/// `ios_app_event_log` on the server side).
///
/// Distinct from `AppLogger`/`appLog(_:category:)`: `AppLogger` buffers
/// arbitrary debug-log lines (with file/line) and flushes them in bulk to
/// `/internal/logs` every 30 seconds — good for "what was happening right
/// before this crashed" diagnostics. `RemoteLogger` instead sends one
/// meaningful lifecycle event at a time — a scan finishing, a backup
/// completing, a force-sync summary — tagged with a short, low-cardinality
/// `category`/`event` pair plus an optional structured `detail` payload, so
/// it can be queried and correlated server-side across the whole app (both
/// the bridge and every client) rather than just this device's console.
///
/// Any Lumisound service can adopt this the same way: call `RemoteLogger.log`
/// once per meaningful operation (never per item in a loop — see the
/// per-batch guidance below), and it reaches `ios_app_event_log` without
/// each call site needing to roll its own networking.
///
/// Always fire-and-forget: `log(...)` returns immediately, never throws, and
/// never blocks the caller — logging must never be able to slow down or fail
/// the operation it's describing. Safe to call from any thread/actor/context
/// (including tight loops that already batch their *other* work — but see
/// the batching note below, since this still performs a real network call).
///
/// IMPORTANT — do not call this once per item inside a loop over a large
/// library. A per-track (or per-song, per-file) call here would repeat the
/// same "blocking call in a tight loop over a big collection" bug class
/// that has caused main-thread hangs in this codebase before (see
/// LibraryManager's periodic scan/refresh sweeps): call it once per batch or
/// once at the start/end of the whole operation, with a `detail` payload
/// summarizing counts, instead.
enum RemoteLogger {

    /// Sends one structured event to the bridge. Fire-and-forget — the
    /// caller does not need to (and should not) await this. Delivery (and
    /// the platform/build/OS stamp) is the Rust core's `logger_event`.
    ///
    /// - Parameters:
    ///   - category: Short, low-cardinality label, e.g. "sync", "backup", "library", "account".
    ///   - event: Short event name, e.g. "scan_completed", "backup_exported".
    ///   - level: "info" (default), "warn", or "error".
    ///   - message: Free-form human-readable summary.
    ///   - detail: Optional JSON-serializable payload (counts, durations, ids).
    ///   - authToken: Token to attribute the event to, overriding the live
    ///     `AccountService.shared?.token` — callers about to clear the session
    ///     (logout, expiry, deletion) snapshot it first.
    static func log(
        category: String,
        event: String,
        level: String = "info",
        message: String = "",
        detail: [String: Any]? = nil,
        authToken: String? = nil
    ) {
        let json = detail.flatMap { d -> String? in
            guard JSONSerialization.isValidJSONObject(d),
                  let data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        Task { @MainActor in
            loggerEvent(category: category, event: event, level: level, message: message,
                        detailJson: json, authToken: authToken ?? AccountService.shared?.token)
        }
    }

    /// Convenience for the common "something failed" case.
    static func logError(
        category: String,
        event: String,
        message: String,
        detail: [String: Any]? = nil,
        authToken: String? = nil
    ) {
        log(category: category, event: event, level: "error", message: message,
            detail: detail, authToken: authToken)
    }
}
