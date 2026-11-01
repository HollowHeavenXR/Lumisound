import Foundation

/// A user-set weekly listening-time target, tracked against real listen
/// time from `/user/stats/weekly` (see `AccountService.fetchWeeklyStats`).
/// Deliberately forward-looking and distinct from Achievements' streaks/
/// badges, which are entirely retrospective — this is "how am I doing
/// against a target I picked", not "what have I already accomplished".
/// Local-only preference (the target itself, not account-synced), same as
/// most per-device settings in this app; only the progress data it's
/// measured against comes from the server.
@MainActor
final class ListeningGoalService: ObservableObject {
    static let shared = ListeningGoalService()

    private static let targetMinutesKey = "listeningGoal.targetMinutes"
    private static let congratulatedWeekKey = "listeningGoal.congratulatedWeek"

    /// `nil` means no goal set. Callers should set it to `nil` (not 0 or a
    /// negative number) to clear it — this only mirrors whatever value it's
    /// given to disk, it doesn't sanitize on write.
    @Published var targetMinutes: Int? {
        didSet {
            goalSetTarget(minutes: targetMinutes.map(Int64.init))
        }
    }

    @Published private(set) var progressMinutes: Int = 0
    @Published private(set) var hasLoaded = false

    private init() {
        let d = UserDefaults.standard
        goalImportLegacy(targetMinutes: Int64(d.integer(forKey: Self.targetMinutesKey)),
                         congratulatedWeek: d.string(forKey: Self.congratulatedWeekKey))
        targetMinutes = goalTarget().map(Int.init)
    }

    var progressFraction: Double {
        guard let targetMinutes, targetMinutes > 0 else { return 0 }
        return min(1.0, Double(progressMinutes) / Double(targetMinutes))
    }

    var isGoalMet: Bool {
        guard let targetMinutes else { return false }
        return progressMinutes >= targetMinutes
    }

    /// Refreshes `progressMinutes` from the last 7 days of real listen
    /// time, and fires a one-time congratulatory toast the first time this
    /// week's goal is reached (tracked by ISO week so it doesn't repeat on
    /// every refresh, but does fire again next week).
    func refresh(account: AccountService) async {
        let days = await account.fetchWeeklyStats()
        let totalSeconds = days.reduce(0) { $0 + $1.listenSeconds }
        progressMinutes = totalSeconds / 60
        hasLoaded = true
        checkCongratulation()
    }

    /// Once per ISO week (rule + state in the Rust core).
    private func checkCongratulation() {
        guard goalShouldCongratulate(progressMinutes: Int64(progressMinutes)) else { return }
        ToastCenter.shared.show("Weekly listening goal reached!", category: .success, icon: "checkmark.seal.fill")
    }
}
