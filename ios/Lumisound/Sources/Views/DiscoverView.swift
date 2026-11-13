import SwiftUI

// MARK: - DiscoverView
//
// "What others are listening to" — a public activity feed and trending-tracks
// list, built from users who've opted in via Settings/Account → Share
// Listening Activity. See GET /social/activity and GET /social/discover.

struct DiscoverView: View {
    @EnvironmentObject private var account: AccountService

    @State private var isLoading = false
    @State private var selectedTab: Tab = .trending
    @Namespace private var pillNamespace

    private enum Tab: String, CaseIterable, Identifiable {
        case trending = "Trending"
        case activity = "Activity"
        var id: String { rawValue }
    }

    /// Custom pill selector matching LibraryTabBar's visual language — the
    /// native `.segmented` Picker this replaced rendered with stock iOS
    /// colors and no accent tint, the only place in the app still using a
    /// default-styled control instead of the app's own pill/capsule design.
    private var tabSelector: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases) { tab in
                Button {
                    withAnimation(LumiMotion.settle) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(selectedTab == tab ? .white : AppTheme.textSecondary)
                        .background {
                            if selectedTab == tab {
                                Capsule(style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [AppTheme.dynamicAccent, AppTheme.accentSoft],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        )
                                    )
                                    .shadow(color: AppTheme.dynamicAccent.opacity(0.4), radius: 6, x: 0, y: 3)
                                    .matchedGeometryEffect(id: "discoverTabPill", in: pillNamespace)
                            } else {
                                Capsule(style: .continuous)
                                    .fill(AppTheme.surface.opacity(0.6))
                                    .overlay(Capsule().stroke(.white.opacity(0.06), lineWidth: 1))
                            }
                        }
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabSelector

            LKPage(title: "Discover", subtitle: "What other listeners are playing and loving.", icon: "sparkles", tint: .purple) {
                if account.isLoggedIn {
                    LKSection {
                        NavigationLink(destination: DiscoverMixView()) {
                            Label("Discover Mix", systemImage: "sparkles")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .buttonStyle(LKRowLinkStyle())
                        NavigationLink(destination: OnThisDayView()) {
                            Label("On This Day", systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .buttonStyle(LKRowLinkStyle())
                        NavigationLink(destination: SubscriptionsView()) {
                            Label("Subscriptions", systemImage: "person.crop.circle.badge.checkmark")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .buttonStyle(LKRowLinkStyle())
                        NavigationLink(destination: ListeningTwinView()) {
                            Label("Listening Twin", systemImage: "person.2.wave.2")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .buttonStyle(LKRowLinkStyle())
                    }
                }

                if !(account.currentUser?.shareListeningActivity ?? false) {
                    LKSection {
                        Text("Turn on \"Share Listening Activity\" in Account settings to appear here and help power Trending.")
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }

                switch selectedTab {
                case .trending:
                    if account.trendingTracks.isEmpty {
                        emptyRow("Nothing trending yet. Check back once more listeners opt in.")
                    } else {
                        LKSection {
                            ForEach(Array(account.trendingTracks.enumerated()), id: \.element.id) { index, track in
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(AppTheme.monoFont(size: 14))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .frame(width: 24, alignment: .center)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(AppTheme.bodyFont(size: 14))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .lineLimit(1)
                                        if let artist = track.artist, !artist.isEmpty {
                                            Text(artist)
                                                .font(AppTheme.bodyFont(size: 12))
                                                .foregroundStyle(AppTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(track.playCount) plays")
                                            .font(AppTheme.bodyFont(size: 11))
                                            .foregroundStyle(AppTheme.textSecondary)
                                        Text("\(track.listenerCount) listener\(track.listenerCount == 1 ? "" : "s")")
                                            .font(AppTheme.bodyFont(size: 11))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            }
                        } header: {
                            sectionHeader("Trending — last 7 days")
                        }
                    }

                case .activity:
                    if account.socialActivity.isEmpty {
                        emptyRow("No recent activity from users sharing their listening.")
                    } else {
                        LKSection {
                            ForEach(account.socialActivity) { entry in
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(AppTheme.elevatedSurface)
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Text(initials(for: entry))
                                                .font(.caption.bold())
                                                .foregroundStyle(AppTheme.dynamicAccent)
                                        )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(displayName(for: entry)) played \(entry.title ?? "a track")")
                                            .font(AppTheme.bodyFont(size: 13))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .lineLimit(2)
                                        if let artist = entry.artist, !artist.isEmpty {
                                            Text(artist)
                                                .font(AppTheme.bodyFont(size: 12))
                                                .foregroundStyle(AppTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if let date = entry.date {
                                        Text(date, style: .relative)
                                            .font(AppTheme.bodyFont(size: 11))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            }
                        } header: {
                            sectionHeader("Recent Activity")
                        }
                    }
                }
            }
            // Without an explicit style this defaults to a grouped-card look —
            // see FavoritesView's identical fix.
        }
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        async let activity: Void = account.fetchSocialActivity()
        async let trending: Void = account.fetchTrendingTracks()
        _ = await (activity, trending)
        isLoading = false
    }

    private func displayName(for entry: ActivityEntry) -> String {
        if let name = entry.displayName, !name.isEmpty { return name }
        return entry.username
    }

    private func initials(for entry: ActivityEntry) -> String {
        let name = displayName(for: entry)
        return String(name.prefix(1)).uppercased()
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }

    private func emptyRow(_ text: String) -> some View {
        LKSection {
            Text(text)
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }
}
