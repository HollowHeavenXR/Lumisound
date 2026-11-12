import ActivityKit
import Foundation
import UIKit

/// Starts/updates/ends the Lock Screen + Dynamic Island Live Activity. Purely
/// local (no push updates). Fed only by `WidgetDataService.publish`, so the
/// Live Activity always shows exactly the snapshot the widgets show.
@MainActor
enum LiveActivityManager {
    private static var activity: Activity<LumisoundActivityAttributes>?
    private static var lastPublished: NowPlayingSnapshot?

    /// Starting an activity needs the app in the foreground; while backgrounded
    /// (normal during playback) `request` throws, and each failed request used
    /// to stack another "Allow Live Activities?" prompt. Requests are skipped
    /// in the background and backed off after a failure.
    private static var lastRequestFailureAt: Date?
    private static let requestRetryCooldown: TimeInterval = 60

    static func publish(_ snapshot: NowPlayingSnapshot) {
        guard snapshot.hasTrack else {
            end()
            return
        }
        // Identical content (e.g. a favourite update that changed nothing):
        // skip the IPC round trip.
        if snapshot == lastPublished, activity != nil { return }
        lastPublished = snapshot

        // A Live Activity outlives this process, but `activity` is in-memory,
        // so after a relaunch re-attach to the running one rather than
        // requesting a second. A reference to one the user dismissed or the
        // system ended is dropped.
        if let a = activity, a.activityState == .ended || a.activityState == .dismissed {
            activity = nil
        }
        if activity == nil,
           let existing = Activity<LumisoundActivityAttributes>.activities.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            activity = existing
        }
        if activity != nil {
            send(snapshot)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        if let lastFailure = lastRequestFailureAt, Date().timeIntervalSince(lastFailure) < requestRetryCooldown { return }

        do {
            activity = try Activity<LumisoundActivityAttributes>.request(
                attributes: LumisoundActivityAttributes(),
                content: content(for: snapshot),
                pushType: nil
            )
            lastRequestFailureAt = nil
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

    /// Called every player tick. If what the Live Activity actually shows is
    /// a different track (or play state) than the last published snapshot,
    /// for example an update that was lost or landed out of order around an
    /// automatic advance or crossfade, send the latest one again.
    static func verify() {
        guard let activity, let latest = lastPublished, pending == nil, !sending else { return }
        guard activity.activityState == .active || activity.activityState == .stale else { return }
        let shown = activity.content.state.now
        guard shown.trackID != latest.trackID || shown.isPlaying != latest.isPlaying else { return }
        if let last = lastVerifyResend, Date().timeIntervalSince(last) < 2 { return }
        lastVerifyResend = Date()
        appWarn("LiveActivityManager: activity showed \"\(shown.title)\", resending \"\(latest.title)\"", category: "widget")
        send(latest)
    }

    private static var pending: NowPlayingSnapshot?
    private static var sending = false
    private static var lastVerifyResend: Date?

    /// Updates go out one at a time, newest last. Separate `Task`s per update
    /// could finish out of order, leaving the previous track on screen.
    private static func send(_ snapshot: NowPlayingSnapshot) {
        pending = snapshot
        guard !sending else { return }
        sending = true
        Task { @MainActor in
            while let next = pending, let activity {
                pending = nil
                await activity.update(content(for: next))
            }
            pending = nil
            sending = false
        }
    }

    private static func content(for snapshot: NowPlayingSnapshot) -> ActivityContent<LumisoundActivityAttributes.ContentState> {
        ActivityContent(
            state: LumisoundActivityAttributes.ContentState(now: snapshot),
            // Past the end of the track with no update, the system marks the
            // activity stale and the view shows it as stopped instead of a
            // bar pinned at 100 %.
            staleDate: snapshot.endDate.map { $0.addingTimeInterval(20) },
            relevanceScore: snapshot.isPlaying ? 100 : 50
        )
    }

    static func end() {
        lastPublished = nil
        pending = nil
        let all = Activity<LumisoundActivityAttributes>.activities
        activity = nil
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
