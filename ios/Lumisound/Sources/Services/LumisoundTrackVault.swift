import Foundation

// The track vault (AES-GCM sealed `{trackID, sourceURL}`) is implemented in
// the Rust core (rust/core/src/lock.rs) and reads blobs written by the older
// CryptoKit implementation unchanged.
enum LumisoundTrackVault {
    struct Payload: Codable {
        var v: Int = 1
        var trackID: String
        var sourceURL: String
    }
}
