import Foundation

/// Shared ISO8601 parser. Creating an `ISO8601DateFormatter` is expensive, and
/// the model `date` computed properties below are read once per row on every
/// SwiftUI redraw — a fresh formatter each time caused visible lag on lists with
/// many items (e.g. Backup History). One shared instance removes that cost.
let sharedISO8601Formatter = ISO8601DateFormatter()

/// Fallback formatters for timestamps the bridge serializes via Python's
/// `datetime.isoformat()` on a *naive* (timezone-unaware) value read back
/// from a MariaDB `TIMESTAMP` column — e.g. `"2026-06-03T20:26:35"`, with no
/// trailing `Z`/offset. `ISO8601DateFormatter`'s default options require one
/// (`.withInternetDateTime`), so it returns `nil` for these — confirmed
/// directly against the live bridge: `member_since` came back exactly this
/// shape, which is why "Member Since" always showed "Unknown" regardless of
/// what the server actually had stored. Two variants since Python's
/// `isoformat()` includes microseconds only when they're non-zero.
private let fallbackDateFormatterWithFraction: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()
private let fallbackDateFormatterNoFraction: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

/// Parses a bridge-supplied timestamp string, tolerating both a proper
/// timezone-suffixed ISO8601 string (the format `sharedISO8601Formatter`
/// alone already handles) and a bare, timezone-less one (see the fallback
/// formatters' doc comment above for why the bridge sometimes sends this
/// shape). Every call site that used to call `sharedISO8601Formatter.date(from:)`
/// directly on a bridge timestamp should go through this instead.
func parseServerDate(_ string: String) -> Date? {
    sharedISO8601Formatter.date(from: string)
        ?? fallbackDateFormatterWithFraction.date(from: string)
        ?? fallbackDateFormatterNoFraction.date(from: string)
}

// MARK: - Models

struct AppUser: Codable, Equatable {
    let id: String
    let username: String
    let displayName: String?
    let email: String?
    let avatarURL: String?
    let dateOfBirth: String?   // ISO YYYY-MM-DD, nil if not set
    var shareListeningActivity: Bool = false
    /// Legacy field, kept only for backward-compatible decoding/encoding of
    /// PUT /user/privacy — no longer read by any endpoint. Aria Lumi (see
    /// AccountService+Intelligence.swift) now runs unconditionally for every
    /// signed-in user rather than being gated by this per-user opt-in.
    var aiAssistedSuggestions: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName  = "display_name"
        case email
        case avatarURL    = "avatar_url"
        case dateOfBirth  = "date_of_birth"
        case shareListeningActivity = "share_listening_activity"
        case aiAssistedSuggestions  = "ai_assisted_suggestions"
    }

    // Hand-written so a boolean flag added in a later app version (like
    // aiAssistedSuggestions) never breaks decoding of an AppUser cached in
    // UserDefaults by an OLDER app version that predates the field — the
    // synthesized Decodable init does NOT fall back to a property's default
    // value when a key is missing, it throws. That bug shipped in 1.4.62/63
    // and logged everyone out on update (old cached user JSON had no
    // "ai_assisted_suggestions" key -> decode failed -> currentUser reset to
    // nil). decodeIfPresent + ?? false makes every Bool flag here tolerant
    // of being absent, from either a stale local cache or an older/newer
    // server response, going forward.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        dateOfBirth = try container.decodeIfPresent(String.self, forKey: .dateOfBirth)
        shareListeningActivity = try container.decodeIfPresent(Bool.self, forKey: .shareListeningActivity) ?? false
        aiAssistedSuggestions = try container.decodeIfPresent(Bool.self, forKey: .aiAssistedSuggestions) ?? false
    }

    init(
        id: String, username: String, displayName: String?, email: String?,
        avatarURL: String?, dateOfBirth: String?,
        shareListeningActivity: Bool = false, aiAssistedSuggestions: Bool = false
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.email = email
        self.avatarURL = avatarURL
        self.dateOfBirth = dateOfBirth
        self.shareListeningActivity = shareListeningActivity
        self.aiAssistedSuggestions = aiAssistedSuggestions
    }
}

// MARK: - Folder Structure Backup (item 3)

