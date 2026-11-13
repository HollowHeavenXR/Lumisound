import MediaPlayer
import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {

    // MARK: Dependencies

    @EnvironmentObject var library: LibraryManager
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var sleepTimer: SleepTimerService
    @EnvironmentObject var updater: UpdateService
    @EnvironmentObject var streaming: StreamingService
    @EnvironmentObject var account: AccountService
    @EnvironmentObject var cacheManager: CacheManagerService
    @EnvironmentObject var folderService: MusicFolderService
    @EnvironmentObject var appLock: AppLockService
    @EnvironmentObject var silenceTrim: SilenceTrimService
    @EnvironmentObject var bluetoothBattery: BluetoothBatteryMonitorService

    /// Drives the Notifications entry row's status pill (On/Off/Needs Access)
    /// and the master toggle inside `NotificationsSettingsView`.
    @ObservedObject var notificationService = NotificationService.shared

    /// Observed purely so this screen re-renders when the user changes tint or
    /// translucency in Appearance → Liquid Glass. `adaptiveGlass` reads
    /// `GlassSettings.shared` at render time without subscribing to it (see
    /// GlassSettings' own "picks up changes on its next redraw" note), which is
    /// fine for surfaces the user isn't looking at — but Liquid Glass is
    /// configured *from inside this very screen*, so without this the row and
    /// picker chrome behind the settings UI would only catch up on a later
    /// unrelated redraw.
    @ObservedObject var glassSettings = GlassSettings.shared

    @State var showLogin = false

    /// Shared with `ContentView`, which hides the floating Car Mode button and
    /// disables auto-activation on car-stereo connection when this is off.
    @AppStorage("carModeEnabled") var carModeEnabled: Bool = false
    /// Shared with `CustomTabBar`/`MiniPlayerBar`/Now Playing's own toggle —
    /// see `NavbarDisplayMode`'s doc comment.
    @AppStorage("navbarDisplayMode") var navbarDisplayMode: NavbarDisplayMode = .tabs
    /// Tab-bar-mode customization — see `NavbarSelectionStyle`'s doc comment.
    @AppStorage("navbarShowTabLabels") var navbarShowTabLabels: Bool = true
    @AppStorage("navbarSelectionStyle") var navbarSelectionStyle: NavbarSelectionStyle = .glassPill
    /// "Allow users to hide different tabs" — shared with `CustomTabBar`;
    /// comma-joined tag numbers. See `hiddenTabsSection`'s doc comment for
    /// the tag numbering and why Settings itself is never included here.
    @AppStorage("navbarHiddenTabs") var navbarHiddenTabsRaw: String = ""
    @AppStorage("wifiOnlyDownloads.enabled") var wifiOnlyDownloadsEnabled: Bool = false

    /// When on, downloads ask the bridge to use aria2 (multi-connection) as the
    /// yt-dlp downloader. Default OFF: benchmarking showed the native downloader
    /// is ~2-3x faster than aria2 on YouTube's CDN for this deployment (aria2's
    /// many-connection splitting added overhead instead of bypassing throttling).
    /// Kept as an opt-in for networks where YouTube hard-throttles single
    /// connections, where aria2 can genuinely win. Read by
    /// `StreamingService.downloadToLibrary` and sent as `use_aria2` to the bridge.
    @AppStorage("ytdlp_use_aria2") var ytdlpUseAria2: Bool = false
    /// Optional custom subfolder for downloads (Settings → yt-dlp). When set,
    /// downloads land in "Imported Music/<folder>". Read by
    /// `StreamingService.downloadDirectory`.
    @AppStorage("ytdlp_download_folder") var ytdlpDownloadFolder: String = ""
    /// Inter-request throttle (yt-dlp --sleep-interval). 0 = fastest. Default 5.
    @AppStorage("ytdlp_throttle_seconds") var ytdlpThrottleSeconds: Int = 5
    /// Parallel DASH fragments (yt-dlp -N). Bridge default is 4 (was 1) — a
    /// meaningful download speedup for fragmented/DASH audio at negligible
    /// memory cost. Matches the bridge's own Query(8, ...) default in
    /// /api/download so the displayed value here is honest about what
    /// actually happens when this is left untouched.
    @AppStorage("ytdlp_concurrent_fragments") var ytdlpConcurrentFragments: Int = 8

    // MARK: YouTube API Key Validation / Exposure Check State

    @State var youtubeKeyConfig: YoutubeApiKeyConfig?
    @State var youtubeKeyInput = ""
    @State var isValidatingYouTubeKey = false
    @State var isSavingYouTubeKey = false
    @State var youtubeExposureTimer: Timer?

    /// Once a configured key is rejected for quota, re-show the "Set Key"
    /// field so the user can replace it. Persisted so it survives app
    /// relaunches until a new/working key is saved or validates again.
    @AppStorage("youtube_api_key_quota_exceeded") var youtubeKeyQuotaExceeded = false

    // MARK: AcoustID API Key State

    @State var acoustIDKeyConfig: AcoustIDApiKeyConfig?
    @State var acoustIDKeyInput = ""
    @State var isSavingAcoustIDKey = false

    // MARK: Streaming & Downloads state (used by streamingDownloadsSection,
    // which lives in SettingsView+StreamingDownloadsSection.swift — kept here
    // since extensions in other files can't hold stored properties)

    @State var showHealthResult = false
    @State var healthOK = false

    // MARK: Body

    /// Top-level Settings categories — replaces the old single cluttered
    /// scroll with focused tabs, each showing only its related sections.
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case audio = "Audio"
        case library = "Library"
        case ytdlp = "yt-dlp"
        case app = "App"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "person.crop.circle"
            case .audio:   return "waveform"
            case .library: return "music.note.list"
            case .ytdlp:   return "arrow.down.circle"
            case .app:     return "gearshape"
            }
        }

        /// Each tab gets its own color (matching the icon/tint its member
        /// sections use in `sectionHeader`) instead of every tab sharing one
        /// flat accent — part of the same "settings' categories should read
        /// as visually distinct at a glance" redesign as the section headers.
        var tint: Color {
            switch self {
            case .general: return .blue
            case .audio:   return .teal
            case .library: return .pink
            case .ytdlp:   return .yellow
            case .app:     return .green
            }
        }
    }

    @State var selectedTab: SettingsTab = .general
    /// The new Settings home's navigation path and search text.
    @State var settingsPath: [SettingsPage] = []
    @State var settingsQuery = ""

    /// Set only by Lumen (see SettingsView+Lumen.swift): renders that one
    /// category as a page inside Lumen's navigation stack. `nil` is the
    /// classic screen, unchanged.
    var lumenPage: SettingsTab? = nil

    var body: some View {
        if let lumenPage {
            lumenPageBody(lumenPage)
        } else {
            settingsHome
        }
    }
}
