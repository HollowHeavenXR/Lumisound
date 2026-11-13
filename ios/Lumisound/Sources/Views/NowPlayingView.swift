import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Now Playing secondary-controls panel
//
// The advanced controls are grouped into switchable panels (segmented control)
// instead of one long vertical wall, so the core playback stays prominent and
// the extras are organized — the layout big music apps use.
enum NowPlayingPanel: String, CaseIterable, Identifiable {
    case controls   = "Controls"
    case sound      = "Sound"
    case queue      = "Queue"
    case lyrics     = "Lyrics"
    case bookmarks  = "Marks"
    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .controls:  return "slider.horizontal.3"
        case .sound:     return "waveform"
        case .queue:     return "list.bullet"
        case .lyrics:    return "quote.bubble"
        case .bookmarks: return "bookmark"
        }
    }
}

/// The big central card's display mode — a reinterpretation of the
/// "headphones / video" toggle from the YouTube-Music-style reference:
/// this app has no video track, so the toggle instead switches the hero
/// card between the artwork display (all 19 built-in styles + custom
/// styles) and a full-size synced lyrics view, surfacing the lyrics
/// feature much more prominently than the old "scroll down to a
/// disclosure panel" placement (which still exists, for the sync editor).
enum NowPlayingDisplayMode: String, CaseIterable, Identifiable {
    case artwork, lyrics
    var id: String { rawValue }
    var iconName: String {
        switch self {
        case .artwork: return "photo.fill"
        case .lyrics:  return "quote.bubble.fill"
        }
    }
    var label: String {
        switch self {
        case .artwork: return "Artwork"
        case .lyrics:  return "Lyrics"
        }
    }
}

// MARK: - Vertical Slider

/// A vertical slider built by rotating a standard SwiftUI Slider -90 degrees.
struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        GeometryReader { geo in
            Slider(
                value: $value,
                in: range
            )
            .rotationEffect(.degrees(-90))
            .frame(width: geo.size.height, height: geo.size.width)
            .offset(
                x: (geo.size.width - geo.size.height) / 2,
                y: (geo.size.height - geo.size.width) / 2
            )
            .tint(AppTheme.dynamicAccent)
        }
    }
}

// MARK: - NowPlayingView

struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayerManager
    // Deliberately NOT `@EnvironmentObject var progress: PlaybackProgress` —
    // that subscribes this view to every ~0.25-0.5s position tick regardless
    // of whether `body` reads it (see NowPlayingView+Timeline.swift's
    // isolation comment). The few pieces that need live position
    // (`NowPlayingScrubber`, `NowPlayingPlaytimeCounter`, `NowPlayingLyricsBody`)
    // declare their own `progress` subscription instead; one-shot reads
    // (adding a bookmark) use `player.position` — a plain, non-published
    // passthrough — instead.
    @EnvironmentObject var library: LibraryManager
    @EnvironmentObject var sleepTimer: SleepTimerService
    @EnvironmentObject var account: AccountService
    @EnvironmentObject var aiDJ: AIDJService
    @EnvironmentObject var deviceSync: DeviceSyncService
    @EnvironmentObject var physicalGestures: PhysicalGesturesService

    // Seeking
    @State var isSeeking = false
    @State var draftPosition: TimeInterval = 0

    // Artwork pulse animation
    @State var artworkScale: CGFloat = 1.0
    @State var artworkOpacity: Double = 1.0

    // Artwork swipe-to-skip (horizontal drag on the artwork area)
    @State var artworkDragOffset: CGFloat = 0
    @State var artworkDragScale: CGFloat = 1.0

    // Track-change animation ID
    @State var artworkAnimationID: String = ""

    // Track info slide-up/fade-in animation
    @State var trackInfoVisible: Bool = true

    // Collapsible panels
    @State var showPlaybackControls = true
    @State var showABRepeat = false
    @State var showEffects = false
    // A Lua theme preset's `layout.eq_expanded_by_default` (see
    // `LuaThemeEngine`) can override this initial value; absent that, this
    // matches the pre-existing hardcoded `true`.
    @State var showEQ = UserDefaults.standard.object(forKey: "lua_layout_eq_expanded") as? Bool ?? true
    @State var showLyrics = false
    @State var showLyricsSyncEditor = false
    /// "Open up custom lyrics files injecting" — a user-supplied .lrc/.txt
    /// file picked via the system document browser. See
    /// `NowPlayingView+Lyrics.swift`'s import button and
    /// `importLyricsFile(from:)` in NowPlayingView+Helpers.swift.
    @State var showLyricsFileImporter = false
    @State var lyricsImportError: String?
    /// True while `generateLyricsWithAria()` (NowPlayingView+Helpers.swift)
    /// has an in-flight request — drives the "Generate with Aria" button's
    /// spinner/disabled state in NowPlayingView+Lyrics.swift.
    @State var isGeneratingLyrics = false
    // Bumped after add/remove so the view re-reads BookmarkStore (which
    // isn't an ObservableObject — it's a plain persisted store, same shape
    // as DownloadLedgerStore/PlayHistoryStore).
    @State var bookmarksRefreshToken = UUID()

    // Artwork style selection — a String rather than `NowPlayingArtworkStyle`
    // directly, since it now needs to represent EITHER one of the 19
    // built-in cases (by rawValue) OR a user-created `CustomNowPlayingStyle`
    // (by its UUID id) — see `selectedBuiltinStyle`/`selectedCustomStyle`.
    // Falls back to the default below both for first-time users AND for
    // anyone whose saved value predates the 2026-07 visual overhaul (the
    // old case names no longer exist in any form).
    @State var artworkStyleSelection: String =
        UserDefaults.standard.string(forKey: "nowPlaying_artworkStyle") ?? NowPlayingArtworkStyle.kaleidoscopeBloom.rawValue
    @ObservedObject var customStyleStore = CustomStyleStore.shared
    @ObservedObject var hiddenStylesStore = HiddenStylesStore.shared
    @State var editingCustomStyle: CustomNowPlayingStyle?
    @State var showStyleManager = false

    // 2026-07 redesign — hero card display mode (artwork vs. full lyrics),
    // live artwork-derived palette (only sampled when the selected custom
    // style opts into `dynamicColorExtraction`), and overflow-menu sheets.
    // Falls back to `.artwork` (the pre-existing hardcoded default) unless a
    // Lua theme preset's `layout.default_display_mode` says otherwise.
    @State var displayMode: NowPlayingDisplayMode = {
        if let raw = UserDefaults.standard.string(forKey: "lua_layout_default_display_mode"),
           let mode = NowPlayingDisplayMode(rawValue: raw) {
            return mode
        }
        return .artwork
    }()
    @State var extractedPalette: ArtworkPalette?

    // Every built-in/custom artwork style wraps its `body` in
    // `TimelineView(.animation(minimumInterval: LumiMotion.frame))` (see ArtworkClock's header comment), which
    // schedules genuine per-frame redraws — SwiftUI does NOT stop delivering
    // those just because this view isn't the front-most tab: `ContentView`'s
    // root `TabView` keeps all 5 of its tagged children instantiated for as
    // long as the app runs (that's what avoids the "collapse into More"
    // UIKit bug documented there), so switching to Library/Queue/Playlists
    // while a track plays left every one of these TimelineViews still firing
    // at up to 120Hz, off-screen, for as long as the user stayed on another
    // tab — a real, continuous CPU/GPU cost with nothing to show for it,
    // plausible as a real contributor to "app always lags, device gets hot
    // within ~10 minutes" for anyone who doesn't just sit on this one tab.
    // `LiveSpectrumArtworkView` already solved the identical problem for its
    // own FFT tap using onAppear/onDisappear (see that view's header
    // comment) — same mechanism here, gating every OTHER style's animation
    // schedule too via `artworkIsPlaying` (NowPlayingView+ArtworkDisplay.swift).
    @State var isVisibleOnScreen = true

    var selectedBuiltinStyle: NowPlayingArtworkStyle? {
        NowPlayingArtworkStyle(rawValue: artworkStyleSelection)
    }

    var selectedCustomStyle: CustomNowPlayingStyle? {
        customStyleStore.style(withID: artworkStyleSelection)
    }

    var visibleBuiltinStyles: [NowPlayingArtworkStyle] {
        NowPlayingArtworkStyle.allCases.filter { !hiddenStylesStore.isHidden($0.rawValue) }
    }

    /// The resolved whole-screen style (typography/layout/spacing/colors) —
    /// see `NowPlayingStyle.swift`'s `NowPlayingScreenStyle`. Reproduces
    /// today's hardcoded look exactly unless a Custom Style is selected.
    var screenStyle: NowPlayingScreenStyle {
        NowPlayingScreenStyle.resolve(from: selectedCustomStyle, extractedPalette: extractedPalette)
    }

    /// Key used to re-run the palette-extraction task below only when it
    /// could actually change something — either the track changes, or the
    /// user switches to/from a style with `dynamicColorExtraction` on.
    var paletteTaskKey: String {
        "\(player.currentSong?.id ?? "-")|\(selectedCustomStyle?.dynamicColorExtraction ?? false)"
    }

    /// "Playing from" label for the pill row above the panel picker —
    /// resolves `player.currentPlaylistID` to its playlist name, falling
    /// back to a generic label when playing from the library at large
    /// (there's no broader "source" tracking elsewhere in the app to draw
    /// on, e.g. distinguishing search results from radio).
    var playingFromLabel: String {
        if let playlistID = player.currentPlaylistID,
           let playlist = library.playlists.first(where: { $0.id == playlistID }) {
            return playlist.name
        }
        return "Your Library"
    }

    /// Applies a style selection and persists it — shared by the picker
    /// chips and the "apply" action from the style manager sheet.
    func selectStyle(_ selectionID: String) {
        artworkStyleSelection = selectionID
        UserDefaults.standard.set(selectionID, forKey: "nowPlaying_artworkStyle")
        if let playlistID = player.currentPlaylistID {
            library.setPreferredArtworkStyle(selectionID, forPlaylistID: playlistID)
        }
    }

    // Seeker + playtime counter styles — @AppStorage (they used to be
    // @State seeded once from UserDefaults) so a change made in Appearance
    // settings, by a Lua theme preset, or by a sync pull shows up here
    // without relaunching.
    @AppStorage("nowPlaying_seekerStyle") var seekerStyle: SeekerStyle = .waveform
    // Defaults to `.hidden`: every seeker style draws its own time labels,
    // so the extra counter row only repeated them (the "1:51 / -0:54" above
    // "1:50 · -0:55" doubling). Anyone who picked a counter keeps it.
    @AppStorage("nowPlaying_playtimeCounterStyle") var playtimeCounterStyle: PlaytimeCounterStyle = .hidden

    /// The Customize sheet — artwork style, seeker and time display, which
    /// used to be three always-visible chip rows on the screen itself.
    @State var showCustomizeSheet = false

    /// Bumped to scroll down to the panels card (the header's "Playing
    /// from" and the utility row's queue button both open the Queue panel).
    @State var panelScrollRequest = 0

    // Queue preview panel
    @AppStorage("nowPlaying_showQueuePreview") var showQueuePreview = true

    /// Shared with `CustomTabBar`/`MiniPlayerBar`/Settings' own toggle — see
    /// `NavbarDisplayMode`'s doc comment. Exposed here too (overflow menu)
    /// since switching to Mini Player mode is most useful right when you're
    /// already looking at Now Playing.
    @AppStorage("navbarDisplayMode") var navbarDisplayMode: NavbarDisplayMode = .tabs

    // Sleep Timer sheet
    @State var showSleepTimerSheet = false

    // Stem separation sheet (Separate Vocals/Instrumental)
    @State var showStemSeparationSheet = false

    // Lyric video export sheet (Share as Video)
    @State var showLyricVideoSheet = false

    // AI DJ session export sheet
    @State var showAIDJExportSheet = false

    // Format info sheet
    @State var showFormatInfoSheet = false
    @State var showPracticeModeSheet = false
    @State var showFocusSessionSheet = false
    @State var voiceMemoBookmark: TrackBookmark?

    // Transfer Playback sheet
    @State var showTransferPlaybackSheet = false
    @State var showListenTogetherSheet = false

    // Custom speed / pitch inline editing
    @State var editingSpeed = false
    @State var speedInput = ""
    @State var editingPitch = false
    @State var pitchInput = ""

    // Lyrics
    @State var lyricsLines: [LrcLine] = []

    // Haptic generators — created once, prepared in onAppear
    let seekHaptic = UIImpactFeedbackGenerator(style: .light)
    let playHaptic = UIImpactFeedbackGenerator(style: .light)
    let skipHaptic = UIImpactFeedbackGenerator(style: .medium)
    let heartHaptic = UIImpactFeedbackGenerator(style: .soft)
    let selectHaptic = UISelectionFeedbackGenerator()

    // Falls back to `.controls` (the pre-existing hardcoded default) unless
    // a Lua theme preset's `layout.default_panel` says otherwise.
    @State var selectedPanel: NowPlayingPanel = {
        if let raw = UserDefaults.standard.string(forKey: "lua_layout_default_panel"),
           let panel = NowPlayingPanel(rawValue: raw) {
            return panel
        }
        return .controls
    }()
    @Namespace var panelPickerNamespace

    var body: some View {
        NavigationStack {
            scrollContent
                .appScreenBackground()
                .background(nowPlayingScreenBackground.ignoresSafeArea())
                .overlay(ListenTogetherReactionsOverlay())
        }
        .sheet(isPresented: $showSleepTimerSheet) {
            SleepTimerSheet()
                .environmentObject(sleepTimer)
                .environmentObject(sleepTimer.progress)
        }
        .sheet(isPresented: $showStemSeparationSheet) {
            if let song = player.currentSong {
                StemSeparationView(song: song)
            }
        }
        .sheet(isPresented: $showLyricVideoSheet) {
            if let song = player.currentSong {
                LyricVideoExportView(song: song, lyrics: lyricsLines)
            }
        }
        .sheet(isPresented: $showAIDJExportSheet) {
            AIDJSessionExportView(log: aiDJ.sessionLog)
        }
        .sheet(isPresented: $showCustomizeSheet) {
            NowPlayingCustomizeSheet(
                artworkStyleSelection: artworkStyleSelection,
                seekerStyle: $seekerStyle,
                playtimeCounterStyle: $playtimeCounterStyle,
                accent: screenStyle.accentColor,
                onSelectArtworkStyle: { selectStyle($0) }
            )
            .environmentObject(library)
            .environmentObject(player)
        }
        // Here rather than on the artwork section, which isn't in the tree
        // while the hero shows lyrics — the overflow menu's "Manage Styles"
        // did nothing in that mode.
        .sheet(item: $editingCustomStyle) { style in
            CustomStyleEditorView(style: style, previewSong: player.currentSong) { saved in
                customStyleStore.update(saved)
                selectStyle(saved.id)
            }
            .environmentObject(library)
        }
        .sheet(isPresented: $showStyleManager) {
            StyleManagerView()
                .environmentObject(library)
        }
        .sheet(isPresented: $showFormatInfoSheet) {
            FormatInfoSheet(song: player.currentSong, isUsingFallback: player.isUsingOpusPlayer)
                .environmentObject(library)
        }
        .sheet(isPresented: $showPracticeModeSheet) {
            PracticeModeView()
                .environmentObject(player)
                .environmentObject(library)
        }
        .sheet(isPresented: $showFocusSessionSheet) {
            FocusSessionView()
                .environmentObject(library)
        }
        .sheet(item: $voiceMemoBookmark) { bookmark in
            VoiceMemoRecorderSheet(bookmark: bookmark)
        }
        .sheet(isPresented: $showListenTogetherSheet) {
            ListenTogetherSheet()
                .environmentObject(ListenRoomService.shared)
                .environmentObject(player)
        }
        .sheet(isPresented: $showTransferPlaybackSheet) {
            TransferPlaybackSheet()
                .environmentObject(account)
                .environmentObject(player)
        }
        .sheet(isPresented: $showLyricsSyncEditor) {
            LyricsSyncEditorView(initialLines: lyricsLines)
                .environmentObject(player)
                .environmentObject(player.progress)
        }
        .fileImporter(
            isPresented: $showLyricsFileImporter,
            // .lrc has no registered system UTType, so it's declared here as
            // a plain-text-conforming type by its filename extension — the
            // same trick has no effect on files that already ARE .txt
            // (.plainText matches those directly).
            allowedContentTypes: [.plainText, UTType(filenameExtension: "lrc") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importLyricsFile(from: url)
            case .failure(let error):
                lyricsImportError = error.localizedDescription
            }
        }
        .alert("Couldn't Import Lyrics", isPresented: Binding(
            get: { lyricsImportError != nil },
            set: { if !$0 { lyricsImportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lyricsImportError ?? "")
        }
        .onChange(of: player.currentSong?.id) { newID in
            guard newID != nil else { return }
            triggerTrackChangeAnimation()
            triggerTrackInfoAnimation()
            loadLyrics()
        }
        // Screen-view telemetry for which Now Playing panel is showing —
        // `.onChange` here catches every path that changes `selectedPanel`
        // (the panel picker's own tap, and the "Playing from"/Queue
        // shortcuts in showPanel()) rather than needing a log call added at
        // each one individually.
        .onChange(of: selectedPanel) { panel in
            appLog("screen_entered: NowPlaying.\(panel.rawValue)", category: "navigation")
        }
        .onChange(of: player.currentPlaylistID) { playlistID in
            guard let playlistID,
                  let playlist = library.playlists.first(where: { $0.id == playlistID }),
                  let raw = playlist.preferredArtworkStyle
            else { return }
            artworkStyleSelection = raw
        }
        .task(id: paletteTaskKey) {
            guard selectedCustomStyle?.dynamicColorExtraction == true else {
                extractedPalette = nil
                return
            }
            extractedPalette = await ArtworkPaletteLoader.palette(for: player.currentSong)
        }
        .onAppear {
            seekHaptic.prepare()
            playHaptic.prepare()
            skipHaptic.prepare()
            heartHaptic.prepare()
            selectHaptic.prepare()
            loadLyrics()
            isVisibleOnScreen = true
        }
        .onDisappear {
            isVisibleOnScreen = false
        }
    }

    /// Whole-screen background, layered behind `GalleryBackgroundView`'s
    /// existing app-wide background: a selected custom style's own blur/
    /// dimming/mesh-gradient/custom-image-or-video treatment, all opt-in
    /// and additive (see `CustomNowPlayingStyle`'s 2026-07 fields). Built-in
    /// artwork styles (or no selection at all) leave this identical to the
    /// pre-redesign behavior — just `GalleryBackgroundView()`.
    @ViewBuilder
    var nowPlayingScreenBackground: some View {
        if let custom = selectedCustomStyle {
            ZStack {
                GalleryBackgroundView()
                if custom.useMeshGradient {
                    NowPlayingMeshGradientBackground(style: custom, extractedPalette: extractedPalette, isVisible: isVisibleOnScreen)
                }
                if custom.customBackgroundMedia != .none {
                    NowPlayingCustomBackgroundMediaView(style: custom, isVisible: isVisibleOnScreen)
                }
                Color.black.opacity(custom.backgroundDimming)
            }
            .blur(radius: screenStyle.backgroundBlurRadius)
        } else {
            GalleryBackgroundView()
        }
    }
}

// MARK: - Pulse Modifier

struct PulseModifier: ViewModifier {
    let isPlaying: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isPlaying)) { timeline in
            let phase = ArtworkClock.pingPong(timeline.date, legDuration: 1.8)
            content
                .scaleEffect(isPlaying ? 1.0 + 0.022 * phase : 1.0)
                .animation(LumiMotion.glide(0.4), value: isPlaying)
        }
    }
}
