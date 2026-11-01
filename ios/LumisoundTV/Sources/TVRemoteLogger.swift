import Foundation

// MARK: - TVRemoteLogger
//
// Discrete, meaningful user activity (logged in, favorited a track, created a
// playlist) for POST /api/log-event — one call per action, never per item in a
// loop. Delivery and the platform/build/device stamp are the Rust core's
// `logger_event` (shared with iOS's RemoteLogger).

enum TVRemoteLogger {

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
                        detailJson: json, authToken: authToken ?? TVAccount.shared.token)
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
}
