import Foundation

// MARK: - AppLogger

/// Thread-safe application logger. Buffers entries in memory and flushes them
/// to the bridge server every 30 seconds (or immediately on errors).
///
/// `log()` / `warn()` / `error()` are `nonisolated` and can be called from any
/// thread, actor, or Task without `await`. The actual buffer write hops to
/// MainActor asynchronously so the caller is never blocked.
@MainActor
final class AppLogger: ObservableObject {

    static let shared = AppLogger()

    // MARK: - LogEntry

    struct LogEntry: Codable {
        let level: String       // "debug", "info", "warning", "error"
        let category: String    // "audio", "library", "account", "ui", "network", "artwork", "general"
        let message: String
        let file: String
        let line: Int
        let timestamp: String   // ISO 8601
        var extra: [String: String]
        // Device/account context — lets server-side log queries be filtered or
        // grouped per device model, OS version, app build, and (when logged in)
        // per-user, so issues reported by one user's device don't get conflated
        // with another's.
        var deviceModel: String = DeviceInfo.modelIdentifier
        var osVersion: String = DeviceInfo.osVersion
        var appVersion: String = DeviceInfo.appVersion
        var userId: String? = nil
        /// Kept on the device: written to the console and to the bug-report
        /// buffer, never uploaded. For high-frequency proof-of-life traces that
        /// are useful while looking at one device and pure noise in a shared
        /// table. Not encoded — the server has no column for it and no use for it.
        var localOnly: Bool = false

        enum CodingKeys: String, CodingKey {
            case level, category, message, file, line, timestamp, extra
            case deviceModel, osVersion, appVersion, userId
        }
    }

    // MARK: - Private state (all @MainActor)

    private var buffer: [LogEntry] = []
    private let maxBuffer = 1_000

    /// Separate from `buffer`: holds the last `maxRecentEntries` log entries for
    /// `recentActivitySummary()`, independent of the flush-to-bridge cycle.
    /// `buffer` is drained (set to `[]`) every 30s by `flush()`, so by the time a
    /// user notices a problem, navigates to Settings → Report a Bug, and fills out
    /// the form, `buffer` is almost always empty — "include recent activity log"
    /// had nothing to attach. This buffer is never cleared by `flush()`, only
    /// trimmed to its cap, so it always reflects what actually just happened.
    private var recentEntries: [LogEntry] = []
    private let maxRecentEntries = 50
    private var flushTimer: Timer?
    private var bridgeURL: String = ""
    private var isConfigured = false

    // MARK: - Breadcrumbs (crash context)

    private static let breadcrumbsKey = "crash_breadcrumbs_v1"
    private let maxBreadcrumbs = 12
    private var breadcrumbs: [String] = []

    private init() {}

    // MARK: - Timestamps

    /// `Date().formatted(.iso8601)` truncates to whole-second resolution —
    /// fine for a single log line, but this app can emit dozens of events
    /// within the same second during a burst (a batch download completing,
    /// a rapid track-skip cascade), which made reconstructing what actually
    /// happened in what order effectively impossible from the timestamp
    /// alone — every event in a burst read as simultaneous. Millisecond
    /// resolution is enough to tell genuinely-ordered rapid events apart
    /// without bloating the payload the way full nanosecond precision would.
    ///
    /// NOTE: an earlier version of this used
    /// `Date().formatted(.iso8601.time(includingFractionalSeconds: true))`
    /// — `ISO8601FormatStyle.time(...)` is NOT additive the way it reads;
    /// it replaces the whole format with a TIME-ONLY string ("04:19:48.331",
    /// no date component at all), which the bridge's parser understandably
    /// rejected outright — confirmed live via its "_parse_log_timestamp:
    /// unparseable value" warnings, which is what caught this.
    /// `ISO8601DateFormatter` with `.withFractionalSeconds` is the
    /// reliable way to get a full, parseable date+time with sub-second
    /// precision.
    /// A fresh formatter per call, not a shared `static let` — `nonisolated`
    /// callers can come from any thread/actor, and `ISO8601DateFormatter`
    /// (an `NSObject` subclass) isn't `Sendable`, so a shared mutable
    /// instance here would be a real concurrency-safety violation (and
    /// under strict concurrency checking, a compile error) rather than just
    /// a style choice. Constructing one per call is cheap enough for a
    /// logger — this isn't a hot path called thousands of times/sec.
    nonisolated static func preciseISO8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: - Configuration

