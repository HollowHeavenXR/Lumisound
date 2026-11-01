import Foundation

struct PlayHistoryEntry: Codable {
    var playCount: Int = 0
    var lastPlayedAt: Date?
}

/// Per-song play counts / last-played dates. Stored and merged by the Rust
/// core (rust/core/src/stores.rs); `entries` is a read cache for views.
@MainActor
final class PlayHistoryStore {
    static let shared = PlayHistoryStore()
    private(set) var entries: [String: PlayHistoryEntry] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: "playHistory.v1") {
            playHistoryImportLegacy(json: data)
        }
        reload()
    }

    private func reload() {
        var m: [String: PlayHistoryEntry] = [:]
        for r in playHistoryAll() {
            m[r.songId] = PlayHistoryEntry(playCount: Int(r.playCount), lastPlayedAt: r.lastPlayedAt.map { Date(timeIntervalSince1970: $0) })
        }
        entries = m
    }

    func recordPlay(songID: String) {
        guard let r = Lumisound.playHistoryRecord(songId: songID) else { return }
        entries[songID] = PlayHistoryEntry(playCount: Int(r.playCount), lastPlayedAt: r.lastPlayedAt.map { Date(timeIntervalSince1970: $0) })
    }

    func playCount(for songID: String) -> Int { entries[songID]?.playCount ?? 0 }

    func lastPlayedAt(for songID: String) -> Date? { entries[songID]?.lastPlayedAt }

    func mergeFromSync(_ remote: [String: PlayHistoryEntry]) {
        let records = remote.map { PlayHistoryRecord(songId: $0.key, playCount: Int64($0.value.playCount), lastPlayedAt: $0.value.lastPlayedAt?.timeIntervalSince1970) }
        if playHistoryMerge(remote: records) { reload() }
    }

    func rekey(from oldID: String, to newID: String) {
        playHistoryRekey(oldId: oldID, newId: newID)
        if let e = entries.removeValue(forKey: oldID), oldID != newID { entries[newID] = e }
    }

    func pruneEntries(keeping validIDs: Set<String>) {
        playHistoryPrune(validIds: Array(validIDs))
        entries = entries.filter { validIDs.contains($0.key) }
    }
}
