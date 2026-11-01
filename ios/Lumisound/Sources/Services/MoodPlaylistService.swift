import Foundation

// MARK: - Mood Bucket

enum MoodBucket: String, CaseIterable {
    case energetic = "Energetic"
    case chill     = "Chill"
    case focus     = "Focus"
    case sleep     = "Sleep"
}

// MARK: - MoodPlaylistService

@MainActor
final class MoodPlaylistService: ObservableObject {

    // MARK: Published

    @Published private(set) var energeticSongs: [Song] = []
    @Published private(set) var chillSongs: [Song]     = []
    @Published private(set) var focusSongs: [Song]     = []
    @Published private(set) var sleepSongs: [Song]     = []
    @Published private(set) var isAnalyzing: Bool      = false

    // MARK: Weak reference to library

    weak var libraryManager: LibraryManager?

    /// Mirrors `AccountService.shared`/`LibraryManager.shared` — gives
    /// non-view code (e.g. `DiagnosticsSnapshotService`) a way to reach the
    /// live instance without needing it threaded through as a parameter.
    static weak var shared: MoodPlaylistService?

    init() {
        Self.shared = self
    }

    // MARK: - Public API

    /// Re-analyzes using the current set of songs from `libraryManager`.
    func reanalyze() {
        guard let library = libraryManager else { return }
        Task { await analyze(songs: library.allSongs) }
    }

    /// Analyzes the provided song list and distributes songs into mood buckets.
    /// Runs at background priority so the main thread is never blocked.
    func analyze(songs: [Song]) async {
        guard !songs.isEmpty else { return }

        isAnalyzing = true
        defer { isAnalyzing = false }

        // Run expensive AVAsset metadata reads at background priority.
        let library = libraryManager
        let classified: [(Song, MoodBucket)] = await Task.detached(priority: .background) {
            var results: [(Song, MoodBucket)] = []
            for song in songs {
                let mood = await Self.classify(song: song, library: library)
                results.append((song, mood))
            }
            return results
        }.value

        var energetic: [Song] = []
        var chill:     [Song] = []
        var focus:     [Song] = []
        var sleep:     [Song] = []

        for (song, mood) in classified {
            switch mood {
            case .energetic: energetic.append(song)
            case .chill:     chill.append(song)
            case .focus:     focus.append(song)
            case .sleep:     sleep.append(song)
            }
        }

        // Publish results on MainActor.
        self.energeticSongs = energetic
        self.chillSongs     = chill
        self.focusSongs     = focus
        self.sleepSongs     = sleep
    }

    // MARK: - Classification Logic (nonisolated so it can run off main actor)

    /// Rules live in the Rust core (rust/core/src/mood.rs); BPM comes from the
    /// song, its tags / earlier analysis, or a fresh analysis.
    private static func classify(song: Song, library: LibraryManager?) async -> MoodBucket {
        var bpm = song.bpm
        if bpm == nil, let url = song.url, url.isFileURL {
            bpm = knownBpm(path: url.path, cacheDir: CoreAudio.unlockDir)
        }
        if bpm == nil {
            bpm = await library?.bpm(for: song)
        }
        let mood = moodClassify(song: MoodSong(id: song.id, bpm: bpm, genre: song.genre, displayName: song.displayName,
                                              artistName: song.artistName, duration: song.duration, path: nil),
                                cacheDir: CoreAudio.unlockDir)
        switch mood {
        case .energetic: return .energetic
        case .chill: return .chill
        case .focus: return .focus
        case .sleep: return .sleep
        }
    }
}