/// One track inside a backed-up watched folder, as pushed to/pulled from
/// `/user/folder-backups`. `sourceTrackID` (the `LUMISOUND_ID`-style identifier,
/// e.g. "youtube:dQw4w9WgXcQ") is what makes a track auto-redownloadable on
/// restore; tracks without one were local-only imports and can only have their
/// folder recreated (empty) for the user to re-add manually.
struct FolderBackupTrack: Codable, Hashable {
    var filename: String
    var title: String?
    var artist: String?
    var durationSeconds: Double?
    var sourceTrackID: String?

    enum CodingKeys: String, CodingKey {
        case filename
        case title
        case artist
        case durationSeconds = "duration_seconds"
        case sourceTrackID   = "source_track_id"
    }
}

/// One watched/imported folder's backed-up structure: its path relative to the
/// app's Documents directory, plus the tracks that lived inside it.
struct FolderBackupEntry: Codable, Hashable {
    var folderPath: String
    var tracks: [FolderBackupTrack]

    enum CodingKeys: String, CodingKey {
        case folderPath = "folder_path"
        case tracks
    }
}

/// Metadata for an automatic server-side backup of this user's sync data
/// (favorites/playlists/settings), taken before every push (and before every
/// restore). See `ios_user_backups` / GET+POST `/user/backups...` on the bridge.
struct SyncBackup: Codable, Identifiable {
    let id: String
    let reason: String
    let createdAt: String
    let favoriteCount: Int
    let playlistCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case reason
        case createdAt     = "created_at"
        case favoriteCount = "favorite_count"
        case playlistCount = "playlist_count"
    }

    /// `created_at` parsed as a `Date`, for display with relative formatting.
    var date: Date? {
        parseServerDate(createdAt)
    }

    var reasonDisplayName: String {
        switch reason {
        case "pre_push":    return "Before sync"
        case "pre_restore": return "Before restore"
        default:            return reason
        }
    }
}

/// A single entry in the "what others are listening to" feed (GET /social/activity).
/// Only ever contains title/artist/played_at plus public profile info — never
/// file contents or URLs.
struct ActivityEntry: Codable, Identifiable {
    let username: String
    let displayName: String?
    let avatarURL: String?
    let title: String?
    let artist: String?
    let playedAt: String?

    var id: String { "\(username)-\(playedAt ?? "")-\(title ?? "")" }

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case avatarURL   = "avatar_url"
        case title
        case artist
        case playedAt    = "played_at"
    }

    var date: Date? {
        guard let playedAt else { return nil }
        return parseServerDate(playedAt)
    }
}

/// A trending track from GET /social/discover — aggregated across users who've
/// opted in to sharing listening activity.
struct TrendingTrack: Codable, Identifiable {
    let title: String
    let artist: String?
    let playCount: Int
    let listenerCount: Int

    var id: String { "\(title)-\(artist ?? "")" }

    enum CodingKeys: String, CodingKey {
        case title
        case artist
        case playCount     = "play_count"
        case listenerCount = "listener_count"
    }
}

/// The single opted-in user whose top artists overlap most with the
/// caller's own — GET /user/social/twin. See `AccountService.fetchListeningTwin`
/// for how this differs from the anonymous cohort behind `TrendingTrack`/
/// similar-listeners recommendations.
struct ListeningTwin: Codable {
    let username: String
    let displayName: String?
    let avatarURL: String?
    /// 0–100, roughly "% of your top 20 artists this person also plays".
    let similarity: Int
    let sharedArtists: [String]

    enum CodingKeys: String, CodingKey {
        case username
        case displayName   = "display_name"
        case avatarURL     = "avatar_url"
        case similarity
        case sharedArtists = "shared_artists"
    }
}

/// GET /user/aria/daily-pick — one AI-picked track per user per UTC
/// calendar day, with a short reason from Aria Lumi. `track`/`reason` are
/// both `nil` when there wasn't enough listening history yet to seed a
/// pick (see main.py's doc comment — never treated as an error).
struct AriaDailyPick: Codable {
    let track: StreamTrack?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case track = "pick"
        case reason
    }
}

/// One active login (device/session) for this account — GET /auth/sessions.
struct AccountSession: Codable, Identifiable {
    let tokenId: String
    let deviceName: String?
    let createdAt: String
    let expiresAt: String?
    let isCurrent: Bool

    var id: String { tokenId }

    enum CodingKeys: String, CodingKey {
        case tokenId    = "token_id"
        case deviceName = "device_name"
        case createdAt  = "created_at"
        case expiresAt  = "expires_at"
        case isCurrent  = "is_current"
    }

