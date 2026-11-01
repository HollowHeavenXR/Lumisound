import Foundation
import SwiftUI
import UIKit

// MARK: - SocialService
//
// Profiles, friends, blocks, and the friends-only activity feed for the new
// Social Ecosystem feature. Presence (online/offline + now-playing polling)
// lives in its own `PresenceService` — kept separate since presence runs a
// standing timer for the whole app session while this service is purely
// request/response, driven by whichever social screen is currently open.
//
// Networking goes through `AccountService.shared` (the same ambient-singleton
// pattern `AudioPlayerManager` already uses to push playback state) rather
// than duplicating the retry/401-handling/error-mapping logic in
// AccountService+PrivateHelpers.swift — `makeRequest` there is `internal`,
// so any type in the app module can call it directly.
@MainActor
final class SocialService: ObservableObject {

    @Published var myProfile: MySocialProfile? = nil
    @Published var friends: [SocialFriend] = []
    @Published var incomingRequests: [SocialFriendRequest] = []
    @Published var outgoingRequests: [SocialFriendRequest] = []
    @Published var blockedUsers: [BlockedUserRef] = []
    @Published var suggestions: [SocialFriendSuggestion] = []
    /// Ranked by listening similarity — see `RecommendedPerson`.
    @Published var recommendedPeople: [RecommendedPerson] = []
    /// Set when `recommendedPeople` is empty and the server said why.
    @Published var recommendedPeopleEmptyReason: RecommendedPeopleEmptyReason?
    @Published var isLoadingRecommendedPeople = false
    @Published var friendsActivity: [SocialActivityEntry] = []
    @Published var searchResults: [SocialUserRef] = []
    @Published var errorMessage: String? = nil
    @Published var isLoading = false

    /// Mirrors `AccountService.shared`/`LibraryManager.shared` — gives
    /// non-view code (e.g. `DiagnosticsSnapshotService`) a way to reach the
    /// live instance without needing it threaded through as a parameter.
    static weak var shared: SocialService?

    init() {
        Self.shared = self
    }

    private var account: AccountService? { AccountService.shared }

    // MARK: - Profile

    func fetchMyProfile() async {
        guard let account, account.isLoggedIn else { return }
        do {
            let data = try await account.makeRequest("/api/social/profile/me")
            myProfile = try JSONDecoder().decode(MySocialProfile.self, from: data)
        } catch {
            handle(error)
        }
    }

    func fetchPublicProfile(userId: String) async -> PublicSocialProfile? {
        guard let account, account.isLoggedIn else { return nil }
        do {
            let data = try await account.makeRequest("/api/social/profile/\(userId)")
            return try JSONDecoder().decode(PublicSocialProfile.self, from: data)
        } catch {
            handle(error)
            return nil
        }
    }

    func updateProfile(
        bio: String? = nil, mainAccentHex: String? = nil, subAccentHex: String? = nil, shareNowPlaying: Bool? = nil,
        pronouns: String? = nil, statusEmoji: String? = nil, statusText: String? = nil, avatarFrame: String? = nil,
        showTopGenres: Bool? = nil, showGuestbook: Bool? = nil,
        showVisitorStats: Bool? = nil, showListeningStats: Bool? = nil,
        accentGlowIntensity: String? = nil,
        avatarDecoration: String? = nil, profileEffect: String? = nil
    ) async {
        guard let account, account.isLoggedIn else { return }
        struct Body: Encodable {
            let bio: String?
            let main_accent_hex: String?
            let sub_accent_hex: String?
            let share_now_playing: Bool?
            let pronouns: String?
            let status_emoji: String?
            let status_text: String?
            let avatar_frame: String?
            let show_top_genres: Bool?
            let show_guestbook: Bool?
            let show_visitor_stats: Bool?
            let show_listening_stats: Bool?
            let accent_glow_intensity: String?
            let avatar_decoration: String?
            let profile_effect: String?
        }
        do {
            _ = try await account.makeRequest(
                "/api/social/profile", method: "PUT",
                body: Body(
                    bio: bio, main_accent_hex: mainAccentHex, sub_accent_hex: subAccentHex, share_now_playing: shareNowPlaying,
                    pronouns: pronouns, status_emoji: statusEmoji, status_text: statusText, avatar_frame: avatarFrame,
                    show_top_genres: showTopGenres, show_guestbook: showGuestbook,
                    show_visitor_stats: showVisitorStats, show_listening_stats: showListeningStats,
                    accent_glow_intensity: accentGlowIntensity,
                    avatar_decoration: avatarDecoration, profile_effect: profileEffect
                )
            )
            await fetchMyProfile()
        } catch {
            handle(error)
        }
    }

