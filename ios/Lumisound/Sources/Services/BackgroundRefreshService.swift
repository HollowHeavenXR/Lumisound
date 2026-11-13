import BackgroundTasks
import Foundation

/// Periodic background check for new uploads on subscribed channels and new
/// tracks on auto-download playlists, via `BGTaskScheduler` — the standard
/// iOS mechanism for this, replacing what Settings help text already
/// (inaccurately) claimed happened automatically: previously, subscriptions
/// only checked when the user tapped "Check Now", and tracked playlists only
/// checked opportunistically on launch.
///
/// IMPORTANT CAVEAT: iOS — not this code — decides if/when a submitted
/// request actually runs. It won't fire before `earliestBeginDate`, and past
/// that the OS schedules it based on the device's usage patterns, battery
/// level, and network state; there is no guaranteed cadence, and it may not
/// run for long stretches if the app isn't opened often. This can't be
/// verified from a dev machine with no physical device — if a user reports
/// subscriptions never update in the background, that's the first thing to
/// suspect (and "Check Now" always still works as a manual fallback).
enum BackgroundRefreshService {
    static let taskIdentifier = "com.lumisound.ios.refresh"

    /// A second, LONGER-RUNNING background task dedicated to downloads.
    ///
    /// `taskIdentifier` above is a `BGAppRefreshTask`, which iOS budgets at
    /// roughly 30 seconds. That is fine for its original purpose — asking
    /// whether anything is new — and hopeless for acting on the answer: at the
    /// bridge's measured ~3s per track, 30 seconds is under a dozen tracks, so
    /// resuming a several-hundred-track playlist in the background was never
    /// going to be more than a trickle no matter how often it ran. Worse, the
    /// refresh task runs subscriptions first and downloads last, so downloads
    /// were the thing most likely to be cut off before starting at all.
    ///
    /// A `BGProcessingTask` gets minutes rather than seconds, which is the
    /// difference between finishing a playlist and nibbling at it. iOS grants it
    /// more conservatively (it favours charging and idle), so this does not
    /// replace the refresh task — it runs the same work with room to complete,
    /// whenever the OS is feeling generous, while the refresh task keeps making
    /// small progress more often and `startForegroundResumeLoop` remains the
    /// dependable driver.
    static let downloadTaskIdentifier = "com.lumisound.ios.downloads"

