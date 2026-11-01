import Foundation

// MARK: - TVRemoteLogger
//
// Ported from ios/Lumisound/Sources/Services/RemoteLogger.swift — same
// POST /api/log-event shape and same distinction from TVAppLogger: this is
// for discrete, meaningful *user activity* (logged in, favorited a track,
// created a playlist, revoked a session) rather than bulk debug-log lines.
// One call per meaningful action, never per item in a loop.

enum TVRemoteLogger {

    /// Fire-and-forget — the caller does not need to (and should not) await this.
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

    @MainActor
    private static func send(
        category: String,
        event: String,
        level: String,
        message: String,
        detail: [String: Any]?,
        authToken: String?
    ) async {
        let base = TVBridgeClient.shared.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/log-event") else { return }

        // Stamp EVERY event with platform + build, merged into `detail`.
        //
        // The bridge records `/api/log-event` with source="ios_client"
        // regardless of who sent it, and the event log has no device column,
        // so tvOS events were previously indistinguishable from iPhone ones —
        // a query for "what is the Apple TV doing" could not be written at
        // all. Stamping here rather than at the ~20 call sites means it
        // cannot be forgotten on a new one.
        var enriched = detail ?? [:]
        enriched["platform"] = "tvos"
        enriched["appVersion"] = TVDeviceInfo.appVersion
        enriched["tvosVersion"] = TVDeviceInfo.osVersion
        enriched["deviceModel"] = TVDeviceInfo.modelIdentifier

        let payload: [String: Any] = [
            "category": category,
            "event": event,
            "level": level,
            "message": message,
            "detail": enriched,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Best-effort auth, same as iOS's RemoteLogger — an anonymous event
        // (e.g. logged out already) still gets recorded server-side, just
        // without a user_id attached. Prefer the caller's explicit snapshot
        // over the live token, which may already have been cleared by the
        // time this async call actually runs (e.g. logout).
        if let token = authToken ?? TVAccount.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        _ = try? await Core.data(for: request)
    }
}