    var createdDate: Date? {
        parseServerDate(createdAt)
    }
}

/// Lifetime listening stats from GET /user/stats.
struct AccountStats: Codable {
    let totalPlays: Int
    let totalListenSeconds: Int
    let topArtists: [TopArtist]
    let topTracks: [TopTrack]

    enum CodingKeys: String, CodingKey {
        case totalPlays         = "total_plays"
        case totalListenSeconds = "total_listen_seconds"
        case topArtists         = "top_artists"
        case topTracks          = "top_tracks"
    }

    struct TopArtist: Codable, Identifiable {
        let artist: String
        let playCount: Int
        var id: String { artist }
        enum CodingKeys: String, CodingKey { case artist, playCount = "play_count" }
    }

    struct TopTrack: Codable, Identifiable {
        let title: String
        let artist: String?
        let playCount: Int
        var id: String { "\(title)-\(artist ?? "")" }
        enum CodingKeys: String, CodingKey { case title, artist, playCount = "play_count" }
    }
}

/// GET /user/stats/year-in-review — a "Wrapped"-style annual recap, same
/// `ios_play_history` source table `AccountStats` reads, just bucketed by
/// calendar year. `YearInReviewView` renders this into a shareable card.
struct YearInReview: Codable {
    let year: Int
    let totalPlays: Int
    let totalListenSeconds: Int
    let distinctArtists: Int
    let distinctTracks: Int
    /// `nil` when no play in the year had a recorded BPM.
    let averageBpm: Double?
    let topArtists: [AccountStats.TopArtist]
    let topTracks: [AccountStats.TopTrack]
    let byMonth: [MonthlyActivity]
    /// `nil` for a year with no listening activity at all.
    let peakDay: PeakDay?

    enum CodingKeys: String, CodingKey {
        case year
        case totalPlays        = "total_plays"
        case totalListenSeconds = "total_listen_seconds"
        case distinctArtists   = "distinct_artists"
        case distinctTracks    = "distinct_tracks"
        case averageBpm        = "average_bpm"
        case topArtists        = "top_artists"
        case topTracks         = "top_tracks"
        case byMonth            = "by_month"
        case peakDay            = "peak_day"
    }

    struct MonthlyActivity: Codable, Identifiable {
        let month: Int
        let plays: Int
        let listenSeconds: Int
        var id: Int { month }
        enum CodingKeys: String, CodingKey { case month, plays, listenSeconds = "listen_seconds" }
    }

    struct PeakDay: Codable {
        let date: String
        let plays: Int
        let listenSeconds: Int
        enum CodingKeys: String, CodingKey { case date, plays, listenSeconds = "listen_seconds" }
    }
}

/// One day's entry from GET /user/stats/heatmap — a much longer-range
/// version of the same per-day shape /user/stats/weekly returns. Powers
/// `ListeningHeatmapView`'s calendar heatmap.
struct HeatmapDay: Codable, Identifiable {
    let date: String
    let plays: Int
    let listenSeconds: Int
    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date, plays
        case listenSeconds = "listen_seconds"
    }
}

/// GET /user/stats/month-in-review — same shape as `YearInReview` but
/// bucketed to a single calendar month (by day instead of by month).
/// Powers the "This Month" mode on `RewindView`.
struct MonthInReview: Codable {
    let year: Int
    let month: Int
    let totalPlays: Int
    let totalListenSeconds: Int
    let distinctArtists: Int
    let distinctTracks: Int
    /// `nil` when no play in the month had a recorded BPM.
    let averageBpm: Double?
    let topArtists: [AccountStats.TopArtist]
    let topTracks: [AccountStats.TopTrack]
    let byDay: [DailyActivity]
    /// `nil` for a month with no listening activity at all.
    let peakDay: YearInReview.PeakDay?

    enum CodingKeys: String, CodingKey {
        case year, month
        case totalPlays        = "total_plays"
        case totalListenSeconds = "total_listen_seconds"
        case distinctArtists   = "distinct_artists"
        case distinctTracks    = "distinct_tracks"
        case averageBpm        = "average_bpm"
        case topArtists        = "top_artists"
        case topTracks         = "top_tracks"
        case byDay              = "by_day"
        case peakDay             = "peak_day"
    }

