import Foundation

// MARK: - AppLogger

/// Application logger. Buffering, identical-repeat collapsing, the bug-report
/// "recent activity" buffer, crash breadcrumbs and the upload to the bridge's
/// `/internal/logs` (every 15 s, immediately on errors, requeued on failure)
/// all run in the Rust core (rust/core/src/logger.rs).
///
/// `log()` / `warn()` / `error()` are `nonisolated` and never block the caller.
/// The entry hops to the main actor only to read who is logged in at the time
/// the line was written (not at upload time).
@MainActor
final class AppLogger: ObservableObject {

    static let shared = AppLogger()

    private static let legacyBreadcrumbsKey = "crash_breadcrumbs_v1"
    private var isConfigured = false

    private init() {}

    /// ISO 8601 with milliseconds.
    nonisolated static func preciseISO8601Now() -> String { logTimestampNow() }

    /// Call once on app launch. Subsequent calls are no-ops. Reports a
    /// breadcrumb trail left by a session that didn't shut down cleanly.
    func configure(bridgeURL: String) {
        guard !isConfigured else { return }
        isConfigured = true
        let legacy = UserDefaults.standard.stringArray(forKey: Self.legacyBreadcrumbsKey) ?? []
        UserDefaults.standard.removeObject(forKey: Self.legacyBreadcrumbsKey)
        loggerConfigure(ctx: LogContext(
            bridgeUrl: bridgeURL, platform: "ios", deviceModel: DeviceInfo.modelIdentifier,
            osVersion: DeviceInfo.osVersion, appVersion: DeviceInfo.appVersion,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"),
            legacyBreadcrumbs: legacy)
    }

    /// A short description of a significant action (scan started, tab
    /// switched…), persisted immediately so a crash leaves it for the next
    /// launch to report. Not for high-frequency events.
    nonisolated func breadcrumb(_ event: String) {
        loggerBreadcrumb(event: event)
    }

    nonisolated func log(
        _ message: String,
        level: String = "info",
        category: String = "general",
        file: String = #file,
        line: Int = #line,
        extra: [String: String] = [:],
        localOnly: Bool = false
    ) {
        #if DEBUG
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[\(level.uppercased())][\(category)] \(message)\(suffix)")
        #endif
        Task { @MainActor in
            loggerLog(level: level, category: category, message: message, file: file, line: Int64(line),
                      extra: extra, localOnly: localOnly, userId: AccountService.shared?.currentUser?.id)
        }
    }

    nonisolated func warn(_ message: String, category: String = "general",
                          file: String = #file, line: Int = #line, extra: [String: String] = [:]) {
        log(message, level: "warning", category: category, file: file, line: line, extra: extra)
    }

    /// Errors upload immediately so they survive an imminent termination.
    nonisolated func error(_ message: String, category: String = "general",
                           file: String = #file, line: Int = #line, extra: [String: String] = [:]) {
        log(message, level: "error", category: category, file: file, line: line, extra: extra)
    }

    /// Breadcrumbs plus recent log lines, attached to bug reports.
    func recentActivitySummary() -> String {
        loggerRecentActivity()
    }
}

// MARK: - Global convenience shims (callable without referencing the shared instance)

/// Logs an info-level message from any context. `localOnly: true` keeps the
/// line on this device (bug-report context only, never uploaded).
func appLog(_ message: String, category: String = "general",
            file: String = #file, line: Int = #line,
            extra: [String: String] = [:], localOnly: Bool = false) {
    AppLogger.shared.log(message, level: "info", category: category, file: file,
                         line: line, extra: extra, localOnly: localOnly)
}

func appWarn(_ message: String, category: String = "general",
             file: String = #file, line: Int = #line,
             extra: [String: String] = [:]) {
    AppLogger.shared.warn(message, category: category, file: file, line: line, extra: extra)
}

func appError(_ message: String, category: String = "general",
              file: String = #file, line: Int = #line,
              extra: [String: String] = [:]) {
    AppLogger.shared.error(message, category: category, file: file, line: line, extra: extra)
}

/// Records a breadcrumb for crash-context reporting on the next launch.
func appBreadcrumb(_ event: String) {
    AppLogger.shared.breadcrumb(event)
}
