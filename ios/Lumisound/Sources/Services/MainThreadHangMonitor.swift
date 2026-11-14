import Foundation
import UIKit

/// Whether any library scan is currently running, readable from any thread.
///
/// `LibraryManager` is `@MainActor`, so its own scan counters cannot be read from
/// `MainThreadHangMonitor`'s background queue — and hopping to the main actor to
/// ask would block on exactly the thread the monitor is trying to measure. Hence
/// this small lock-guarded mirror, incremented and decremented alongside
/// `LibraryManager.beginScan`/`endScan`.
///
/// A count rather than a flag, because scans legitimately overlap (a forced
/// refresh waiting on an in-flight automatic one), and a bare flag would be
/// cleared by whichever finished first while the other was still running.
final class ScanActivityIndicator: @unchecked Sendable {
    static let shared = ScanActivityIndicator()
    private let lock = NSLock()
    private var count = 0

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return count > 0
    }

    func began() {
        lock.lock(); count += 1; lock.unlock()
    }

    func ended() {
        lock.lock(); count = max(0, count - 1); lock.unlock()
    }
}

/// Named sections of main-thread work, so a stall report can say what was
/// running instead of only that something was.
///
/// The hang monitor cannot sample the main thread's stack (see its `report`),
/// and `libraryScanInFlight` turned out to be too coarse: it was true for ~90%
/// of stalls, but a scan is mostly off-main work bracketed by a few main-actor
/// steps, and the flag cannot say which step — or whether the stall was some
/// unrelated work that merely overlapped a scan. Wrapping the known-heavy
/// main-actor steps in `measure` gives the monitor a list of what actually ran
/// during the stall. Labels are fixed strings naming code paths; nothing about
/// the library's contents is recorded.
final class MainThreadActivity: @unchecked Sendable {
    static let shared = MainThreadActivity()
    private let lock = NSLock()
    private var recent: [(label: String, start: Date, end: Date)] = []
    private var active: [(label: String, start: Date)] = []
    private static let capacity = 64

    @discardableResult
    static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        shared.lock.lock(); shared.active.append((label, start)); shared.lock.unlock()
        defer {
            let end = Date()
            shared.lock.lock()
            if let i = shared.active.lastIndex(where: { $0.label == label && $0.start == start }) {
                shared.active.remove(at: i)
            }
            shared.recent.append((label, start, end))
            if shared.recent.count > capacity { shared.recent.removeFirst(shared.recent.count - capacity) }
            shared.lock.unlock()
        }
        return try body()
    }

    /// Sections that overlapped `from...to`, longest first, as "label 1.23s".
    /// Still-running sections are included with their duration so far.
    func overlapping(from: Date, to: Date) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var hits: [(String, TimeInterval)] = recent
            .filter { $0.end >= from && $0.start <= to }
            .map { ($0.label, $0.end.timeIntervalSince($0.start)) }
        hits += active.map { ($0.label + " (running)", to.timeIntervalSince($0.start)) }
        return hits
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map { String(format: "%@ %.2fs", $0.0, $0.1) }
    }
}

/// Whether the process is currently executing inside an OS-granted background
/// window (a `BGAppRefreshTask` / `BGProcessingTask` handler).
///
/// Exists so that library scans can be blocked in the background — which is what
/// the `0x8BADF00D` scene-update watchdog kills were — WITHOUT also breaking the
/// one case where scanning while backgrounded is entirely legitimate.
/// `BackgroundRefreshService` reconciles finished downloads from a
/// `BGAppRefreshTask`, and importing those calls straight into the local scan. A
/// blanket background guard would have silently stopped downloads that completed
/// while the app was away from ever entering the library until the user next
/// opened it — trading a crash for quiet data loss.
///
/// Lock-guarded and readable from any thread, for the same reason as
/// `ScanActivityIndicator`.
final class BackgroundExecutionContext: @unchecked Sendable {
    static let shared = BackgroundExecutionContext()
    private let lock = NSLock()
    private var depth = 0

    /// True while at least one OS-granted background task handler is running.
    var isGrantedBackgroundTime: Bool {
        lock.lock(); defer { lock.unlock() }
        return depth > 0
    }

    /// Runs `body` marked as OS-granted background work. A counter rather than a
    /// flag because these handlers can overlap (the refresh task and the
    /// download catch-up task are scheduled independently), and a bare flag would
    /// be cleared by whichever finished first while the other was still working.
    func withGrantedBackgroundTime<T>(_ body: () async throws -> T) async rethrows -> T {
        lock.lock(); depth += 1; lock.unlock()
        defer { lock.lock(); depth = max(0, depth - 1); lock.unlock() }
        return try await body()
    }
}

