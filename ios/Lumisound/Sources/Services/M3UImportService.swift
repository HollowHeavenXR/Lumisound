import Foundation

/// M3U/M3U8 playlist import: parsing and matching run in the Rust core.
enum M3UImportService {
    struct ImportResult {
        let matchedSongIDs: [String]
        let totalEntries: Int
    }

    @MainActor
    static func `import`(fileURL: URL, library: LibraryManager) -> ImportResult {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: fileURL) else { return ImportResult(matchedSongIDs: [], totalEntries: 0) }
        let candidates = library.allSongs.map {
            M3uCandidate(id: $0.id, filename: $0.url?.lastPathComponent, displayName: $0.displayName, artistName: $0.artistName)
        }
        let r = m3uMatch(data: data, library: candidates)
        return ImportResult(matchedSongIDs: r.matchedSongIds, totalEntries: Int(r.totalEntries))
    }
}
