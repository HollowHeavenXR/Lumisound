import Foundation
import UIKit

// MARK: - StreamingService

@MainActor
final class StreamingService: ObservableObject {

    // MARK: UserDefaults keys

    static let bridgeURLKey      = "ios_bridge_url"
    static let apiKeyKey         = "ios_bridge_api_key"
    static let preferredFormatKey = "streaming_preferred_format"
    static let downloadPathKey    = "download_path_key"
    /// Optional user-named subfolder (Settings → yt-dlp → Download Folder) that
    /// downloads are placed into, so a big playlist lands in one folder instead
    /// of dumping into "Imported Music" — saving manual moving in the Files app.
    static let downloadSubfolderKey = "ytdlp_download_folder"

    /// Strips path separators and trims a user-entered folder name to a single
    /// safe path component (so it can't escape the download directory).
    static func sanitizedFolderName(_ raw: String) -> String {
        String(raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80))
    }

    /// Lists existing subfolder names directly under "Imported Music" (one
    /// level deep) — the set of destinations `DownloadFolderPicker` offers
    /// besides the root and "create new". Unlike deriving the list from
    /// `LibraryManager.allSongs`, this includes empty folders (just created,
    /// nothing downloaded into them yet).
    static func existingDownloadFolderNames() -> [String] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let importDir = docs.appendingPathComponent("Imported Music")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: importDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Creates (if needed) a subfolder under "Imported Music" — used when the
    /// user picks "New Folder…" in `DownloadFolderPicker` so it shows up
    /// immediately (in the picker and the Folders tab) even before anything
    /// has been downloaded into it.
    @discardableResult
    static func createDownloadFolder(named name: String) -> Bool {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let dir = docs.appendingPathComponent("Imported Music").appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Resolves a (possibly empty) folder name — as stored on a
    /// `TrackedPlaylist.destinationFolder` or the global `downloadSubfolderKey`
    /// setting — to the actual destination directory URL to pass as
    /// `downloadToLibrary`'s `destinationDir`. Empty/nil means "Imported Music"
    /// root itself.
    static func downloadDirectory(forFolderName name: String?) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let base = docs.appendingPathComponent("Imported Music")
        guard let name, !name.isEmpty else { return base }
        let sanitized = sanitizedFolderName(name)
        guard !sanitized.isEmpty else { return base }
        return base.appendingPathComponent(sanitized, isDirectory: true)
    }

    /// Public URL baked into the app — routed via a Cloudflare Tunnel so
    /// it works anywhere without home WiFi. Users can override in Settings.
    static let defaultBridgeURL = "https://lumisound-bridge.xenusanimations.studio"

    /// Whether `url` points at the official bridge, ignoring differences that
    /// do not change which server is reached.
    ///
    /// Scheme and host are compared case-insensitively (both are
    /// case-insensitive per RFC 3986) and any trailing slash is dropped. The
    /// path is deliberately included in the comparison: a URL on the right host
    /// but under someone's own prefix is a different deployment, and the shared
    /// key should not be sent there.
    static func isOfficialBridge(_ url: String) -> Bool {
        func normalise(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasSuffix("/") { text.removeLast() }
            guard let components = URLComponents(string: text),
                  let host = components.host else {
                return text.lowercased()
            }
            let scheme = (components.scheme ?? "https").lowercased()
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            let port = components.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host.lowercased())\(port)\(path)"
        }
        return normalise(url) == normalise(defaultBridgeURL)
    }

    // MARK: Available formats

    static let availableFormats: [(label: String, value: String)] = [
        ("M4A (Default)", "m4a"),
        ("MP3",           "mp3"),
        ("FLAC",          "flac"),
        ("Opus",          "opus"),
        ("Best Quality",  "best"),
    ]

    // MARK: Private — Stream URL Cache

    var streamURLCache: [String: (url: URL, expiry: Date)] = [:]
    static let streamURLCacheTTL: TimeInterval = 5 * 60 * 60  // 5 hours

    // MARK: Published state

    @Published var searchResults: [StreamTrack] = []
    @Published var isSearching       = false
    @Published var isLoadingStream   = false
    @Published var isResolvingPlaylist = false
    @Published var isPlaylistResult  = false
    @Published var errorMessage: String?

    // MARK: Server Library state

    @Published var serverTracks: [ServerTrack] = []
    @Published var isSearchingServer = false
    /// nil until the first server-library load; then true/false per the bridge's
    /// `configured` flag (whether SERVER_MUSIC_DIR is set). Lets the UI show a
    /// clear "not set up" message instead of an indefinitely-empty list.
    @Published var serverLibraryConfigured: Bool? = nil

    // MARK: User Music Library state (personal per-user storage)

    @Published var userMusicTracks: [UserMusicTrack] = []
    @Published var isLoadingUserMusic = false
    @Published var downloadHistory: [DownloadHistoryTrack] = []
    @Published var isLoadingDownloadHistory = false
    @Published var isUploadingUserMusic = false
    @Published var uploadProgress: Double = 0

    // MARK: Pending Imports (see StreamingService+PendingDownloads.swift)

    /// One track successfully imported by `reconcilePendingDownloads` this
    /// app session — feeds the "Pending Imports" screen's "Recently
    /// Imported" list so the otherwise-silent background reconciliation
    /// pass (launch/foreground/BGAppRefreshTask/push) is actually visible
    /// and shows WHERE each track landed. Session-scoped only, no disk
    /// persistence — this is a status feed, not a durable record (that's
    /// what the library itself already is).
    struct RecentImport: Identifiable {
        let id = UUID()
        let title: String
        let artist: String?
        /// nil/empty means the plain "Imported Music" root, same convention
        /// `TrackedPlaylist.destinationFolder` uses.
        let destinationFolder: String?
        let importedAt: Date
    }
    /// Newest first, capped at `recentImportsLimit` — this is a lightweight
    /// activity feed, not a full history (see `downloadHistory` for that).
    @Published private(set) var recentImports: [RecentImport] = []
    private let recentImportsLimit = 20

    func recordRecentImport(title: String, artist: String?, destinationFolder: String?) {
        recentImports.insert(
            RecentImport(title: title, artist: artist, destinationFolder: destinationFolder, importedAt: Date()),
            at: 0
        )
        if recentImports.count > recentImportsLimit {
            recentImports.removeLast(recentImports.count - recentImportsLimit)
        }
    }
    /// Cloud storage usage/quota for the logged-in user — see `fetchStorageUsage(token:)`.
    /// `nil` until the first successful fetch.
    @Published var storageUsage: StorageUsage? = nil
    /// This user's personalized weekly mix — see `fetchWeeklyMix(token:)`.
    @Published var weeklyMix: [WeeklyMixTrack] = []

    // MARK: User Music Metadata state (rich metadata from /user/music/metadata)

    @Published var userMusicMetadata: [UserMusicMetadataTrack] = []
    @Published var isLoadingUserMusicMetadata = false
    @Published var isSyncingLibraryBackup = false

    // MARK: Gallery state

    @Published var galleryImages: [GalleryImageInfo] = []
    @Published var isLoadingGallery = false
    @Published var isUploadingGalleryImage = false

    // MARK: Ambient shared reference
    //
    // Mirrors `AccountService.shared` — gives `BackgroundService` (which has no
    // direct SwiftUI environment access to this type at the point gallery images
    // are mutated) a way to trigger cloud gallery upload/restore automatically,
    // for all logged-in users, with no opt-in UI.
    static weak var shared: StreamingService?

    init() {
        Self.shared = self
    }

    // MARK: Persisted settings

    var bridgeURL: String {
        get { UserDefaults.standard.string(forKey: Self.bridgeURLKey) ?? Self.defaultBridgeURL }
        set { UserDefaults.standard.set(newValue, forKey: Self.bridgeURLKey) }
    }

    /// Shared Bearer key for the official bridge's check_auth()-gated legacy
    /// routes (search/stream/download/track/resolve/spotify/playlist/lyrics/
    /// radio — see ios-bridge/main.py's check_auth()). Injected at build time
    /// via Info.plist's LumisoundBridgeAPIKey -> $(LUMISOUND_BRIDGE_API_KEY)
    /// (see ../../Config/Base.xcconfig) rather than hardcoded, so the actual
    /// secret never sits in source/git history — added 2026-08-30 when
    /// server-side enforcement of this key was turned on. Like any
    /// client-embedded secret it's still extractable from the compiled app
    /// binary; it stops casual abuse of the shared public bridge, not a
    /// determined attacker, so treat it as a defense layer alongside
    /// server-side rate limiting rather than a strong secret. Empty if the
    /// build didn't inject a value (see Config/Secrets.xcconfig.example).
    private static let officialBridgeAPIKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "LumisoundBridgeAPIKey") as? String) ?? ""

    /// Security hardening — a self-hosted-bridge Bearer credential, sent
    /// identically to the main account token (see
    /// StreamSearchView+ServerLibraryActions.swift), so it gets the exact
    /// same Keychain treatment AccountService.token does instead of sitting
    /// in plain UserDefaults. Same first-read migration for anyone who
    /// already had one saved before this change.
    var apiKey: String {
        get {
            if let migrated = UserDefaults.standard.string(forKey: Self.apiKeyKey) {
                KeychainTokenStore.set(migrated, account: "bridge_api_key")
                UserDefaults.standard.removeObject(forKey: Self.apiKeyKey)
                return migrated
            }
            if let stored = KeychainTokenStore.get(account: "bridge_api_key"), !stored.isEmpty {
                return stored
            }
            // No self-hosted override configured — use the baked-in key only
            // when still pointed at the official bridge. A self-hosted
            // operator who hasn't set their own key should get "" (open, or
            // rejected by their own server), never our official secret.
            //
            // Compared NORMALISED, not as raw strings. This was an exact `==`,
            // which meant a stored bridge URL differing from the default in any
            // cosmetically irrelevant way — a trailing slash, a capitalised
            // host, http:// typed instead of https:// — silently returned "" and
            // the app then sent no Authorization header at all. Every
            // check_auth-gated route (search, stream, download, resolve) answers
            // 401 to that, so playback simply failed with nothing on screen
            // explaining why. Observed live as stream_proxy_auth_rejected events
            // carrying had_auth_header=false while the key was present, correct,
            // and byte-identical to the server's.
            //
            // `makeRequest` already trims trailing slashes off this same value
            // when building a URL, so the app was happily TALKING to a host it
            // simultaneously judged to be someone else's — that inconsistency is
            // the actual defect, not the stored value.
            return Self.isOfficialBridge(bridgeURL) ? Self.officialBridgeAPIKey : ""
        }
        set {
            if newValue.isEmpty {
                KeychainTokenStore.delete(account: "bridge_api_key")
            } else {
                KeychainTokenStore.set(newValue, account: "bridge_api_key")
            }
            UserDefaults.standard.removeObject(forKey: Self.apiKeyKey)
        }
    }

    var preferredFormat: String {
        get { UserDefaults.standard.string(forKey: Self.preferredFormatKey) ?? "m4a" }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.preferredFormatKey)
            objectWillChange.send()
        }
    }

    var downloadDirectory: URL {
        get {
            let base: URL
            if let savedPath = UserDefaults.standard.string(forKey: Self.downloadPathKey),
               let url = URL(string: savedPath) {
                base = url
            } else {
                // .documentDirectory essentially never fails to resolve on a real
                // device, but a hard crash here would take down the whole app over
                // a directory lookup — fall back to temporaryDirectory (always
                // available) rather than fatalError, matching BPMAnalyzerService's
                // cache-path fallback.
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                base = docs.appendingPathComponent("Imported Music")
            }
            // Place downloads inside the user's custom folder if one is set, so a
            // whole playlist lands together. The library scan recurses, so dedup
            // and playback still see everything regardless of subfolder.
            if let sub = UserDefaults.standard.string(forKey: Self.downloadSubfolderKey) {
                let name = Self.sanitizedFolderName(sub)
                if !name.isEmpty {
                    return base.appendingPathComponent(name, isDirectory: true)
                }
            }
            return base
        }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: Self.downloadPathKey)
        }
    }

    var isConfigured: Bool { true } // always configured via default URL

}