/// Detects and reports main-thread stalls as they happen.
///
/// Why this exists: the app already subscribes to MetricKit's `hangDiagnostics`
/// (see `PerformanceMonitorService`), and in practice it has never once reported
/// anything — across days of field telemetry containing multiple crash and
/// disk-write diagnostics delivered through the *same* callback, and alongside
/// user-reported multi-second freezes and confirmed `0x8BADF00D` watchdog kills.
/// MetricKit is not broken; it is just the wrong tool for this job. It batches
/// diagnostics roughly daily and only delivers them on a subsequent launch, so a
/// freeze that happened minutes ago is simply not knowable from it.
///
/// The other existing sampler cannot help either: `CPUSampler` runs on a `Timer`
/// scheduled on `RunLoop.main`, which means a blocked main thread also blocks the
/// very timer that would have to notice. It is a victim of the hang, not an
/// observer of it.
///
/// So this monitor deliberately lives on its own background queue and watches the
/// main thread from the outside. That is the only vantage point from which a
/// blocked main thread is observable at all.
final class MainThreadHangMonitor {

    static let shared = MainThreadHangMonitor()

    /// Report anything at or above this. Chosen to sit above ordinary frame
    /// hitches (a dropped frame is ~16 ms, and a slow view build can legitimately
    /// take a few hundred) and below the ~10 s at which iOS's scene-update
    /// watchdog kills the process — the band where a freeze is long enough for a
    /// person to notice and call it a freeze, but the app is still alive to
    /// report it.
    private static let threshold: TimeInterval = 1.0

    /// How often a new ping is attempted once the previous one has landed. This
    /// does not bound the accuracy of the measurement — the duration comes from
    /// the ping's own round trip — it only bounds how quickly a stall that starts
    /// just after a ping returns is noticed.
    private static let probeInterval: TimeInterval = 0.25

    /// Rate limit. A main thread that is stalling repeatedly — a scan hitching
    /// every few hundred milliseconds, say — would otherwise report on each
    /// recovery, turning one bad stretch into a flood that costs more to send
    /// than it explains.
    private static let minimumReportInterval: TimeInterval = 30

