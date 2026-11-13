import SwiftUI

// MARK: - AchievementsView
//
// Shows listening streaks and badge unlocks from GET /user/achievements.
// Badges are derived server-side from play history — nothing to configure.

struct AchievementsView: View {
    @EnvironmentObject private var account: AccountService

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    /// The badge whose "how to unlock" detail sheet is currently presented
    /// (set when the user taps a badge cell).
    @State private var selectedBadge: Badge?

    /// Set true for a few seconds by `checkForNewBadges()` whenever at least
    /// one badge newly unlocks — drives a one-shot confetti burst overlay.
    @State private var showConfetti = false

    var body: some View {
        LKPage(title: "Achievements", subtitle: "Milestones from how you listen.", icon: "trophy.fill", tint: .yellow) {
            LKSection {
                if let data = account.achievements {
                    LabeledContent("Current Streak") {
                        Text(streakLabel(data.currentStreakDays))
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .foregroundStyle(AppTheme.textPrimary)

                    LabeledContent("Longest Streak") {
                        Text(streakLabel(data.longestStreakDays))
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .foregroundStyle(AppTheme.textPrimary)

                    LabeledContent("Total Plays") {
                        Text("\(data.totalPlays)")
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .foregroundStyle(AppTheme.textPrimary)

                    LabeledContent("Listening Time") {
                        Text(formattedListenTime(data.totalListenSeconds))
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                } else {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } header: {
                sectionHeader("Streaks")
            }

            if let data = account.achievements {
                LKSection {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Self.allBadges, id: \.id) { badge in
                            Button {
                                selectedBadge = badge
                            } label: {
                                badgeCell(badge, unlocked: data.badges.contains(badge.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    sectionHeader("Badges")
                } footer: {
                    Text("\(data.badges.count) of \(Self.allBadges.count) unlocked · tap a badge to see how to earn it")
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        // Without an explicit style this defaults to a grouped-card look —
        // see FavoritesView's identical fix.
        .background(GalleryBackgroundView().ignoresSafeArea())
        .overlay(ConfettiOverlay(isActive: showConfetti).ignoresSafeArea())
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await account.fetchAchievements()
            checkForNewBadges()
        }
        .refreshable {
            await account.fetchAchievements()
            checkForNewBadges()
        }
        .sheet(item: $selectedBadge) { badge in
            badgeDetailSheet(badge, unlocked: account.achievements?.badges.contains(badge.id) ?? false)
        }
    }

    // MARK: - Badge Detail ("how to unlock") Sheet

    @ViewBuilder
    private func badgeDetailSheet(_ badge: Badge, unlocked: Bool) -> some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(AppTheme.textSecondary.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 10)

            Image(systemName: badge.icon)
                .font(.system(size: 56))
                .foregroundStyle(unlocked ? AppTheme.dynamicAccent : AppTheme.textSecondary.opacity(0.5))
                .padding(.top, 8)

            Text(badge.title)
                .font(AppTheme.headlineFont(size: 24))
                .foregroundStyle(AppTheme.textPrimary)

            HStack(spacing: 6) {
                Image(systemName: unlocked ? "checkmark.seal.fill" : "lock.fill")
                Text(unlocked ? "Unlocked" : "Locked")
            }
            .font(AppTheme.bodyFont(size: 14).weight(.semibold))
            .foregroundStyle(unlocked ? AppTheme.success : AppTheme.textSecondary)

            VStack(spacing: 8) {
                Text("How to earn this")
                    .font(AppTheme.bodyFont(size: 12).weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .kerning(0.8)
                Text(badge.requirement)
                    .font(AppTheme.bodyFont(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            // Live progress toward this badge, when the metric is known.
            if let progress = progressText(for: badge) {
                Text(progress)
                    .font(AppTheme.monoFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(EditionScreenBackground())
        .presentationDetents([.medium])
    }

    /// Best-effort current-progress line for badges whose metric is in the
    /// fetched achievements payload (plays / listening time / streak).
    private func progressText(for badge: Badge) -> String? {
        guard let data = account.achievements else { return nil }
        switch badge.id {
        case "plays_10":   return "Progress: \(data.totalPlays) / 10 plays"
        case "plays_50":   return "Progress: \(data.totalPlays) / 50 plays"
        case "plays_100":  return "Progress: \(data.totalPlays) / 100 plays"
        case "plays_500":  return "Progress: \(data.totalPlays) / 500 plays"
        case "plays_1000": return "Progress: \(data.totalPlays) / 1000 plays"
        case "hours_1":    return "Progress: \(data.totalListenSeconds / 3600) / 1 hour"
        case "hours_10":   return "Progress: \(data.totalListenSeconds / 3600) / 10 hours"
        case "hours_24":   return "Progress: \(data.totalListenSeconds / 3600) / 24 hours"
        case "hours_100":  return "Progress: \(data.totalListenSeconds / 3600) / 100 hours"
        case "streak_3":   return "Progress: \(data.currentStreakDays) / 3 days"
        case "streak_7":   return "Progress: \(data.currentStreakDays) / 7 days"
        case "streak_30":  return "Progress: \(data.currentStreakDays) / 30 days"
        case "streak_100": return "Progress: \(data.currentStreakDays) / 100 days"
        default:           return nil
        }
    }

    // MARK: - New Badge Detection

    /// Persists earned badge ids to `UserDefaults["earnedBadges"]` (a JSON-encoded
    /// `Set<String>`) and fires a celebratory toast for any badge that's newly
    /// unlocked since the last check. Other features (e.g. settings sync) may
    /// also read/write this same key, so we merge rather than overwrite.
    private func checkForNewBadges() {
        guard let data = account.achievements else { return }
        let currentBadges = Set(data.badges)

        let defaults = UserDefaults.standard
        var earned: Set<String> = []
        if let stored = defaults.data(forKey: "earnedBadges"),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: stored) {
            earned = decoded
        }

        let newlyUnlocked = currentBadges.subtracting(earned)
        guard !newlyUnlocked.isEmpty else { return }

        let merged = earned.union(currentBadges)
        if let encoded = try? JSONEncoder().encode(merged) {
            defaults.set(encoded, forKey: "earnedBadges")
        }

        // Celebratory confetti burst — resets itself after playing out so a
        // later unlock in the same session can retrigger it.
        showConfetti = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            showConfetti = false
        }

        // Only toast for badges we recognize (skip silently for any future
        // server-side badge ids this build doesn't know how to display).
        for badge in Self.allBadges where newlyUnlocked.contains(badge.id) {
            ToastCenter.shared.show(
                "Achievement unlocked: \(badge.title)!",
                category: .success,
                icon: badge.icon
            )
            // Also deliver a real device notification so the unlock surfaces
            // even if the user isn't looking at this screen.
            NotificationService.shared.notify(
                title: "Achievement Unlocked 🏆",
                body: "\(badge.title) — \(badge.requirement)",
                identifier: "badge-\(badge.id)"
            )
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }

    private func streakLabel(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }

    private func formattedListenTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    @ViewBuilder
    private func badgeCell(_ badge: Badge, unlocked: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: badge.icon)
                .font(.system(size: 24))
                .foregroundStyle(unlocked ? AppTheme.dynamicAccent : AppTheme.textSecondary.opacity(0.4))
            Text(badge.title)
                .font(AppTheme.bodyFont(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(unlocked ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.5))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(unlocked ? AppTheme.dynamicAccent.opacity(0.12) : AppTheme.surface.opacity(0.5))
        )
        .opacity(unlocked ? 1 : 0.6)
    }

    fileprivate struct Badge: Identifiable {
        let id: String
        let title: String
        let icon: String
        /// Plain-language description of exactly how to unlock the badge,
        /// shown in the tap-to-reveal detail sheet.
        let requirement: String
    }

    fileprivate static let allBadges: [Badge] = [
        Badge(id: "plays_10", title: "10 Plays", icon: "play.circle",
              requirement: "Play 10 tracks. Every time a song finishes (or you skip past the halfway point) it counts toward your total plays."),
        Badge(id: "plays_50", title: "50 Plays", icon: "play.circle.fill",
              requirement: "Reach 50 total plays across your whole library."),
        Badge(id: "plays_100", title: "100 Plays", icon: "repeat.circle",
              requirement: "Reach 100 total plays. Keep listening — every track counts."),
        Badge(id: "plays_500", title: "500 Plays", icon: "repeat.circle.fill",
              requirement: "Reach 500 total plays. A serious listening milestone."),
        Badge(id: "plays_1000", title: "1000 Plays", icon: "star.circle.fill",
              requirement: "Reach 1,000 total plays. Reserved for the most dedicated listeners."),
        Badge(id: "hours_1", title: "1 Hour Listened", icon: "clock",
              requirement: "Spend 1 hour of total listening time in the app."),
        Badge(id: "hours_10", title: "10 Hours Listened", icon: "clock.fill",
              requirement: "Accumulate 10 hours of total listening time."),
        Badge(id: "hours_24", title: "24 Hours Listened", icon: "timer",
              requirement: "Accumulate a full day (24 hours) of total listening time."),
        Badge(id: "hours_100", title: "100 Hours Listened", icon: "hourglass",
              requirement: "Accumulate 100 hours of total listening time."),
        Badge(id: "streak_3", title: "3-Day Streak", icon: "flame",
              requirement: "Listen to at least one track on 3 days in a row to start a streak."),
        Badge(id: "streak_7", title: "Week Streak", icon: "flame.fill",
              requirement: "Keep your daily listening streak going for 7 days straight."),
        Badge(id: "streak_30", title: "Month Streak", icon: "calendar",
              requirement: "Listen at least once a day for 30 consecutive days."),
        Badge(id: "streak_100", title: "100-Day Streak", icon: "calendar.badge.clock",
              requirement: "Maintain a daily listening streak for 100 consecutive days."),
        Badge(id: "night_owl", title: "Night Owl", icon: "moon.stars.fill",
              requirement: "Listen to music late at night (between midnight and 5 AM)."),
        Badge(id: "early_bird", title: "Early Bird", icon: "sunrise.fill",
              requirement: "Listen to music early in the morning (between 5 AM and 8 AM)."),
        Badge(id: "marathon", title: "Marathon", icon: "figure.run.circle.fill",
              requirement: "Listen for 3+ hours in a single day without a long break."),
        Badge(id: "crate_digger", title: "Crate Digger", icon: "shippingbox.fill",
              requirement: "Build a large library — import or download a big collection of tracks."),
        Badge(id: "globe_trotter", title: "Globe Trotter", icon: "globe",
              requirement: "Listen to music from many different artists across your library."),
        Badge(id: "completionist", title: "Completionist", icon: "checkmark.seal.fill",
              requirement: "Play an album all the way through, from the first track to the last."),
        Badge(id: "shuffle_master", title: "Shuffle Master", icon: "shuffle",
              requirement: "Listen to a long shuffled session with shuffle mode turned on."),
    ]
}
