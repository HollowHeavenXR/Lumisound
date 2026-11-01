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

    enum VaultError: Error {
        case encodingFailed
        case invalidCiphertext
    }

    static func encrypt(trackID: String, sourceURL: String) throws -> String {
        guard let blob = vaultEncrypt(trackId: trackID, sourceUrl: sourceURL) else { throw VaultError.encodingFailed }
        return blob
    }

    static func decrypt(_ base64: String) -> Payload? {
        vaultDecrypt(blob: base64).map { Payload(v: Int($0.v), trackID: $0.trackId, sourceURL: $0.sourceUrl) }
    }
}
