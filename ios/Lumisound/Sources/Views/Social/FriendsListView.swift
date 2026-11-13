import SwiftUI

// MARK: - FriendsListView
//
// The main Friends hub, redesigned (2026-07-21) around a Discord-style
// segmented structure instead of one long flat scroll: Friends / Discover /
// Requests / Activity, switched via a horizontal chip picker rather than a
// stack of NavigationLink rows. Every capability from the original single-
// screen version is preserved — search/add by username and mutual-friend
// suggestions now live under "Discover", accept/decline/cancel requests
// under "Requests" (still badge-counted, now on the picker chip itself),
// the friends-only activity feed and blocked-users management are still
// reachable (Activity segment / toolbar menu) — plus five new features
// woven directly into the new structure: private nicknames, custom friend
// tags/groups (with filter chips), a weekly activity leaderboard,
// "listening together" (friends playing the exact same track right now),
// and friendiversary callouts. See `FriendsSegments.swift` for the
// Discover/Requests/Activity segment bodies.
//
// Owns the standing "poll my friends' presence" timer for as long as this
// screen is visible — PresenceService.startFriendsPolling/stopFriendsPolling
// is intentionally screen-scoped (not app-wide) since there's no reason to
// keep refreshing friends' online status when no friends UI is on screen.
struct FriendsListView: View {
    @EnvironmentObject private var social: SocialService
    @EnvironmentObject private var account: AccountService
    @StateObject private var presenceService = PresenceService.shared

    private enum Segment: String, CaseIterable, Identifiable {
        case friends = "Friends"
        case discover = "Discover"
        case requests = "Requests"
        case activity = "Activity"
        var id: String { rawValue }
    }

    @State private var segment: Segment = .friends
    @State private var showBlockedUsers = false

