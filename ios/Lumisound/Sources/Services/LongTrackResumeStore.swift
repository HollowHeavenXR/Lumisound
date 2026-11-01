import Foundation

struct LongTrackResumePoint: Codable {
    var position: TimeInterval
    var updatedAt: Date
}

/// Resume points for tracks ≥ 20 minutes; rules + storage in the Rust core.
@MainActor
final class LongTrackResumeStore {
    static let shared = LongTrackResumeStore()
    static let minimumDuration: TimeInterval = 20 * 60
    static let nearEndMargin: TimeInterval = 30

    private init() {
        if let data = UserDefaults.standard.data(forKey: "longTrackResumePoints.v1") {
            longResumeImportLegacy(json: data)
        }
    }

    func resumePosition(for song: Song) -> TimeInterval? {
        longResumePosition(songId: song.id, duration: song.duration)
    }

    func recordPosition(_ position: TimeInterval, for song: Song) {
        longResumeRecord(songId: song.id, duration: song.duration, position: position)
    }

    func clear(for songID: Song.ID) {
        longResumeClear(songId: songID)
    }
}
