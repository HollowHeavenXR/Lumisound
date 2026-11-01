import Foundation

// MARK: - TVAppLogger
//
// Same Rust-core logger as iOS's AppLogger (rust/core/src/logger.rs):
// buffered upload to /internal/logs, repeat collapsing, crash breadcrumbs.
// `log()`/`warn()`/`error()` are `nonisolated` and never block the caller.

@MainActor
final class TVAppLogger: ObservableObject {

    static let shared = TVAppLogger()

    private static let legacyBreadcrumbsKey = "tv.crash_breadcrumbs_v1"
    private var isConfigured = false

    private init() {}

    nonisolated static func preciseISO8601Now() -> String { logTimestampNow() }

    /// Call once on app launch. Subsequent calls are no-ops.
    func configure(bridgeURL: String) {
        guard !isConfigured else { return }
        isConfigured = true
        let legacy = UserDefaults.standard.stringArray(forKey: Self.legacyBreadcrumbsKey) ?? []
        UserDefaults.standard.removeObject(forKey: Self.legacyBreadcrumbsKey)
        loggerConfigure(ctx: LogContext(
            bridgeUrl: bridgeURL, platform: "tvos", deviceModel: TVDeviceInfo.modelIdentifier,
            osVersion: TVDeviceInfo.osVersion, appVersion: TVDeviceInfo.appVersion,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"),
            legacyBreadcrumbs: legacy)
    }

    nonisolated func breadcrumb(_ event: String) {
        loggerBreadcrumb(event: event)
    }

    nonisolated func log(
        _ message: String,
        level: String = "info",
        category: String = "general",
        file: String = #file,
        line: Int = #line,
        extra: [String: String] = [:]
    ) {
        #if DEBUG
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[\(level.uppercased())][\(category)] \(message)\(suffix)")
        #endif
        Task { @MainActor in
            loggerLog(level: level, category: category, message: message, file: file, line: Int64(line),
                      extra: extra, localOnly: false,
                      userId: TVAccount.shared.token.flatMap { TVJWT.subject(from: $0) })
        }
    }

    nonisolated func warn(_ message: String, category: String = "general",
                          file: String = #file, line: Int = #line, extra: [String: String] = [:]) {
        log(message, level: "warning", category: category, file: file, line: line, extra: extra)
    }

    nonisolated func error(_ message: String, category: String = "general",
                           file: String = #file, line: Int = #line, extra: [String: String] = [:]) {
        log(message, level: "error", category: category, file: file, line: line, extra: extra)
    }

    func recentActivitySummary() -> String {
        loggerRecentActivity()
    }
}

func tvLog(_ message: String, category: String = "general",
           file: String = #file, line: Int = #line, extra: [String: String] = [:]) {
    TVAppLogger.shared.log(message, level: "info", category: category, file: file, line: line, extra: extra)
}

func tvWarn(_ message: String, category: String = "general",
            file: String = #file, line: Int = #line, extra: [String: String] = [:]) {
    TVAppLogger.shared.warn(message, category: category, file: file, line: line, extra: extra)
}

func tvError(_ message: String, category: String = "general",
             file: String = #file, line: Int = #line, extra: [String: String] = [:]) {
    TVAppLogger.shared.error(message, category: category, file: file, line: line, extra: extra)
}

func tvBreadcrumb(_ event: String) {
    TVAppLogger.shared.breadcrumb(event)
}
