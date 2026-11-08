import AppIntents

// MARK: - Lumisound App Intents / Siri Shortcuts
//
// Entirely on-device voice/Shortcuts control — no server round-trip. Each
// intent reaches the live `AudioPlayerManager`/`LibraryManager` via their
// `.shared` weak singletons (the same mechanism `BackgroundRefreshService`
// uses, since an App Intent — like a BGTask — runs outside the normal
// SwiftUI environment and has no other way to reach app state).
//
// None of these open the app. They all used to (`openAppWhenRun = true`), on
// the theory that the `.shared` singletons might not exist in a background
// launch. The cost was that every Siri request from a locked phone stopped to
// ask for Face ID, and every request from an unlocked one threw the app over
// whatever was on screen. The singletons are `@StateObject`s on the App struct,
// which SwiftUI creates when it builds the app's scene graph at process launch;
// what a background launch can lack is time for them to finish, which
// `IntentReadiness` waits out — and if they never appear, it fails with a
// message saying so rather than hanging. Intents that start audio adopt
// `AudioPlaybackIntent`, which is what permits starting playback from the
// background.

enum LumisoundIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case noFavorites
    case playlistNotFound
    case emptyPlaylist
    case noSearchResults
    case nothingPlaying
    case artistNotFound
    case emptyLibrary

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            return "Lumisound needs to finish loading — please try again in a moment."
        case .noFavorites:
            return "You don't have any favorite songs yet."
        case .playlistNotFound:
            return "That playlist couldn't be found — it may have been deleted or renamed."
        case .emptyPlaylist:
            return "That playlist doesn't have any songs yet."
        case .noSearchResults:
            return "Couldn't find anything to play for that search."
        case .nothingPlaying:
            return "Nothing is playing in Lumisound right now."
        case .artistNotFound:
            return "That artist isn't in your library."
        case .emptyLibrary:
            return "Your Lumisound library is empty."
        }
    }
}

/// Waits for the app's state to exist before an intent touches it.
///
/// An intent can be the reason the process was launched, in which case it
/// arrives while the player and library are still being created, and before
/// the library snapshot has loaded. Failing straight away turned "Siri, play my
/// favorites" into an error whenever the app had not been opened recently.
@MainActor
enum IntentReadiness {
    private static func wait<T>(seconds: Double = 8, _ get: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let value = get() { return value }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static func player() async throws -> AudioPlayerManager {
        guard let player = await wait({ AudioPlayerManager.shared }) else {
            throw LumisoundIntentError.appNotReady
        }
        return player
    }

    /// The library, once it has songs in it (or has visibly finished loading
    /// an empty one).
    static func library() async throws -> LibraryManager {
        guard let library = await wait({ LibraryManager.shared }) else {
            throw LumisoundIntentError.appNotReady
        }
        _ = await wait(seconds: 6) { library.allSongs.isEmpty ? nil : true }
        return library
    }

    static func streaming() async throws -> StreamingService {
        guard let streaming = await wait({ StreamingService.shared }) else {
            throw LumisoundIntentError.appNotReady
        }
        return streaming
    }
}

struct PlayFavoritesIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Favorites"
    static var description = IntentDescription("Plays your favorite songs in Lumisound.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let library = try await IntentReadiness.library()
        let player = try await IntentReadiness.player()
        let favorites = library.favoriteSongs
        guard !favorites.isEmpty else {
            throw LumisoundIntentError.noFavorites
        }
        player.setQueue(favorites, startIndex: 0, autoplay: true)
        return .result()
    }
}

struct TogglePlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play/Pause"
    static var description = IntentDescription("Toggles play/pause in Lumisound.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = try await IntentReadiness.player()
        player.togglePlayPause()
        return .result()
    }
}

struct SkipToNextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Skip to Next Track"
    static var description = IntentDescription("Skips to the next track in Lumisound.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = try await IntentReadiness.player()
        player.userSkipToNext()
        return .result()
    }
}

struct SkipToPreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Skip to Previous Track"
    static var description = IntentDescription("Skips to the previous track in Lumisound.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = try await IntentReadiness.player()
        player.skipToPrevious()
        return .result()
    }
}

struct ToggleShuffleIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Shuffle"
    static var description = IntentDescription("Toggles shuffle in Lumisound.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = try await IntentReadiness.player()
        player.toggleShuffle()
        return .result()
    }
}

