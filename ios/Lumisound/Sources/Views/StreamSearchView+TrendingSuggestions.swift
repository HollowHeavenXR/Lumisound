import SwiftUI
import UniformTypeIdentifiers

extension StreamSearchView {

    // MARK: — Trending searches & suggestions
    //
    // Data reality check (see StreamingService+Search.swift): the bridge's
    // GET /api/search/trending only ever returns `{ query, count }` pairs for
    // a given `days` window — there's no genre/source/region breakdown to
    // key a "trending by category" split on. What the endpoint DOES already
    // support is the `days` window itself, so the real, data-backed
    // improvement here is exposing that as a genuine Today / This Week /
    // This Month facet (previously hardcoded to 7 and never surfaced),
    // plus a manual refresh with a staleness indicator, plus replacing the
    // flat numbered list with ranked "heat" cards. True per-genre/region
    // trending would need a new bridge endpoint — see the workstream summary.

    /// Which time window is currently selected, derived from `trendingWindowDays`.
    private var currentTrendingWindow: TrendingWindow {
        TrendingWindow(rawValue: trendingWindowDays) ?? .week
    }

    /// Highest count in the current list — used to normalize each item's
    /// "heat bar" width to 0...1 relative to the top query, so the bars read
    /// as a comparison rather than an arbitrary length.
    private var trendingMaxCount: Int {
        trendingQueries.map(\.count).max() ?? 1
    }

    /// First few entries get the larger "hero" card treatment in a
    /// horizontal carousel; the rest fall back to a compact ranked list —
    /// mirrors how most charts apps present a top tier vs. the long tail.
    private var trendingHeroCount: Int { min(5, trendingQueries.count) }
    private var trendingHeroItems: [SearchQueryCount] { Array(trendingQueries.prefix(trendingHeroCount)) }
    private var trendingRestItems: [SearchQueryCount] {
        trendingQueries.count > trendingHeroCount ? Array(trendingQueries[trendingHeroCount...]) : []
    }

    /// Fetches trending queries for `days` and updates the staleness clock.
    /// Shared by the initial load, the window switcher, and manual refresh.
    func loadTrending(days: Int) {
        trendingWindowDays = days
        isLoadingTrending = true
        Task {
            let results = await streaming.searchTrending(limit: 15, days: days)
            trendingQueries = results
            trendingLastUpdated = Date()
            isLoadingTrending = false
        }
    }

    /// Async twin of `loadTrending(days:)` for SwiftUI's `.refreshable`,
    /// which needs an awaitable closure rather than a fire-and-forget `Task`.
    func refreshTrendingAsync() async {
        isLoadingTrending = true
        let results = await streaming.searchTrending(limit: 15, days: trendingWindowDays)
        trendingQueries = results
        trendingLastUpdated = Date()
        isLoadingTrending = false
    }

