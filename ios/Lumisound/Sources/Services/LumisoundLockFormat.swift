import Foundation

// MARK: - LumisoundLockFormat
//
// The `.lms` lock (8-byte `LMSLOCK1` header + XOR-masked audio) lives in the
// Rust core (rust/media/src/lock.rs, shared with the bridge). Format lock-in,
// not DRM: the bytes are not a decodable container until unlocked. Lock and
// unlock stream in 1 MiB blocks and write atomically, so large lossless
// tracks no longer have to fit in memory.
enum LumisoundLockFormat {
    static func isLocked(at url: URL) -> Bool {
        lmsIsLocked(path: url.path)
    }

    /// Writes a locked copy of `plainURL` to `lockedURL`; never touches the source.
    static func lock(plainURL: URL, to lockedURL: URL) -> Bool {
        lmsLock(plainPath: plainURL.path, lockedPath: lockedURL.path)
    }

    /// Writes playable bytes to `outURL` (legacy un-masked `.lms` passes through).
    static func unlock(lockedURL: URL, to outURL: URL) -> Bool {
        let ok = lmsUnlock(lockedPath: lockedURL.path, outPath: outURL.path)
        if !ok {
            appWarn("LumisoundLockFormat.unlock: failed for \(lockedURL.lastPathComponent) -> \(outURL.path)", category: "audio")
        }
        return ok
    }
}