/// "Siri, skip forward 30 seconds in Lumisound" — a plain `Int` (seconds).
/// `Measurement<UnitDuration>` was tried twice (once blocked by an old
/// deployment target, once by an unparseable literal default) and even
/// once BOTH of those were fixed, still failed the archive on its own —
/// isolated by confirming this Xcode 26.6 toolchain's
/// `appintentsmetadataprocessor` rejects `Measurement` as an `@Parameter`
/// type outright ("Invalid parameter type. AppEntity and AppEnum are the
/// only allowed types"), on a required parameter with no default,
/// identically on both iOS and tvOS. Whatever the cause (toolchain bug or
/// genuinely unsupported), `Int` is unambiguously a supported primitive
/// parameter type and Siri still resolves a spoken duration into it fine
/// — it just always lands in seconds rather than letting the user name a
/// unit.
struct SeekForwardIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Skip Forward"
    static var description = IntentDescription("Skips forward in the current track in Lumisound.")
    static var openAppWhenRun: Bool = false

    // Named uniquely (not `seconds`, which `SeekBackwardIntent` below also
    // used to declare) — the previous "Invalid parameter type. AppEntity
    // and AppEnum are the only allowed types" failure, which survived
    // every actual type change tried (Measurement, then Int), turned out
    // to track this instead: two sibling AppIntents in the same file both
    // declaring a same-named @Parameter apparently confuses this Xcode
    // 26.6 toolchain's appintentsmetadataprocessor into misreporting a
    // bogus type error rather than a naming-collision one.
    @Parameter(title: "Seconds", default: 15)
    var forwardSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Skip forward \(\.$forwardSeconds) seconds in Lumisound")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = try await IntentReadiness.player()
        player.seek(to: player.position + TimeInterval(forwardSeconds))
        return .result()
    }
}

struct SeekBackwardIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Skip Backward"
    static var description = IntentDescription("Skips backward (rewinds) in the current track in Lumisound.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Seconds", default: 15)
    var backwardSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Skip backward \(\.$backwardSeconds) seconds in Lumisound")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = try await IntentReadiness.player()
        player.seek(to: player.position - TimeInterval(backwardSeconds))
        return .result()
    }
}

struct CycleRepeatModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Cycle Repeat Mode"
    static var description = IntentDescription("Cycles Lumisound's repeat mode between off, repeat-all, and repeat-one.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = try await IntentReadiness.player()
        player.cycleRepeatMode()
        return .result()
    }
}

/// Lets Siri/Shortcuts start a sleep timer without opening the app.
struct StartSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Sleep Timer"
    static var description = IntentDescription("Starts Lumisound's sleep timer for a number of minutes.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Minutes", default: 30)
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$minutes)-minute sleep timer")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await IntentReadiness.player()
        guard let sleepTimer = SleepTimerService.shared else {
            throw LumisoundIntentError.appNotReady
        }
        let clampedMinutes = min(max(minutes, 1), 240)
        sleepTimer.start(duration: TimeInterval(clampedMinutes * 60))
        return .result()
    }
}

/// An `AppEntity` wrapper around `Playlist` so Siri/Shortcuts can offer the
/// user's playlists by name as a pickable parameter (with autocomplete/
/// disambiguation handled by the system from `PlaylistEntityQuery` below).
struct PlaylistEntity: AppEntity {
    let id: UUID
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static var defaultQuery = PlaylistEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PlaylistEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor
    private func allPlaylists() async -> [Playlist] {
        (try? await IntentReadiness.library())?.playlists ?? []
    }

    func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
        await allPlaylists()
            .filter { identifiers.contains($0.id) }
            .map { PlaylistEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        await allPlaylists().map { PlaylistEntity(id: $0.id, name: $0.name) }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        await allPlaylists()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map { PlaylistEntity(id: $0.id, name: $0.name) }
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Playlist"
    static var description = IntentDescription("Plays one of your playlists in Lumisound.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist) in Lumisound")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let library = try await IntentReadiness.library()
        let player = try await IntentReadiness.player()
        guard let match = library.playlists.first(where: { $0.id == playlist.id }) else {
            throw LumisoundIntentError.playlistNotFound
        }
        let songs = library.songs(for: match)
        guard !songs.isEmpty else {
            throw LumisoundIntentError.emptyPlaylist
        }
        player.setQueue(songs, startIndex: 0, autoplay: true)
        return .result()
    }
}

