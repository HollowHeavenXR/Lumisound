import Foundation
import UIKit

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
    /// caller does not need to (and should not) await this.
    ///
    /// - Parameters:
    ///   - category: Short, low-cardinality label, e.g. "sync", "backup", "library", "account".
    ///   - event: Short event name, e.g. "scan_completed", "backup_exported".
    ///   - level: "info" (default), "warn", or "error".
    ///   - message: Free-form human-readable summary.
    ///   - detail: Optional structured payload (counts, durations, ids). Must
    ///     be a JSON-serializable dictionary (String/Number/Bool/Array/Dictionary/NSNull values).
    ///   - authToken: Explicit bearer token to attribute this event to, overriding
    ///     the live `AccountService.shared?.token` lookup. Since this call is
    ///     fire-and-forget, its network request runs on a later run-loop turn —
    ///     a caller that's about to clear the session token (logout, session
    ///     expiry, account deletion) must snapshot it *before* clearing and
    ///     pass it here, or the event would race the clear and lose its
    ///     user attribution entirely.
    static func log(
        category: String,
        event: String,
        level: String = "info",
        message: String = "",
        detail: [String: Any]? = nil,
        authToken: String? = nil
    ) {
        Task { @MainActor in
            await send(category: category, event: event, level: level, message: message,
                       detail: detail, authToken: authToken)
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

    // MARK: - Private

    @MainActor
    private static func send(
        category: String,
        event: String,
        level: String,
        message: String,
        detail: [String: Any]?,
        authToken: String?
    ) async {
        let base = (UserDefaults.standard.string(forKey: StreamingService.bridgeURLKey)
                    ?? StreamingService.defaultBridgeURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/log-event") else { return }

        var payload: [String: Any] = [
            "category": category,
            "event": event,
            "level": level,
            "message": message,
        ]
        // Every event carries the build and device that produced it.
        //
        // iOS events had neither, so the log could not answer the one question
        // that matters after shipping a fix: is this report coming from a build
        // that contains it? That made "is it fixed?" unanswerable and left
        // stale reports from an old build looking identical to new failures.
        // tvOS has stamped these since its telemetry was written; this brings
        // iOS to the same footing.
        var enriched = detail ?? [:]
        enriched["platform"] = "ios"
        enriched["appVersion"] = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        enriched["build"] = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        enriched["osVersion"] = UIDevice.current.systemVersion
        payload["detail"] = enriched

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Best-effort auth — an anonymous/logged-out event still gets
        // recorded server-side (see api_log_event in main.py), just without
        // a user_id attached. Prefer the caller's explicit snapshot (see
        // `authToken` doc above) over the live value, which may already have
        // been cleared by the time this async call actually runs.
        if let token = authToken ?? AccountService.shared?.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Deliberately not retried and the result is discarded — this is
        // best-effort telemetry, not a mutation the app's correctness
        // depends on. A dropped log-event on a flaky connection is fine; a
        // retry storm from a background scan is not.
        _ = try? await Core.data(for: request)
    }
}