    /// Call once on app launch. Subsequent calls (e.g. from SwiftUI `.task` re-fires) are no-ops.
    func configure(bridgeURL: String) {
        guard !isConfigured else { return }
        isConfigured = true
        self.bridgeURL = bridgeURL
        reportPriorSessionBreadcrumbsIfAny()
        _append(LogEntry(level: "info", category: "app", message: "App launched",
                         file: "LumisoundApp.swift", line: 0,
                         timestamp: Self.preciseISO8601Now(), extra: [:]))
        startFlushTimer()
    }

    // MARK: - Breadcrumbs (nonisolated — callable from any context)

    /// Records a short description of a significant action (scan started, song
    /// changed, tab switched...) and persists the trail to UserDefaults
    /// immediately. If the app crashes before the next graceful shutdown, the
    /// *next* launch finds this trail still on disk and reports it as a single
    /// consolidated log entry — turning "it just crashed" into "it crashed
    /// right after switching to Search while the library was still scanning."
    /// Deliberately NOT for high-frequency events (position ticks, scroll) —
    /// only discrete, meaningful ones; each call performs a UserDefaults write.
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

    /// If a breadcrumb trail survived from a previous run, that session never
    /// reached a clean shutdown path (crash, force-quit, OS termination) — log
    /// what it was doing right before, then clear the trail so a normal
    /// background/terminate afterward doesn't re-report the same stale data.
    private func reportPriorSessionBreadcrumbsIfAny() {
        guard let prior = UserDefaults.standard.stringArray(forKey: Self.breadcrumbsKey),
              !prior.isEmpty
        else { return }
        let summary = prior.joined(separator: "  →  ")
        _append(LogEntry(level: "warning", category: "app",
                         message: "Possible unclean shutdown — last actions before previous session ended: \(summary)",
                         file: "AppLogger.swift", line: 0,
                         timestamp: Self.preciseISO8601Now(), extra: [:]))
        UserDefaults.standard.removeObject(forKey: Self.breadcrumbsKey)
    }

    // MARK: - Public log methods (nonisolated — callable from any context)

    nonisolated func log(
        _ message: String,
        level: String = "info",
        category: String = "general",
        file: String = #file,
        line: Int = #line,
        extra: [String: String] = [:],
        localOnly: Bool = false
    ) {
        let shortFile = URL(fileURLWithPath: file).lastPathComponent
        let ts = Self.preciseISO8601Now()
        let entry = LogEntry(level: level, category: category, message: message,
                             file: shortFile, line: line, timestamp: ts, extra: extra,
                             localOnly: localOnly)
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
        // Flush immediately so errors are never lost if the app terminates soon after.
        Task { @MainActor [weak self] in await self?.flush() }
    }

    // MARK: - Bug Reports