/// Searches the streaming bridge (YouTube by default) for *query* and plays the
/// best match, queuing a few more related results as Up Next — mirrors the
/// Auto-Radio seeding pattern in `LumisoundApp.swift` (which calls
/// `relatedTracks` rather than `search(query:source:)` specifically so it
/// doesn't clobber the published `searchResults` state the Stream Search tab's
/// UI is bound to; this intent has the exact same requirement, since the app
/// is being foregrounded and the user may already have a search in progress).
struct SearchAndPlayIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Search and Play"
    static var description = IntentDescription("Searches and plays a song in Lumisound.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Search")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$query) in Lumisound")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = try await IntentReadiness.player()
        let streaming = try await IntentReadiness.streaming()
        let tracks = await streaming.relatedTracks(query: query, source: "youtube", limit: 5)
        guard !tracks.isEmpty else {
            throw LumisoundIntentError.noSearchResults
        }
        var songs: [Song] = []
        for track in tracks {
            guard let url = try? await streaming.streamURL(for: track) else { continue }
            songs.append(streaming.toSong(track: track, streamURL: url))
        }
        guard !songs.isEmpty else {
            throw LumisoundIntentError.noSearchResults
        }
        player.setQueue(songs, startIndex: 0, autoplay: true)
        return .result()
    }
}

// MARK: - Playback control (one intent, one Siri entry, many commands)

/// The commands `PlaybackControlIntent` understands. An `AppEnum` is one of
/// the two parameter kinds a Siri phrase can embed, so a single App Shortcut
/// can answer "Pause Lumisound", "Next song in Lumisound", "Turn on shuffle in
/// Lumisound" and the rest. Apple allows ten App Shortcuts per app, and a
/// shortcut per command had already used them up.
enum PlaybackCommandOption: String, AppEnum {
    case play
    case pause
    case next
    case previous
    case restart
    case skipForward
    case skipBackward
    case shuffleOn
    case shuffleOff
    case repeatOne
    case repeatAll
    case repeatOff

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Playback Command"

    static var caseDisplayRepresentations: [PlaybackCommandOption: DisplayRepresentation] = [
        .play: DisplayRepresentation(title: "Play", synonyms: ["Resume", "Unpause", "Continue", "Keep playing"]),
        .pause: DisplayRepresentation(title: "Pause", synonyms: ["Stop", "Pause the music", "Stop the music", "Hold"]),
        .next: DisplayRepresentation(title: "Next song", synonyms: ["Next", "Next track", "Skip", "Skip this song", "Skip song"]),
        .previous: DisplayRepresentation(title: "Previous song", synonyms: ["Previous", "Previous track", "Go back", "Last song"]),
        .restart: DisplayRepresentation(title: "Restart song", synonyms: ["Start over", "Play from the beginning", "Replay"]),
        .skipForward: DisplayRepresentation(title: "Skip forward", synonyms: ["Fast forward", "Jump ahead", "Forward"]),
        .skipBackward: DisplayRepresentation(title: "Skip back", synonyms: ["Rewind", "Go back a bit", "Jump back", "Back"]),
        .shuffleOn: DisplayRepresentation(title: "Shuffle on", synonyms: ["Turn on shuffle", "Shuffle", "Enable shuffle"]),
        .shuffleOff: DisplayRepresentation(title: "Shuffle off", synonyms: ["Turn off shuffle", "Stop shuffling", "Disable shuffle"]),
        .repeatOne: DisplayRepresentation(title: "Repeat this song", synonyms: ["Repeat one", "Loop this song", "Repeat song", "On repeat"]),
        .repeatAll: DisplayRepresentation(title: "Repeat all", synonyms: ["Repeat", "Loop", "Repeat the queue", "Loop all"]),
        .repeatOff: DisplayRepresentation(title: "Repeat off", synonyms: ["Turn off repeat", "Stop repeating", "No repeat"]),
    ]
}