    private let queue = DispatchQueue(label: "com.lumisound.hangmonitor", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Mutated on `queue` and on the main thread, so every access is guarded by
    /// `lock` rather than assumed atomic — a torn read here would produce
    /// fabricated hang durations, which is worse than no monitoring.
    private let lock = NSLock()
    private var lastReportAt: Date?
    private var isProbeOutstanding = false
    /// When the outstanding ping was sent, and main-thread stacks sampled
    /// while it has been waiting (see `MainThreadBacktrace`).
    private var probeSentAt = Date()
    private var stackSamples: [String] = []
    /// Last known application state, refreshed by each ping that lands.
    ///
    /// `UIApplication.shared.applicationState` is main-thread-only, and this
    /// monitor's whole purpose is to avoid touching the main thread while it may
    /// be blocked. A value at most one probe interval stale is entirely good
    /// enough for "should I be watching right now". Held here under `lock`
    /// rather than as a static, because it is written on the main thread and read
    /// on `queue` — the definition of a race if left unguarded.
    private var lastKnownState: UIApplication.State = .active

    private init() {}

    func start() {
        DispatchQueue.main.async { MainThreadBacktrace.registerMainThread() }
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + Self.probeInterval, repeating: Self.probeInterval)
            t.setEventHandler { [weak self] in self?.probe() }
            self.timer = t
            t.resume()
        }
    }

    /// Sends one ping and lets its completion measure the stall.
    ///
    /// Measured on ARRIVAL rather than reported as soon as the threshold is
    /// crossed, because the threshold is not the interesting number — the total
    /// is. An earlier version of this reported the moment `threshold` elapsed,
    /// which logged a five-second freeze as "1.0s" and would have made the very
    /// symptom being chased unrecognisable in the data. Waiting for the ping to
    /// land gives the true duration; a stall that never ends has its own
    /// unmistakable signal in the watchdog crash report.
    private func probe() {
        lock.lock()
        // A ping already in flight is itself the measurement in progress — it
        // will report when it lands. Sending more would only queue work behind
        // the block that is already waiting.
        if isProbeOutstanding {
            // Still waiting on the last ping: the main thread is stuck right
            // now. Sample where (once at 1.5 s, again at 6 s — a long hang is
            // often not in the same place the whole time).
            let waited = Date().timeIntervalSince(probeSentAt)
            let due = (stackSamples.isEmpty && waited >= 1.5) || (stackSamples.count == 1 && waited >= 6)
            let foreground = lastKnownState == .active
            lock.unlock()
            if due, foreground {
                let stack = MainThreadBacktrace.capture()
                if !stack.isEmpty {
                    lock.lock()
                    stackSamples.append(String(format: "@%.1fs: ", waited) + stack.prefix(40).joined(separator: " | "))
                    lock.unlock()
                }
            }
            return
        }
        isProbeOutstanding = true
        stackSamples = []
        let sentAt = Date()
        probeSentAt = sentAt
        let stateAtSend = lastKnownState
        lock.unlock()

        // An empty block on the main queue: it runs as soon as the main thread is
        // free, so how long it waited IS the stall.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(sentAt)
            let stateNow = UIApplication.shared.applicationState

            self.lock.lock()
            self.lastKnownState = stateNow
            self.isProbeOutstanding = false
            let recentlyReported = self.lastReportAt
                .map { Date().timeIntervalSince($0) < Self.minimumReportInterval } ?? false
            // Required active at BOTH ends. A wait that began or ended outside the
            // foreground is mostly the process having been suspended, and wall
            // clock keeps running while suspended — reporting that as a main-thread
            // hang would be the same "stopwatch left running" mistake the scan
            // telemetry already had to correct for.
            let shouldReport = elapsed >= Self.threshold
                && stateAtSend == .active
                && stateNow == .active
                && !recentlyReported
            if shouldReport { self.lastReportAt = Date() }
            let stacks = self.stackSamples
            self.stackSamples = []
            self.lock.unlock()

            guard shouldReport else { return }
            // Reported back on the monitor's own queue: the main thread has just
            // been stuck for seconds and is about to have a backlog of real work
            // to get through, so this adds none of its own to it.
            let arrivedAt = Date()
            self.queue.async { self.report(elapsed: elapsed, sentAt: sentAt, arrivedAt: arrivedAt, stacks: stacks) }
        }
    }

    private func report(elapsed: TimeInterval, sentAt: Date, arrivedAt: Date, stacks: [String]) {
        // `stacks` are samples of the main thread taken while it was stuck
        // (`MainThreadBacktrace`, from `probe`). `Thread.callStackSymbols`
        // here would describe this queue, not the blocked thread. Alongside:
        // the true duration and whether a library scan was in flight.
        let scanning = ScanActivityIndicator.shared.isActive
        // Half a second of lead-in: SwiftUI re-renders on the run-loop turn
        // AFTER the state change that caused it, so the change that set off a
        // render-bound stall usually finishes just before the ping was sent.
        let activity = MainThreadActivity.shared.overlapping(
            from: sentAt.addingTimeInterval(-0.5), to: arrivedAt
        )
        appError(String(format: "Main thread stalled for %.2fs (scanning: %@)", elapsed, scanning ? "yes" : "no"),
                 category: "performance")
        RemoteLogger.log(
            category: "performance",
            event: "main_thread_hang",
            level: elapsed >= 5 ? "error" : "warning",
            message: String(format: "main thread stalled for %.2fs", elapsed),
            detail: [
                "stallSeconds": round(elapsed * 100) / 100,
                // The single most useful discriminator available without a real
                // main-thread stack: it separates "the library scan is blocking
                // the UI" from "something else is".
                "libraryScanInFlight": scanning,
                "thermalState": ProcessInfo.processInfo.thermalState.lumisoundDescription,
                "mainThreadActivity": activity,
                // Where the main thread actually was, sampled during the stall
                // ("Image 0xoffset symbol", innermost first).
                "mainStack": stacks,
                // BUGFIX (found via telemetry audit — every real hang report on
                // record had `mainThreadActivity: []`, and `selectedTab` kept
                // showing index 6, which isn't even one of Classic's 5 tabs):
                // this used to unconditionally read "selected_tab", the
                // CLASSIC tab bar's int. Lumen is the default interface for
                // every real (non-screenshot-mode) user, and
                // `LumenRootView` doesn't maintain that key as "what's on
                // screen" — it only WRITES to it as a deep-link request echo
                // for widgets/Shortcuts (0=library, 3=cloud, 6=settings, …)
                // and otherwise leaves whatever stale value was last
                // requested sitting there, sometimes for days. So every hang
                // report from a Lumen user had a "selectedTab" field that was
                // either stale or outright meaningless — explaining why 6
                // (Settings' deep-link code) kept recurring independent of
                // what screen the hang actually happened on. Lumen's OWN
                // current-tab `@AppStorage` ("lumen_selected_tab") already
                // tracks the real on-screen tab correctly; just read from the
                // right key for whichever edition is actually active.
                "currentScreen": Self.currentScreenDescription(),
            ]
        )
    }

    /// What's actually on screen, independent of which interface edition is
    /// active — see the BUGFIX note at this function's one call site.
    /// UserDefaults is safe to read from this queue, unlike anything on the
    /// main actor.
    private static func currentScreenDescription() -> String {
        if InterfaceEdition.isLumen {
            let raw = UserDefaults.standard.string(forKey: "lumen_selected_tab") ?? "home"
            return "lumen.\(raw)"
        }
        return "classic.\(UserDefaults.standard.integer(forKey: "selected_tab"))"
    }
}
