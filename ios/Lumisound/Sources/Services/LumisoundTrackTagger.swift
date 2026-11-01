import Foundation

/// Track identity tag stored in the file's `com.lumisound.trackdata` xattr —
/// read/written by the Rust core (sealed with the track vault).
enum LumisoundTrackTagger {
    @discardableResult
    static func tag(fileURL: URL, trackID: String, sourceURL: String) -> Bool {
        let ok = trackTag(path: fileURL.path, trackId: trackID, sourceUrl: sourceURL)
        if !ok {
            appWarn("LumisoundTrackTagger: xattr write failed for \(fileURL.lastPathComponent)", category: "background")
        }
        return ok
    }

    static func readTag(fileURL: URL) -> LumisoundTrackVault.Payload? {
        trackReadTag(path: fileURL.path).map { LumisoundTrackVault.Payload(v: Int($0.v), trackID: $0.trackId, sourceURL: $0.sourceUrl) }
    }

    static func isTagged(fileURL: URL) -> Bool {
        trackIsTagged(path: fileURL.path)
    }

    static func needsTagging(fileURL: URL, expectedTrackID: String) -> Bool {
        readTag(fileURL: fileURL)?.trackID != expectedTrackID
    }
}