struct PlaybackControlIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Control Playback"
    static var description = IntentDescription("Play, pause, skip, rewind, shuffle or repeat in Lumisound.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Command")
    var command: PlaybackCommandOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$command) in Lumisound")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = try await IntentReadiness.player()
        switch command {
        case .play:
            guard player.currentSong != nil || !player.queue.isEmpty else {
                throw LumisoundIntentError.nothingPlaying
            }
            if !player.isPlaying { player.resume() }
        case .pause:
            if player.isPlaying { player.pause() }
        case .next:
            player.userSkipToNext()
        case .previous:
            player.skipToPrevious()
        case .restart:
            guard player.currentSong != nil else { throw LumisoundIntentError.nothingPlaying }
            player.seek(to: 0)
            if !player.isPlaying { player.resume() }
        case .skipForward:
            guard player.currentSong != nil else { throw LumisoundIntentError.nothingPlaying }
            player.seek(to: player.position + 15)
        case .skipBackward:
            guard player.currentSong != nil else { throw LumisoundIntentError.nothingPlaying }
            player.seek(to: player.position - 15)
        case .shuffleOn:
            if !player.shuffleEnabled { player.toggleShuffle() }
        case .shuffleOff:
            if player.shuffleEnabled { player.toggleShuffle() }
        case .repeatOne:
            player.repeatMode = .one
            player.updateNowPlaying()
        case .repeatAll:
            player.repeatMode = .all
            player.updateNowPlaying()
        case .repeatOff:
            player.repeatMode = .off
            player.updateNowPlaying()
        }
        return .result()
    }
}

// MARK: - Artists

/// An artist in the library, so "Play Daft Punk in Lumisound" can name one.
struct ArtistEntity: AppEntity {
    let id: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Artist"
    static var defaultQuery = ArtistEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct ArtistEntityQuery: EntityStringQuery {
    /// Suggestions double as the vocabulary Siri is given for the phrase (see
    /// `updateAppShortcutParameters()`), so they are capped to the artists the
    /// listener has most songs by rather than every name in a large library.
    private static let suggestionLimit = 300

    @MainActor
    private func library() async -> LibraryManager? {
        try? await IntentReadiness.library()
    }

    func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        guard let library = await library() else { return [] }
        return await MainActor.run {
            identifiers.filter { !library.songs(byArtist: $0).isEmpty }.map(ArtistEntity.init(id:))
        }
    }

    func suggestedEntities() async throws -> [ArtistEntity] {
        guard let library = await library() else { return [] }
        return await MainActor.run {
            library.artists
                .map { ($0, library.songs(byArtist: $0).count) }
                .filter { !$0.0.isEmpty }
                .sorted { $0.1 > $1.1 }
                .prefix(Self.suggestionLimit)
                .map { ArtistEntity(id: $0.0) }
        }
    }

    func entities(matching string: String) async throws -> [ArtistEntity] {
        guard let library = await library() else { return [] }
        return await MainActor.run {
            library.artists
                .filter { $0.localizedCaseInsensitiveContains(string) }
                .prefix(50)
                .map(ArtistEntity.init(id:))
        }
    }
}

struct PlayArtistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Artist"
    static var description = IntentDescription("Plays songs by an artist in your Lumisound library.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Artist")
    var artist: ArtistEntity

    @Parameter(title: "Shuffle", default: true)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$artist) in Lumisound") {
            \.$shuffle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let library = try await IntentReadiness.library()
        let player = try await IntentReadiness.player()
        let songs = library.songs(byArtist: artist.id)
        guard !songs.isEmpty else { throw LumisoundIntentError.artistNotFound }
        player.setQueue(shuffle ? songs.smartShuffled() : songs, startIndex: 0, autoplay: true)
        return .result()
    }
}

// MARK: - Whole library

struct ShuffleLibraryIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle Library"
    static var description = IntentDescription("Shuffles every song in your Lumisound library.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let library = try await IntentReadiness.library()
        let player = try await IntentReadiness.player()
        guard !library.allSongs.isEmpty else { throw LumisoundIntentError.emptyLibrary }
        player.setQueue(library.allSongs.smartShuffled(), startIndex: 0, autoplay: true)
        return .result()
    }
}

// MARK: - Current song

struct FavoriteCurrentSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Favorite This Song"
    static var description = IntentDescription("Adds the song playing in Lumisound to your favorites.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = try await IntentReadiness.library()
        let player = try await IntentReadiness.player()
        guard let song = player.currentSong else { throw LumisoundIntentError.nothingPlaying }
        if library.isFavorite(songID: song.id) {
            return .result(dialog: "\(song.displayName) is already in your favorites.")
        }
        library.toggleFavorite(songID: song.id)
        WidgetDataService.shared.updateFavoriteState(isFavorite: true)
        return .result(dialog: "Added \(song.displayName) to your favorites.")
    }
}

