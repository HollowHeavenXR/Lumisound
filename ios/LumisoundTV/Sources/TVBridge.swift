import Foundation

// MARK: - TVTrack (search result)

struct TVTrack: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let durationSeconds: Int
    let thumbnailURL: String
    let source: String
    let youtubeURL: String

    enum CodingKeys: String, CodingKey {
        case id, title, artist, source
        case durationSeconds = "duration_seconds"
        case thumbnailURL    = "thumbnail_url"
        case youtubeURL      = "youtube_url"
    }
}

// MARK: - UserMusicTrack (per-user cloud library)

struct UserMusicTrack: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let genre: String
    let trackNumber: String
    let hasArtwork: Bool
    let serverPath: String
    let filename: String
    let ext: String          // the REAL container extension — already unwrapped
                              // server-side for a locked track (e.g. "opus" for
                              // "Song.opus.lms"), never "lms" itself.
    /// True for a Lumisound-locked (`.lms`) cloud backup of a track converted
    /// by the native iOS app's `LumisoundExclusiveExtensionService` — its
    /// bytes on the server are XOR-masked, not directly decodable audio,
    /// until unlocked with `TVLockFormat` (a port of the iOS app's own
    /// `LumisoundLockFormat` — see that type's header comment). tvOS
    /// downloads+unlocks these before playback instead of streaming the raw
    /// URL — see `TVPlayerModel.resolvedAsset(for:)`.
    let isLocked: Bool
    /// ISO 8601 upload timestamp (falls back server-side to the file's mtime
    /// when no metadata row exists) — the only ordering signal available for
    /// a "Recently Added" shelf, since `/user/music` otherwise returns tracks
    /// sorted alphabetically by album/title.
    let uploadedAt: String?
    /// Tempo, measured server-side (see ios-bridge/locked_media.py) — including
    /// for locked files, which no client can analyse itself. Nil when the track
    /// has no steady beat the estimator would commit to.
    let bpm: Double?
    /// How the track ends and begins — measured server-side so both apps decide
    /// crossfades from identical data. See TVTransitionProfile.
    let trailingSilenceS: Double?
    let outroSlopeDB: Double?
    let outroColdStop: Bool?
    let introLeadInS: Double?
    let introOnsetHardness: Double?

    /// Nil until the server has profiled this track, in which case the player
    /// falls back to measuring the tail itself.
    var transitionProfile: TVTransitionProfile? {
        guard trailingSilenceS != nil || outroSlopeDB != nil || introLeadInS != nil else { return nil }
        return TVTransitionProfile(
            trailingSilence: trailingSilenceS ?? 0,
            outroSlopeDB: outroSlopeDB ?? 0,
            outroColdStop: outroColdStop ?? false,
            introLeadIn: introLeadInS ?? 0,
            introOnsetHardness: introOnsetHardness ?? 0
        )
    }

    /// What to actually show for this track, never a raw filename.
    ///
    /// Falling back to `filename` put the extension on screen — a locked
    /// track is stored as "<title>.<realext>.lms", so an empty title surfaced
    /// as "It's Going Down Now.opus". The server also strips both extensions
    /// for its own fallback now; this is the client-side half, so a stale or
    /// older bridge can't put an extension back on screen either.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        var name = filename
        // Outer container first (".lms"), then the real audio extension.
        for suffix in [".lms"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        if let dot = name.lastIndex(of: "."), name[name.index(after: dot)...].count <= 5 {
            name = String(name[..<dot])
        }
        return name.isEmpty ? filename : name
    }

    var durationText: String {
        let s = Int(duration)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    var uploadedDate: Date? {
        guard let uploadedAt else { return nil }
        return tvParseISO8601(uploadedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, genre, filename, ext
        case trackNumber = "track_number"
        case hasArtwork  = "has_artwork"
        case serverPath  = "server_path"
        case isLocked    = "is_locked"
        case uploadedAt  = "uploaded_at"
        case bpm
        case trailingSilenceS   = "trailing_silence_s"
        case outroSlopeDB       = "outro_slope_db"
        case outroColdStop      = "outro_cold_stop"
        case introLeadInS       = "intro_lead_in_s"
        case introOnsetHardness = "intro_onset_hardness"
    }
}

/// Parses the bridge's ISO-8601 timestamps, which show up both with and
/// without fractional seconds depending on the source column/fallback that
/// produced them — see `tvFormattedTimestamp` in TVAccountExtras.swift for
/// the same two-formatter dance applied to a display string instead of a `Date`.
/// Shared, built once.
///
/// This function used to allocate BOTH formatters on every call. Constructing an
/// `ISO8601DateFormatter` costs far more than using one, and this is called from
/// inside a sort comparator over the whole library (`TVHomeView.recentlyAdded`),
/// so the cost multiplied out badly: sorting n tracks is ~n·log n comparisons,
/// each reading `uploadedDate` on two tracks, each of those building two
/// formatters. At 273 tracks that is on the order of 10,000 formatter
/// allocations per sort — and Home evaluated that sort several times per render,
/// including on every half-second playback tick. That is the multi-second freeze
/// on entering the library while audio kept playing: the audio thread was fine,
/// the main thread was allocating date formatters.
///
/// Both are read-only after setup. `DateFormatter` and `ISO8601DateFormatter`
/// are documented as thread-safe for parsing once configured, so sharing them is
/// safe even though callers are not all on the main actor.
private let tvISO8601WithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let tvISO8601WithoutFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func tvParseISO8601(_ iso: String) -> Date? {
    tvISO8601WithFraction.date(from: iso) ?? tvISO8601WithoutFraction.date(from: iso)
}

// MARK: - TVFavorite (GET /user/favorites row)
//
// Favoriting on tvOS is scoped to Personal Cloud Library tracks only — a
// UserMusicTrack.id is a stable hash of its server path (see `_stable_id` in
// ios-bridge/main.py), so it round-trips as the same `song_id` iOS uses when
// favoriting the same cloud track. Search results and playlist entries don't
// have a similarly stable, source-independent id, so they aren't favoritable
// here (mirrors why they aren't included in `TVPlayable.favoriteSongID`).

struct TVFavorite: Codable, Hashable {
    let songID: String
    let title: String?
    let artist: String?
    let album: String?

    enum CodingKeys: String, CodingKey {
        case songID = "song_id"
        case title, artist, album
    }
}

// MARK: - Discovery / stats models (GET /user/on-this-day, /user/stats*, /user/achievements)

/// GET /user/on-this-day — its `tracks` are already exactly TVTrack-shaped
/// (id/title/artist/duration_seconds/thumbnail_url/source/youtube_url), so
/// this reuses that type directly rather than a parallel one.
struct TVOnThisDayGroup: Codable, Hashable, Identifiable {
    let yearsAgo: Int
    let year: Int
    let tracks: [TVTrack]
    var id: Int { year }

    enum CodingKeys: String, CodingKey {
        case yearsAgo = "years_ago"
        case year, tracks
    }
}

struct TVStatArtist: Decodable, Hashable, Identifiable {
    let artist: String
    let playCount: Int
    var id: String { artist }

    enum CodingKeys: String, CodingKey {
        case artist
        case playCount = "play_count"
    }
}

struct TVStatTrack: Decodable, Hashable, Identifiable {
    let title: String
    let artist: String?
    let playCount: Int
    var id: String { "\(title)|\(artist ?? "")" }

    enum CodingKeys: String, CodingKey {
        case title, artist
        case playCount = "play_count"
    }
}

struct TVStatsSummary: Decodable, Hashable {
    let totalPlays: Int
    let totalListenSeconds: Int
    let topArtists: [TVStatArtist]
    let topTracks: [TVStatTrack]

    enum CodingKeys: String, CodingKey {
        case totalPlays = "total_plays"
        case totalListenSeconds = "total_listen_seconds"
        case topArtists = "top_artists"
        case topTracks = "top_tracks"
    }
}

struct TVWeeklyStatDay: Decodable, Hashable, Identifiable {
    let date: String
    let plays: Int
    let listenSeconds: Int
    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date, plays
        case listenSeconds = "listen_seconds"
    }
}

