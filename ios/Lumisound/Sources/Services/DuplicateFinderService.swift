import Foundation
import UIKit

// MARK: - DuplicateFinderService

/// App side of the Lumisound Duplicate Engine (rust/core/src/dupes.rs).
///
/// The engine decides everything — what counts as a duplicate (exact file,
/// same source, same recording by its LumiPrint acoustic print, or a likely
/// title/artist match that isn't a Live/Remix/Sped-Up variant), how sure it
/// is, which copy to keep and why — and plans a reversible clean-up. This
/// class gathers the library facts the engine needs, publishes the report,
/// and applies clean-ups through `LibraryManager.resolveDuplicates`
/// (copies go to Recently Deleted; favorites and playlist places move to the
/// kept copy; every clean-up can be undone for 30 days).
@MainActor
final class DuplicateFinderService: ObservableObject {

    static let shared = DuplicateFinderService()
    private init() {
        journal = dupeJournal()
    }

    // MARK: Published state

    @Published private(set) var isScanning = false
    /// "Comparing files", "Listening", "Matching".
    @Published private(set) var phase = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var groups: [DupeGroup] = []
    @Published private(set) var report: DupeReport?
    @Published private(set) var journal: [DupeResolution] = []
    @Published private(set) var lastScanDate: Date? = {
        let ts = UserDefaults.standard.double(forKey: "duplicateFinder_lastScanTimestamp")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }()

    /// New acoustic prints per scan. Cached prints are free, so a large
    /// library converges over a few scans instead of one long one.
    static let printBudget: UInt32 = 300

    /// Kept for the text matchers elsewhere (dead-link healing, artwork, GIFs).
    static let durationTolerance: TimeInterval = 2.0
    nonisolated static func extractFeatureName(from text: String) -> String? { dupFeatureName(text: text) }
    nonisolated static func normalize(_ text: String) -> String { dupNormalize(text: text) }
    nonisolated static func normalizeArtist(_ text: String) -> String { dupNormalizeArtist(text: text) }

    // MARK: Periodic scan

    private var periodicTimer: Timer?
    private static let periodicScanInterval: TimeInterval = 6 * 60 * 60

    /// Called once at launch: scans when stale, then every six hours while
    /// the app is in the foreground. Scans only find; nothing is removed
    /// without the listener.
    func startPeriodicScanning() {
        guard periodicTimer == nil else { return }
        if lastScanDate.map({ Date().timeIntervalSince($0) >= Self.periodicScanInterval }) ?? true {
            Task { await scan() }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.periodicScanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard UIApplication.shared.applicationState == .active else { return }
                await self?.scan()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }

    // MARK: Scan

    /// Full-library scan.
    func scan() async {
        guard !isScanning, let library = LibraryManager.shared else { return }
        isScanning = true
        phase = "Preparing"
        progress = 0
        let candidates = Self.candidates(for: library.allSongs)
        let relay = DupeProgressRelay { [weak self] phase, done, total in
            self?.phase = phase
            self?.progress = total > 0 ? Double(done) / Double(total) : 0
        }
        let result = await Self.runEngine(candidates, budget: Self.printBudget, progress: relay)
        report = result
        groups = result.groups
        let now = Date()
        lastScanDate = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "duplicateFinder_lastScanTimestamp")
        isScanning = false
        phase = ""
        appLog("Duplicate Engine: \(result.groups.count) group(s) in \(result.scanned) songs, \(result.fingerprinted) new prints, \(result.pendingPrints) pending, \(ByteCountFormatter.string(fromByteCount: Int64(result.reclaimBytes), countStyle: .file)) reclaimable", category: "library")
    }

    /// Scoped scan (a folder): same engine, own result, never touches the
    /// full-library state above.
    func scanScoped(_ songs: [Song]) async -> DupeReport {
        await Self.runEngine(Self.candidates(for: songs), budget: Self.printBudget, progress: nil)
    }

    nonisolated private static func runEngine(_ candidates: [DupeCandidate], budget: UInt32, progress: DupeProgress?) async -> DupeReport {
        await Task.detached(priority: .utility) {
            dupeScan(songs: candidates,
                     options: DupeScanOptions(cacheDir: CoreAudio.unlockDir, printBudget: budget, acoustic: true),
                     progress: progress)
        }.value
    }

