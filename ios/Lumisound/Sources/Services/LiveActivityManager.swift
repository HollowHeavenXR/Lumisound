import ActivityKit
import Foundation
import UIKit

/// Starts/updates/ends the Lock Screen + Dynamic Island Live Activity. Purely
/// local (no push updates). Fed only by `WidgetDataService.publish`, so the
/// Live Activity always shows exactly the snapshot the widgets show.
///
/// Delivery rules (the activity used to stay on the previous track after a
/// crossfade, or after pause → skip/rewind while the app was in the background):
/// - Every live activity is updated, not just the one this process remembers.
///   A crash or relaunch could leave two; the one that was updated was not
///   always the one on screen. Extras are ended.
/// - Updates go out one at a time, newest last, coalesced over a few
///   milliseconds (track change + artwork + play state land as one update),
///   under a background-task assertion so a paused, backgrounded app is not
///   suspended between `update` being called and iOS receiving it.
/// - After sending, what each activity actually holds (`content.state`) is
///   compared with the latest snapshot and resent if it differs. A watchdog
///   keeps checking for a while after every change — independent of the
///   player's position timer, which stops while paused.
/// - Each snapshot carries a `revision`; the Live Activity view also reads the
///   App Group copy and shows whichever is newer (see `LumisoundLiveActivity`),
///   so a redraw after a button tap shows the new track even if the
///   ActivityKit update was dropped.
@MainActor
enum LiveActivityManager {
    private static var lastPublished: NowPlayingSnapshot?
    /// The activity this process started or adopted; kept when extras are ended.
    private static var primaryID: String?

    /// Starting an activity needs the app in the foreground; while backgrounded
    /// (normal during playback) `request` throws, and each failed request used
    /// to stack another "Allow Live Activities?" prompt. Requests are skipped
    /// in the background and backed off after a failure.
    private static var lastRequestFailureAt: Date?
    private static let requestRetryCooldown: TimeInterval = 60