    /// A short text dump of recent breadcrumbs and buffered log entries,
    /// attached to user-submitted bug reports (Settings → Help → Report a Bug)
    /// to give context without requiring the user to describe what led up to it.
    func recentActivitySummary() -> String {
        var lines: [String] = []
        if !breadcrumbs.isEmpty {
            lines.append("Recent activity:")
            lines.append(contentsOf: breadcrumbs)
        }
        let recentLogs = recentEntries.suffix(50)
        if !recentLogs.isEmpty {
            lines.append("Recent logs:")
            lines.append(contentsOf: recentLogs.map { "[\($0.level)][\($0.category)] \($0.message)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    // MARK: Repeat collapsing
    //
    // A handful of message shapes accounted for most of the server-side log
    // table. Measured over one 14-day retention window: an audio "proof of life"
    // trace at 78,601 rows, a tag-write failure warning at 32,787, another at
    // 32,640, and download poll-status lines in the tens of thousands — out of
    // ~523,000 rows total for a few dozen users.
    //
    // None of those are more informative at 30,000 copies than at one with a
    // count beside it. Rather than picking off each call site (and waiting for the
    // next chatty one to be added), identical repeats are collapsed here, where
    // every log line already passes through.
    //
    // Deliberately NOT a level filter. Dropping `info` wholesale would take the
    // one-off lines that make a timeline readable along with the noise, and the
    // noise is repetition, not severity — two of the worst offenders are warnings.
    private struct RepeatKey: Hashable {
        let level: String
        let category: String
        let message: String
    }
    private var repeatFirstSeen: [RepeatKey: Date] = [:]
    private var repeatSuppressed: [RepeatKey: Int] = [:]

    /// Identical entries inside this window collapse into the first one.
    private let repeatWindow: TimeInterval = 60

    /// Digits are normalised out before comparing, so lines that differ only by a
    /// job id, a level reading or a byte count still count as the same message —
    /// which is exactly the shape of the high-volume offenders.
    private static func repeatSignature(_ message: String) -> String {
        String(message.map { $0.isNumber ? "#" : $0 }).prefix(120).description
    }

    /// True when this entry should be dropped as a repeat. Emits a summary line
    /// for the ones it swallowed when the window closes, so the count is never
    /// silently lost.
    private func shouldCollapse(_ entry: LogEntry, now: Date) -> Bool {
        let key = RepeatKey(level: entry.level, category: entry.category,
                            message: Self.repeatSignature(entry.message))
        guard let firstSeen = repeatFirstSeen[key] else {
            repeatFirstSeen[key] = now
            return false
        }
        if now.timeIntervalSince(firstSeen) < repeatWindow {
            repeatSuppressed[key, default: 0] += 1
            return true
        }
        // Window closed. If anything was swallowed, say how much before starting
        // the next window with this entry as its first occurrence.
        let suppressed = repeatSuppressed.removeValue(forKey: key) ?? 0
        repeatFirstSeen[key] = now
        // `!entry.localOnly` matters: without it, collapsing a device-local trace
        // would still push its "repeated Nx" summary into the upload buffer —
        // reintroducing, in smaller form, exactly the traffic localOnly exists to
        // prevent.
        if suppressed > 0 && !entry.localOnly {
            buffer.append(LogEntry(
                level: entry.level, category: entry.category,
                message: "(repeated \(suppressed)x in the last \(Int(repeatWindow))s) \(entry.message)",
                file: entry.file, line: entry.line,
                timestamp: Self.preciseISO8601Now(), extra: entry.extra))
        }
        return false
    }

    private func _append(_ entry: LogEntry) {
        var entry = entry
        // Read at append time (MainActor) rather than at the nonisolated call
        // site — `currentUser` can only be read safely here, and using the
        // value at flush time would tag entries with whoever is logged in
        // *now* rather than who triggered them.
        entry.userId = AccountService.shared?.currentUser?.id

        // `recentEntries` (bug-report context) and the DEBUG console below always
        // get the entry; only the upload buffer is filtered. A local diagnostic is
        // still worth having on the device that produced it.
        let collapsed = shouldCollapse(entry, now: Date())
        if !entry.localOnly && !collapsed {
            buffer.append(entry)
            if buffer.count > maxBuffer {
                buffer.removeFirst(buffer.count - maxBuffer)
            }
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
        // "More advanced real-time usage/event logging... that auto gets
        // uploaded and updated to the server constantly" — tightened from
        // 30s. Not tightened further than this: errors already flush
        // immediately (see error()/log(level: .error)) regardless of this
        // timer, so this interval only governs how promptly ordinary
        // info/debug/warning volume lands, not how fast a real problem is
        // reported — going much below 15s buys little for that while
        // adding meaningfully more request/battery overhead for a
        // background-audio app that can be running for hours at a stretch.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.flush() }
        }
        // Lets iOS batch this wake-up with others (battery).
        flushTimer?.tolerance = (15) * 0.1
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
            // The bridge's /internal/logs returns 204 No Content on success
            // (see ios-bridge/main.py), not 200 — this checked for an exact
            // 200 match, so EVERY successful upload was misread as a
            // failure. The "failed" branch shoves the whole just-sent batch
            // back into `buffer`, so the same entries got endlessly
            // re-sent every 30s flush forever (capped at maxBuffer, so it
            // couldn't grow past that, but never actually drained either)
            // — real client-observed symptom: log uploads appearing to
            // stall/go silent while the app kept working fine otherwise,
            // since this endless resend/regrow cycle could itself stall on
            // a big enough requeued payload.
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

// MARK: - Global convenience shims (callable without referencing the shared instance)

/// Logs an info-level message from any context. File/line captured at call site.
/// `localOnly: true` keeps the line on this device — console and bug-report
/// context only, never uploaded. For high-frequency traces that are useful while
/// watching one device and pure noise in a shared table.
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

/// Records a short breadcrumb of a significant action for crash-context
/// reporting on the next launch. See `AppLogger.breadcrumb`.
func appBreadcrumb(_ event: String) {
    AppLogger.shared.breadcrumb(event)
}
