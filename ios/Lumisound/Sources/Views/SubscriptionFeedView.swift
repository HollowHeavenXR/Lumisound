import SwiftUI

// MARK: - SubscriptionFeedView
//
// Aggregated "New Releases" feed — every new upload discovered across ALL
// followed channels (from a manual "Check"/"Check All" tap, auto-download,
// or the bridge's own periodic background polling loop) in one scrollable
// list, instead of checking each subscription individually. Backed by the
// persisted GET/POST/DELETE /user/subscriptions/feed* endpoints, so it also
// surfaces uploads found while the app wasn't open.

struct SubscriptionFeedView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var player: AudioPlayerManager

    @State private var items: [SubscriptionFeedItem] = []
    @State private var isLoading = false
    @State private var loadingItemID: String?

    var body: some View {
        List {
            if isLoading && items.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if items.isEmpty {
                EmptyStateView(
                    icon: "sparkles",
                    title: "No new releases yet",
                    message: "New uploads from channels you follow will show up here as they're found — whether you check manually or Lumisound finds them in the background."
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(items) { item in
                    Button {
                        open(item)
                    } label: {
                        HStack(spacing: 12) {
                            thumbnail(for: item)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.track?.title ?? "Unknown track")
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .lineLimit(1)
                                Text(item.channelName ?? item.track?.artist ?? "")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineLimit(1)
                                if let discoveredAt = item.discoveredAt, let date = parseServerDate(discoveredAt) {
                                    Text(relativeDateString(date))
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                            }
                            Spacer()
                            if loadingItemID == item.id {
                                ProgressView()
                            } else if !item.isRead {
                                Circle()
                                    .fill(AppTheme.dynamicAccent)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AppTheme.surface.opacity(item.isRead ? 0.4 : 0.7))
                    .swipeActions {
                        Button(role: .destructive) {
                            dismissItem(item)
                        } label: {
                            Label("Dismiss", systemImage: "xmark")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear.ignoresSafeArea())
        .navigationTitle("New Releases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if items.contains(where: { !$0.isRead }) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Mark All Read") {
                        Task {
                            await account.markAllSubscriptionFeedRead()
                            markAllReadLocally()
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        items = await account.fetchSubscriptionFeed()
        isLoading = false
    }

    private func open(_ item: SubscriptionFeedItem) {
        if !item.isRead {
            markReadLocally(item.id)
            Task { await account.markSubscriptionFeedItemRead(id: item.id) }
        }
        guard let track = item.track else { return }
        guard loadingItemID == nil else { return }
        loadingItemID = item.id
        Task {
            defer { loadingItemID = nil }
            do {
                let url = try await streaming.streamURL(for: track)
                let song = streaming.toSong(track: track, streamURL: url)
                player.play(song: song, in: [song])
            } catch {
                streaming.errorMessage = error.localizedDescription
            }
        }
    }

    private func dismissItem(_ item: SubscriptionFeedItem) {
        items.removeAll { $0.id == item.id }
        Task { await account.dismissSubscriptionFeedItem(id: item.id) }
    }

    // `SubscriptionFeedItem` is a plain `Decodable` with `let` fields, so
    // optimistic local read-state updates go through a rebuild rather than
    // in-place mutation.
    private func markReadLocally(_ id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[idx]
        items[idx] = SubscriptionFeedItem(
            id: item.id, subscriptionId: item.subscriptionId, track: item.track,
            discoveredAt: item.discoveredAt, isRead: true,
            channelName: item.channelName, channelThumbnail: item.channelThumbnail
        )
    }

    private func markAllReadLocally() {
        items = items.map { item in
            SubscriptionFeedItem(
                id: item.id, subscriptionId: item.subscriptionId, track: item.track,
                discoveredAt: item.discoveredAt, isRead: true,
                channelName: item.channelName, channelThumbnail: item.channelThumbnail
            )
        }
    }

    /// Shared — called for every feed row on every render.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func relativeDateString(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func thumbnail(for item: SubscriptionFeedItem) -> some View {
        let thumbURLString = item.track?.thumbnailURL ?? item.channelThumbnail ?? ""
        if let url = URL(string: thumbURLString), !thumbURLString.isEmpty {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Image(systemName: "music.note")
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 22))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 44, height: 44)
        }
    }
}