struct WhatsPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Playing"
    static var description = IntentDescription("Tells you the song playing in Lumisound.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = try await IntentReadiness.player()
        guard let song = player.currentSong else { throw LumisoundIntentError.nothingPlaying }
        let state = player.isPlaying ? "Playing" : "Paused on"
        return .result(dialog: "\(state) \(song.displayName) by \(song.artistName).")
    }
}

struct LumisoundShortcuts: AppShortcutsProvider {
    // Apple caps AppShortcutsProvider at 10 entries per app — exceeding it
    // fails the archive outright ("Found 11 App Shortcuts, but each app may
    // have at most 10"), and the metadata processor's OTHER diagnostics from
    // the same failed export are misleading side effects of that overflow.
    //
    // Only AppEntity/AppEnum parameters can be embedded in a phrase — never a
    // String or Int, which fails the archive with a misattributed "Invalid
    // parameter type" error. That is why every transport command now lives in
    // one `PlaybackControlIntent` keyed by an AppEnum, which freed the slots
    // for artists, the whole library, favoriting and "what's playing". The
    // older single-purpose intents (TogglePlayPause, SkipToNextTrack, Seek…,
    // ToggleShuffle, CycleRepeatMode) are kept so Shortcuts built on them keep
    // working.
    //
    // Phrases embedding an entity only match names Siri has been told about:
    // `LumisoundShortcuts.updateAppShortcutParameters()` has to run after the
    // library loads and whenever playlists change. It was never called, so
    // "Play <playlist> in Lumisound" could not match anything.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaybackControlIntent(),
            phrases: [
                "\(\.$command) \(.applicationName)",
                "\(\.$command) in \(.applicationName)",
                "\(\.$command) on \(.applicationName)",
                "\(\.$command) the music in \(.applicationName)",
                "\(.applicationName) \(\.$command)",
            ],
            shortTitle: "Control Playback",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: PlayFavoritesIntent(),
            phrases: [
                "Play my favorites in \(.applicationName)",
                "Play favorites in \(.applicationName)",
                "Play my favorite songs in \(.applicationName)",
                "Play my liked songs in \(.applicationName)",
            ],
            shortTitle: "Play Favorites",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: [
                "Shuffle my library in \(.applicationName)",
                "Shuffle all songs in \(.applicationName)",
                "Shuffle everything in \(.applicationName)",
                "Play my music in \(.applicationName)",
                "Play some music in \(.applicationName)",
            ],
            shortTitle: "Shuffle Library",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) in \(.applicationName)",
                "Play my \(\.$playlist) playlist in \(.applicationName)",
                "Play the \(\.$playlist) playlist in \(.applicationName)",
                "Shuffle \(\.$playlist) in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: [
                "Play \(\.$artist) in \(.applicationName)",
                "Play songs by \(\.$artist) in \(.applicationName)",
                "Play music by \(\.$artist) in \(.applicationName)",
                "Shuffle \(\.$artist) in \(.applicationName)",
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
        )
        AppShortcut(
            intent: SearchAndPlayIntent(),
            // No `\(\.$query)` interpolation — `query` is a plain String; Siri
            // asks for it when only the phrase is matched.
            phrases: [
                "Search and play in \(.applicationName)",
                "Play a song in \(.applicationName)",
                "Find a song in \(.applicationName)",
            ],
            shortTitle: "Search and Play",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: FavoriteCurrentSongIntent(),
            phrases: [
                "Like this song in \(.applicationName)",
                "Favorite this song in \(.applicationName)",
                "Add this song to my favorites in \(.applicationName)",
                "I love this song in \(.applicationName)",
            ],
            shortTitle: "Favorite Song",
            systemImageName: "heart"
        )
        AppShortcut(
            intent: WhatsPlayingIntent(),
            phrases: [
                "What's playing in \(.applicationName)",
                "What song is this in \(.applicationName)",
                "What's this song in \(.applicationName)",
            ],
            shortTitle: "What's Playing",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: StartSleepTimerIntent(),
            phrases: [
                "Start a sleep timer in \(.applicationName)",
                "Set a sleep timer in \(.applicationName)",
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz.fill"
        )
    }
}

/// Re-registers the entity names Siri can match in phrases ("Play
/// <playlist> in Lumisound"). Debounced, because playlist edits arrive in
/// bursts and each call makes the system re-query every entity.
@MainActor
enum SiriVocabularyRefresher {
    private static var pending: Task<Void, Never>?

    static func refreshSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            LumisoundShortcuts.updateAppShortcutParameters()
        }
    }
}