    struct DailyActivity: Codable, Identifiable {
        let date: String
        let plays: Int
        let listenSeconds: Int
        var id: String { date }
        enum CodingKeys: String, CodingKey { case date, plays, listenSeconds = "listen_seconds" }
    }

    /// Short display name for the month, e.g. "March 2026".
    var displayName: String {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        if let date = Calendar.current.date(from: comps) {
            return formatter.string(from: date)
        }
        return "\(month)/\(year)"
    }
}

/// One collaborator entry from GET /user/playlists/{id}/collaborators.
struct PlaylistCollaborator: Decodable, Identifiable {
    let userId: String
    let username: String
    let role: String
    let addedAt: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId   = "user_id"
        case username
        case role
        case addedAt  = "added_at"
    }
}

/// One entry from GET /user/playlists/shared-with-me.
struct SharedWithMePlaylist: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let role: String
    let ownerUsername: String
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, role
        case ownerUsername = "owner_username"
        case updatedAt     = "updated_at"
    }
}

/// One track within GET /user/playlists/{id}.
struct SharedPlaylistTrack: Decodable {
    let trackUrl: String?
    let localSongId: String?
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case trackUrl        = "track_url"
        case localSongId     = "local_song_id"
        case title, artist, album
        case durationSeconds = "duration_seconds"
    }
}

/// Response from GET /user/scrobble.
struct ScrobbleLinks: Decodable {
    let lastfmLinked: Bool
    let lastfmUsername: String?
    let listenbrainzLinked: Bool
    let librefmLinked: Bool
    let librefmUsername: String?
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case lastfmLinked       = "lastfm_linked"
        case lastfmUsername     = "lastfm_username"
        case listenbrainzLinked = "listenbrainz_linked"
        case librefmLinked      = "librefm_linked"
        case librefmUsername    = "librefm_username"
        case enabled
    }
}

/// One entry from GET /user/subscriptions.
struct ArtistSubscription: Decodable, Identifiable {
    let id: String
    let channelUrl: String
    let channelName: String?
    let lastVideoId: String?
    let lastCheckedAt: String?
    let createdAt: String?
    let channelId: String?
    let channelThumbnail: String?
    /// When true, new uploads from this channel are auto-downloaded into the
    /// library (see `AccountService.checkSubscriptionAndAutoDownload`),
    /// mirroring `TrackedPlaylist.isAutoDownload`. (Feature: subscriptions-expansion)
    let autoDownload: Bool
    /// Optional destination subfolder under "Imported Music" for this
    /// subscription's auto-downloads — nil/empty falls back to the global
    /// Download Folder setting, same convention as `TrackedPlaylist.destinationFolder`.
    let destinationFolder: String?
    /// When true, new-upload alerts (in-app notification + push + webhook)
    /// are suppressed for this channel without unsubscribing — new uploads
    /// still appear in the "New Releases" feed.
    let notificationsMuted: Bool
    /// Free-text grouping label the user assigns (e.g. "Podcasts", "DJs").
    let category: String?
    /// Human-readable insight derived server-side from observed upload
    /// timestamps (e.g. "Uploads ~weekly"), or nil if there's not yet
    /// enough history to estimate a cadence.
    let uploadFrequencyLabel: String?
    /// True if no new upload has been observed in a while (see the bridge's
    /// `_INACTIVE_SUBSCRIPTION_MONTHS`) — surfaced in the UI as a one-tap
    /// "consider unsubscribing" suggestion.
    let isStale: Bool
    /// Days since the last observed new upload (or since subscribing, if
    /// none has ever been observed). nil only in pathological cases.
    let daysSinceActivity: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case channelUrl        = "channel_url"
        case channelName       = "channel_name"
        case lastVideoId       = "last_video_id"
        case lastCheckedAt     = "last_checked_at"
        case createdAt         = "created_at"
        case channelId         = "channel_id"
        case channelThumbnail  = "channel_thumbnail"
        case autoDownload         = "auto_download"
        case destinationFolder    = "destination_folder"
        case notificationsMuted   = "notifications_muted"
        case category
        case uploadFrequencyLabel = "upload_frequency_label"
        case isStale               = "is_stale"
        case daysSinceActivity     = "days_since_activity"
    }
}