struct TVAchievements: Decodable, Hashable {
    let currentStreakDays: Int
    let longestStreakDays: Int
    let totalPlays: Int
    let totalListenSeconds: Int
    let badges: [String]

    enum CodingKeys: String, CodingKey {
        case currentStreakDays = "current_streak_days"
        case longestStreakDays = "longest_streak_days"
        case totalPlays = "total_plays"
        case totalListenSeconds = "total_listen_seconds"
        case badges
    }
}

// MARK: - Smart playlists (GET /user/music/smart-playlists — server-computed
// BPM buckets over the Personal Cloud Library; distinct from iOS's on-device
// Lua smart-playlist engine, which needs a local library scan tvOS doesn't
// have — see TVOS round-3 research notes)

struct TVSmartPlaylistTrack: Decodable, Hashable {
    let id: String
    let filename: String
    let title: String?
    let artist: String?
    let album: String?
    let bpm: Double
}

struct TVSmartPlaylistBucket: Decodable, Hashable, Identifiable {
    let name: String
    let key: String
    let tracks: [TVSmartPlaylistTrack]
    var id: String { key }
}

private struct TVSmartPlaylistsResponse: Decodable {
    let playlists: [TVSmartPlaylistBucket]
}

// MARK: - Round 4: sessions, notifications, subscriptions, friends/presence
//
// Scoped down from the full iOS feature set — see the round-4 research
// notes. Skipped entirely: Listen Together (Apple SharePlay/GroupActivities,
// no tvOS path), push-notification registration (no APNs setup here, but the
// notification *inbox* below is a separate plain GET, unaffected), and
// account actions poorly suited to a remote-typed 10-foot UI (change
// password, 2FA setup, delete account).

struct TVSession: Decodable, Hashable, Identifiable {
    let tokenID: String
    let deviceName: String?
    let createdAt: String?
    let expiresAt: String?
    let isCurrent: Bool
    var id: String { tokenID }

    enum CodingKeys: String, CodingKey {
        case tokenID = "token_id"
        case deviceName = "device_name"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case isCurrent = "is_current"
    }
}

private struct TVSessionsResponse: Decodable {
    let sessions: [TVSession]
}

struct TVNotification: Decodable, Hashable, Identifiable {
    let id: String
    let type: String
    let title: String?
    let body: String?
    let createdAt: String?
    let readAt: String?
    var isUnread: Bool { readAt == nil }

    enum CodingKeys: String, CodingKey {
        case id, type, title, body
        case createdAt = "created_at"
        case readAt = "read_at"
    }
}

struct TVSubscriptionFeedItem: Decodable, Hashable, Identifiable {
    let id: String
    let track: TVTrack?
    let discoveredAt: String?
    let isRead: Bool
    let channelName: String?

    enum CodingKeys: String, CodingKey {
        case id, track
        case discoveredAt = "discovered_at"
        case isRead = "is_read"
        case channelName = "channel_name"
    }
}

struct TVFriend: Decodable, Hashable, Identifiable {
    let userID: String
    let username: String?
    let displayName: String?
    var id: String { userID }
    var name: String { displayName ?? username ?? "Friend" }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case username
        case displayName = "display_name"
    }
}

private struct TVFriendsResponse: Decodable {
    let friends: [TVFriend]
}

struct TVFriendPresence: Decodable, Hashable {
    let userID: String
    let online: Bool
    let isPlaying: Bool
    let nowPlayingTitle: String?
    let nowPlayingArtist: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case online
        case isPlaying = "is_playing"
        case nowPlayingTitle = "now_playing_title"
        case nowPlayingArtist = "now_playing_artist"
    }
}

private struct TVFriendsPresenceResponse: Decodable {
    let presence: [TVFriendPresence]
}

/// A friend currently listening, paired with their presence — what "Friends
/// Listening Now" actually renders (only friends where `presence.isPlaying`).
struct TVFriendListening: Identifiable {
    let friend: TVFriend
    let presence: TVFriendPresence
    var id: String { friend.id }
}

// MARK: - TVPlaylist / TVPlaylistTrack (cross-device synced playlists)
//
// Mirrors GET /user/playlists (see AccountModels.swift's `SharedPlaylistTrack`
// / `SharedPlaylistDetail` on iOS for the reference shape). Playlists on the
// bridge are a generic list of tracks, each backed by either a `local_song_id`
// (an on-device library item — meaningless off the phone that added it, since
// tvOS has no local file/media library access at all) or a `track_url` (the
// URL the adding device played that track from — for a Personal Cloud Library
// song this is the bridge's own `/user/music/stream` URL, which *is* playable
// here). Only tracks with an http(s) `track_url` are playable on tvOS.

