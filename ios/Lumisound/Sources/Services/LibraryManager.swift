import Foundation
import UIKit

/// Progress snapshot for an in-flight library scan — lets the launch screen
/// show "Scanning 340 of 1,100 songs…" instead of a generic spinner for users
/// with big libraries, where a scan can take many seconds.
struct LibraryScanProgress: Equatable {
    let current: Int
    let total: Int
}

@MainActor
final class LibraryManager: ObservableObject {
    @Published var allSongs: [Song] = [] {
        didSet {
            favoriteSongsCache = nil
            MainThreadActivity.measure("library.ambiguousTitles") { Self.recomputeAmbiguousTitles(from: allSongs) }
        }
    }

    /// Recomputes the set of titles that don't identify anything — see
    /// `AmbiguousTitleIndex`, which owns the storage precisely because
    /// `Song.displayName` (a nonisolated computed property on a struct) has to
    /// read it and this class is `@MainActor`.
    private static func recomputeAmbiguousTitles(from songs: [Song]) {
        var seen = Set<String>(minimumCapacity: songs.count)
        var duplicated = Set<String>()
        for song in songs where !song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = song.ambiguityKey
            if !seen.insert(key).inserted { duplicated.insert(key) }
        }
        AmbiguousTitleIndex.replace(with: duplicated)
    }
    @Published var artists: [String] = []
    @Published var albums: [String] = []
    @Published var genres: [String] = []
    @Published var playlists: [Playlist] = []
    @Published var favoriteSongIDs: Set<String> = [] {
        didSet {
            favoriteKeyCache = Set(favoriteSongIDs.map { Self.favoriteKey(for: $0) })
            favoriteSongsCache = nil
        }
    }

    /// Filename-only forms of `favoriteSongIDs`, kept in step by the `didSet`
    /// above so `isFavorite` can do its cross-device match as a set lookup
    /// rather than scanning every favourite on every row render.
    private(set) var favoriteKeyCache: Set<String> = []
    @Published var isScanning: Bool = false
    @Published var scanProgress: LibraryScanProgress? = nil
    @Published var errorMessage: String?
    @Published var lastScanResult: String? = nil

    let persistence: PersistenceService
    let artwork: ArtworkService
    let importer = DocumentImportService()

    // Mirrors `AccountService.shared`/`StreamingService.shared` — gives
    // `BackgroundRefreshService` (invoked directly by iOS via BGTaskScheduler,
    // with no SwiftUI environment access) a way to reach the live library
    // instance for auto-downloading newly-found tracked-playlist tracks.
    static weak var shared: LibraryManager?

    /// Tracks how many scans (media library, local documents, watched folders,
    /// specific-directory) are currently in flight. `isScanning` reflects
    /// whether *any* of them are running, so the launch screen and library UI
    /// stay in "scanning" state for the full duration of a multi-scan launch
    /// instead of flipping to "done" as soon as the first scan finishes.
    var activeScanCount: Int = 0
    var watchedFolderScanTask: Task<Void, Never>?
    var lastWatchedFolderScanDate = Date.distantPast
    /// Throttle for `scanLocalDocuments()` — see that function's doc comment.
    var lastLocalDocumentsScanDate = Date.distantPast
    /// When the last scan actually STARTED, for the interval reported alongside
    /// each completed scan. Distinct from the throttle date above, which only
    /// tracks the throttled entry point and so cannot see scans arriving through
    /// `scanLocalDocumentsAsync`. Static because the scan itself is coalesced
    /// process-wide.
    static var lastScanStartedAt: Date?

    /// Whether any *user-visible* scan is running.
    ///
    /// Separate from `activeScanCount`, which counts every scan including the
    /// automatic ones. `isScanning` gates real UI — the launch screen holds on
    /// it, tabs show progress on it, Settings disables a button on it — so a
    /// scan nobody asked for must not raise it. Automatic passes (the
    /// auto-download check, the return-to-foreground refresh, pending-download
    /// reconciliation) now run silently; only a scan the user actually asked
    /// for, by pulling to refresh or tapping Refresh, shows anything.
    ///
    /// This is what "one long refresh that freezes everything" was: the work
    /// itself is off the main actor and always was, but a single automatic scan
    /// held the visible scanning state for its whole duration where several
    /// short ones had at least let go in between.
    var visibleScanCount: Int = 0

    func beginScan(visible: Bool = true) {
        ScanActivityIndicator.shared.began()
        if visible {
            visibleScanCount += 1
            if !isScanning { isScanning = true }
        }
        activeScanCount += 1
        // `@Published` fires `objectWillChange` on every assignment, whether or
        // not the value differs, so `isScanning` above is only ever assigned on a
        // real transition — re-asserting `true` while a scan was already running
        // forced a full SwiftUI re-render across every view observing
        // LibraryManager for no change at all.
    }

    func endScan(visible: Bool = true) {
        ScanActivityIndicator.shared.ended()
        activeScanCount = max(0, activeScanCount - 1)
        if visible {
            visibleScanCount = max(0, visibleScanCount - 1)
        }
        // Cleared on the VISIBLE count, not the total: a background scan still
        // running must not keep the launch screen up or a tab spinning.
        if visibleScanCount == 0, isScanning {
            isScanning = false
        }
    }

    var mediaSongs: [Song] = []
    var importedSongs: [Song] = []

    /// The in-flight restore of the on-disk library snapshot, awaited by the
    /// first local-documents scan.
    ///
    /// Both are started within moments of each other at launch, and the restore
    /// has to read and JSON-decode a file first, so the scan usually wins the
    /// race. That ordering is the difference between a scan that diffs against a
    /// known library and one that sees `importedSongs` empty and therefore treats
    /// every file on disk as new — which is what field telemetry recorded on
    /// every single launch (`librarySize: 0`, `newSongs: 3546`), and what made
    /// the full main-actor merge and index rebuild run each time.
    ///
    /// Awaiting it costs the scan the snapshot decode's remaining time exactly
    /// once per launch, and saves re-merging the entire library.
    static var snapshotLoadTask: Task<Void, Never>?

    // MARK: Indexed lookups (rebuilt alongside `allSongs` in `rebuildAllSongs()`)
    //
    // `songs(byArtist:)`/`songs(inAlbum:)`/`songs(inGenre:)`/`songs(for:)` used
    // to be a fresh `allSongs.filter { ... }` (or a fresh `Dictionary(uniqueKeysWithValues:)`
    // build for playlists) on every single call — and every visible row in the
    // Artists/Albums/Genres tabs and every row in the Playlists tab calls one of
    // these on every render. At a few hundred+ songs, with a few dozen visible
    // rows, that's thousands of full-array scans per render pass. These caches
    // turn each lookup into an O(1) dictionary read; they're plain (non-`@Published`)
    // stored properties since nothing observes them directly — only
    // `rebuildAllSongs()`'s existing `allSongs`/`artists`/`albums`/`genres`
    // publishes need to trigger a re-render, these just need to be *current* by
    // the time a row reads them.
    var songsByID: [String: Song] = [:]
    var songsByArtist: [String: [Song]] = [:]
    var songsByAlbum: [String: [Song]] = [:]
    var songsByGenre: [String: [Song]] = [:]

    /// Pending debounced rebuild task. Cancelled and replaced on each rapid mutation.
    var pendingRebuildTask: Task<Void, Never>?
    /// Pending debounced snapshot-persist task (see `persistSnapshotIfSettled`).
    /// Separate from `pendingRebuildTask`'s 100ms debounce: `rebuildAllSongs()`
    /// itself runs once per single-song mutation (e.g. each BPM analysis
    /// completing, one at a time, well outside that 100ms window), and every
    /// one of those was unconditionally re-encoding and writing the *entire*
    /// library snapshot to disk. This gives the disk write its own, longer
    /// debounce so a string of individual mutations collapses into one write.
    var pendingSnapshotPersistTask: Task<Void, Never>?

    var foregroundObserver: NSObjectProtocol?
    var metadataReenrichTimer: Timer?
    var isReenrichingMetadata = false
    var metadataRefreshTimer: Timer?
    var isRefreshingMetadata = false
    /// Set while `forceMetadataSync` is running, so the Settings button can
    /// show a spinner and avoid overlapping runs.
    @Published var isForcingMetadataSync = false
    /// Rotating cursor into `importedSongs` for `refreshNextMetadataBatch()` —
    /// advances by `metadataRefreshBatchSize` each tick so every track gets
    /// re-read eventually without ever doing a full-library pass in one go.
    var metadataRefreshCursor = 0

    /// Cached because it is read on every Home reload, every Favorites
    /// rebuild, the hub shortcuts and every sync push, and each read was a
    /// full pass over the library with a string split per non-favourite song.
    /// Invalidated by `allSongs` and `favoriteSongIDs`, the only two inputs.
    var favoriteSongs: [Song] {
        if let cached = favoriteSongsCache { return cached }
        let result = MainThreadActivity.measure("library.favoriteSongs") {
            Self.collapseFavorites(allSongs.filter { isFavorite(songID: $0.id) }, exact: favoriteSongIDs)
        }
        favoriteSongsCache = result
        return result
    }
    private var favoriteSongsCache: [Song]?

    /// One entry per favourite track. The filename fallback in `isFavorite`
    /// (needed for favourites made on the Apple TV) also matched every other
    /// copy of the same file — a second folder, a local copy beside the
    /// cloud entry — so one favourite showed up twice. Keeps, per filename,
    /// the copy whose id was actually favourited, else one with a local file;
    /// order is preserved.
    static func collapseFavorites(_ songs: [Song], exact: Set<String>) -> [Song] {
        var chosen: [String: Song] = [:]
        var order: [String] = []
        for song in songs {
            let key = favoriteKey(for: song.id)
            guard let current = chosen[key] else {
                chosen[key] = song
                order.append(key)
                continue
            }
            let better = (exact.contains(song.id) && !exact.contains(current.id))
                || (exact.contains(song.id) == exact.contains(current.id) && current.url?.isFileURL != true && song.url?.isFileURL == true)
            if better { chosen[key] = song }
        }
        return order.compactMap { chosen[$0] }
    }

    init(persistence: PersistenceService = .shared, artwork: ArtworkService = .shared) {
        self.persistence = persistence
        self.artwork = artwork
        Self.shared = self
        favoriteSongIDs = persistence.loadFavorites()
        playlists = persistence.loadPlaylists()
        // Show last session's library moments after launch — see
        // `loadPersistedSnapshot`. Fired as a Task (not awaited here) since
        // `init` runs before SwiftUI's first frame — awaiting inline would
        // block that frame on the file read/decode, freezing the launch
        // screen's animations for exactly as long as this took, which is
        // the bug `loadPersistedSnapshot` was rewritten to fix. The real
        // scans below always run afterward and overwrite this with fresh
        // data; this just removes the "empty list for several seconds"
        // window for users with big libraries (1000+ songs).
        // Held so the first local scan can await it — see
        // `snapshotLoadTask`'s declaration for why that ordering matters.
        Self.snapshotLoadTask = Task { [weak self] in await self?.loadPersistedSnapshot() }
        // Re-scan local documents whenever the app returns to the foreground so
        // that files the user added via the Files app while Lumisound was
        // backgrounded are picked up without requiring a manual refresh.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scanLocalDocuments() }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        metadataReenrichTimer?.invalidate()
        metadataRefreshTimer?.invalidate()
    }

}