/// One entry from GET /user/subscriptions/feed — a single new upload
/// discovered for one of the user's subscriptions, aggregated across every
/// followed channel into one persisted, browsable list (Feature:
/// subscriptions-expansion). `track` is nil if the bridge's stored JSON
/// somehow failed to decode (defensive — shouldn't normally happen).
struct SubscriptionFeedItem: Decodable, Identifiable {
    let id: String
    let subscriptionId: String
    let track: StreamTrack?
    let discoveredAt: String?
    let isRead: Bool
    let channelName: String?
    let channelThumbnail: String?

    enum CodingKeys: String, CodingKey {
        case id
        case subscriptionId   = "subscription_id"
        case track
        case discoveredAt     = "discovered_at"
        case isRead            = "is_read"
        case channelName       = "channel_name"
        case channelThumbnail  = "channel_thumbnail"
    }
}

/// Result from POST /youtube/resolve-channel — a real YouTube channel
/// resolved from a URL/@handle/search term.
struct ResolvedChannel: Decodable {
    let channelId: String
    let channelTitle: String
    let channelThumbnail: String

    enum CodingKeys: String, CodingKey {
        case channelId        = "channel_id"
        case channelTitle     = "channel_title"
        case channelThumbnail = "channel_thumbnail"
    }
}

/// Response from POST /user/subscriptions/{id}/check.
struct SubscriptionCheckResult: Decodable {
    let newTracks: [StreamTrack]

    enum CodingKeys: String, CodingKey {
        case newTracks = "new_tracks"
    }
}

/// Response from GET /user/discord-webhook.
struct DiscordWebhookStatus: Decodable {
    let configured: Bool
    let enabled: Bool
    let webhookUrl: String?

    enum CodingKeys: String, CodingKey {
        case configured, enabled
        case webhookUrl = "webhook_url"
    }
}

/// Response from GET /user/discord-rpc-config — the server-side registration
/// for the local Discord Rich Presence daemon (Application client ID +
/// optional art asset name). Lets the daemon run with just an RPC token.
struct DiscordRpcConfig: Decodable {
    let configured: Bool
    let enabled: Bool
    /// Resolved value the local daemon should actually use — already
    /// falls back to Lumisound's own shared Discord application
    /// server-side when the user hasn't set a personal override
    /// (see `isCustom`).
    let discordClientId: String?
    let largeImage: String?
    let smallImage: String?
    let showButtons: Bool
    /// `true` only when `discordClientId`/the art assets above are this
    /// user's OWN registered Discord Application, not Lumisound's shared
    /// default one.
    let isCustom: Bool

    enum CodingKeys: String, CodingKey {
        case configured, enabled
        case discordClientId = "discord_client_id"
        case largeImage = "large_image"
        case smallImage = "small_image"
        case showButtons = "show_buttons"
        case isCustom = "is_custom"
    }
}

/// Response shape for GET /user/youtube-api-key — the user's personal YouTube
/// Data API v3 key, used by /api/resolve to enumerate full YouTube playlists
/// (bypassing yt-dlp's ~205-entry flat-playlist cap). `apiKey` is masked
/// (e.g. "AIzaSy...AbPw") since the full key is never sent back after saving.
/// Status of this account's stored yt-dlp cookies.txt upload. The cookie
/// contents themselves are never sent back from the server — only whether
/// one is configured and when it was last updated.
struct YtdlpCookiesStatus: Decodable {
    let configured: Bool
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case configured
        case updatedAt = "updated_at"
    }
}

/// Detailed result of validating this account's stored yt-dlp cookies —
/// mirrors the structural + live checks the bridge runs in
/// `_validate_user_cookies` (required sign-in cookies present/expired, plus
/// whether LOGIN_INFO is present for age-restricted content).
struct YtdlpCookiesValidation: Decodable {
    let status: String
    let detail: String
    let missing: [String]
    let ageRestrictionReady: Bool
    let cookieCount: Int

    enum CodingKeys: String, CodingKey {
        case status, detail, missing
        case ageRestrictionReady = "age_restriction_ready"
        case cookieCount = "cookie_count"
    }
}

struct YoutubeApiKeyConfig: Decodable {
    let configured: Bool
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case configured
        case apiKey = "api_key"
    }
}

/// Response shape for GET /user/acoustid-api-key — the user's personal
/// AcoustID API key (free registration at acoustid.org), used by
/// AcoustIDService to identify tracks with wrong/missing tags via audio
/// fingerprint. `apiKey` is masked, same convention as `YoutubeApiKeyConfig`.
struct AcoustIDApiKeyConfig: Decodable {
    let configured: Bool
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case configured
        case apiKey = "api_key"
    }
}