// MARK: - StreamingError

enum StreamingError: LocalizedError {
    case notConfigured
    case invalidURL
    case timeout
    case notFound(String)
    case httpError(Int)
    case incompleteDownload
    case corruptDownload
    /// Carries a specific, already-user-facing reason string straight from
    /// the bridge's error `detail` field (e.g. "upload your YouTube cookies
    /// to play age-restricted videos") instead of a generic message.
    case serverDetail(String)
    /// Another download of this exact sourceTrackID is already in flight
    /// (see `DownloadLedgerStore.beginDownload`) — not a real failure, just
    /// "don't duplicate work someone else already started."
    case alreadyInFlight
    /// The requested track is already present locally and was skipped before
    /// starting a download. Auto-download callers use this to avoid reporting
    /// a dedupe hit as a newly completed download.
    case alreadyDownloaded
    /// Blocked by the Wi-Fi Only Downloads setting (Settings → Streaming)
    /// — see `NetworkPathMonitor`/`downloadToLibrary`'s guard at the top.
    case wifiRequired
    /// The bridge previously reported this track as gone for good (removed,
    /// private, terminated channel) and it is still inside its cool-off, so no
    /// request was made — see `DownloadFailureStore`. Distinct from `.notFound`,
    /// which is a fresh answer from the server rather than a remembered one.
    case permanentlyUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Streaming service is unavailable right now."
        case .invalidURL:
            return "The bridge returned an invalid stream URL."
        case .timeout:
            return "Stream URL fetch timed out. Try again."
        case .notFound(let title):
            // A handful of videos genuinely go unavailable (removed,
            // region-locked, a real Content-ID takedown) independent of
            // channel type — not necessarily an app bug, and not
            // necessarily permanent. See the removed
            // isBlockedTopicChannelTrack/_is_topic_channel_video special
            // case this replaced: that treated every auto-generated
            // "Topic" channel track as permanently blocked, which stopped
            // being true once yt-dlp's player-client fallback started
            // handling them like any other video.
            return "Could not find a stream URL for \"\(title)\". It may be temporarily unavailable — try again later."
        case .serverDetail(let detail):
            return detail
        case .httpError(let code):
            switch code {
            case 401, 403:
                return "You're not signed in or don't have permission for this. Try signing in again."
            case 404:
                return "Not found on the server — it may have already been removed."
            case 413:
                return "File is too large for the server to accept."
            case 500...599:
                return "Server error (HTTP \(code)). Please try again later."
            default:
                return "Request failed (HTTP \(code)). Please try again later."
            }
        case .incompleteDownload:
            return "Download was incomplete. Please try again."
        case .corruptDownload:
            return "Downloaded file failed an integrity check. Please try again."
        case .alreadyInFlight:
            return "This track is already being downloaded."
        case .alreadyDownloaded:
            return "This track is already downloaded."
        case .wifiRequired:
            return "Wi-Fi Only Downloads is on and you're on cellular — connect to Wi-Fi or turn the setting off in Settings → Streaming."
        case .permanentlyUnavailable:
            return "This track is no longer available to download. The app will check again for it later."
        }
    }
}
