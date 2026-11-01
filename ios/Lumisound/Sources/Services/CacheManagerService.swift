import Foundation

// MARK: - CacheManagerService

@MainActor
final class CacheManagerService: ObservableObject {

    // MARK: Published

    @Published private(set) var artworkCacheSize:  Int64 = 0
    @Published private(set) var artworkCacheCount: Int   = 0
    @Published private(set) var tempFilesSize:     Int64 = 0
    @Published private(set) var downloadedMusicSize: Int64 = 0
    @Published private(set) var artistImageCacheSize:  Int64 = 0
    @Published private(set) var artistImageCacheCount: Int   = 0
    @Published private(set) var transcodeCacheSize: Int64 = 0
    @Published private(set) var isScanning: Bool = false

    /// Files physically present in Imported Music that no current `Song` in
    /// the library references — leftovers from a deletion that didn't clean
    /// up its file, or files dropped in via the Files app that were never
    /// indexed. Populated by `scanOrphans(knownFilenames:)`, not the regular
    /// `scan()`, since it needs the live library's filenames to compare
    /// against and `CacheManagerService` otherwise has no `LibraryManager`
    /// dependency.
    @Published private(set) var orphanedFiles: [URL] = []
    @Published private(set) var orphanedFilesSize: Int64 = 0
    @Published private(set) var isScanningOrphans: Bool = false

    // MARK: Private

    private var lastScanDate: Date?

    /// URL of the ArtworkService disk cache folder.
    /// Mirrors the path computed in `ArtworkService.init`.
    private var artworkCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    /// Documents/Imported Music directory used by `DocumentImportService`.
    private var importedMusicURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Imported Music", isDirectory: true)
    }

    /// Mirrors the path computed in `ArtistImageService.init`.
    private var artistImageCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ArtistImages", isDirectory: true)
    }

    /// Mirrors the path computed in `AudioEncoderService.init`.
    private var transcodeCacheURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lumisound_transcode", isDirectory: true)
    }

    // MARK: - Public API

    /// Triggers a fresh scan if no scan has been run in the last 5 minutes.
    func scanOnAppear() {
        if let last = lastScanDate, Date().timeIntervalSince(last) < 300 { return }
        Task { await scan() }
    }

    /// Scans all cache locations and refreshes published size properties
    /// (size walks run in the Rust core, off the main actor).
    func scan() async {
        isScanning = true
        defer { isScanning = false }
        let (art, music, artist, transcode) = (artworkCacheURL?.path, importedMusicURL?.path,
                                               artistImageCacheURL?.path, transcodeCacheURL.path)
        let tmp = FileManager.default.temporaryDirectory.path
        let stats = await Task.detached(priority: .background) {
            (art.map { cacheDirStats(dir: $0) } ?? DirStats(files: 0, bytes: 0),
             cachePrefixedStats(dir: tmp, prefix: "dl_"),
             music.map { cacheDirStats(dir: $0) } ?? DirStats(files: 0, bytes: 0),
             artist.map { cacheDirStats(dir: $0) } ?? DirStats(files: 0, bytes: 0),
             cacheDirStats(dir: transcode))
        }.value
        artworkCacheCount     = Int(stats.0.files)
        artworkCacheSize      = Int64(stats.0.bytes)
        tempFilesSize         = Int64(stats.1.bytes)
        downloadedMusicSize   = Int64(stats.2.bytes)
        artistImageCacheCount = Int(stats.3.files)
        artistImageCacheSize  = Int64(stats.3.bytes)
        transcodeCacheSize    = Int64(stats.4.bytes)
        lastScanDate          = Date()
    }

    // MARK: - Clear Operations

    /// Clears the artwork memory cache and removes all files from the disk cache directory.
    func clearArtworkCache() {
        ArtworkService.shared.clearCache()
        if let url = artworkCacheURL {
            removeContents(of: url)
        }
        artworkCacheSize  = 0
        artworkCacheCount = 0
    }

    /// Clears the artwork cache and temp download files together. Does not
    /// touch imported music — that's the user's actual library.
    func clearAll() {
        clearArtworkCache()
        clearTempFiles()
        clearArtistImageCache()
        clearTranscodeCache()
    }

    /// Clears the artist-photo memory cache and removes all files from its disk cache directory.
    func clearArtistImageCache() {
        ArtistImageService.shared.clearCache()
        if let url = artistImageCacheURL {
            removeContents(of: url)
        }
        artistImageCacheSize  = 0
        artistImageCacheCount = 0
    }

    /// Deletes leftover audio-transcode work files. Safe any time playback
    /// isn't actively mid-transcode — a fresh file is written the next time
    /// one's needed.
    func clearTranscodeCache() {
        removeContents(of: transcodeCacheURL)
        transcodeCacheSize = 0
    }

    /// Compares files physically present in Imported Music against
    /// `knownFilenames` (the current library's referenced filenames) and
    /// records any that aren't referenced by anything — leftovers from a
    /// deletion that didn't clean up its file, or files dropped in via the
    /// Files app that were never indexed into the library.
    func scanOrphans(knownFilenames: Set<String>) async {
        isScanningOrphans = true
        defer { isScanningOrphans = false }
        guard let musicDir = importedMusicURL?.path else { return }
        let known = Array(knownFilenames)
        let scan = await Task.detached(priority: .background) {
            cacheFindOrphans(musicDir: musicDir, knownFilenames: known)
        }.value
        orphanedFiles = scan.paths.map { URL(fileURLWithPath: $0) }
        orphanedFilesSize = Int64(scan.bytes)
    }

    /// Deletes every file currently recorded in `orphanedFiles`.
    func deleteOrphanedFiles() {
        _ = cacheRemovePaths(paths: orphanedFiles.map(\.path))
        orphanedFiles = []
        orphanedFilesSize = 0
    }

    /// Deletes all `dl_*` temporary directories inside `FileManager.temporaryDirectory`.
    func clearTempFiles() {
        cacheRemovePrefixed(dir: FileManager.default.temporaryDirectory.path, prefix: "dl_")
        tempFilesSize = 0
    }

    // MARK: - Private Helpers

    /// Removes all contents inside `url` without removing the directory itself.
    nonisolated func removeContents(of url: URL) {
        cacheClearContents(dir: url.path)
    }
}

// MARK: - Formatting Helpers

extension CacheManagerService {

    /// Human-readable byte string (e.g. "12.4 MB").
    static func formattedSize(_ bytes: Int64) -> String {
        formatBytes(bytes: UInt64(max(0, bytes)))
    }
}