/// One entry from GET /user/notifications.
struct AppNotification: Decodable, Identifiable {
    let id: String
    let type: String
    let title: String
    let body: String?
    let createdAt: String?
    let readAt: String?

    var isUnread: Bool { readAt == nil }

    enum CodingKeys: String, CodingKey {
        case id, type, title, body
        case createdAt = "created_at"
        case readAt    = "read_at"
    }
}

/// Response from POST /user/scrobble/lastfm/request-token.
struct LastfmRequestToken: Decodable {
    let token: String
    let authUrl: String

    enum CodingKeys: String, CodingKey {
        case token
        case authUrl = "auth_url"
    }
}

/// Full playlist (with tracks) from GET /user/playlists/{id}.
struct SharedPlaylistDetail: Decodable {
    let id: String
    let name: String
    let description: String?
    let role: String
    let tracks: [SharedPlaylistTrack]
}

/// One track from GET /user/queue.
struct QueueItem: Decodable {
    let localSongId: String?
    let trackUrl: String?
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case localSongId      = "local_song_id"
        case trackUrl         = "track_url"
        case title, artist, album
        case durationSeconds  = "duration_seconds"
    }
}

/// Listening streaks and badge unlocks from GET /user/achievements.
struct AchievementsData: Codable {
    let totalPlays: Int
    let totalListenSeconds: Int
    let currentStreakDays: Int
    let longestStreakDays: Int
    let badges: [String]

    enum CodingKeys: String, CodingKey {
        case totalPlays         = "total_plays"
        case totalListenSeconds = "total_listen_seconds"
        case currentStreakDays  = "current_streak_days"
        case longestStreakDays  = "longest_streak_days"
        case badges
    }
}

/// One candidate metadata result (from iTunes/MusicBrainz/Deezer) sent to
/// POST /user/intelligence/metadata-resolve for AI-assisted disambiguation.
/// Mirrors the backend's `MetadataCandidate` Pydantic model field-for-field.
struct MetadataCandidate: Codable {
    let title: String
    let artist: String
    let album: String?
    let year: String?
    let source: String
    /// Thumbnail/cover art URL for this candidate (e.g. iTunes'
    /// artworkUrl100/artworkUrl600), when known — sent to Aria Lumi as real
    /// vision input, not just compared as text. Named to match the
    /// backend's `artwork_url` Pydantic field literally, same convention
    /// this struct's other fields and `AccountService+Intelligence.swift`'s
    /// `Response` struct already use (no snake_case<->camelCase coding
    /// strategy is configured on this encoder).
    let artwork_url: String?
}

/// One copy in a Duplicate Finder group, as sent to Aria Lumi's
/// `/user/intelligence/duplicate-resolve` (see `AccountService
/// +Intelligence.resolveDuplicateKeeper`). Field names match the backend's
/// Pydantic `DuplicateCandidate` literally (snake_case, no coding-strategy
/// conversion configured), same convention `MetadataCandidate` above uses.
struct DuplicateResolveCandidate: Codable {
    let format: String
    let bitrate_kbps: Int?
    let sample_rate: Int?
    let duration_seconds: Double
    let file_size_bytes: Int
    let has_embedded_metadata: Bool
    let is_favorite: Bool
}

/// Aria Lumi's pick of which copy to KEEP in a Duplicate Finder group.
/// Carries `memoryID` so a later manual override can be reported back via
/// `reportDuplicateCorrection`, closing the learning loop the same way
/// `MetadataResolution` does for metadata picks.
struct DuplicateResolution {
    let keepIndex: Int
    let memoryID: Int?
    /// "high" / "medium" / "low", as returned by the bridge — DuplicateFinderService
    /// only auto-applies (actually removes the losing copies) on "high"; anything
    /// else is treated as a plain suggestion the user reviews manually, same as before.
    let confidence: String
}

// MARK: - Admin Dashboard

/// GET /admin/api/overview — same data the standalone web dashboard shows
/// (see main.py's _ADMIN_DASHBOARD_HTML), just consumed natively. Only
/// reachable server-side by ADMIN_TOKEN or the hardcoded operator account's
/// own JWT — see AdminDashboardView's own doc comment for the client-side
/// half of that gate.
struct AdminOverview: Codable {
    let version: String
    let ytDlpVersion: String
    let userCount: Int
    let musicFileCount: Int
    let musicBytes: Int
    let disk: DiskUsage?
    let downloadJobs24h: [String: Int]
    let recentErrorCount24h: Int
    let concurrency: Concurrency