struct TVPlaylistTrack: Codable, Hashable, Identifiable {
    let id: String
    let trackURL: String?
    let localSongID: String?
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case trackURL       = "track_url"
        case localSongID    = "local_song_id"
        case title, artist, album
        case durationSeconds = "duration_seconds"
    }

    /// True when this entry has a remote stream URL rather than only a
    /// `file://` path from the device that added it.
    var isRemotelyPlayable: Bool {
        guard let trackURL else { return false }
        return trackURL.hasPrefix("http://") || trackURL.hasPrefix("https://")
    }

    /// The bare filename this entry refers to, for matching against the cloud
    /// library — see `TVBridgeClient.libraryMatch(for:)`.
    ///
    /// Both forms the phone writes end in the real filename:
    ///   local:Imported Music/KPOP Demon Hunters/Takedown.opus.lms
    ///   file:///private/var/mobile/.../Takedown.opus.lms
    /// so the last path component is the part that carries across devices. The
    /// `file://` form is percent-encoded, hence the decode.
    var libraryFilenameHint: String? {
        if let localSongID, let last = localSongID.split(separator: "/").last {
            return String(last)
        }
        if let trackURL, let last = trackURL.split(separator: "/").last {
            return String(last).removingPercentEncoding ?? String(last)
        }
        return nil
    }
}

struct TVPlaylist: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let folder: String?
    var tracks: [TVPlaylistTrack]
}

// MARK: - TVPlayable (unified playback item)
//
// Both search results and per-user library tracks reduce to this so the player
// handles them uniformly. `authToken`, when set, is sent as a Bearer header for
// the stream + artwork (per-user library requires auth; search streams don't).

struct TVPlayable: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let streamURL: URL
    let artworkURL: URL?
    let authToken: String?
    /// Set only when this item came from the Personal Cloud Library, where
    /// `id` is already the stable favoritable song id — see `TVFavorite`.
    var favoriteSongID: String?
    /// True for a Lumisound-locked (`.lms`) Personal Cloud Library track —
    /// see `UserMusicTrack.isLocked`'s doc comment. Always `false` for
    /// search results and playlist entries, which are never locked.
    var isLocked: Bool = false
    /// The real container extension, only meaningful (non-empty) when
    /// `isLocked` — needed to name the unlocked temp file correctly. See
    /// `TVPlayerModel.resolvedAsset(for:)`.
    var ext: String = ""
    /// Server-measured tempo, used to beat-snap Auto Crossfade. Nil when
    /// unknown, in which case the fade simply is not snapped.
    var bpm: Double? = nil
    /// How this track ends and begins — see TVAutoCrossfade.
    var transitionProfile: TVTransitionProfile? = nil
    /// Real duration, so a fade can be capped against the track's own length.
    var durationSeconds: Double = 0
}

// MARK: - TVSyncTrackBody (POST /user/playlists/{id}/tracks request body —
// mirrors the bridge's `SyncTrack` Pydantic model)

struct TVSyncTrackBody: Encodable {
    let localSongID: String? = nil
    let trackURL: String?
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case localSongID = "local_song_id"
        case trackURL = "track_url"
        case title, artist, album
        case durationSeconds = "duration_seconds"
    }
}

// MARK: - TVBridgeClient

@MainActor
final class TVBridgeClient: ObservableObject {
    static let shared = TVBridgeClient()

    /// The same public bridge the iOS app uses by default.
    let baseURL = "https://lumisound-bridge.xenusanimations.studio"

