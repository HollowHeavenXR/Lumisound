import SwiftUI

// MARK: - TVStatsView
//
// Round 3: lifetime stats, a 7-day activity chart, and achievement badges —
// all from GET /user/stats, /user/stats/weekly, /user/achievements (the same
// server-side play-history aggregation iOS's AccountService+Stats.swift and
// AchievementsView.swift already use). Badge catalog ported from
// AchievementsView.swift's `allBadges`, including the per-badge "how to
// unlock" detail sheet (originally skipped as a first-pass scope call, not
// a technical blocker — see TVOS_SKIPPED_FEATURES.md).

struct TVStatsView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String

    /// The badge whose "how to unlock" detail sheet is currently presented —
    /// same shape as `AchievementsView.selectedBadge` on iOS.
    @State private var selectedBadge: TVBadge?

    var body: some View {
        ScrollView {
            if client.isLoadingStats && client.stats == nil {
                TVLoadingState(text: "Loading your stats…")
            } else {
                VStack(alignment: .leading, spacing: TVMetrics.section) {
                    TVScreenTitle(title: "Listening Stats", eyebrow: "Account")
                    lifetimeSection.padding(.horizontal, TVMetrics.margin)
                    HStack(alignment: .top, spacing: 40) {
                        weeklySection
                        streakCard
                    }
                    .padding(.horizontal, TVMetrics.margin)
                    topArtistsShelf
                    topTracksShelf
                    badgesSection
                        .padding(.horizontal, TVMetrics.margin)
                }
                .padding(.bottom, 80)
            }
        }
        .tvAmbientBackground()
        .task {
            if client.stats == nil { await client.fetchStats(token: token) }
        }
        .sheet(item: $selectedBadge) { badge in
            badgeDetailSheet(badge, isUnlocked: (client.achievements?.badges ?? []).contains(badge.id))
        }
    }

    // MARK: Lifetime summary

    /// The two headline numbers, big. Everything else on the screen is detail
    /// under these.
    private var lifetimeSection: some View {
        HStack(spacing: 30) {
            heroNumber(value: "\(client.stats?.totalPlays ?? 0)", label: "Total plays",
                       systemImage: "play.fill")
            heroNumber(value: formattedListenTime(client.stats?.totalListenSeconds ?? 0),
                       label: "Time listening", systemImage: "clock.fill")
        }
    }

    private func heroNumber(value: String, label: String, systemImage: String) -> some View {
        HStack(spacing: 26) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Circle().fill(TVPalette.brand))
                .shadow(color: TVPalette.violet.opacity(0.5), radius: 16, y: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 64, weight: .heavy, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(label.uppercased())
                    .font(TVType.eyebrow)
                    .tracking(2)
                    .foregroundStyle(TVPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .tvGlassPanel()
    }

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("STREAKS")
                .font(TVType.eyebrow)
                .tracking(2.4)
                .foregroundStyle(TVPalette.neonAlt)
            streakLine(days: client.achievements?.currentStreakDays ?? 0, label: "Current",
                       systemImage: "flame.fill",
                       color: Color(red: 1.0, green: 0.55, blue: 0.3))
            streakLine(days: client.achievements?.longestStreakDays ?? 0, label: "Longest",
                       systemImage: "trophy.fill",
                       color: Color(red: 1.0, green: 0.80, blue: 0.32))
        }
        .padding(30)
        .frame(width: 380, height: 300, alignment: .topLeading)
        .tvGlassPanel()
    }

    private func streakLine(days: Int, label: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(color)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(streakLabel(days))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                Text(label)
                    .font(TVType.rowDetail)
                    .foregroundStyle(TVPalette.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var topArtistsShelf: some View {
        if let stats = client.stats, !stats.topArtists.isEmpty {
            TVShelfSection(title: "Top Artists", subtitle: "Who you play most") {
                ForEach(Array(stats.topArtists.enumerated()), id: \.element.id) { index, artist in
                    rankCard(rank: index + 1, primary: artist.artist, secondary: nil, count: artist.playCount)
                }
            }
        }
    }

    @ViewBuilder
    private var topTracksShelf: some View {
        if let stats = client.stats, !stats.topTracks.isEmpty {
            TVShelfSection(title: "Top Tracks", subtitle: "Your most-played songs") {
                ForEach(Array(stats.topTracks.enumerated()), id: \.element.id) { index, track in
                    rankCard(rank: index + 1, primary: track.title, secondary: track.artist, count: track.playCount)
                }
            }
        }
    }

    /// A ranked entry: the big numeral IS the design — generated art seeded by
    /// the name gives each card its own colour so a row of them isn't a row of
    /// identical grey boxes.
    private func rankCard(rank: Int, primary: String, secondary: String?, count: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            TVGeneratedArt(seed: primary, systemImage: secondary == nil ? "music.mic" : "music.note")
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(rank)")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                Spacer(minLength: 0)
                Text(primary)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(2)
                if let secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                Text("\(count) plays")
                    .font(TVType.meta)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(22)
        }
        .frame(width: 250, height: 250)
        .clipShape(RoundedRectangle(cornerRadius: TVMetrics.cardCorner, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
    }

    // MARK: Weekly activity

    private var weeklySection: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("THIS WEEK")
                .font(TVType.eyebrow)
                .tracking(2.4)
                .foregroundStyle(TVPalette.neonAlt)
            if client.weeklyStats.isEmpty {
                Text("No listening activity in the last 7 days yet.")
                    .font(TVType.body)
                    .foregroundStyle(TVPalette.textTertiary)
                    .frame(maxHeight: .infinity)
            } else {
                let maxSeconds = max(1, client.weeklyStats.map(\.listenSeconds).max() ?? 1)
                HStack(alignment: .bottom, spacing: 28) {
                    ForEach(client.weeklyStats) { day in
                        VStack(spacing: 10) {
                            Text("\(day.plays)")
                                .font(TVType.meta)
                                .foregroundStyle(TVPalette.textSecondary)
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(day.listenSeconds > 0 ? AnyShapeStyle(TVPalette.brandVertical)
                                      : AnyShapeStyle(Color.white.opacity(0.1)))
                                .frame(width: 54, height: max(8, 150 * CGFloat(day.listenSeconds) / CGFloat(maxSeconds)))
                                .shadow(color: day.listenSeconds > 0 ? TVPalette.violet.opacity(0.4) : .clear,
                                        radius: 10, y: 4)
                            Text(weekdayLabel(day.date))
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(TVPalette.textTertiary)
                        }
                    }
                }
                .frame(height: 200, alignment: .bottom)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300, alignment: .topLeading)
        .tvGlassPanel()
    }

    private func weekdayLabel(_ isoDate: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: isoDate) else { return "" }
        let weekday = DateFormatter()
        weekday.dateFormat = "EEE"
        return weekday.string(from: date)
    }

    // MARK: Achievements

    private var badgesSection: some View {
        let unlocked = Set(client.achievements?.badges ?? [])
        let unlockedCount = TVBadge.all.filter { unlocked.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 24) {
            TVSectionHeader(title: "Achievements",
                            subtitle: "\(unlockedCount) of \(TVBadge.all.count) unlocked")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 24)], spacing: 30) {
                ForEach(TVBadge.all) { badge in
                    Button {
                        selectedBadge = badge
                    } label: {
                        badgeCell(badge, isUnlocked: unlocked.contains(badge.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func badgeCell(_ badge: TVBadge, isUnlocked: Bool) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isUnlocked ? AnyShapeStyle(TVPalette.brand) : AnyShapeStyle(Color.white.opacity(0.06)))
                Circle()
                    .strokeBorder(Color.white.opacity(isUnlocked ? 0.3 : 0.1), lineWidth: 1)
                Image(systemName: isUnlocked ? badge.icon : "lock.fill")
                    .font(.system(size: isUnlocked ? 36 : 26, weight: .semibold))
                    .foregroundStyle(isUnlocked ? Color.white : TVPalette.textTertiary)
            }
            .frame(width: 100, height: 100)
            .shadow(color: isUnlocked ? TVPalette.violet.opacity(0.5) : .clear, radius: 18, y: 6)
            Text(badge.title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(isUnlocked ? Color.white : TVPalette.textTertiary)
        }
        .frame(width: 170)
    }

    // MARK: Badge Detail ("how to unlock") Sheet — ported from AchievementsView.swift

    private func badgeDetailSheet(_ badge: TVBadge, isUnlocked: Bool) -> some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(isUnlocked ? AnyShapeStyle(TVPalette.brand) : AnyShapeStyle(Color.white.opacity(0.06)))
                Circle()
                    .strokeBorder(Color.white.opacity(isUnlocked ? 0.3 : 0.1), lineWidth: 1)
                Image(systemName: isUnlocked ? badge.icon : "lock.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(isUnlocked ? Color.white : TVPalette.textTertiary)
            }
            .frame(width: 160, height: 160)
            .shadow(color: isUnlocked ? TVPalette.violet.opacity(0.5) : .clear, radius: 24, y: 8)
            .padding(.top, 20)

            Text(badge.title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)

            HStack(spacing: 8) {
                Image(systemName: isUnlocked ? "checkmark.seal.fill" : "lock.fill")
                Text(isUnlocked ? "Unlocked" : "Locked")
            }
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(isUnlocked ? TVPalette.brand : TVPalette.textTertiary)

            VStack(spacing: 10) {
                Text("HOW TO EARN THIS")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(TVPalette.textTertiary)
                    .kerning(1.2)
                Text(badge.requirement)
                    .font(.system(size: 22, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 60)

            if let progress = progressText(for: badge) {
                Text(progress)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundStyle(TVPalette.textTertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvAmbientBackground()
    }

    /// Best-effort current-progress line for badges whose metric is in the
    /// fetched achievements payload (plays / listening time / streak) — same
    /// metric set `AchievementsView.progressText` uses on iOS.
    private func progressText(for badge: TVBadge) -> String? {
        guard let data = client.achievements else { return nil }
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

    private func streakLabel(_ days: Int) -> String {
        "\(days) \(days == 1 ? "day" : "days")"
    }

    private func formattedListenTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - TVBadge (ported catalog from AchievementsView.swift's `allBadges`)

struct TVBadge: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// Plain-language description of exactly how to unlock the badge, shown
    /// in the tap-to-reveal detail sheet — verbatim from `AchievementsView`'s
    /// `allBadges` on iOS.
    let requirement: String

    static let all: [TVBadge] = [
        TVBadge(id: "plays_10", title: "10 Plays", icon: "play.circle",
                requirement: "Play 10 tracks. Every time a song finishes (or you skip past the halfway point) it counts toward your total plays."),
        TVBadge(id: "plays_50", title: "50 Plays", icon: "play.circle.fill",
                requirement: "Reach 50 total plays across your whole library."),
        TVBadge(id: "plays_100", title: "100 Plays", icon: "repeat.circle",
                requirement: "Reach 100 total plays. Keep listening — every track counts."),
        TVBadge(id: "plays_500", title: "500 Plays", icon: "repeat.circle.fill",
                requirement: "Reach 500 total plays. A serious listening milestone."),
        TVBadge(id: "plays_1000", title: "1000 Plays", icon: "star.circle.fill",
                requirement: "Reach 1,000 total plays. Reserved for the most dedicated listeners."),
        TVBadge(id: "hours_1", title: "1 Hour Listened", icon: "clock",
                requirement: "Spend 1 hour of total listening time in the app."),
        TVBadge(id: "hours_10", title: "10 Hours Listened", icon: "clock.fill",
                requirement: "Accumulate 10 hours of total listening time."),
        TVBadge(id: "hours_24", title: "24 Hours Listened", icon: "timer",
                requirement: "Accumulate a full day (24 hours) of total listening time."),
        TVBadge(id: "hours_100", title: "100 Hours Listened", icon: "hourglass",
                requirement: "Accumulate 100 hours of total listening time."),
        TVBadge(id: "streak_3", title: "3-Day Streak", icon: "flame",
                requirement: "Listen to at least one track on 3 days in a row to start a streak."),
        TVBadge(id: "streak_7", title: "Week Streak", icon: "flame.fill",
                requirement: "Keep your daily listening streak going for 7 days straight."),
        TVBadge(id: "streak_30", title: "Month Streak", icon: "calendar",
                requirement: "Listen at least once a day for 30 consecutive days."),
        TVBadge(id: "streak_100", title: "100-Day Streak", icon: "calendar.badge.clock",
                requirement: "Maintain a daily listening streak for 100 consecutive days."),
        TVBadge(id: "night_owl", title: "Night Owl", icon: "moon.stars.fill",
                requirement: "Listen to music late at night (between midnight and 5 AM)."),
        TVBadge(id: "early_bird", title: "Early Bird", icon: "sunrise.fill",
                requirement: "Listen to music early in the morning (between 5 AM and 8 AM)."),
        TVBadge(id: "marathon", title: "Marathon", icon: "figure.run.circle.fill",
                requirement: "Listen for 3+ hours in a single day without a long break."),
        TVBadge(id: "crate_digger", title: "Crate Digger", icon: "shippingbox.fill",
                requirement: "Build a large library — import or download a big collection of tracks."),
        TVBadge(id: "globe_trotter", title: "Globe Trotter", icon: "globe",
                requirement: "Listen to music from many different artists across your library."),
        TVBadge(id: "completionist", title: "Completionist", icon: "checkmark.seal.fill",
                requirement: "Play an album all the way through, from the first track to the last."),
        TVBadge(id: "shuffle_master", title: "Shuffle Master", icon: "shuffle",
                requirement: "Listen to a long shuffled session with shuffle mode turned on."),
    ]
}