    enum CodingKeys: String, CodingKey {
        case version
        case ytDlpVersion = "yt_dlp_version"
        case userCount = "user_count"
        case musicFileCount = "music_file_count"
        case musicBytes = "music_bytes"
        case disk
        case downloadJobs24h = "download_jobs_24h"
        case recentErrorCount24h = "recent_error_count_24h"
        case concurrency
    }

    struct DiskUsage: Codable {
        let totalBytes: Int64
        let usedBytes: Int64
        let freeBytes: Int64
        enum CodingKeys: String, CodingKey {
            case totalBytes = "total_bytes"
            case usedBytes = "used_bytes"
            case freeBytes = "free_bytes"
        }
    }

    struct Concurrency: Codable {
        let ytdlpMax: Int
        let ytdlpAvailable: Int
        let transcodeMax: Int
        let transcodeAvailable: Int
        enum CodingKeys: String, CodingKey {
            case ytdlpMax = "ytdlp_max"
            case ytdlpAvailable = "ytdlp_available"
            case transcodeMax = "transcode_max"
            case transcodeAvailable = "transcode_available"
        }
    }
}

/// One row from GET /admin/api/download-jobs (ios_download_log).
struct AdminDownloadJob: Codable, Identifiable {
    let id: Int
    let source: String
    let sourceId: String
    let title: String?
    let status: String
    let errorMessage: String?
    let durationMs: Int?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, source, status
        case sourceId = "source_id"
        case title
        case errorMessage = "error_message"
        case durationMs = "duration_ms"
        case createdAt = "created_at"
    }
}

/// One row from GET /admin/api/errors (ios_app_logs, level='error').
struct AdminErrorLogEntry: Codable, Identifiable {
    let category: String
    let message: String
    let file: String?
    let line: Int?
    let timestamp: String?
    let appVersion: String?
    let osVersion: String?

    var id: String { "\(timestamp ?? "")-\(category)-\(message.prefix(40))" }

    enum CodingKeys: String, CodingKey {
        case category, message, file, line, timestamp
        case appVersion = "app_version"
        case osVersion = "os_version"
    }
}

/// One row from GET /admin/api/logs — the general-purpose audit log browser
/// (every level/category, filterable), distinct from `AdminErrorLogEntry`
/// (which GET /admin/api/errors scopes to level='error' only).
struct AdminLogEntry: Codable, Identifiable {
    let level: String
    let category: String
    let message: String
    let file: String?
    let line: Int?
    let timestamp: String?
    let deviceModel: String?
    let osVersion: String?
    let appVersion: String?
    let userId: String?

    var id: String { "\(timestamp ?? "")-\(category)-\(level)-\(message.prefix(40))" }

    enum CodingKeys: String, CodingKey {
        case level, category, message, file, line, timestamp
        case deviceModel = "device_model"
        case osVersion = "os_version"
        case appVersion = "app_version"
        case userId = "user_id"
    }
}

/// One row from GET /admin/api/users — powers the Admin Dashboard's user
/// management list (deactivate/reactivate/force-logout).
struct AdminUser: Codable, Identifiable {
    let id: String
    let username: String
    let email: String?
    let createdAt: String?
    let lastLogin: String?
    let isActive: Bool
    let activeSessions: Int
    let isOperator: Bool
    /// nil = no per-user override set (falls back to the server-wide
    /// default) — distinct from an override explicitly set to 0 bytes.
    let storageQuotaBytes: Int?
    /// Optional (not just semantically, but for missing-key safety) — a
    /// bridge deployment running before this field existed server-side
    /// would otherwise fail to decode the WHOLE admin user list with a
    /// generic "data couldn't be read" error instead of just missing this
    /// one number. `nil` reads as 0 used at every call site.
    let storageUsedBytes: Int?

    enum CodingKeys: String, CodingKey {
        case id, username, email
        case createdAt = "created_at"
        case lastLogin = "last_login"
        case isActive = "is_active"
        case activeSessions = "active_sessions"
        case isOperator = "is_operator"
        case storageQuotaBytes = "storage_quota_bytes"
        case storageUsedBytes = "storage_used_bytes"
    }
}