    /// Library facts per song for the engine (main actor: reads the library
    /// and the play queue).
    static func candidates(for songs: [Song]) -> [DupeCandidate] {
        let library = LibraryManager.shared
        let player = AudioPlayerManager.shared
        var playlistCounts: [String: UInt32] = [:]
        for p in library?.playlists ?? [] {
            for id in Set(p.songIDs) { playlistCounts[id, default: 0] += 1 }
        }
        let queued = Set(player?.queue.map(\.id) ?? [])
        let current = player?.currentSong?.id
        return songs.map { song in
            let path = song.url.flatMap { $0.isFileURL ? $0.path : nil }
            return DupeCandidate(
                id: song.id,
                title: song.title,
                artist: song.artist,
                duration: song.duration,
                path: path,
                sourceTrackId: song.sourceTrackID,
                bitrateKbps: UInt32(max(0, song.bitrate)),
                sampleRate: UInt32(max(0, song.sampleRate)),
                isFavorite: library?.isFavorite(songID: song.id) ?? false,
                playCount: UInt32(max(0, library?.playCount(for: song.id) ?? 0)),
                playlistCount: playlistCounts[song.id] ?? 0,
                hasArtwork: song.artworkCacheKey != nil,
                hasLyrics: false,
                protected: song.id == current || queued.contains(song.id),
                removable: song.persistentID == nil && path != nil
            )
        }
    }

    // MARK: Groups

    func song(_ id: String) -> Song? {
        LibraryManager.shared?.allSongs.first { $0.id == id }
    }

    /// The listener picked another copy to keep.
    func chooseKeeper(_ group: DupeGroup, keeperID: String) {
        let updated = dupeChooseKeeper(group: group, keeperId: keeperID)
        replace(updated)
    }

    /// "These aren't duplicates": never grouped again.
    func ignore(_ group: DupeGroup) {
        dupeIgnore(songIds: group.copies.map(\.id))
        drop(group.id)
    }

    /// Clean up one group: removed copies go to Recently Deleted, their
    /// favorites and playlist places move to the kept copy.
    @discardableResult
    func resolve(_ group: DupeGroup) -> Bool {
        guard let library = LibraryManager.shared, !group.removeIds.isEmpty else { return false }
        guard library.resolveDuplicates(keeperID: group.keeperId, removeIDs: group.removeIds) != nil else {
            ToastCenter.shared.show("Couldn't move the extra copies to Recently Deleted", category: .warning)
            return false
        }
        drop(group.id)
        journal = dupeJournal()
        return true
    }

    /// Groups "Clean up all" would touch: strong evidence, nothing to warn about.
    var safeGroups: [DupeGroup] { groups.filter(\.autoSafe) }

    /// Cleans every safe group; returns (groups resolved, bytes moved).
    @discardableResult
    func resolveAllSafe() -> (Int, UInt64) {
        var done = 0
        var bytes: UInt64 = 0
        for g in safeGroups where resolve(g) {
            done += 1
            bytes += g.reclaimBytes
        }
        if done > 0 {
            ToastCenter.shared.show("Cleaned \(done) duplicate group\(done == 1 ? "" : "s") — undo any time in Clean-up History", category: .success)
        }
        return (done, bytes)
    }

    /// Put a clean-up back: restores the copies and their playlist places.
    func undo(_ resolution: DupeResolution) {
        guard let library = LibraryManager.shared else { return }
        let restored = library.undoDuplicateResolution(resolution)
        journal = dupeJournal()
        ToastCenter.shared.show(restored > 0 ? "Restored \(restored) cop\(restored == 1 ? "y" : "ies")" : "Those copies are no longer in Recently Deleted",
                                category: restored > 0 ? .success : .warning)
    }

    private func replace(_ g: DupeGroup) {
        if let i = groups.firstIndex(where: { $0.id == g.id }) { groups[i] = g }
    }

    private func drop(_ id: String) {
        groups.removeAll { $0.id == id }
    }
}

/// Bridges engine progress callbacks (worker thread) to the main actor,
/// throttled to ~10 updates a second.
final class DupeProgressRelay: DupeProgress, @unchecked Sendable {
    private let onUpdate: @MainActor (String, UInt32, UInt32) -> Void
    private var last: CFAbsoluteTime = 0
    private let lock = NSLock()

    init(_ onUpdate: @escaping @MainActor (String, UInt32, UInt32) -> Void) {
        self.onUpdate = onUpdate
    }

    func onProgress(phase: String, done: UInt32, total: UInt32) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let due = now - last > 0.1 || done == 0 || done >= total
        if due { last = now }
        lock.unlock()
        guard due else { return }
        Task { @MainActor [onUpdate] in onUpdate(phase, done, total) }
    }
}

extension DupeKind {
    var label: String {
        switch self {
        case .exactFile: return "Identical files"
        case .sameSource: return "Same source"
        case .sameRecording: return "Same recording"
        case .likelySame: return "Likely the same"
        }
    }

    var symbol: String {
        switch self {
        case .exactFile: return "equal.square.fill"
        case .sameSource: return "link"
        case .sameRecording: return "waveform"
        case .likelySame: return "text.magnifyingglass"
        }
    }
}
