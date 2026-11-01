import Foundation

// MARK: - TVAppLogger
//
// Ported from ios/Lumisound/Sources/Services/AppLogger.swift — same
// buffered-batch-upload design, same POST /internal/logs shape (the bridge
// endpoint doesn't distinguish which client sent it), same crash-breadcrumb
// mechanism. `log()`/`warn()`/`error()` are `nonisolated` and safe to call
// from any thread/actor without `await`.

@MainActor
final class TVAppLogger: ObservableObject {

    static let shared = TVAppLogger()

    struct LogEntry: Codable {
        let level: String
        let category: String
        let message: String
        let file: String
        let line: Int
        let timestamp: String
        var extra: [String: String]
        var deviceModel: String = TVDeviceInfo.modelIdentifier
        var osVersion: String = TVDeviceInfo.osVersion
        var appVersion: String = TVDeviceInfo.appVersion
        var userId: String? = nil
    }

    private var buffer: [LogEntry] = []
    private let maxBuffer = 1_000
    private var recentEntries: [LogEntry] = []
    private let maxRecentEntries = 50
    private var flushTimer: Timer?
    private var bridgeURL: String = ""
    private var isConfigured = false

    private static let breadcrumbsKey = "tv.crash_breadcrumbs_v1"
    private let maxBreadcrumbs = 12
    private var breadcrumbs: [String] = []

    private init() {}

    nonisolated static func preciseISO8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// Call once on app launch. Subsequent calls are no-ops.
    func configure(bridgeURL: String) {
        guard !isConfigured else { return }
        isConfigured = true
        self.bridgeURL = bridgeURL
        reportPriorSessionBreadcrumbsIfAny()
        _append(LogEntry(level: "info", category: "app", message: "tvOS app launched",
                         file: "LumisoundTVApp.swift", line: 0,
                         timestamp: Self.preciseISO8601Now(), extra: [:]))
        startFlushTimer()
    }

    // MARK: Breadcrumbs

    nonisolated func breadcrumb(_ event: String) {
        Task { @MainActor [weak self] in self?._recordBreadcrumb(event) }
    }

    private func _recordBreadcrumb(_ event: String) {
        breadcrumbs.append("\(Self.preciseISO8601Now()) — \(event)")
        if breadcrumbs.count > maxBreadcrumbs {
            breadcrumbs.removeFirst(breadcrumbs.count - maxBreadcrumbs)
        }
        UserDefaults.standard.set(breadcrumbs, forKey: Self.breadcrumbsKey)
    }

    /// If a breadcrumb trail survived from a previous run, that session
    /// never reached a clean shutdown (crash, force-quit, tvOS termination)
    /// — log what it was doing right before, then clear the trail.
    private func reportPriorSessionBreadcrumbsIfAny() {
        guard let prior = UserDefaults.standard.stringArray(forKey: Self.breadcrumbsKey),
              !prior.isEmpty
        else { return }
        let summary = prior.joined(separator: "  →  ")
        _append(LogEntry(level: "warning", category: "app",
                         message: "Possible unclean shutdown — last actions before previous session ended: \(summary)",
                         file: "TVAppLogger.swift", line: 0,
                         timestamp: Self.preciseISO8601Now(), extra: [:]))
        UserDefaults.standard.removeObject(forKey: Self.breadcrumbsKey)
    }

    // MARK: Public log methods

    nonisolated func log(
        _ message: String,
        level: String = "info",
        category: String = "general",
        file: String = #file,
        line: Int = #line,
        extra: [String: String] = [:]
    ) {
        let shortFile = URL(fileURLWithPath: file).lastPathComponent
        let ts = Self.preciseISO8601Now()
        let entry = LogEntry(level: level, category: category, message: message,
                             file: shortFile, line: line, timestamp: ts, extra: extra)
        Task { @MainActor [weak self] in self?._append(entry) }
    }

    nonisolated func warn(
        _ message: String,
        category: String = "general",
        file: String = #file,
        line: Int = #line,
        extra: [String: String] = [:]
    ) {
        log(message, level: "warning", category: category, file: file, line: line, extra: extra)
    }

    nonisolated func error(
        _ message: String,
        category: String = "general",
        file: String = #file,
        line: Int = #line,
        extra: [String: String] = [:]
    ) {
        log(message, level: "error", category: category, file: file, line: line, extra: extra)
        Task { @MainActor [weak self] in await self?.flush() }
    }

    // MARK: Private

    private func _append(_ entry: LogEntry) {
        var entry = entry
        entry.userId = TVAccount.shared.token.flatMap { TVJWT.subject(from: $0) }
        buffer.append(entry)
        if buffer.count > maxBuffer {
            buffer.removeFirst(buffer.count - maxBuffer)
        }
        recentEntries.append(entry)
        if recentEntries.count > maxRecentEntries {
            recentEntries.removeFirst(recentEntries.count - maxRecentEntries)
        }
        #if DEBUG
        let extra = entry.extra.isEmpty ? "" : " \(entry.extra)"
        print("[\(entry.level.uppercased())][\(entry.category)] \(entry.message)\(extra)")
        #endif
    }

    private func startFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.flush() }
        }
    }

    private func flush() async {
        guard !buffer.isEmpty, !bridgeURL.isEmpty else { return }
        let entries = buffer
        buffer.removeAll()

        let base = bridgeURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(base)/internal/logs") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            req.httpBody = try JSONEncoder().encode(entries)
            let (_, resp) = try await Core.data(for: req)
            // /internal/logs returns 204 on success, not 200 — check the
            // whole 2xx range (see AppLogger.swift's identical fix note:
            // checking for exactly 200 here previously meant every
            // successful upload looked like a failure and got endlessly
            // requeued).
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(statusCode) {
                let requeue = entries.suffix(maxBuffer - buffer.count)
                buffer.insert(contentsOf: requeue, at: 0)
            }
        } catch {
            let requeue = entries.suffix(maxBuffer - buffer.count)
            buffer.insert(contentsOf: requeue, at: 0)
        }
    }
}

// MARK: - Global convenience shims

func tvLog(_ message: String, category: String = "general",
           file: String = #file, line: Int = #line,
           extra: [String: String] = [:]) {
    TVAppLogger.shared.log(message, level: "info", category: category, file: file, line: line, extra: extra)
}

func tvWarn(_ message: String, category: String = "general",
            file: String = #file, line: Int = #line,
            extra: [String: String] = [:]) {
    TVAppLogger.shared.warn(message, category: category, file: file, line: line, extra: extra)
}

func tvError(_ message: String, category: String = "general",
             file: String = #file, line: Int = #line,
             extra: [String: String] = [:]) {
    TVAppLogger.shared.error(message, category: category, file: file, line: line, extra: extra)
}

func tvBreadcrumb(_ event: String) {
    TVAppLogger.shared.breadcrumb(event)
}