    /// Shared Bearer key for the bridge's check_auth()-gated legacy routes
    /// (/api/search, /api/stream/proxy, etc. — see ios-bridge/main.py's
    /// check_auth()). tvOS has no self-hosted-bridge override (baseURL is
    /// always the official bridge here), so this is read unconditionally.
    /// Injected at build time via Info.plist's LumisoundBridgeAPIKey ->
    /// $(LUMISOUND_BRIDGE_API_KEY) (see ../../Config/Base.xcconfig) rather
    /// than hardcoded — mirrors StreamingService.officialBridgeAPIKey in the
    /// main iOS app, added 2026-08-30 when server-side enforcement of this
    /// key was turned on. Empty if the build didn't inject a value.
    static let officialBridgeAPIKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "LumisoundBridgeAPIKey") as? String) ?? ""

    // MARK: - Stream ticket
    //
    // Mirrors the iOS app's StreamingService+StreamTicket.swift — see that
    // file's header comment for the full reasoning. Short version: AVPlayer
    // does not reliably reapply AVURLAsset's HTTP-header auth to the byte-
    // range requests that follow a stream's opening request, so the bridge
    // issues a short-lived ticket this app instead carries in the URL's
    // query string, which every request (ranged or not) always includes.
    //
    // tvOS never adopted this — `streamURL(for:)` below only ever sent
    // `X-Account-Token` as a header via `TVPlayerView`'s `AVURLAssetHTTPHeaderFieldsKey`,
    // so every tvOS stream played its opening chunk and then 401'd on the
    // very first range request. Confirmed in production telemetry:
    // `stream_proxy_auth_rejected` is overwhelmingly Apple TV traffic
    // (23.6k of ~24.8k recorded events, 100% ranged, 100% missing both the
    // auth header and the account token by the time the request reached the
    // bridge) — this is the "tracks stop partway through" bug on tvOS.
    private var cachedStreamTicket: String?
    private var cachedStreamTicketExpiry: Date = .distantPast

    /// Fetches (or reuses) a stream ticket for `token`. Safe to call
    /// opportunistically — results are cached and refreshed at half their
    /// TTL, same policy as the iOS app's `streamTicket()`.
    @discardableResult
    func refreshStreamTicketIfNeeded(token: String) async -> String? {
        if let ticket = cachedStreamTicket, Date() < cachedStreamTicketExpiry {
            return ticket
        }
        guard let url = URL(string: baseURL + "/api/stream/ticket") else { return nil }
        struct Response: Decodable { let ticket: String; let expires_in: Double? }
        do {
            var req = URLRequest(url: url)
            req.setValue(token, forHTTPHeaderField: "X-Account-Token")
            req.timeoutInterval = 15
            let (data, response) = try await Core.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let ttl = decoded.expires_in ?? 3600
            cachedStreamTicket = decoded.ticket
            cachedStreamTicketExpiry = Date().addingTimeInterval(ttl / 2)
            return decoded.ticket
        } catch {
            return nil
        }
    }

    // Search
    @Published var results: [TVTrack] = []
    @Published var isSearching = false
    @Published var searchError: String?

    // Per-user library
    @Published var library: [UserMusicTrack] = []
    @Published var isLoadingLibrary = false
    @Published var libraryError: String?
    @Published var libraryConfigured = true

    // Synced playlists
    @Published var playlists: [TVPlaylist] = []
    @Published var isLoadingPlaylists = false
    @Published var playlistsError: String?
    @Published var playlistMutationError: String?

    // Favorites (Personal Cloud Library tracks only — see `TVFavorite`)
    @Published var favoriteSongIDs: Set<String> = []
    /// Filename-only forms of `favoriteSongIDs`, for cross-device matching.
    ///
    /// The two platforms identify the same song with different ids: the phone
    /// stores `local:Imported Music/<folder>/<file>` (its own on-device path),
    /// while a cloud track here is keyed by a server-side content hash. Those
    /// can never be equal, so favourites made on the phone simply never showed
    /// up on the Apple TV even though both devices were reading the same
    /// account's favourites list.
    ///
    /// The filename is the one part both sides genuinely share — it is what
    /// the phone uploads and what the cloud library stores. Verified against
    /// the real account: 14 of 14 favourites match their cloud track this way.
    @Published var favoriteKeys: Set<String> = []
    @Published var isLoadingFavorites = false

    // Discovery / stats
    @Published var discoverMix: [TVTrack] = []
    @Published var isLoadingDiscoverMix = false
    @Published var onThisDay: [TVOnThisDayGroup] = []
    @Published var isLoadingOnThisDay = false
    @Published var smartPlaylists: [TVSmartPlaylistBucket] = []
    @Published var isLoadingSmartPlaylists = false
    @Published var stats: TVStatsSummary?
    @Published var weeklyStats: [TVWeeklyStatDay] = []
    @Published var achievements: TVAchievements?
    @Published var isLoadingStats = false

    // Round 4: sessions, notifications, subscriptions, friends
    @Published var sessions: [TVSession] = []
    @Published var isLoadingSessions = false
    @Published var notifications: [TVNotification] = []
    @Published var isLoadingNotifications = false
    @Published var subscriptionFeed: [TVSubscriptionFeedItem] = []
    @Published var isLoadingSubscriptionFeed = false
    @Published var friendsListening: [TVFriendListening] = []
    /// Shared listening feed — see TVSocial.swift.
    @Published var socialActivity: [TVSocialActivity] = []

    /// Cloud library keyed by lowercased filename, rebuilt whenever `library`
    /// changes. Used to resolve playlist entries that only carry a phone-local
    /// path — see `libraryMatch(for:)`.
    private(set) var libraryByFilename: [String: UserMusicTrack] = [:]

    /// In-flight search query, so a stale/slower response can't overwrite a newer one.
    private var activeSearch = ""

    // MARK: Networking

    /// Performs a request, retrying once on a transient failure (timeout / 5xx
    /// such as a gateway 502). The first call to a slow endpoint (YouTube search,
    /// or the library's cold ffprobe pass) often times out at the gateway; the
    /// retry hits the server's warm cache and usually returns quickly.
    private func dataWithRetry(_ request: URLRequest, retries: Int = 1) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await Core.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 500, retries > 0 {
                return try await dataWithRetry(request, retries: retries - 1)
            }
            // Centralized "app activity" error logging — every GET call site
            // in this file routes through here, so this one spot catches
            // most network failures without needing a log call at each of
            // the ~15 call sites individually. Only fires once per real
            // failure (the terminal give-up point, not every retry attempt).
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                tvWarn("Request failed", category: "network", extra: [
                    "path": request.url?.path ?? "?", "status": "\(http.statusCode)",
                ])
                // Also reported remotely, not just to the local console.
                // `tvWarn` only reaches this box's own log buffer, which is
                // unreadable without the Apple TV in front of you — which is
                // exactly the situation every tvOS bug in this project has been
                // investigated from. Since every GET in this file funnels
                // through here, one call covers ~15 call sites, and the path +
                // status together identify almost any tvOS-side API failure
                // (401 = token never attached, 404 = wrong path, 5xx = bridge).
                TVRemoteLogger.logError(
                    category: "network", event: "request_failed",
                    message: "HTTP \(http.statusCode) \(request.url?.path ?? "?")",
                    detail: ["path": request.url?.path ?? "?",
                             "status": http.statusCode,
                             "method": request.httpMethod ?? "GET",
                             "hadAuthHeader": request.value(forHTTPHeaderField: "Authorization") != nil]
                )
            }
            return (data, response)
        } catch {
            let ns = error as NSError
            // Cancellation is checked BEFORE retrying, not after.
            //
            // The retry came first, so a request cancelled because its screen went
            // away was reissued — for a screen that no longer exists — and only
            // then recognised as cancelled. On a remote-driven UI that navigates
            // constantly this was the single most common "failure" in the logs, so
            // it was also the most retried. Re-asking for /user/on-this-day on
            // behalf of a tab the user already left is pure waste.
            if ns.code == NSURLErrorCancelled {
                throw error
            }
            if retries > 0 { return try await dataWithRetry(request, retries: retries - 1) }

            // Cancellations never reach here — handled above before any retry.
            // Kept out of the error log for the reason that fix records: -999 is
            // what every `.task` produces when its screen goes away mid-request,
            // which on a remote-driven UI happens constantly, and logging them as
            // errors buried the real network failures underneath.

            TVRemoteLogger.logError(
                category: "network", event: "request_failed_after_retries",
                message: error.localizedDescription,
                detail: ["path": request.url?.path ?? "?",
                         "errorDomain": ns.domain, "errorCode": ns.code,
                         "method": request.httpMethod ?? "GET"]
            )
            tvError("Request failed after retries: \(error.localizedDescription)", category: "network", extra: [
                "path": request.url?.path ?? "?",
            ])
            throw error
        }
    }

    // MARK: Search

    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        activeSearch = q
        isSearching = true
        searchError = nil
        defer { if activeSearch == q { isSearching = false } }

        guard var comps = URLComponents(string: baseURL + "/api/search") else { return }
        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "source", value: "youtube"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = comps.url else { return }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 60  // YouTube extraction routinely takes 20-35s
            req.setValue("Bearer \(Self.officialBridgeAPIKey)", forHTTPHeaderField: "Authorization")
            // Lets the bridge search with this account's YouTube Data API key
            // (near-instant) instead of the slow yt-dlp scrape.
            if let accountToken = TVAccount.shared.token {
                req.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
            }
            let (data, response) = try await dataWithRetry(req)
            guard activeSearch == q else { return }  // a newer search superseded this one
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                searchError = "Search failed. Try again."
                results = []
                return
            }
            results = try JSONDecoder().decode([TVTrack].self, from: data)
            searchError = results.isEmpty ? "No results for \"\(q)\"." : nil
        } catch {
            guard activeSearch == q else { return }
            searchError = "Couldn’t reach the music service. Try again."
            results = []
        }
    }

    // MARK: Per-user library

    func fetchLibrary(token: String, search: String = "") async {
        isLoadingLibrary = true
        libraryError = nil
        defer { isLoadingLibrary = false }

        guard var comps = URLComponents(string: baseURL + "/user/music") else { return }
        comps.queryItems = [URLQueryItem(name: "limit", value: "100000")]
        let s = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { comps.queryItems?.append(URLQueryItem(name: "search", value: s)) }
        guard let url = comps.url else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120  // cold ffprobe pass on the server can be slow

        struct Response: Decodable {
            let tracks: [UserMusicTrack]
            let total: Int
            let configured: Bool
        }
        do {
            let (data, response) = try await dataWithRetry(req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                libraryError = http.statusCode == 401
                    ? "Your session expired. Please log in again."
                    : "Library is taking a while to load. Tap Retry."
                return
            }
            // Decoding is real CPU work that scales with account size (this
            // request's own `limit=100000` says the server expects to need
            // to) — offloaded the same way `TVHomeView.rebuildRecentlyAdded()`
            // already offloads its sort over this same `library`, rather
            // than running a potentially-large decode directly on the
            // @MainActor like every other request here does.
            let decoded = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(Response.self, from: data)
            }.value
            libraryConfigured = decoded.configured
            if !decoded.configured {
                libraryError = "User music storage is not configured on the server."
                library = []
                rebuildLibraryIndex()
                return
            }
            library = decoded.tracks
            rebuildLibraryIndex()
        } catch {
            libraryError = "Couldn’t load your library. Tap Retry."
            library = []
            rebuildLibraryIndex()
        }
    }

    // MARK: Playlists

    func fetchPlaylists(token: String) async {
        isLoadingPlaylists = true
        playlistsError = nil
        defer { isLoadingPlaylists = false }

        guard let url = URL(string: baseURL + "/user/playlists") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        do {
            let (data, response) = try await dataWithRetry(req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                playlistsError = http.statusCode == 401
                    ? "Your session expired. Please log in again."
                    : "Couldn’t load your playlists. Tap Retry."
                return
            }
            playlists = try JSONDecoder().decode([TVPlaylist].self, from: data)
        } catch {
            playlistsError = "Couldn’t load your playlists. Tap Retry."
            playlists = []
        }
    }

    /// Bare mutation request — used for create/rename/delete/add-track/
    /// remove-track. Deliberately doesn't use `dataWithRetry`: those retry a
    /// transient 5xx, which is safe for idempotent GETs but could double a
    /// non-idempotent create/add on a slow success that looked like a
    /// failure at the gateway.
    @discardableResult
    private func mutate(_ path: String, method: String, token: String, jsonBody: Data? = nil) async -> Bool {
        guard let url = URL(string: baseURL + path) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        // Centralized "app activity" error logging — every mutation call
        // site (playlist CRUD, favorites, sessions, notifications, play
        // history) routes through here.
        do {
            let (_, response) = try await Core.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                tvWarn("Mutation returned no HTTP response", category: "network", extra: ["path": path, "method": method])
                return false
            }
            let ok = (200..<300).contains(http.statusCode)
            if !ok {
                tvWarn("Mutation failed", category: "network", extra: [
                    "path": path, "method": method, "status": "\(http.statusCode)",
                ])
            }
            return ok
        } catch {
            tvError("Mutation request failed: \(error.localizedDescription)", category: "network", extra: [
                "path": path, "method": method,
            ])
            return false
        }
    }

    // MARK: Playlist mutations

    func createPlaylist(name: String, token: String) async -> Bool {
        playlistMutationError = nil
        guard let body = try? JSONEncoder().encode(["name": name]) else { return false }
        let ok = await mutate("/user/playlists", method: "POST", token: token, jsonBody: body)
        if ok {
            await fetchPlaylists(token: token)
            TVRemoteLogger.log(category: "playlist", event: "playlist_created", authToken: token)
        } else {
            playlistMutationError = "Couldn’t create the playlist. Try again."
        }
        return ok
    }

    func renamePlaylist(id: String, name: String, token: String) async -> Bool {
        playlistMutationError = nil
        guard let body = try? JSONEncoder().encode(["name": name]) else { return false }
        let ok = await mutate("/user/playlists/\(id)", method: "PUT", token: token, jsonBody: body)
        if ok {
            await fetchPlaylists(token: token)
            TVRemoteLogger.log(category: "playlist", event: "playlist_renamed", authToken: token)
        } else {
            playlistMutationError = "Couldn’t rename the playlist. Try again."
        }
        return ok
    }

    func deletePlaylist(id: String, token: String) async -> Bool {
        playlistMutationError = nil
        let ok = await mutate("/user/playlists/\(id)", method: "DELETE", token: token)
        if ok {
            playlists.removeAll { $0.id == id }
            TVRemoteLogger.log(category: "playlist", event: "playlist_deleted", authToken: token)
        } else {
            playlistMutationError = "Couldn’t delete the playlist. Try again."
        }
        return ok
    }

    /// Adds a track to a playlist, then refreshes so the detail view reflects
    /// the server-assigned position/id immediately.
    func addTrack(_ body: TVSyncTrackBody, toPlaylist playlistID: String, token: String) async -> Bool {
        playlistMutationError = nil
        guard let json = try? JSONEncoder().encode(body) else { return false }
        let ok = await mutate("/user/playlists/\(playlistID)/tracks", method: "POST", token: token, jsonBody: json)
        if ok {
            await fetchPlaylists(token: token)
            TVRemoteLogger.log(category: "playlist", event: "playlist_track_added", authToken: token)
        } else {
            playlistMutationError = "Couldn’t add that track. Try again."
        }
        return ok
    }

    func removeTrack(_ trackID: String, fromPlaylist playlistID: String, token: String) async -> Bool {
        playlistMutationError = nil
        let ok = await mutate("/user/playlists/\(playlistID)/tracks/\(trackID)", method: "DELETE", token: token)
        if ok {
            if let idx = playlists.firstIndex(where: { $0.id == playlistID }) {
                playlists[idx].tracks.removeAll { $0.id == trackID }
            }
            TVRemoteLogger.log(category: "playlist", event: "playlist_track_removed", authToken: token)
        } else {
            playlistMutationError = "Couldn’t remove that track. Try again."
        }
        return ok
    }

    // MARK: Favorites

    func fetchFavorites(token: String) async {
        isLoadingFavorites = true
        defer { isLoadingFavorites = false }
        guard let url = URL(string: baseURL + "/user/favorites") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, response) = try? await dataWithRetry(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let favorites = try? JSONDecoder().decode([TVFavorite].self, from: data)
        else { return }
        favoriteSongIDs = Set(favorites.map { $0.songID })
        favoriteKeys = Set(favorites.map { Self.favoriteKey(for: $0.songID) })
    }

    /// Reduces any favourite id to the part every device agrees on — the bare
    /// filename, with the "local:" scheme prefix and any directory components
    /// removed.
    static func favoriteKey(for songID: String) -> String {
        var s = songID
        if let colon = s.firstIndex(of: ":"), s.hasPrefix("local:") {
            s = String(s[s.index(after: colon)...])
        }
        return s.split(separator: "/").last.map(String.init) ?? s
    }

    func isFavorite(_ songID: String) -> Bool {
        if favoriteSongIDs.contains(songID) { return true }
        // Fall back to the shared filename key so a favourite made on another
        // device (different id scheme) still reads as favourited here.
        return favoriteKeys.contains(Self.favoriteKey(for: songID))
    }

    /// Whether a Personal Cloud Library track is favourited. Matches on the
    /// FILENAME rather than the track's server id, which is what makes a
    /// favourite created on the phone visible here.
    func isFavorite(track: UserMusicTrack) -> Bool {
        if favoriteSongIDs.contains(track.id) { return true }
        return favoriteKeys.contains(Self.favoriteKey(for: track.filename))
    }

    /// Optimistically flips local state, then reconciles with the server —
    /// keeps the star responsive to remote-click without waiting on a
    /// round-trip, but self-heals if the request actually failed.
    func toggleFavorite(track: UserMusicTrack, token: String) async {
        let songID = track.id
        let wasFavorite = isFavorite(songID)
        if wasFavorite {
            favoriteSongIDs.remove(songID)
            favoriteKeys.remove(Self.favoriteKey(for: songID))
        } else {
            favoriteSongIDs.insert(songID)
            favoriteKeys.insert(Self.favoriteKey(for: songID))
        }

        let ok: Bool
        if wasFavorite {
            ok = await mutate("/user/favorites/\(songID)", method: "DELETE", token: token)
        } else {
            let payload: [String: String] = [
                "song_id": songID, "title": track.title, "artist": track.artist, "album": track.album,
            ]
            guard let body = try? JSONEncoder().encode(payload) else { return }
            ok = await mutate("/user/favorites", method: "POST", token: token, jsonBody: body)
        }
        if !ok {
            // Revert the optimistic flip.
            if wasFavorite { favoriteSongIDs.insert(songID) } else { favoriteSongIDs.remove(songID) }
        } else {
            TVRemoteLogger.log(category: "favorites", event: wasFavorite ? "favorite_removed" : "favorite_added",
                                detail: ["song_id": songID], authToken: token)
        }
    }

    // MARK: Play history / stats

    /// Reports a play to the bridge (POST /user/history) — powers Discover
    /// Mix, On This Day, and Stats, none of which have anything to show
    /// until tvOS starts logging plays itself (mirrors what iOS already
    /// does elsewhere in its playback path).
    func logPlay(title: String, artist: String, trackURL: String, listenSeconds: Int, token: String) async {
        struct Body: Encodable {
            let title: String
            let artist: String?
            let trackURL: String?
            let listenSeconds: Int
            enum CodingKeys: String, CodingKey {
                case title, artist
                case trackURL = "track_url"
                case listenSeconds = "listen_seconds"
            }
        }
        let body = Body(
            title: title,
            artist: artist.isEmpty ? nil : artist,
            trackURL: trackURL,
            listenSeconds: listenSeconds
        )
        guard let json = try? JSONEncoder().encode(body) else { return }
        await mutate("/user/history", method: "POST", token: token, jsonBody: json)
    }

    func fetchDiscoverMix(token: String) async {
        isLoadingDiscoverMix = true
        defer { isLoadingDiscoverMix = false }
        guard let url = URL(string: baseURL + "/user/discover-mix?limit=30") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        guard let (data, response) = try? await dataWithRetry(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let tracks = try? JSONDecoder().decode([TVTrack].self, from: data)
        else { return }
        discoverMix = tracks
    }

    func fetchOnThisDay(token: String) async {
        isLoadingOnThisDay = true
        defer { isLoadingOnThisDay = false }
        guard let url = URL(string: baseURL + "/user/on-this-day") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, response) = try? await dataWithRetry(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let groups = try? JSONDecoder().decode([TVOnThisDayGroup].self, from: data)
        else { return }
        onThisDay = groups
    }

    func fetchSmartPlaylists(token: String) async {
        isLoadingSmartPlaylists = true
        defer { isLoadingSmartPlaylists = false }
        guard let url = URL(string: baseURL + "/user/music/smart-playlists") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, response) = try? await dataWithRetry(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TVSmartPlaylistsResponse.self, from: data)
        else { return }
        smartPlaylists = decoded.playlists
    }

    /// Cross-references a smart-playlist entry against the already-loaded
    /// Personal Cloud Library by filename — `/user/music/smart-playlists`
    /// returns `ios_user_music_metadata.id` (a content hash), not the
    /// `_stable_id(path)` `/user/music` (and `UserMusicTrack.id`) uses, so
    /// they aren't directly joinable by id. Filename is effectively unique
    /// within one user's music directory in practice; a track that doesn't
    /// resolve is simply skipped rather than shown unplayable.
    func resolvedTrack(for smart: TVSmartPlaylistTrack) -> UserMusicTrack? {
        library.first { $0.filename.caseInsensitiveCompare(smart.filename) == .orderedSame }
    }

    /// Sequential rather than parallel fetches — simpler and lower-risk than
    /// coordinating concurrent requests for a screen that's visited
    /// occasionally, not a hot path where the extra latency would matter.
    func fetchStats(token: String) async {
        isLoadingStats = true
        defer { isLoadingStats = false }
        stats = await fetchStatsSummary(token: token)
        weeklyStats = await fetchWeeklyStatsRaw(token: token)
        achievements = await fetchAchievementsRaw(token: token)
    }

    private func fetchStatsSummary(token: String) async -> TVStatsSummary? {
        guard let url = URL(string: baseURL + "/user/stats") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, response) = try? await dataWithRetry(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(TVStatsSummary.self, from: data)
    }

    private func fetchWeeklyStatsRaw(token: String) async -> [TVWeeklyStatDay] {
        guard let url = URL(string: baseURL + "/user/stats/weekly") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, response) = try? await dataWithRetry(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return [] }
        return (try? JSONDecoder().decode([TVWeeklyStatDay].self, from: data)) ?? []
    }

    private func fetchAchievementsRaw(token: String) async -> TVAchievements? {
        // Streaks/time-of-day badges are computed against the device's local
        // calendar day server-side — see the endpoint's own doc comment for
        // why an omitted offset (defaulting to UTC) can silently break a
        // streak that never actually broke for a non-UTC user.
        let offsetMinutes = TimeZone.current.secondsFromGMT() / 60
        guard var comps = URLComponents(string: baseURL + "/user/achievements") else { return nil }
        comps.queryItems = [URLQueryItem(name: "tz_offset_minutes", value: String(offsetMinutes))]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, response) = try? await dataWithRetry(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(TVAchievements.self, from: data)
    }

    // MARK: Sessions

    func fetchSessions(token: String) async {
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        guard let url = URL(string: baseURL + "/auth/sessions") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, response) = try? await dataWithRetry(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TVSessionsResponse.self, from: data)
        else { return }
        sessions = decoded.sessions
    }

    /// Returns true if the revoked session was this device's own current one
    /// — the caller should log out locally, since the token backing this
    /// very session no longer exists server-side.
    @discardableResult
    func revokeSession(_ tokenID: String, token: String) async -> Bool {
        let wasCurrent = sessions.first(where: { $0.tokenID == tokenID })?.isCurrent ?? false
        let ok = await mutate("/auth/sessions/\(tokenID)", method: "DELETE", token: token)
        if ok {
            sessions.removeAll { $0.tokenID == tokenID }
            tvLog("Session revoked", category: "auth", extra: ["was_current": "\(wasCurrent)"])
            TVRemoteLogger.log(category: "auth", event: "session_revoked",
                                detail: ["was_current_device": wasCurrent], authToken: token)
        }
        return ok && wasCurrent
    }

    // MARK: Notifications

    func fetchNotifications(token: String) async {
        isLoadingNotifications = true
        defer { isLoadingNotifications = false }
        guard let url = URL(string: baseURL + "/user/notifications") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, response) = try? await dataWithRetry(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode([TVNotification].self, from: data)
        else { return }
        notifications = decoded
    }

    func markNotificationRead(_ id: String, token: String) async {
        guard await mutate("/user/notifications/\(id)/read", method: "POST", token: token) else { return }
        await fetchNotifications(token: token)
        TVRemoteLogger.log(category: "notifications", event: "notification_read", authToken: token)
    }

    func markAllNotificationsRead(token: String) async {
        guard await mutate("/user/notifications/read-all", method: "POST", token: token) else { return }
        await fetchNotifications(token: token)
        TVRemoteLogger.log(category: "notifications", event: "notifications_read_all", authToken: token)
    }

    // MARK: Subscriptions feed (read-only — see round-4 scope note above)

    func fetchSubscriptionFeed(token: String) async {
        isLoadingSubscriptionFeed = true
        defer { isLoadingSubscriptionFeed = false }
        guard let url = URL(string: baseURL + "/user/subscriptions/feed?limit=40") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, response) = try? await dataWithRetry(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode([TVSubscriptionFeedItem].self, from: data)
        else { return }
        subscriptionFeed = decoded
    }

    // MARK: Friends listening now (read-only — no add/accept/decline UI;
    // see round-4 scope note above on why a full social tab doesn't fit a
    // shared living-room screen)

    func fetchFriendsListening(token: String) async {
        guard let friendsURL = URL(string: baseURL + "/api/social/friends") else { return }
        var friendsReq = URLRequest(url: friendsURL)
        friendsReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        friendsReq.timeoutInterval = 30
        guard let (friendsData, friendsResp) = try? await dataWithRetry(friendsReq),
              let friendsHTTP = friendsResp as? HTTPURLResponse, (200..<300).contains(friendsHTTP.statusCode),
              let friendsDecoded = try? JSONDecoder().decode(TVFriendsResponse.self, from: friendsData),
              !friendsDecoded.friends.isEmpty
        else {
            friendsListening = []
            return
        }

        guard let presenceURL = URL(string: baseURL + "/api/social/presence/friends") else { return }
        var presenceReq = URLRequest(url: presenceURL)
        presenceReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        presenceReq.timeoutInterval = 30
        guard let (presenceData, presenceResp) = try? await dataWithRetry(presenceReq),
              let presenceHTTP = presenceResp as? HTTPURLResponse, (200..<300).contains(presenceHTTP.statusCode),
              let presenceDecoded = try? JSONDecoder().decode(TVFriendsPresenceResponse.self, from: presenceData)
        else { return }

        let presenceByID = Dictionary(uniqueKeysWithValues: presenceDecoded.presence.map { ($0.userID, $0) })
        friendsListening = friendsDecoded.friends.compactMap { friend in
            guard let presence = presenceByID[friend.userID], presence.isPlaying else { return nil }
            return TVFriendListening(friend: friend, presence: presence)
        }
    }

    // MARK: URL builders

    /// Bridge proxy stream URL for a search result — AVPlayer streams this directly.
    ///
    /// Appends whatever stream ticket is currently cached (see above) — this
    /// function stays synchronous (its ~16 call sites across the TV app all
    /// build queues synchronously via `compactMap`), so a cold cache simply
    /// means this one URL goes out without a ticket, same graceful
    /// degradation the iOS app's `streamURL(for:)` already has for a
    /// signed-out user. If `token` is available, also kicks off a background
    /// refresh so the NEXT call — i.e. every subsequent track in the same
    /// queue/session — has one ready.
    func streamURL(for track: TVTrack) -> URL? {
        guard var comps = URLComponents(string: baseURL + "/api/stream/proxy") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "id", value: track.id),
            URLQueryItem(name: "source", value: track.source),
            URLQueryItem(name: "format", value: "m4a"),
        ]
        if track.source == "soundcloud" {
            comps.queryItems?.append(URLQueryItem(name: "url", value: track.youtubeURL))
        }
        if let ticket = cachedStreamTicket, Date() < cachedStreamTicketExpiry {
            comps.queryItems?.append(URLQueryItem(name: "ticket", value: ticket))
        } else if let token = TVAccount.shared.token {
            Task { await refreshStreamTicketIfNeeded(token: token) }
        }
        return comps.url
    }

    private func encodedPath(_ path: String) -> String? {
        path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }

    func userMusicStreamURL(for track: UserMusicTrack) -> URL? {
        guard let p = encodedPath(track.serverPath) else { return nil }
        return URL(string: "\(baseURL)/user/music/stream?path=\(p)")
    }

    func userMusicArtworkURL(for track: UserMusicTrack) -> URL? {
        guard track.hasArtwork, let p = encodedPath(track.serverPath) else { return nil }
        return URL(string: "\(baseURL)/user/music/artwork?path=\(p)")
    }

    // MARK: Playable mappers

    func playable(from track: TVTrack) -> TVPlayable? {
        guard let url = streamURL(for: track) else { return nil }
        return TVPlayable(
            id: track.id, title: track.title, artist: track.artist,
            streamURL: url,
            artworkURL: URL(string: track.thumbnailURL),
            // Without this, /api/stream/proxy sees no X-Account-Token and falls
            // back to the bridge's shared (often stale) cookies.txt, which
            // YouTube rejects with "Sign in to confirm you're not a bot" —
            // the tvOS "nothing streams" bug. iOS's StreamingService already
            // attaches this on every stream request; tvOS didn't.
            authToken: TVAccount.shared.token
        )
    }

    func playable(from track: UserMusicTrack, token: String) -> TVPlayable? {
        guard let url = userMusicStreamURL(for: track) else { return nil }
        return TVPlayable(
            id: track.id,
            title: track.displayTitle,
            artist: track.artist,
            streamURL: url,
            artworkURL: userMusicArtworkURL(for: track),
            authToken: token,
            favoriteSongID: track.id,
            isLocked: track.isLocked,
            ext: track.ext,
            bpm: track.bpm,
            transitionProfile: track.transitionProfile,
            durationSeconds: track.duration
        )
    }

    /// Only produces a playable for tracks with a remote stream URL — see
    /// `TVPlaylistTrack.isRemotelyPlayable`. Playlist tracks backed only by a
    /// `local_song_id` (an on-device library item on whichever iPhone/iPad
    /// added them) have no artwork endpoint tvOS can key against, so no
    /// artwork is attached; the player falls back to its placeholder art.
    /// Playlist entries, resolved against the cloud library when they carry no
    /// remote URL of their own.
    ///
    /// This is why "playlists don't sync to tvOS". They DO sync — the bridge
    /// returns them intact — but a playlist built on the phone stores each entry
    /// as a snapshot pointing at the file on THAT device:
    ///
    ///     track_url:     file:///private/var/mobile/.../Takedown.opus.lms
    ///     local_song_id: local:Imported Music/KPOP Demon Hunters/Takedown.opus.lms
    ///
    /// A `file://` path inside an iPhone's sandbox means nothing on an Apple TV,
    /// so every such entry failed `isRemotelyPlayable` and was dropped — leaving
    /// playlists that arrived, listed, and were completely empty.
    ///
    /// But the same track is usually in the user's cloud library, which tvOS can
    /// stream. Matching the entry to that row turns a dead snapshot into a
    /// playable track, and brings the artwork with it (these entries carry none
    /// of their own, which is why playlist rows showed placeholder art even when
    /// they played).
    func playable(from track: TVPlaylistTrack, token: String) -> TVPlayable? {
        // A genuine remote URL always wins: it is what the playlist actually
        // points at, and resolving past it could silently substitute a
        // different recording that happens to share a name.
        if track.isRemotelyPlayable, let urlString = track.trackURL, let url = URL(string: urlString) {
            return TVPlayable(
                id: track.id,
                title: track.title,
                artist: track.artist ?? "",
                streamURL: url,
                artworkURL: nil,
                authToken: token
            )
        }
        guard let match = libraryMatch(for: track) else { return nil }
        // Built from the LIBRARY row, not the snapshot — the library row is what
        // can actually be streamed, favourited and shown artwork for.
        return playable(from: match, token: token)
    }

    /// Later duplicates lose: the first row wins, so a filename appearing twice
    /// resolves consistently rather than depending on dictionary ordering.
    func rebuildLibraryIndex() {
        var index: [String: UserMusicTrack] = [:]
        index.reserveCapacity(library.count)
        for track in library {
            let key = track.filename.lowercased()
            if index[key] == nil { index[key] = track }
        }
        libraryByFilename = index
    }

    /// Finds the cloud-library row a playlist entry refers to.
    ///
    /// Filename first: `local_song_id` ends in the file's own name, which
    /// survives being moved between folders and is far more specific than a
    /// title. Title+artist is the fallback for entries whose id doesn't carry a
    /// usable filename — deliberately requiring BOTH to match, since titles
    /// alone collide constantly across a library (an "Intro" on six albums).
    func libraryMatch(for track: TVPlaylistTrack) -> UserMusicTrack? {
        if let name = track.libraryFilenameHint?.lowercased(), !name.isEmpty,
           let hit = libraryByFilename[name] {
            return hit
        }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty else { return nil }
        let artist = (track.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return library.first {
            $0.displayTitle.lowercased() == title
                && (artist.isEmpty || $0.artist.lowercased() == artist)
        }
    }

    // MARK: Add-to-playlist payload mappers
    //
    // A playlist track is stored server-side as a denormalized snapshot
    // (title/artist/album/url), not a reference back to the library — so
    // these just carry the streamable URL forward as `track_url`, the same
    // shape a playlist entry created on iOS would have for a cloud-library
    // or streamed track.

    func syncTrackBody(from track: UserMusicTrack) -> TVSyncTrackBody? {
        guard let url = userMusicStreamURL(for: track) else { return nil }
        return TVSyncTrackBody(
            trackURL: url.absoluteString,
            title: track.displayTitle,
            artist: track.artist.isEmpty ? nil : track.artist,
            album: track.album.isEmpty ? nil : track.album,
            durationSeconds: Int(track.duration)
        )
    }

    func syncTrackBody(from track: TVTrack) -> TVSyncTrackBody? {
        guard let url = streamURL(for: track) else { return nil }
        return TVSyncTrackBody(
            trackURL: url.absoluteString,
            title: track.title,
            artist: track.artist.isEmpty ? nil : track.artist,
            album: nil,
            durationSeconds: track.durationSeconds
        )
    }
}