    private static var liveActivities: [Activity<LumisoundActivityAttributes>] {
        Activity<LumisoundActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    static func publish(_ snapshot: NowPlayingSnapshot) {
        guard snapshot.hasTrack, AudioPlayerManager.showsLiveActivity else {
            end()
            return
        }
        let live = liveActivities
        // Identical content (e.g. a favourite update that changed nothing):
        // skip the IPC round trip.
        if let last = lastPublished, last.sameContent(as: snapshot), !live.isEmpty { return }
        lastPublished = snapshot

        if !live.isEmpty {
            send(snapshot)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        if let lastFailure = lastRequestFailureAt, Date().timeIntervalSince(lastFailure) < requestRetryCooldown { return }

        do {
            let a = try Activity<LumisoundActivityAttributes>.request(
                attributes: LumisoundActivityAttributes(),
                content: content(for: snapshot),
                pushType: nil
            )
            primaryID = a.id
            lastRequestFailureAt = nil
            watch()
        } catch {
            lastRequestFailureAt = Date()
            appError("LiveActivityManager: failed to start activity: \(error.localizedDescription)", category: "widget")
            // "Maximum number of activities" — orphans from earlier sessions
            // (a crash never runs `end()`) fill the per-app cap. End them so
            // the next attempt has room.
            let orphans = Activity<LumisoundActivityAttributes>.activities
            guard !orphans.isEmpty else { return }
            appWarn("LiveActivityManager: ending \(orphans.count) orphaned activity(s) from prior session(s)", category: "widget")
            Task {
                for orphan in orphans {
                    await orphan.end(orphan.content, dismissalPolicy: .immediate)
                }
            }
        }
    }

    /// Called every player tick and by the watchdog. If what an activity
    /// actually holds is a different track, play state or timeline than the
    /// last published snapshot, send the latest one again.
    static func verify() {
        // In the background iOS ignores these updates anyway (outside an
        // intent, where `flush` sets `inIntent`); resending would only burn
        // battery. The foreground republish and the end-of-track refresh
        // cover that time.
        guard inIntent || UIApplication.shared.applicationState == .active else { return }
        guard let latest = lastPublished, pending == nil, !sending else { return }
        guard let stale = liveActivities.first(where: { !$0.content.state.now.isDelivery(of: latest) }) else { return }
        if let last = lastVerifyResend, Date().timeIntervalSince(last) < 1.5 { return }
        lastVerifyResend = Date()
        appWarn("LiveActivityManager: activity showed \"\(stale.content.state.now.title)\", resending \"\(latest.title)\"", category: "widget")
        send(latest)
    }

    /// Waits (up to ~2 s) until queued updates have been delivered and every
    /// activity holds the latest snapshot. Called before a widget/Live
    /// Activity intent returns, since iOS redraws the activity at that moment
    /// and may suspend the (paused) app right after.
    private static var inIntent = false

    static func flush() async {
        inIntent = true
        defer { inIntent = false }
        // A command can change the track a turn of the run loop later
        // (engine callbacks hop onto the main actor): let those land first.
        for _ in 0..<3 { await Task.yield() }
        for _ in 0..<100 {
            if !sending, pending == nil {
                guard let latest = lastPublished,
                      liveActivities.contains(where: { !$0.content.state.now.isDelivery(of: latest) })
                else { return }
                lastVerifyResend = nil
                verify()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static var pending: NowPlayingSnapshot?
    private static var sending = false
    private static var lastVerifyResend: Date?

    /// Updates go out one at a time, newest last. Separate `Task`s per update
    /// could finish out of order, leaving the previous track on screen.
    private static func send(_ snapshot: NowPlayingSnapshot) {
        pending = snapshot
        watch()
        guard !sending else { return }
        sending = true
        let bgTask = beginBackgroundWork()
        Task { @MainActor in
            // Coalesce a burst (track change, artwork, play state) into one update.
            try? await Task.sleep(nanoseconds: 40_000_000)
            var rounds = 0
            while let next = pending, rounds < 6 {
                pending = nil
                rounds += 1
                let live = endExtras(liveActivities)
                for a in live {
                    await a.update(content(for: next))
                }
                // Confirm what the system now holds; anything that didn't take
                // goes round again (bounded).
                if pending == nil, live.contains(where: { !$0.content.state.now.isDelivery(of: next) }) {
                    pending = next
                }
            }
            pending = nil
            sending = false
            endBackgroundWork(bgTask)
        }
    }

    /// Ends every live activity but one, so updates can't go to a hidden
    /// duplicate while a stale one stays on screen.
    private static func endExtras(_ live: [Activity<LumisoundActivityAttributes>]) -> [Activity<LumisoundActivityAttributes>] {
        guard live.count > 1 else {
            if let only = live.first { primaryID = only.id }
            return live
        }
        let keep = live.first(where: { $0.id == primaryID }) ?? live[0]
        primaryID = keep.id
        let extras = live.filter { $0.id != keep.id }
        appWarn("LiveActivityManager: ending \(extras.count) duplicate activity(s)", category: "widget")
        Task {
            for a in extras { await a.end(a.content, dismissalPolicy: .immediate) }
        }
        return [keep]
    }

    // MARK: Watchdog

    private static var watchTask: Task<Void, Never>?
    private static var watchUntil: Date = .distantPast

    /// Re-checks the activities once a second for 12 s after every change.
    private static func watch() {
        watchUntil = Date().addingTimeInterval(12)
        guard watchTask == nil else { return }
        watchTask = Task { @MainActor in
            while Date() < watchUntil, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                verify()
            }
            watchTask = nil
        }
    }

    // MARK: Background time

    private static func beginBackgroundWork() -> UIBackgroundTaskIdentifier {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "LiveActivityUpdate") {
            UIApplication.shared.endBackgroundTask(id)
        }
        return id
    }

    private static func endBackgroundWork(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }

    private static func content(for snapshot: NowPlayingSnapshot) -> ActivityContent<LumisoundActivityAttributes.ContentState> {
        ActivityContent(
            state: LumisoundActivityAttributes.ContentState(now: snapshot),
            // The moment the track ends the system marks the activity stale
            // and redraws it. iOS ignores updates from this app while it plays
            // in the background, so that redraw is how an automatic advance or
            // crossfade reaches the Lock Screen: the view then reads the newer
            // snapshot the app has already saved in the App Group.
            staleDate: snapshot.endDate.map { $0.addingTimeInterval(0.75) },
            relevanceScore: snapshot.isPlaying ? 100 : 50
        )
    }

    static func end() {
        lastPublished = nil
        pending = nil
        primaryID = nil
        watchTask?.cancel()
        watchTask = nil
        let all = Activity<LumisoundActivityAttributes>.activities
        guard !all.isEmpty else { return }
        Task {
            for a in all {
                var state = a.content.state
                state.now.isPlaying = false
                await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
}
