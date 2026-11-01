import Foundation

/// Deleted songs are moved into Documents/.RecentlyDeleted for 30 days and
/// can be restored to "Imported Music". File moves, bookkeeping and expiry
/// run in the Rust core; this keeps the published list and the
/// security-scoped access the original file may need.
@MainActor
final class RecentlyDeletedService: ObservableObject {
    static weak var shared: RecentlyDeletedService?

    struct Entry: Codable, Identifiable {
        let id: String
        var song: Song
        var trashFilename: String
        var deletedAt: Date
    }

    @Published private(set) var entries: [Entry] = []
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private var docs: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }
    private var trashDir: String? { docs?.appendingPathComponent(".RecentlyDeleted", isDirectory: true).path }

    init() {
        if let data = UserDefaults.standard.data(forKey: "recently_deleted_entries_v1") {
            deletedSongsImportLegacy(json: data)
        }
        reload()
        Self.shared = self
    }

    private func reload() {
        entries = deletedSongs().compactMap { e in
            guard let data = e.songJson.data(using: .utf8), let song = try? JSONDecoder().decode(Song.self, from: data) else { return nil }
            return Entry(id: e.id, song: song, trashFilename: e.trashFilename, deletedAt: Date(timeIntervalSince1970: e.deletedAt))
        }
    }

    @discardableResult
    func trash(song: Song) -> Bool {
        guard let url = song.url, let trashDir,
              let data = try? JSONEncoder().encode(song), let json = String(data: data, encoding: .utf8) else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard deletedSongTrash(songId: song.id, songJson: json, srcPath: url.path, trashDir: trashDir) else {
            appWarn("RecentlyDeletedService.trash: move failed for \(url.path)", category: "library")
            return false
        }
        reload()
        return true
    }

    func restore(entryID: String) -> Song? {
        guard let trashDir, let docs else { return nil }
        let original = entries.first { $0.id == entryID }?.song.url?.lastPathComponent
        guard let r = deletedSongRestore(entryId: entryID, trashDir: trashDir,
                                         restoreDir: docs.appendingPathComponent("Imported Music", isDirectory: true).path,
                                         originalName: original),
              let data = r.songJson.data(using: .utf8), var song = try? JSONDecoder().decode(Song.self, from: data)
        else { reload(); return nil }
        song.url = URL(fileURLWithPath: r.path)
        reload()
        return song
    }

    func restoreAll() -> [Song] {
        entries.map(\.id).compactMap { restore(entryID: $0) }
    }

    func purge(entryID: String) {
        guard let trashDir else { return }
        deletedSongPurge(entryId: entryID, trashDir: trashDir)
        reload()
    }

    func purgeAll() {
        guard let trashDir else { return }
        deletedSongsPurgeAll(trashDir: trashDir)
        reload()
    }

    func purgeExpired() {
        guard let trashDir else { return }
        if deletedSongsPurgeExpired(trashDir: trashDir) > 0 { reload() }
    }
}