    var body: some View {
        VStack(spacing: 0) {
            segmentPicker
            Group {
                switch segment {
                case .friends:
                    FriendsSegmentView(presenceService: presenceService)
                case .discover:
                    DiscoverSegmentView()
                case .requests:
                    RequestsSegmentView()
                case .activity:
                    ActivitySegmentView()
                }
            }
        }
        .background(AppTheme.background)
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LumiMenu {
                    Button {
                        showBlockedUsers = true
                    } label: {
                        Label("Blocked Users", systemImage: "hand.raised")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(AppTheme.textPrimary)
                }
            }
        }
        // `.onAppear` (not `.task`, which only ever runs once for this
        // view's lifetime) — Friends is now a persistent tab rather than a
        // freshly-pushed NavigationLink destination, so re-fetching only
        // on first-ever appearance meant the list could go stale (or never
        // load at all if that one fetch was slow/failed) for the rest of
        // the session. Re-firing on every appearance matches the same fix
        // applied to ProfileView and the existing AccountView badge count.
        .onAppear {
            presenceService.startFriendsPolling(account: account)
            Task {
                await social.fetchFriends()
                await social.fetchFriendRequests()
                await social.fetchSuggestions()
                await social.fetchFriendTagNames()
                await social.fetchListeningTogether()
            }
        }
        .onDisappear {
            presenceService.stopFriendsPolling()
        }
        // Keeps "Listening Together" reasonably live without a second
        // standing timer of its own — it just piggybacks on the friends-
        // presence poll this screen already runs every 30s (see
        // PresenceService.friendsPollInterval).
        .onChange(of: presenceService.friendsPresence) { _ in
            Task { await social.fetchListeningTogether() }
        }
        .sheet(isPresented: $showBlockedUsers) {
            NavigationStack { BlockedUsersView() }
        }
    }

    private var segmentPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Segment.allCases) { seg in
                    segmentButton(seg)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }

    private func segmentButton(_ seg: Segment) -> some View {
        Button {
            withAnimation(LumiMotion.fade(0.2)) { segment = seg }
        } label: {
            HStack(spacing: 4) {
                Text(seg.rawValue)
                    .font(AppTheme.bodyFont(size: 13).weight(segment == seg ? .semibold : .regular))
                if seg == .requests && !social.incomingRequests.isEmpty {
                    Text("\(social.incomingRequests.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(AppTheme.error, in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(segment == seg ? .white : AppTheme.textSecondary)
            .background(Capsule().fill(segment == seg ? AppTheme.dynamicAccent : AppTheme.surface))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Presence grouping (Friends segment)

/// Discord-style buckets for the Friends segment's grouped list — computed
/// purely from already-fetched presence data, no extra network calls.
private enum PresenceGroup: String, CaseIterable {
    case listeningNow = "Listening Now"
    case online = "Online"
    case recentlyActive = "Recently Active"
    case offline = "Offline"
}

private struct FriendGroupSection: Identifiable {
    let kind: PresenceGroup
    let friends: [SocialFriend]
    var id: String { kind.rawValue }
}

/// Shared — called for every friend row on every render.
private let relativeTimeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

private func relativeTimeString(_ date: Date) -> String {
    relativeTimeFormatter.localizedString(for: date, relativeTo: Date())
}

/// Shared small-caps section header used across every Friends-tab segment
/// (this file and FriendsSegments.swift).
func friendsSectionHeader(_ text: String) -> some View {
    Text(text.uppercased())
        .font(AppTheme.bodyFont(size: 11))
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(0.8)
}

// MARK: - FriendsSegmentView
//
// The redesigned core: grouped-by-presence friend list (Listening Now /
// Online / Recently Active / Offline), richer cards (nickname, tags, inline
// now-playing / last-seen), tag filter chips, an in-list search filter, and
// two new-feature banners up top (friendiversary callouts, listening
// together).
struct FriendsSegmentView: View {
    @EnvironmentObject private var social: SocialService
    @ObservedObject var presenceService: PresenceService

    @State private var searchText = ""
    @State private var selectedTag: String? = nil
    @State private var manageSheetFriend: SocialFriend? = nil

    private var presenceByUserId: [String: SocialPresence] {
        Dictionary(presenceService.friendsPresence.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func groupKind(_ friend: SocialFriend) -> PresenceGroup {
        guard let presence = presenceByUserId[friend.userId] else { return .offline }
        if presence.online && presence.isPlaying { return .listeningNow }
        if presence.online { return .online }
        if let lastSeen = presence.lastSeenAt.flatMap(parseServerDate), Date().timeIntervalSince(lastSeen) < 86_400 {
            return .recentlyActive
        }
        return .offline
    }

    private var groupedFriends: [FriendGroupSection] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = social.friends.filter { friend in
            (selectedTag == nil || friend.tags.contains(selectedTag!)) &&
            (trimmedQuery.isEmpty ||
             friend.effectiveName.localizedCaseInsensitiveContains(trimmedQuery) ||
             friend.username.localizedCaseInsensitiveContains(trimmedQuery))
        }
        let grouped = Dictionary(grouping: filtered, by: groupKind)
        return PresenceGroup.allCases.compactMap { kind in
            guard let items = grouped[kind], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                $0.effectiveName.localizedCaseInsensitiveCompare($1.effectiveName) == .orderedAscending
            }
            return FriendGroupSection(kind: kind, friends: sorted)
        }
    }

    var body: some View {
        List {
            Section {
                friendiversaryBanner
                listeningTogetherBanner
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                tagFilterChips
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                searchField
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if social.friends.isEmpty {
                Section {
                    Text("No friends yet — head to Discover to search for someone.")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(AppTheme.surface)
            } else if groupedFriends.isEmpty {
                Section {
                    Text("No friends match this filter.")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(AppTheme.surface)
            } else {
                ForEach(groupedFriends) { section in
                    Section {
                        ForEach(section.friends) { friend in
                            friendRow(friend)
                        }
                    } header: {
                        friendsSectionHeader("\(section.kind.rawValue) (\(section.friends.count))")
                    }
                    .listRowBackground(AppTheme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable {
            await social.fetchFriends()
            await social.fetchFriendTagNames()
        }
        .sheet(item: $manageSheetFriend) { friend in
            FriendManageSheet(friend: friend)
        }
    }

    // MARK: New feature: friendiversary callouts

    @ViewBuilder
    private var friendiversaryBanner: some View {
        let matches = social.friends.compactMap { friend -> (SocialFriend, Int)? in
            friend.friendiversaryYears.map { (friend, $0) }
        }
        if !matches.isEmpty {
            ProfileInfoCard(title: "Friendiversary", icon: "gift.fill", tint: AppTheme.dynamicAccent) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(matches, id: \.0.userId) { friend, years in
                        HStack(spacing: 8) {
                            SocialAvatarView(userId: friend.userId, size: 28)
                            Text("🎉 \(years) year\(years == 1 ? "" : "s") of friendship with \(friend.effectiveName) today!")
                                .font(AppTheme.bodyFont(size: 13))
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                    }
                }
            }
        }
    }

    // MARK: New feature: listening together

    @ViewBuilder
    private var listeningTogetherBanner: some View {
        if !social.listeningTogether.isEmpty, let track = social.listeningTogetherTrack {
            ProfileInfoCard(title: "Listening Together", icon: "waveform", tint: AppTheme.dynamicAccent) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        social.listeningTogether.count == 1
                            ? "1 friend is also listening to"
                            : "\(social.listeningTogether.count) friends are also listening to"
                    )
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    Text([track.title, track.artist].compactMap { $0 }.joined(separator: " — "))
                        .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: -8) {
                        ForEach(social.listeningTogether.prefix(6)) { user in
                            NavigationLink(destination: PublicProfileView(userId: user.userId)) {
                                SocialAvatarView(userId: user.userId, size: 30)
                                    .overlay(Circle().stroke(AppTheme.background, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: Tag filter chips

    @ViewBuilder
    private var tagFilterChips: some View {
        if !social.friendTagNames.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tagChip(label: "All", isSelected: selectedTag == nil) { selectedTag = nil }
                    ForEach(social.friendTagNames, id: \.self) { tag in
                        tagChip(label: tag, isSelected: selectedTag == tag) {
                            selectedTag = (selectedTag == tag) ? nil : tag
                        }
                    }
                }
            }
        }
    }

    private func tagChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(AppTheme.bodyFont(size: 12).weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? .white : AppTheme.textPrimary)
                .background(Capsule().fill(isSelected ? AppTheme.dynamicAccent : AppTheme.surface))
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.textSecondary)
            TextField("Filter friends", text: $searchText)
                .autocorrectionDisabled()
                .foregroundStyle(AppTheme.textPrimary)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Friend row

    private func friendRow(_ friend: SocialFriend) -> some View {
        let presence = presenceByUserId[friend.userId]
        return HStack(spacing: 12) {
            NavigationLink(destination: PublicProfileView(userId: friend.userId)) {
                HStack(spacing: 12) {
                    SocialAvatarView(userId: friend.userId, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(friend.effectiveName)
                                .font(AppTheme.bodyFont(size: 15).weight(.medium))
                                .foregroundStyle(AppTheme.textPrimary)
                            // Only show the raw @username alongside a
                            // nickname — when there's no nickname,
                            // effectiveName already IS the display/username.
                            if let nickname = friend.nickname, !nickname.isEmpty {
                                Text("@\(friend.username)")
                                    .font(AppTheme.bodyFont(size: 11))
                                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                            }
                        }
                        PresenceIndicatorView(presence: presence, dotSize: 8)
                        // Richer presence: a prominent relative "last seen"
                        // caption for offline/recently-active friends,
                        // beyond PresenceIndicatorView's plain "Offline" text.
                        if !(presence?.online ?? false), let lastSeen = presence?.lastSeenAt.flatMap(parseServerDate) {
                            Text("Last seen \(relativeTimeString(lastSeen))")
                                .font(AppTheme.bodyFont(size: 11))
                                .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                        }
                        if !friend.tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(friend.tags, id: \.self) { tag in
                                        Text(tag)
                                            .font(AppTheme.bodyFont(size: 10))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .foregroundStyle(AppTheme.dynamicAccent)
                                            .background(Capsule().fill(AppTheme.dynamicAccent.opacity(0.15)))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                manageSheetFriend = friend
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await social.removeFriend(friend.userId) }
            } label: {
                Label("Remove", systemImage: "person.badge.minus")
            }
            Button {
                Task { await social.blockUser(friend.userId) }
            } label: {
                Label("Block", systemImage: "hand.raised")
            }
            .tint(.orange)
        }
    }
}

// MARK: - FriendManageSheet
//
// New feature UI: private nickname + custom tags/groups editor for one
// friend, reached via the "..." button on their row. Nicknames/tags are
// both scoped to the caller only (see the bridge's set_friend_nickname /
// add_friend_tag doc comments) — the friend being managed never sees this.
struct FriendManageSheet: View {
    @EnvironmentObject private var social: SocialService
    @Environment(\.dismiss) private var dismiss

    let friend: SocialFriend
    @State private var nicknameText: String
    @State private var newTagText = ""
    @State private var isSaving = false

    init(friend: SocialFriend) {
        self.friend = friend
        _nicknameText = State(initialValue: friend.nickname ?? "")
    }

    /// Reads live from the service rather than the sheet's own captured
    /// `friend` snapshot, so adding/removing a tag while the sheet is open
    /// updates this list immediately after each round trip.
    private var currentTags: [String] {
        social.friends.first(where: { $0.userId == friend.userId })?.tags ?? friend.tags
    }

    private var suggestedTags: [String] {
        social.friendTagNames.filter { !currentTags.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nickname") {
                    TextField(friend.displayName ?? friend.username, text: $nicknameText)
                        .autocorrectionDisabled()
                    Text("Only visible to you — \(friend.displayName ?? friend.username) never sees this.")
                        .font(AppTheme.bodyFont(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Section("Tags") {
                    if currentTags.isEmpty {
                        Text("No tags yet.")
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        ForEach(currentTags, id: \.self) { tag in
                            HStack {
                                Text(tag).foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Button {
                                    Task { await social.removeFriendTag(friend.userId, tagName: tag) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack {
                        TextField("New tag (e.g. Close Friends)", text: $newTagText)
                            .autocorrectionDisabled()
                        Button("Add") {
                            let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            Task {
                                await social.addFriendTag(friend.userId, tagName: trimmed)
                                newTagText = ""
                            }
                        }
                        .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if !suggestedTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggestedTags, id: \.self) { tag in
                                    Button {
                                        Task { await social.addFriendTag(friend.userId, tagName: tag) }
                                    } label: {
                                        Text(tag)
                                            .font(AppTheme.bodyFont(size: 12))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .foregroundStyle(AppTheme.dynamicAccent)
                                            .background(Capsule().fill(AppTheme.dynamicAccent.opacity(0.15)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage \(friend.displayName ?? friend.username)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            let trimmed = nicknameText.trimmingCharacters(in: .whitespaces)
                            await social.setFriendNickname(friend.userId, nickname: trimmed.isEmpty ? nil : trimmed)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

// MARK: - BlockedUsersView

/// Simple management sheet for GET /api/social/block — presented modally
/// from FriendsListView's toolbar menu rather than pushed, since it's an
/// infrequent "moderation" surface rather than a primary navigation
/// destination.
struct BlockedUsersView: View {
    @EnvironmentObject private var social: SocialService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if social.blockedUsers.isEmpty {
                Text("You haven't blocked anyone.")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                ForEach(social.blockedUsers) { user in
                    HStack {
                        SocialAvatarView(userId: user.userId, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName ?? user.username).foregroundStyle(AppTheme.textPrimary)
                            Text("@\(user.username)")
                                .font(AppTheme.bodyFont(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        Button("Unblock") {
                            Task { await social.unblockUser(user.userId) }
                        }
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.dynamicAccent)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { await social.fetchBlockedUsers() }
    }
}

// MARK: - FriendsActivityFeedView

/// Full-screen friends-only feed of recent plays/favorites — see GET
/// /api/social/activity/friends. Reachable from the redesigned Activity
/// segment's "View Full Activity Feed" link. Distinct from the pre-existing
/// global DiscoverView feed (which surfaces ALL opted-in users, not just
/// friends).
struct FriendsActivityFeedView: View {
    @EnvironmentObject private var social: SocialService

    var body: some View {
        List {
            if social.friendsActivity.isEmpty {
                Text("No recent activity from friends yet.")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                    .listRowBackground(AppTheme.surface)
            } else {
                ForEach(social.friendsActivity) { entry in
                    HStack(spacing: 12) {
                        SocialAvatarView(userId: entry.userId, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(entry.displayName ?? entry.username)
                                    .fontWeight(.medium)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Image(systemName: entry.isPlayed ? "play.fill" : "heart.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(entry.isPlayed ? AppTheme.dynamicAccent : AppTheme.error)
                            }
                            Text([entry.title, entry.artist].compactMap { $0 }.joined(separator: " — "))
                                .font(AppTheme.bodyFont(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .listRowBackground(AppTheme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Friends Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task { await social.fetchFriendsActivity() }
        .refreshable { await social.fetchFriendsActivity() }
    }
}