/// One flagged row from GET /admin/api/storage-integrity — either a
/// metadata row whose file is missing on disk, or (only when hash
/// verification was requested) one whose content no longer matches what
/// was actually uploaded.
struct AdminStorageIntegrityIssue: Codable, Identifiable {
    let id: String
    let userId: String
    let filename: String

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case filename
    }
}

/// GET /admin/api/storage-integrity's response — see that endpoint's doc
/// comment on the bridge for why this exists (user-uploaded music lives
/// only on this server's filesystem, with no prior way to detect a file
/// silently lost or corrupted).
struct AdminStorageIntegrityReport: Codable {
    let checked: Int
    let totalRows: Int
    let hashVerified: Bool
    let missing: [AdminStorageIntegrityIssue]
    let corrupted: [AdminStorageIntegrityIssue]

    enum CodingKeys: String, CodingKey {
        case checked
        case totalRows = "total_rows"
        case hashVerified = "hash_verified"
        case missing, corrupted
    }
}

// MARK: - Cross-Device Playback Handoff

/// One row from GET /user/devices (a push-token registration with display
/// metadata) — the transfer target picker's data source.
struct RegisteredDevice: Codable, Identifiable {
    let deviceToken: String
    let platform: String
    let deviceName: String?
    let lastSeenAt: String?

    var id: String { deviceToken }
    var displayName: String { deviceName?.isEmpty == false ? deviceName! : platform.capitalized }

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case platform
        case deviceName = "device_name"
        case lastSeenAt = "last_seen_at"
    }
}

// MARK: - Podcasts

/// One row from GET /podcasts/search (iTunes Search API, proxied) — feeds
/// `AddPodcastSheet`'s search tab; not yet a subscription until tapped.
struct PodcastSearchResult: Codable, Identifiable {
    let title: String?
    let artist: String?
    let feedURL: String
    let artworkURL: String?

    var id: String { feedURL }

    enum CodingKeys: String, CodingKey {
        case title, artist
        case feedURL = "feed_url"
        case artworkURL = "artwork_url"
    }
}

struct PodcastSubscription: Codable, Identifiable {
    let id: String
    let feedURL: String
    let title: String?
    let artworkURL: String?
    let addedAt: String?
    var notificationsMuted: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case feedURL = "feed_url"
        case title
        case artworkURL = "artwork_url"
        case addedAt = "added_at"
        case notificationsMuted = "notifications_muted"
    }
}

struct PodcastEpisode: Codable, Identifiable {
    let guid: String
    let title: String
    let description: String
    let audioURL: String
    let durationSeconds: Int?
    let publishedAt: String?
    /// Podcasting 2.0 `<podcast:chapters url="...">`, when the feed
    /// includes it — pass to `AccountService.fetchPodcastChapters(url:)`
    /// on demand (not fetched automatically per-episode).
    let chaptersURL: String?

    var id: String { guid }

    enum CodingKeys: String, CodingKey {
        case guid, title, description
        case audioURL = "audio_url"
        case durationSeconds = "duration_seconds"
        case publishedAt = "published_at"
        case chaptersURL = "chapters_url"
    }
}

/// One entry from GET /user/podcasts/chapters (Podcasting 2.0 JSON chapters format).
struct PodcastChapter: Codable, Identifiable {
    let startTimeSeconds: Double
    let title: String
    let imageURL: String?

    var id: Double { startTimeSeconds }

    enum CodingKeys: String, CodingKey {
        case startTimeSeconds = "start_time_seconds"
        case title
        case imageURL = "image_url"
    }
}

struct PodcastEpisodeProgress: Codable {
    let episodeGuid: String
    /// Only present when fetched cross-feed (no `feed_url` filter) — see
    /// `AccountService.fetchRecentPodcastProgress`.
    let feedURL: String?
    /// A cached snapshot from when progress was last saved, not a live
    /// re-fetch of the episode — see main.py's doc comment on
    /// get_podcast_episode_progress.
    let title: String?
    let positionSeconds: Double
    let durationSeconds: Double
    let completed: Bool
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case episodeGuid = "episode_guid"
        case feedURL = "feed_url"
        case title
        case positionSeconds = "position_seconds"
        case durationSeconds = "duration_seconds"
        case completed
        case updatedAt = "updated_at"
    }
}
