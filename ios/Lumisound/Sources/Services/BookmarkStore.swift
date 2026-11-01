import Foundation

struct TrackBookmark: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var timestamp: TimeInterval
    var label: String
    var createdAt: Date = Date()
}

/// Timestamp bookmarks per song, stored and merged by the Rust core.
@MainActor
final class BookmarkStore {
    static let shared = BookmarkStore()
    private(set) var bookmarksBySong: [String: [TrackBookmark]] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: "trackBookmarks.v1") {
            bookmarksImportLegacy(json: data)
        }
        reload()
    }

    private func reload() {
        var m: [String: [TrackBookmark]] = [:]
        for b in bookmarksAll() {
            m[b.songId, default: []].append(TrackBookmark(id: b.id, timestamp: b.timestamp, label: b.label,
                                                          createdAt: Date(timeIntervalSince1970: b.createdAt)))
        }
        bookmarksBySong = m
    }

    func bookmarks(for songID: String) -> [TrackBookmark] {
        (bookmarksBySong[songID] ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    @discardableResult
    func addBookmark(songID: String, timestamp: TimeInterval, label: String) -> TrackBookmark {
        let r = bookmarkAdd(songId: songID, timestamp: timestamp, label: label)
        let b = TrackBookmark(id: r.id, timestamp: r.timestamp, label: r.label, createdAt: Date(timeIntervalSince1970: r.createdAt))
        bookmarksBySong[songID, default: []].append(b)
        return b
    }

    func removeBookmark(songID: String, bookmarkID: String) {
        bookmarkRemove(songId: songID, bookmarkId: bookmarkID)
        bookmarksBySong[songID]?.removeAll { $0.id == bookmarkID }
        if bookmarksBySong[songID]?.isEmpty == true { bookmarksBySong.removeValue(forKey: songID) }
    }

    func mergeFromSync(_ remote: [String: [TrackBookmark]]) {
        let records = remote.flatMap { song, list in
            list.map { BookmarkRecord(songId: song, id: $0.id, timestamp: $0.timestamp, label: $0.label, createdAt: $0.createdAt.timeIntervalSince1970) }
        }
        if bookmarksMerge(remote: records) { reload() }
    }
}
