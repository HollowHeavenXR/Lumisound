import SwiftUI

// MARK: - SubscriptionsView
//
// Lets the user follow YouTube/SoundCloud channels (GET/POST/DELETE
// /user/subscriptions). "Check Now" re-resolves a channel's latest uploads
// and surfaces any new tracks, also creating an in-app notification (unless
// that channel is muted). Each subscription can also: auto-download new
// uploads into the library, be filed under a free-text category, and shows
// an upload-frequency insight ("Uploads ~weekly") plus a one-tap unsubscribe
// suggestion once it's gone stale. A toolbar link opens the aggregated "New
// Releases" feed across every followed channel.

struct SubscriptionsView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager

    @State private var subscriptions: [ArtistSubscription] = []
    @State private var isLoading = false

    @State private var channelURL = ""
    @State private var channelName = ""
    @State private var isAdding = false
    @State private var errorText: String?

    @State private var checkingID: String?
    @State private var isCheckingAll = false
    @State private var newTracksBySubscription: [String: [StreamTrack]] = [:]
    @State private var loadingTrackID: String?

    // Categories (Feature: subscriptions-expansion) — nil selection shows every subscription.
    @State private var selectedCategory: String?

    // Per-subscription settings sheet (auto-download, mute, category).
    @State private var editingSubscription: ArtistSubscription?

    // Unread badge for the "New Releases" feed toolbar link.
    @State private var unreadFeedCount = 0

    // Tracked playlists (local, on-device) — a separate area from channel follows.
    @ObservedObject private var trackedStore = TrackedPlaylistStore.shared
    @State private var playlistURL = ""
    @State private var playlistName = ""
    @State private var playlistError: String?

    /// Subscriptions filtered to `selectedCategory`, or all of them if nil.
    private var filteredSubscriptions: [ArtistSubscription] {
        guard let selectedCategory else { return subscriptions }
        return subscriptions.filter { $0.category == selectedCategory }
    }

    /// Every distinct category currently in use, sorted, for the filter menu.
    private var availableCategories: [String] {
        Array(Set(subscriptions.compactMap { $0.category })).sorted()
    }

    /// Channels or playlists.
    enum Shelf: String { case channels, playlists }
    @State private var shelf: Shelf = .channels
    @State private var showAdd = false

    private var autoDownloadCount: Int {
        subscriptions.filter(\.autoDownload).count + trackedStore.playlists.filter(\.isAutoDownload).count
    }

    var body: some View {
        LKPage(title: "Subscriptions", subtitle: "Channels and playlists Lumisound watches and downloads for you.",
               icon: "dot.radiowaves.left.and.right", tint: .cyan, showsHero: false) {
            dashboard
            if showAdd { addCard.transition(.opacity.combined(with: .move(edge: .top))) }
            LKSegmented(options: [(Shelf.channels, "Channels · \(subscriptions.count)"), (Shelf.playlists, "Playlists · \(trackedStore.playlists.count)")],
                        selection: $shelf, tint: .cyan)
            if shelf == .channels {
                channelShelf
            } else {
                playlistShelf
            }
        }
        .animation(LumiMotion.fade(0.22), value: shelf)
        .animation(LumiMotion.fade(0.22), value: showAdd)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(LumiMotion.glide) { showAdd.toggle() }
                } label: {
                    Image(systemName: showAdd ? "xmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.cyan)
                }
                .accessibilityLabel(showAdd ? "Close" : "Add channel or playlist")
            }
        }
        .sheet(item: $editingSubscription) { sub in
            SubscriptionSettingsSheet(subscription: sub) {
                Task { await load() }
            }
        }
        .task {
            await load()
            unreadFeedCount = await account.fetchSubscriptionFeed(unreadOnly: true, limit: 200).count
            if subscriptions.isEmpty && trackedStore.playlists.isEmpty { showAdd = true }
        }
        .refreshable { await load() }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LKStat(value: "\(subscriptions.count)", label: "Channels", icon: "person.2.wave.2", tint: .cyan)
                LKStat(value: "\(trackedStore.playlists.count)", label: "Playlists", icon: "music.note.list", tint: .blue)
                LKStat(value: "\(autoDownloadCount)", label: "Auto-download", icon: "arrow.down.circle", tint: .green)
            }
            HStack(spacing: 10) {
                NavigationLink {
                    SubscriptionFeedView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 16, weight: .bold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("New Releases").font(.subheadline.weight(.semibold))
                            Text(unreadFeedCount > 0 ? "\(min(unreadFeedCount, 99)) unread" : "All caught up").font(.caption2).opacity(0.85)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .padding(12)
                    .foregroundStyle(.white)
                    .background(Color.cyan.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                if !subscriptions.isEmpty {
                    Button { checkAll() } label: {
                        VStack(spacing: 4) {
                            if isCheckingAll { ProgressView().tint(.cyan) } else { Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .bold)) }
                            Text("Check all").font(.caption2.weight(.semibold))
                        }
                        .frame(width: 84, height: 52)
                        .foregroundStyle(.cyan)
                        .background(Color.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isCheckingAll || checkingID != nil)
                }
            }
        }
    }

    // MARK: Add

    /// One box for both: a playlist link (list=…) is tracked, anything else is followed as a channel.
    private var addCard: some View {
        let input = shelf == .playlists ? playlistURL : channelURL
        let isPlaylist = shelf == .playlists || input.contains("list=")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isPlaylist ? "music.note.list" : "person.crop.circle.badge.plus")
                    .foregroundStyle(.cyan)
                Text(isPlaylist ? "Track a playlist" : "Follow a channel")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            LKField(placeholder: shelf == .playlists ? "YouTube playlist link" : "Channel or playlist link, @handle or name",
                    text: shelf == .playlists ? $playlistURL : $channelURL)
                .keyboardType(.URL)
            LKField(placeholder: "Name (optional)", text: shelf == .playlists ? $playlistName : $channelName)
            LKPrimaryButton(title: isPlaylist ? "Track Playlist" : "Follow", icon: isPlaylist ? "plus" : "bell.badge", tint: .cyan, busy: isAdding) {
                if isPlaylist {
                    if shelf == .channels {
                        playlistURL = channelURL
                        playlistName = channelName
                        channelURL = ""
                        channelName = ""
                        shelf = .playlists
                    }
                    addPlaylist()
                } else {
                    addSubscription()
                }
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            if let errorText, !isPlaylist {
                Text(errorText).font(.footnote).foregroundStyle(AppTheme.error)
            }
            if let playlistError, isPlaylist {
                Text(playlistError).font(.footnote).foregroundStyle(AppTheme.error)
            }
            Text(isPlaylist
                 ? "Open a tracked playlist to download it. Anything already in your library is skipped."
                 : "New uploads are checked in the background (when iOS allows) and announced unless the channel is muted.")
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(14)
        .background(LKCardBackground(tint: .cyan))
    }

    // MARK: Channels

    @ViewBuilder
    private var channelShelf: some View {
        if !availableCategories.isEmpty { categoryFilterBar }
        if isLoading && subscriptions.isEmpty {
            ProgressView().tint(.cyan).frame(maxWidth: .infinity).padding(30)
        } else if subscriptions.isEmpty {
            LKEmpty(icon: "person.crop.circle.badge.checkmark", title: "No channels yet",
                    message: "Follow a YouTube or SoundCloud channel to hear about new uploads.", tint: .cyan)
        } else if filteredSubscriptions.isEmpty {
            LKEmpty(icon: "line.3.horizontal.decrease.circle", title: "Nothing in \"\(selectedCategory ?? "")\"", tint: .cyan)
        } else {
            // One grouped card of compact rows: ~56pt per channel instead of a
            // full card each, so a long follow list fits on a screen or two.
            VStack(spacing: 0) {
                ForEach(Array(filteredSubscriptions.enumerated()), id: \.element.id) { index, sub in
                    if index > 0 { LKDivider(inset: 62) }
                    channelRow(sub)
                }
            }
            .padding(.vertical, 4)
            .background(LKCardBackground())
        }
    }

    private func channelRow(_ sub: ArtistSubscription) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                channelThumbnail(for: sub)
                    .frame(width: 38, height: 38)
                    .overlay(alignment: .bottomTrailing) {
                        if sub.autoDownload {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white, .green)
                                .background(Circle().fill(AppTheme.surface).padding(-1))
                                .offset(x: 3, y: 3)
                                .accessibilityLabel("Auto-download on")
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.channelName ?? sub.channelUrl)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text(channelMeta(sub))
                        .font(.caption2)
                        .foregroundStyle(sub.isStale ? AppTheme.warning : AppTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { toggleMute(sub) } label: {
                    Image(systemName: sub.notificationsMuted ? "bell.slash" : "bell.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(sub.notificationsMuted ? AppTheme.textSecondary : Color.cyan)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(sub.notificationsMuted ? "Unmute alerts" : "Mute alerts")
                Button { check(sub) } label: {
                    Group {
                        if checkingID == sub.id { ProgressView().controlSize(.small).tint(.cyan) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .bold)) }
                    }
                    .foregroundStyle(.cyan)
                    .frame(width: 30, height: 30)
                    .background(Color.cyan.opacity(0.13), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(checkingID != nil || isCheckingAll)
                .accessibilityLabel("Check for new uploads")
                Menu {
                    Button { editingSubscription = sub } label: { Label("Settings", systemImage: "gearshape") }
                    Button(role: .destructive) { remove(sub) } label: { Label("Unfollow", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
            }
            if let newTracks = newTracksBySubscription[sub.id] {
                if newTracks.isEmpty {
                    Text("No new uploads.").font(.caption2).foregroundStyle(AppTheme.textSecondary).padding(.leading, 48)
                } else {
                    VStack(spacing: 0) {
                        ForEach(newTracks) { track in
                            Button { play(track: track) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "play.circle.fill").font(.system(size: 18)).foregroundStyle(.cyan)
                                    Text(track.title).font(.caption).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                    Spacer()
                                    if loadingTrackID == track.id { ProgressView().controlSize(.small) }
                                }
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.leading, 48)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button { editingSubscription = sub } label: { Label("Settings", systemImage: "gearshape") }
            Button(role: .destructive) { remove(sub) } label: { Label("Unfollow", systemImage: "trash") }
        }
    }

    /// "Rock · Uploads ~weekly", or a quiet-channel hint once it's gone stale.
    private func channelMeta(_ sub: ArtistSubscription) -> String {
        var parts: [String] = []
        if let category = sub.category { parts.append(category) }
        if sub.isStale {
            parts.append("Quiet for a long time")
        } else if let freq = sub.uploadFrequencyLabel {
            parts.append(freq)
        }
        if sub.notificationsMuted { parts.append("Muted") }
        return parts.isEmpty ? "Following" : parts.joined(separator: " · ")
    }

    // MARK: Playlists

    @ViewBuilder
    private var playlistShelf: some View {
        if trackedStore.playlists.isEmpty {
            LKEmpty(icon: "music.note.list", title: "No tracked playlists",
                    message: "Paste a YouTube playlist link to keep it in sync with your library.", tint: .blue)
        } else {
            LKGrid {
                ForEach(trackedStore.playlists) { pl in
                    NavigationLink {
                        TrackedPlaylistDetailView(playlist: pl)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            playlistThumbnail(for: pl)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .background(AppTheme.elevatedSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    if pl.isAutoDownload {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.white, .green)
                                            .padding(6)
                                    }
                                }
                            Text(pl.name).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                            Text(pl.lastTrackCount > 0 ? "\(pl.lastTrackCount) tracks" : "Not checked yet")
                                .font(.caption2).foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(10)
                        .background(LKCardBackground(corner: 18))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { trackedStore.remove(id: pl.id) } label: { Label("Stop tracking", systemImage: "trash") }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var categoryFilterBar: some View {
        Group {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryChip(title: "All", isSelected: selectedCategory == nil) {
                        selectedCategory = nil
                    }
                    ForEach(availableCategories, id: \.self) { category in
                        categoryChip(title: category, isSelected: selectedCategory == category) {
                            selectedCategory = (selectedCategory == category) ? nil : category
                        }
                    }
                }
            }
        }
    }

    private func categoryChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LKChip(title: title, selected: isSelected, tint: .cyan)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        subscriptions = await account.fetchSubscriptions()
        if let selectedCategory, !availableCategories.contains(selectedCategory) {
            self.selectedCategory = nil
        }
        isLoading = false
    }

    private func toggleMute(_ sub: ArtistSubscription) {
        Task {
            if await account.updateSubscriptionSettings(id: sub.id, notificationsMuted: !sub.notificationsMuted) {
                await load()
            }
        }
    }

    private func addSubscription() {
        let trimmedURL = channelURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else { return }
        let trimmedName = channelName.trimmingCharacters(in: .whitespaces)
        isAdding = true
        errorText = nil
        Task {
            if await account.addSubscription(channelUrl: trimmedURL, channelName: trimmedName.isEmpty ? nil : trimmedName) {
                channelURL = ""
                channelName = ""
                await load()
            } else {
                errorText = account.errorMessage ?? "Failed to add subscription."
            }
            isAdding = false
        }
    }

    private func remove(_ sub: ArtistSubscription) {
        Task {
            if await account.removeSubscription(id: sub.id) {
                subscriptions.removeAll { $0.id == sub.id }
                newTracksBySubscription[sub.id] = nil
            }
        }
    }

    private func check(_ sub: ArtistSubscription) {
        checkingID = sub.id
        Task {
            newTracksBySubscription[sub.id] = await account.checkSubscriptionAndAutoDownload(
                sub, streaming: streaming, library: library
            )
            checkingID = nil
        }
    }

    /// Checks every subscription in turn, same as tapping "Check" on each
    /// row — this is the manual, foreground equivalent of what
    /// `BackgroundRefreshService` runs periodically in the background.
    /// Subscriptions with auto-download on also get any new tracks
    /// downloaded straight into the library.
    private func checkAll() {
        guard !isCheckingAll else { return }
        isCheckingAll = true
        Task {
            for sub in subscriptions {
                newTracksBySubscription[sub.id] = await account.checkSubscriptionAndAutoDownload(
                    sub, streaming: streaming, library: library
                )
            }
            isCheckingAll = false
        }
    }

    private func play(track: StreamTrack) {
        guard loadingTrackID == nil else { return }
        loadingTrackID = track.id
        Task {
            defer { loadingTrackID = nil }
            do {
                let url = try await streaming.streamURL(for: track)
                let song = streaming.toSong(track: track, streamURL: url)
                player.play(song: song, in: [song])
            } catch {
                streaming.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Tracked Playlists

    @ViewBuilder
    private func playlistThumbnail(for pl: TrackedPlaylist) -> some View {
        if let url = URL(string: pl.thumbnailURL), !pl.thumbnailURL.isEmpty {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Image(systemName: "music.note.list")
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        } else {
            Image(systemName: "music.note.list")
                .font(.system(size: 30))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addPlaylist() {
        let url = playlistURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        playlistError = nil
        if trackedStore.add(url: url, name: playlistName) {
            playlistURL = ""
            playlistName = ""
        } else {
            playlistError = "That playlist is already tracked (or the URL is invalid)."
        }
    }

    @ViewBuilder
    private func channelThumbnail(for sub: ArtistSubscription) -> some View {
        if let thumb = sub.channelThumbnail, let url = URL(string: thumb), !thumb.isEmpty {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
        }
    }
}
