import SwiftUI

/// A GitHub-contributions-style calendar heatmap of listening activity over
/// the last year (GET /user/stats/heatmap) — weeks as columns, Sunday...
/// Saturday as rows, each day tinted by how many plays it had relative to
/// the busiest day in the window. A different lens on the same
/// `ios_play_history` data `RewindView`'s recap cards and Achievements'
/// streaks already use, laid out for "when do I actually listen" pattern
/// spotting rather than a single number or a leaderboard.
struct ListeningHeatmapView: View {
    @EnvironmentObject private var account: AccountService

    @State private var days: [HeatmapDay] = []
    @State private var isLoading = true

    private let cellSize: CGFloat = 12
    private let cellSpacing: CGFloat = 3
    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().padding(.top, 60)
            } else if days.isEmpty {
                EmptyStateView(
                    icon: "calendar",
                    title: "No Listening History Yet",
                    message: "Play some music and your activity will show up here."
                )
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    LKHero(title: "Heatmap", subtitle: "Every day you listened, at a glance.", icon: "calendar", tint: .green)
                        .padding(.horizontal, 16)
                    summaryRow
                    ScrollView(.horizontal, showsIndicators: false) {
                        heatmapGrid
                            .padding(.horizontal, 16)
                    }
                    legend
                }
                .padding(.vertical, 16)
            }
        }
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Listening Heatmap")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        days = await account.fetchListeningHeatmap()
        isLoading = false
    }

    // MARK: - Derived data

    private var playsByDate: [String: Int] {
        Dictionary(days.map { ($0.date, $0.plays) }, uniquingKeysWith: +)
    }

    private var maxPlays: Int { days.map(\.plays).max() ?? 0 }
    private var totalPlays: Int { days.reduce(0) { $0 + $1.plays } }
    private var activeDayCount: Int { days.filter { $0.plays > 0 }.count }

    /// Every date from the first day in the response through the last, so
    /// the grid has no gaps even on days with zero plays.
    private var orderedDates: [Date] {
        guard let firstKey = days.first?.date, let lastKey = days.last?.date,
              let start = Self.isoFormatter.date(from: firstKey),
              let end = Self.isoFormatter.date(from: lastKey) else { return [] }
        var result: [Date] = []
        var cursor = start
        let calendar = Calendar(identifier: .gregorian)
        while cursor <= end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    // MARK: - Summary

    private var summaryRow: some View {
        HStack(spacing: 20) {
            statTile(value: "\(totalPlays)", label: "plays")
            statTile(value: "\(activeDayCount)", label: "active days")
        }
        .padding(.horizontal, 16)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold()).foregroundStyle(AppTheme.textPrimary)
            Text(label).font(.caption).foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var heatmapGrid: some View {
        let dates = orderedDates
        if let firstDate = dates.first {
            let calendar = Calendar(identifier: .gregorian)
            // Pad so the first column starts on Sunday (weekday 1), same as GitHub's graph.
            let leadingPad = calendar.component(.weekday, from: firstDate) - 1
            let paddedDates: [Date?] = Array(repeating: nil, count: leadingPad) + dates.map { $0 }
            let columns = (paddedDates.count + 6) / 7

            HStack(alignment: .top, spacing: cellSpacing) {
                ForEach(0..<columns, id: \.self) { col in
                    VStack(spacing: cellSpacing) {
                        ForEach(0..<7, id: \.self) { row in
                            let index = col * 7 + row
                            if index < paddedDates.count, let date = paddedDates[index] {
                                cell(for: date)
                            } else {
                                Color.clear.frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(for date: Date) -> some View {
        let plays = playsByDate[Self.isoFormatter.string(from: date)] ?? 0
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(colorForPlays(plays))
            .frame(width: cellSize, height: cellSize)
    }

    private func colorForPlays(_ plays: Int) -> Color {
        guard plays > 0, maxPlays > 0 else { return AppTheme.elevatedSurface }
        let intensity = min(1.0, Double(plays) / Double(maxPlays))
        return AppTheme.dynamicAccent.opacity(0.15 + 0.85 * intensity)
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 6) {
            Text("Less").font(.caption2).foregroundStyle(AppTheme.textSecondary)
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(level == 0 ? AppTheme.elevatedSurface : AppTheme.dynamicAccent.opacity(0.15 + 0.85 * level))
                    .frame(width: cellSize, height: cellSize)
            }
            Text("More").font(.caption2).foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 16)
    }
}