    /// Registers both task handlers. MUST be called before the app finishes
    /// launching — from `LumisoundApp.init()`, not a View's `.task`/`.onAppear`
    /// (BGTaskScheduler requires registration before the app is fully active).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: refreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: downloadTaskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleDownloads(task: processingTask)
        }
    }

    /// Requests the next background run. Call once after launch and again
    /// after each run completes — a submitted request is consumed when it
    /// fires (or replaced by a newer `submit()` for the same identifier).
    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        // Requested as soon as 5 minutes out, matching TrackedPlaylistStore's
        // own 5-minute auto-download throttle — but this is only the
        // EARLIEST iOS is allowed to run it, not a promise it will. In
        // practice BGAppRefreshTask is scheduled at the OS's discretion
        // based on usage patterns/battery/network state and routinely runs
        // far less often than requested (see this file's top-level doc
        // comment) — a 5-minute request does not produce 5-minute cadence,
        // it just removes the 4-hour floor that used to be here.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            appWarn("BackgroundRefreshService: submit failed: \(error.localizedDescription)", category: "background")
        }
    }

    /// Requests the next long-form download catch-up. Call alongside
    /// `scheduleNext()`.
    static func scheduleNextDownloadCatchUp() {
        let request = BGProcessingTaskRequest(identifier: downloadTaskIdentifier)
        // Downloading is the entire point, so unlike the track-vault task this
        // one genuinely cannot run without the network — saying so lets iOS pick
        // a moment when it will actually succeed instead of waking us to fail.
        request.requiresNetworkConnectivity = true
        // NOT requiring external power. It would make iOS more willing to run
        // this, but "resume my playlist only while plugged in" is not what a user
        // who started a download asked for, and the work is network-bound rather
        // than the sustained CPU grind that flag is meant for.
        request.requiresExternalPower = false
        // Further out than the refresh task's 5 minutes: a processing task is a
        // bigger favour to ask, and asking too eagerly gets it deprioritised.
        // Still only a floor, never a promise — see this file's top doc comment.
        // Next due pass of the 15-hour schedule (read from defaults: this isn't
        // main-actor code). Interrupted passes resume from the refresh task.
        let last = UserDefaults.standard.object(forKey: "autoDownloads.lastFullRun") as? Date ?? .distantPast
        let due = last.addingTimeInterval(15 * 3600)
        request.earliestBeginDate = due > Date() ? due : Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            appWarn("BackgroundRefreshService: download catch-up submit failed: \(error.localizedDescription)", category: "background")
        }
    }

    private static func handleDownloads(task: BGProcessingTask) {
        // Chain the next run before doing any work, same as the refresh task.
        scheduleNextDownloadCatchUp()

        let work = Task {
            await runDownloadCatchUp()
            task.setTaskCompleted(success: true)
        }
        // Cancellation is what makes this safe to cut off at any point:
        // `runAutoDownloads` checks for it and leaves an unfinished playlist
        // marked as still owing work, so an expired task resumes rather than
        // losing its place. See TrackedPlaylistStore.runAutoDownloads.
        task.expirationHandler = {
            work.cancel()
        }
    }

    @MainActor
    private static func runDownloadCatchUp() async {
        guard let library = LibraryManager.shared, let streaming = StreamingService.shared else { return }
        appLog("BackgroundRefreshService: running download catch-up", category: "background")
        // Deliberately ONLY the download path — no subscription check. Those
        // already have the refresh task, and letting them share this one would
        // recreate the starvation this task exists to escape.
        //
        // Reconcile first, for the same reason as the launch and foreground
        // paths: a job the bridge already finished is a track the resume pass
        // must see as owned, or it asks for it again.
        // Marked as granted background time so the local-documents scan that
        // importing a finished download triggers is allowed to run — see
        // BackgroundExecutionContext.
        await BackgroundExecutionContext.shared.withGrantedBackgroundTime {
            let store = TrackedPlaylistStore.shared
            // iOS's daily slot: a full pass when 15 h have passed or a pass
            // was interrupted; otherwise there is nothing to do.
            if store.hasInterruptedPass || Date() >= store.nextScheduledRun {
                await store.runPass(streaming: streaming, library: library, reason: "iOS background task")
            }
        }
    }

    private static func handle(task: BGAppRefreshTask) {
        // Schedule the NEXT run before doing any work — if this run fails or
        // is cut short by the OS, the periodic chain continues regardless.
        scheduleNext()

        let work = Task {
            await runChecks()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    @MainActor
    private static func runChecks() async {
        appLog("BackgroundRefreshService: running checks", category: "background")

        guard let library = LibraryManager.shared, let streaming = StreamingService.shared else {
            // No library/streaming yet (e.g. very early launch) — still run
            // the subscription check itself, just without auto-download.
            await AccountService.shared?.checkAllSubscriptions()
            return
        }

        // Passing streaming/library lets checkAllSubscriptions auto-download
        // new uploads for any subscription with that opt-in enabled, same as
        // runAutoDownloads below does for tracked playlists.
        await AccountService.shared?.checkAllSubscriptions(streaming: streaming, library: library)

        // Pick up any downloads that finished server-side while the app
        // wasn't around to fetch them (see StreamingService+PendingDownloads)
        // — done first and cheaply (a single GET when there's nothing
        // pending), so it isn't starved by runAutoDownloads below if this
        // task's tight execution budget runs out first.
        // Same reasoning as runDownloadCatchUp: this is OS-granted background
        // time, so the scan behind an import is legitimate here.
        await BackgroundExecutionContext.shared.withGrantedBackgroundTime {
            let store = TrackedPlaylistStore.shared
            if store.hasInterruptedPass || Date() >= store.nextScheduledRun {
                await store.runPass(streaming: streaming, library: library, reason: "iOS background refresh")
            } else if StreamingService.hasRecentDownloadActivity {
                await streaming.reconcilePendingDownloads()
            }
        }
    }
}