    var trendingSearchesBody: some View {
        Group {
            if trendingQueries.isEmpty && isLoadingTrending {
                VStack(alignment: .leading, spacing: 0) {
                    trendingHeader
                    SkeletonList(rowCount: 5)
                }
            } else if trendingQueries.isEmpty {
                VStack(spacing: 0) {
                    Spacer()
                    CloudEmptyStateView(
                        icon: "flame",
                        title: "Nothing Trending Yet",
                        message: "Search YouTube or SoundCloud, or paste a playlist URL — including a Bandcamp track/album link or a Spotify track/album/playlist link. Popular searches will show up here.",
                        actionTitle: "Refresh",
                        action: { loadTrending(days: trendingWindowDays) }
                    )
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        trendingHeader

                        // Top tier — ranked "heat" cards in a horizontal carousel.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(trendingHeroItems.enumerated()), id: \.element.id) { idx, item in
                                    TrendingHeroCard(rank: idx + 1, item: item, maxCount: trendingMaxCount) {
                                        searchText = item.query
                                        triggerSearch()
                                    }
                                    .modifier(StaggeredFadeInModifier(index: idx, token: resultsAnimationToken))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 2)
                        }

                        // Long tail — compact ranked rows.
                        if !trendingRestItems.isEmpty {
                            VStack(spacing: 8) {
                                ForEach(Array(trendingRestItems.enumerated()), id: \.element.id) { idx, item in
                                    TrendingRankRow(rank: idx + trendingHeroCount + 1, item: item, maxCount: trendingMaxCount) {
                                        searchText = item.query
                                        triggerSearch()
                                    }
                                    .modifier(StaggeredFadeInModifier(index: idx + trendingHeroCount, token: resultsAnimationToken))
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    // Extra clearance below the last row — MiniPlayerBar
                    // (80pt) + tab bar (~83pt) + margin, see SongsTab's
                    // identical fix.
                    .padding(.bottom, 190)
                }
                .scrollContentBackground(.hidden)
                .refreshable {
                    await refreshTrendingAsync()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: trendingQueries.isEmpty)
    }

    /// Header row: flame label, time-window switcher, refresh button, and a
    /// staleness caption underneath.
    private var trendingHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                CloudSectionHeader(icon: "flame.fill", text: "Trending Searches")
                Spacer()
                trendingWindowMenu
                trendingRefreshButton
            }
            if !trendingUpdatedText.isEmpty {
                Text(trendingUpdatedText)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var trendingWindowMenu: some View {
        LumiMenu {
            ForEach(TrendingWindow.allCases) { window in
                Button {
                    loadTrending(days: window.rawValue)
                } label: {
                    if currentTrendingWindow == window {
                        Label(window.label, systemImage: "checkmark")
                    } else {
                        Text(window.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentTrendingWindow.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(AppTheme.bodyFont(size: 12).weight(.semibold))
            .foregroundStyle(AppTheme.dynamicAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppTheme.dynamicAccent.opacity(0.12), in: Capsule())
        }
    }

    private var trendingRefreshButton: some View {
        Button {
            loadTrending(days: trendingWindowDays)
        } label: {
            Group {
                if isLoadingTrending {
                    ProgressView()
                        .tint(AppTheme.textSecondary)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .frame(width: 26, height: 26)
            .background(AppTheme.surface, in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isLoadingTrending)
    }

    var suggestionsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            CloudSectionHeader(icon: "text.magnifyingglass", text: "Suggestions")
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, item in
                    Button {
                        searchText = item.query
                        triggerSearch()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(width: 20)
                            Text(item.query)
                                .font(AppTheme.bodyFont(size: 14))
                                .foregroundStyle(AppTheme.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(PressableButtonStyle())

                    if idx < suggestions.count - 1 {
                        Divider().background(AppTheme.background)
                    }
                }
            }
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: .ultraThinMaterial)
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
    }
}

// MARK: - TrendingWindow

/// Days-based trending window, mapped straight onto the `days` parameter
/// `searchTrending` already accepts.
private enum TrendingWindow: Int, CaseIterable, Identifiable {
    case today = 1
    case week  = 7
    case month = 30

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .week:  return "This Week"
        case .month: return "This Month"
        }
    }
}

// MARK: - TrendingHeroCard

/// Large ranked card for the top tier of the trending carousel — rank badge
/// (gold/silver/bronze for #1-3), query text, and a "heat bar" showing this
/// query's popularity relative to the #1 spot.
private struct TrendingHeroCard: View {
    let rank: Int
    let item: SearchQueryCount
    let maxCount: Int
    let action: () -> Void

    private var heatFraction: Double {
        guard maxCount > 0 else { return 0 }
        return min(1, max(0.08, Double(item.count) / Double(maxCount)))
    }

    private var rankColors: [Color] {
        switch rank {
        case 1:  return [Color(red: 1.0, green: 0.84, blue: 0.4), Color(red: 0.87, green: 0.63, blue: 0.12)]
        case 2:  return [Color(white: 0.88), Color(white: 0.62)]
        case 3:  return [Color(red: 0.82, green: 0.55, blue: 0.33), Color(red: 0.58, green: 0.37, blue: 0.22)]
        default: return [AppTheme.dynamicAccent, AppTheme.dynamicAccentSecondary]
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: rankColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 28, height: 28)
                        Text("\(rank)")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    if rank <= 3 {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(rankColors[0])
                    }
                }

                Text(item.query)
                    .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(AppTheme.elevatedSurface)
                            Capsule()
                                .fill(LinearGradient(colors: rankColors, startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(4, geo.size.width * heatFraction))
                        }
                    }
                    .frame(height: 5)

                    Text("\(item.count) \(item.count == 1 ? "search" : "searches")")
                        .font(AppTheme.monoFont(size: 10))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(14)
            .frame(width: 158, height: 150, alignment: .topLeading)
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), fallback: .ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - TrendingRankRow

/// Compact ranked row for the long tail of the trending list (rank 6+).
private struct TrendingRankRow: View {
    let rank: Int
    let item: SearchQueryCount
    let maxCount: Int
    let action: () -> Void

    private var heatFraction: Double {
        guard maxCount > 0 else { return 0 }
        return min(1, max(0.05, Double(item.count) / Double(maxCount)))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 20, alignment: .center)

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.query)
                        .font(AppTheme.bodyFont(size: 14))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(AppTheme.elevatedSurface)
                            Capsule()
                                .fill(AppTheme.dynamicAccent.opacity(0.85))
                                .frame(width: max(3, geo.size.width * heatFraction))
                        }
                    }
                    .frame(height: 4)
                }

                Spacer(minLength: 8)

                Text("\(item.count)")
                    .font(AppTheme.monoFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), fallback: .ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
    }
}