    func setPinnedTracks(_ tracks: [PinnedTrack]) async {
        guard let account, account.isLoggedIn else { return }
        struct Body: Encodable { let tracks: [PinnedTrack] }
        do {
            _ = try await account.makeRequest("/api/social/profile/pinned-tracks", method: "PUT", body: Body(tracks: tracks))
            await fetchMyProfile()
        } catch {
            handle(error)
        }
    }

    // MARK: - Banner

    /// Uploads raw picker data (straight from `PhotosPicker`) as the profile
    /// banner, preserving animation if it's a GIF — same "sniff raw bytes
    /// before any UIImage conversion" reasoning as
    /// `AccountService.uploadAvatarData(_:)`, since decoding first would
    /// silently flatten a GIF to its first frame. Non-GIF data (HEIC/PNG/
    /// whatever the picker handed back) gets decoded and re-encoded as JPEG,
    /// same as the avatar path, since the bridge only accepts GIF or JPEG
    /// bytes.
    func uploadBannerData(_ data: Data) async {
        guard let account, account.isLoggedIn else { return }
        if isGIFData(data) {
            guard data.count <= 15_728_640 else {
                errorMessage = "GIF banners must be under 15MB."
                return
            }
            await sendBanner(data, contentType: "image/gif", account: account)
            return
        }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) else {
            appWarn("uploadBannerData: could not decode/encode image data", category: "social")
            return
        }
        guard jpeg.count <= 15_728_640 else {
            errorMessage = "Banner must be under 15MB."
            return
        }
        await sendBanner(jpeg, contentType: "image/jpeg", account: account)
    }

    private func sendBanner(_ data: Data, contentType: String, account: AccountService) async {
        guard var req = account.makeBaseRequest("/api/social/profile/banner", method: "POST") else { return }
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        do {
            let (_, resp) = try await Core.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                appWarn("uploadBannerData: HTTP \(status)", category: "social")
                errorMessage = "Couldn't upload banner (HTTP \(status))."
                return
            }
            appLog("uploadBannerData: uploaded \(data.count / 1024)KB (\(contentType))", category: "social")
        } catch {
            handle(error)
        }
    }

    func removeBanner() async {
        guard let account, account.isLoggedIn else { return }
        do {
            _ = try await account.makeRequest("/api/social/profile/banner", method: "DELETE")
        } catch {
            handle(error)
        }
    }

    /// Fetches another (or this) user's banner image, or `nil` if they
    /// haven't set one (a 404 is the normal "no banner" case, not an error —
    /// callers fall back to the plain accent-gradient banner).
    static func loadBanner(userId: String) async -> UIImage? {
        guard let account = AccountService.shared,
              let req = account.makeBaseRequest("/api/social/profile/banner/\(userId)", method: "GET")
        else { return nil }
        guard let (data, resp) = try? await Core.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        if isGIFData(data) { return await UIImage.gifImageAsync(data: data) }
        return UIImage(data: data)
    }

    // MARK: - User search (add-friend flow)

    /// Guards against out-of-order completions — a caller firing this once
    /// per keystroke (even debounced) can still have a slower response for
    /// an *earlier* query land after a faster one for a *later* query, which
    /// would otherwise silently overwrite `searchResults` with results that
    /// don't match what's currently typed.
    private var searchGeneration = 0

    func searchUsers(query: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        guard let account, account.isLoggedIn, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        do {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let data = try await account.makeRequest("/api/social/users/search?q=\(encoded)")
            struct Response: Decodable { let users: [SocialUserRef] }
            let users = try JSONDecoder().decode(Response.self, from: data).users
            guard generation == searchGeneration else { return }
            searchResults = users
        } catch {
            guard generation == searchGeneration else { return }
            handle(error)
        }
    }

    // MARK: - Friend requests

    func sendFriendRequest(toUserId: String? = nil, toUsername: String? = nil) async -> Bool {
        guard let account, account.isLoggedIn else { return false }
        struct Body: Encodable { let to_user_id: String?; let to_username: String? }
        do {
            _ = try await account.makeRequest(
                "/api/social/friends/request", method: "POST",
                body: Body(to_user_id: toUserId, to_username: toUsername)
            )
            appLog("Friend request sent", category: "social")
            await fetchFriendRequests()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func acceptRequest(_ requestId: String) async {
        await respond(requestId: requestId, action: "accept")
    }

    func declineRequest(_ requestId: String) async {
        await respond(requestId: requestId, action: "decline")
    }

    func cancelRequest(_ requestId: String) async {
        await respond(requestId: requestId, action: "cancel")
    }

    private func respond(requestId: String, action: String) async {
        guard let account, account.isLoggedIn else { return }
        do {
            _ = try await account.makeRequest("/api/social/friends/request/\(requestId)/\(action)", method: "POST")
            appLog("Friend request \(action)ed", category: "social")
            async let requests: () = fetchFriendRequests()
            async let friendsList: () = fetchFriends()
            _ = await (requests, friendsList)
        } catch {
            handle(error)
        }
    }

    func fetchFriendRequests() async {
        guard let account, account.isLoggedIn else { return }
        do {
            let data = try await account.makeRequest("/api/social/friends/requests")
            let response = try JSONDecoder().decode(SocialFriendRequestsResponse.self, from: data)
            incomingRequests = response.incoming
            outgoingRequests = response.outgoing
        } catch {
            handle(error)
        }
    }

    // MARK: - Friends list

    func fetchFriends() async {
        guard let account, account.isLoggedIn else { return }
        do {
            let data = try await account.makeRequest("/api/social/friends")
            struct Response: Decodable { let friends: [SocialFriend] }
            friends = try JSONDecoder().decode(Response.self, from: data).friends
        } catch {
            handle(error)
        }
    }

    func removeFriend(_ userId: String) async {
        guard let account, account.isLoggedIn else { return }
        do {
            _ = try await account.makeRequest("/api/social/friends/\(userId)", method: "DELETE")
            appLog("Friend removed", category: "social")
            await fetchFriends()
        } catch {
            handle(error)
        }
    }

    // MARK: - Blocking

    func blockUser(_ userId: String) async {
        guard let account, account.isLoggedIn else { return }
        do {
            _ = try await account.makeRequest("/api/social/block/\(userId)", method: "POST")
            async let friendsList: () = fetchFriends()
            async let requests: () = fetchFriendRequests()
            async let blocked: () = fetchBlockedUsers()
            _ = await (friendsList, requests, blocked)
        } catch {
            handle(error)
        }
    }

    func unblockUser(_ userId: String) async {
        guard let account, account.isLoggedIn else { return }
        do {
            _ = try await account.makeRequest("/api/social/block/\(userId)", method: "DELETE")
            await fetchBlockedUsers()
        } catch {
            handle(error)
        }
    }

    func fetchBlockedUsers() async {
        guard let account, account.isLoggedIn else { return }
        do {
            let data = try await account.makeRequest("/api/social/block")
            struct Response: Decodable { let blocked: [SocialUserRef] }
            blockedUsers = try JSONDecoder().decode(Response.self, from: data).blocked.map(BlockedUserRef.init)
        } catch {
            handle(error)
        }
    }

    // MARK: - Extra feature: mutual-friend suggestions

    func fetchSuggestions() async {
        guard let account, account.isLoggedIn else { return }
        do {
            let data = try await account.makeRequest("/api/social/friends/suggestions")
            struct Response: Decodable { let suggestions: [SocialFriendSuggestion] }
            suggestions = try JSONDecoder().decode(Response.self, from: data).suggestions
        } catch {
            handle(error)
        }
    }

    // MARK: - Recommended people (ranked by listening similarity)

    /// Loads people worth adding, ranked by how much their listening resembles
    /// the caller's.
    ///
    /// Kept separate from `fetchSuggestions` rather than replacing it: mutual
    /// friends are strong evidence when they exist, and taste similarity is what
    /// works when they do not. The two answer different questions and the UI
    /// shows both.
    func fetchRecommendedPeople() async {
        guard let account, account.isLoggedIn else { return }
        isLoadingRecommendedPeople = true
        defer { isLoadingRecommendedPeople = false }
        do {
            let data = try await account.makeRequest("/api/social/recommended-people")
            struct Response: Decodable {
                let people: [RecommendedPerson]
                let reason: String?
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            recommendedPeople = decoded.people
            recommendedPeopleEmptyReason = decoded.people.isEmpty
                ? decoded.reason.flatMap(RecommendedPeopleEmptyReason.init(rawValue:))
                : nil
        } catch {
            handle(error)
        }
    }

    // MARK: - Extra feature: friends-only activity feed

    func fetchFriendsActivity() async {
        guard let account, account.isLoggedIn else { return }
        do {
            let data = try await account.makeRequest("/api/social/activity/friends")
            struct Response: Decodable { let activity: [SocialActivityEntry] }
            friendsActivity = try JSONDecoder().decode(Response.self, from: data).activity
        } catch {
            handle(error)
        }
    }

    // MARK: - Extra feature: profile guestbook (comments)

    func fetchProfileComments(userId: String) async -> [ProfileComment] {
        guard let account, account.isLoggedIn else { return [] }
        do {
            let data = try await account.makeRequest("/api/social/profile/\(userId)/comments")
            return try JSONDecoder().decode(ProfileCommentsResponse.self, from: data).comments
        } catch {
            handle(error)
            return []
        }
    }

    @discardableResult
    func postProfileComment(userId: String, body: String) async -> ProfileComment? {
        guard let account, account.isLoggedIn else { return nil }
        struct Body: Encodable { let body: String }
        do {
            let data = try await account.makeRequest(
                "/api/social/profile/\(userId)/comments", method: "POST", body: Body(body: body)
            )
            return try JSONDecoder().decode(ProfileComment.self, from: data)
        } catch {
            handle(error)
            return nil
        }
    }

    func deleteProfileComment(_ commentId: String) async {
        guard let account, account.isLoggedIn else { return }
        do {
            _ = try await account.makeRequest("/api/social/profile/comments/\(commentId)", method: "DELETE")
        } catch {
            handle(error)
        }
    }

    // MARK: - Extra feature: music compatibility ("Music Match")

    func fetchCompatibility(userId: String) async -> MusicCompatibility? {
        guard let account, account.isLoggedIn else { return nil }
        do {
            let data = try await account.makeRequest("/api/social/compatibility/\(userId)")
            return try JSONDecoder().decode(MusicCompatibility.self, from: data)
        } catch {
            handle(error)
            return nil
        }
    }

    /// What a library actually sounds like — median tempo, its spread, and the
    /// median tonal balance.
    ///
    /// Friends-only server-side, same rule as compatibility: a library's shape
    /// says what someone genuinely listens to rather than what they chose to
    /// put on their profile.
    func fetchSonicFingerprint(userId: String) async -> SonicFingerprint? {
        guard let account, account.isLoggedIn else { return nil }
        do {
            let data = try await account.makeRequest("/api/social/fingerprint/\(userId)")
            return try JSONDecoder().decode(SonicFingerprint.self, from: data)
        } catch {
            // Quietly absent rather than surfaced as an error: a new library
            // legitimately has no shape yet, and a profile should simply not
            // show the section instead of reporting a failure.
            return nil
        }
    }

    /// A playable mix blending the caller's and `userId`'s top artists —
    /// the "press play" companion to `fetchCompatibility`'s score-only
    /// match. Friends-only server-side, same as compatibility.
    func fetchBlendMix(userId: String) async -> [StreamTrack] {
        guard let account, account.isLoggedIn else { return [] }
        do {
            let data = try await account.makeRequest("/api/social/blend/\(userId)")
            return try JSONDecoder().decode([StreamTrack].self, from: data)
        } catch {
            handle(error)
            return []
        }
    }

    // MARK: - Friends tab expansion (2026-07-21)
    //
    // Five additions woven into the redesigned FriendsListView: private
    // nicknames, custom friend tags/groups, a weekly activity leaderboard,
    // and "listening together". (Friendiversary callouts are computed
    // entirely client-side from `SocialFriend.friendsSince` — no service
    // method needed for that one.)

    @Published var friendTagNames: [String] = []
    @Published var leaderboard: [FriendLeaderboardEntry] = []
    @Published var listeningTogether: [SocialUserRef] = []
    @Published var listeningTogetherTrack: (title: String, artist: String?)? = nil

    /// Sets or clears (pass `nil`/empty) a private nickname for a friend.
    /// Re-fetches the friends list afterward so `SocialFriend.nickname`
    /// (and thus every row using `effectiveName`) reflects it immediately.
    func setFriendNickname(_ friendId: String, nickname: String?) async {
        guard let account, account.isLoggedIn else { return }
        struct Body: Encodable { let nickname: String? }
        do {
            _ = try await account.makeRequest(
                "/api/social/friends/\(friendId)/nickname", method: "PUT", body: Body(nickname: nickname)
            )
            await fetchFriends()
        } catch {
            handle(error)
        }
    }

    func fetchFriendTagNames() async {
        guard let account, account.isLoggedIn else { return }
        do {
            let data = try await account.makeRequest("/api/social/friends/tags")
            friendTagNames = try JSONDecoder().decode(FriendTagNamesResponse.self, from: data).tags
        } catch {
            handle(error)
        }
    }

    func addFriendTag(_ friendId: String, tagName: String) async {
        guard let account, account.isLoggedIn else { return }
        struct Body: Encodable { let tag_name: String }
        do {
            _ = try await account.makeRequest(
                "/api/social/friends/\(friendId)/tags", method: "POST", body: Body(tag_name: tagName)
            )
            async let friendsList: () = fetchFriends()
            async let tagNames: () = fetchFriendTagNames()
            _ = await (friendsList, tagNames)
        } catch {
            handle(error)
        }
    }

    func removeFriendTag(_ friendId: String, tagName: String) async {
        guard let account, account.isLoggedIn else { return }
        // `.urlPathAllowed` alone still permits a literal "/", which would
        // be misread as an extra path segment rather than part of the tag
        // name — strip it from the allowed set so a tag containing one gets
        // correctly percent-encoded instead of corrupting the URL.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = tagName.addingPercentEncoding(withAllowedCharacters: allowed) ?? tagName
        do {
            _ = try await account.makeRequest("/api/social/friends/\(friendId)/tags/\(encoded)", method: "DELETE")
            await fetchFriends()
        } catch {
            handle(error)
        }
    }

    /// "Most active friend this week" — ranked by play count.
    func fetchLeaderboard(days: Int = 7) async {
        guard let account, account.isLoggedIn else { return }
        do {
            let data = try await account.makeRequest("/api/social/friends/leaderboard?days=\(days)")
            leaderboard = try JSONDecoder().decode(FriendLeaderboardResponse.self, from: data).leaderboard
        } catch {
            handle(error)
        }
    }

    /// Which friends are playing the exact same track as the caller right
    /// now (see GET /api/social/presence/listening-together).
    func fetchListeningTogether() async {
        guard let account, account.isLoggedIn else { return }
        do {
            let data = try await account.makeRequest("/api/social/presence/listening-together")
            let response = try JSONDecoder().decode(ListeningTogetherResponse.self, from: data)
            listeningTogether = response.listeningTogether
            listeningTogetherTrack = response.title.map { ($0, response.artist) }
        } catch {
            handle(error)
        }
    }


    // MARK: - Extra feature: featured/spotlight playlist

    /// Fetches the caller's own server-stored playlists for the Featured
    /// Playlist picker sheet. Deliberately not cached/`@Published` — this is
    /// only ever needed while that one sheet is open.
    func fetchMyPlaylists() async -> [RemotePlaylistSummary] {
        guard let account, account.isLoggedIn else { return [] }
        do {
            let data = try await account.makeRequest("/user/playlists")
            return try JSONDecoder().decode([RemotePlaylistSummary].self, from: data)
        } catch {
            handle(error)
            return []
        }
    }

    /// Sets (`playlistId` non-nil) or clears (`nil`) the featured playlist.
    func setFeaturedPlaylist(playlistId: String?) async {
        guard let account, account.isLoggedIn else { return }
        struct Body: Encodable { let playlist_id: String? }
        do {
            _ = try await account.makeRequest(
                "/api/social/profile/featured-playlist", method: "PUT", body: Body(playlist_id: playlistId)
            )
            await fetchMyProfile()
        } catch {
            handle(error)
        }
    }

    // MARK: - Extra feature: "recently played together"

    func fetchRecentlyPlayedTogether(userId: String) async -> [SharedRecentTrack] {
        guard let account, account.isLoggedIn else { return [] }
        do {
            let data = try await account.makeRequest("/api/social/profile/\(userId)/recently-played-together")
            return try JSONDecoder().decode(SharedRecentTracksResponse.self, from: data).tracks
        } catch {
            handle(error)
            return []
        }
    }

    // MARK: - Helpers

    /// `function` defaults to `#function`, which Swift resolves to the NAME
    /// OF THE CALLER at each of this method's ~30 call sites automatically —
    /// no need to touch any of them. Added because the plain error text
    /// alone (e.g. "The data couldn't be read because it is missing.", a
    /// DecodingError's generic localizedDescription for a missing/null key)
    /// gives no way to tell which of ~10 different endpoints this service
    /// calls actually failed, from the log alone.
    private func handle(_ error: Error, function: String = #function) {
        if let err = error as? AccountError {
            errorMessage = err.message
        } else {
            errorMessage = error.localizedDescription
        }
        appWarn("SocialService.\(function) error: \(errorMessage ?? "")", category: "social")
    }
}

/// GET /api/social/block's entries wrapped as Identifiable — same shape as
/// `SocialUserRef`, just named distinctly so a blocked-users list and a
/// search-results list are never accidentally interchangeable at the type level.
struct BlockedUserRef: Identifiable, Equatable {
    let userId: String
    let username: String
    let displayName: String?
    let avatarURL: String?
    var id: String { userId }

    init(_ ref: SocialUserRef) {
        userId = ref.userId
        username = ref.username
        displayName = ref.displayName
        avatarURL = ref.avatarURL
    }
}
