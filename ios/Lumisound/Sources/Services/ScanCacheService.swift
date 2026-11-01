import Foundation

/// Persists `(mtime, fileSize) → Song` mappings on disk so repeated library scans
/// skip AVURLAsset metadata extraction for unchanged files.
/// Must be accessed on @MainActor (mirrors LibraryManager's actor isolation).
@MainActor
final class ScanCacheService {
    static let shared = ScanCacheService()

    struct FileStamp: Hashable {
        let mtime: TimeInterval
        let size: Int64
    }

    private let cacheURL: URL
    private var docsPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL.path ?? ""
    }

    /// The cache itself (same on-disk layout as before) lives in the Rust
    /// core, which also stats files and decides hits; Songs cross as JSON.
    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheURL = caches.appendingPathComponent("library_scan_cache_v4.json")
        scanCacheOpen(cachePath: cacheURL.path)
    }

    nonisolated static func fileStamp(for url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              let mdate = attrs[.modificationDate] as? Date
        else { return nil }
        return FileStamp(mtime: mdate.timeIntervalSince1970, size: size)
    }

    nonisolated static func documentsRelativePath(for url: URL) -> String? {
        guard url.isFileURL,
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        let docsPath = docs.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(docsPath) else { return nil }
        return String(filePath.dropFirst(docsPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated static func stableKey(for url: URL) -> String {
        Self.documentsRelativePath(for: url) ?? url.standardizedFileURL.path
    }

    /// Splits files into cached Songs (unchanged since cached) and URLs that
    /// need a fresh read — one core call for the whole batch.
    nonisolated static func partition(_ urls: [URL]) -> (cached: [Song], uncached: [URL]) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL.path ?? ""
        let p = scanCachePartition(paths: urls.map { $0.standardizedFileURL.path }, documentsDir: docs)
        let songs = (try? JSONDecoder().decode([Song].self, from: p.cachedSongsJson)) ?? []
        return (songs, p.uncachedPaths.map { URL(fileURLWithPath: $0) })
    }

    func store(song: Song, for url: URL, stamp: FileStamp) {
        guard let data = try? JSONEncoder().encode(song) else { return }
        scanCacheStore(path: url.standardizedFileURL.path, documentsDir: docsPath, songJson: data)
    }

    func persist() {
        Task.detached(priority: .utility) { scanCachePersist() }
    }

    func evictMissing() {
        scanCacheEvictMissing(documentsDir: docsPath)
    }
}
