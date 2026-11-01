import AVFoundation
import Foundation
import UIKit

// MARK: - LumisoundExclusiveExtensionService
//
// Finishes the "this track belongs to Lumisound" pipeline started by
// LumisoundTrackVault/LumisoundTrackTagger (the encrypted xattr metadata):
// locks an already-downloaded, already-vault-tagged track's bytes (see
// `LumisoundLockFormat`) and appends a Lumisound-exclusive marker
// extension on top of the real one — no re-encode, no format change.
//
// The marker is appended as an OUTER extension on top of the real one
// (e.g. "Song.opus" -> "Song.opus.lms"), not stripped/renamed away:
//   - `url.pathExtension` is genuinely ".lms" — no other app, share sheet,
//     or file browser has any type association for it, which is the whole
//     point ("exclusive").
//   - The REAL (post-re-encode) container format is still recoverable in
//     O(1), no file I/O, by unwrapping one more path-extension level
//     (`effectiveExtension` below). Every place in this codebase that
//     branches on file extension to make a format-dependent decision
//     (playback routing for opus/webm/ogg, the lossless/format-tag badges,
//     Vorbis-comment parsing, video frame artwork extraction, the
//     corruption scanner's/library scan's "is this an audio file" gate)
//     calls `effectiveExtension(for:)` instead of raw `pathExtension` — see
//     git history for the full list.
//
// `convert` used to unconditionally re-encode every track to AAC .m4a
// before locking it — so every converted track played back via
// AVAudioFile's native Tier 1 path instead of needing the opus/webm
// compatibility fallback on every play. That silently overrode a user's
// preferred download format (opus/flac/mp3 all ended up as .m4a.lms on
// disk regardless of Settings) since essentially every track gets swept
// into this pass eventually. Fixed: the lock now wraps the ORIGINAL
// downloaded bytes as-is (see `convert` below) — the outer `.lms` marker
// is appended on top of whatever the real extension already is (e.g.
// "Song.opus" -> "Song.opus.lms"), so the on-disk format matches what the
// user actually asked for. Playback still works for every format because
// every route that plays a `.lms` file already dispatches on
// `effectiveExtension(for:)` (opus/webm compatibility fallback included),
// not a hardcoded assumption of AAC.
//
// The marker extension alone used to be the ONLY thing making a `.lms` file
// exclusive — a copy with the marker stripped off was still a perfectly
// standard, decodable file to any player. It no longer is: the original
// bytes are additionally masked by `LumisoundLockFormat` before being
// written to the `.lms` path, so what's actually on disk isn't a valid
// audio container to ANY framework — including this app's own — until
// explicitly unlocked back to a real file right before playback
// (`playableURL(for:)` below). A stripped/renamed-back copy on another
// device genuinely will not play.
enum LumisoundExclusiveExtensionService {
    static let marker = "lms"

    /// The extension callers should reason about for any FORMAT decision —
    /// unwraps the Lumisound marker to recover the real container extension
    /// underneath it; returns the plain extension unchanged for anything not
    /// yet converted.
    static func effectiveExtension(for url: URL) -> String {
        lmsEffectiveExtension(path: url.path)
    }

    static func isConverted(_ url: URL) -> Bool {
        lmsIsConverted(path: url.path)
    }

    /// A URL safe to hand directly to `AVAudioFile(forReading:)` /
    /// `AVPlayerItem(url:)` — returns `url` unchanged for anything not
    /// `.lms`-marked, otherwise a real, directly-playable temp copy with
    /// `LumisoundLockFormat`'s mask reversed (see that type's header
    /// comment for what's actually locked and why: a `.lms` file's on-disk
    /// bytes are genuinely not a valid audio container to ANY framework,
    /// including this app's own AVFoundation calls, until unlocked).
    ///
    /// Cached at a stable path (keyed by the real filename, not a per-call
    /// temp name) so repeated plays of the same track don't re-unlock (and
    /// re-write a full copy of the file) every single time — reused as long
    /// as the cached copy is at least as new as the locked source, so a
    /// re-lock (re-conversion, or the legacy-file migration in
    /// `relockLegacyFile`) correctly invalidates it.
    /// Unlocked copies of `.lms` files live here (tmp; the OS may purge it).
    static var playableCacheDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lumisound_lms_playable", isDirectory: true)
    }

    /// Directly playable URL: the file itself, or a fresh unlocked copy from
    /// the cache (Rust core: one unlock per file at a time, reused while
    /// newer than the locked file, retried once, original URL on failure).
    static func playableURL(for url: URL) -> URL {
        guard isConverted(url) else { return url }
        let started = Date()
        let warm = hasWarmPlayableCache(for: url)
        let out = lmsPlayablePath(path: url.path, cacheDir: playableCacheDir.path)
        if out == url.path {
            appWarn("LumisoundExclusiveExtensionService.playableURL: unlock failed for \(url.lastPathComponent)", category: "audio")
        } else if !warm {
            appLog("LumisoundExclusiveExtensionService: cold unlock \(url.lastPathComponent) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s", category: "audio")
        }
        return URL(fileURLWithPath: out)
    }

    static func hasWarmPlayableCache(for url: URL) -> Bool {
        lmsHasWarmCache(path: url.path, cacheDir: playableCacheDir.path)
    }

    static func prewarmPlayableURL(for url: URL) async {
        guard isConverted(url), !hasWarmPlayableCache(for: url) else { return }
        _ = await Task.detached(priority: .utility) {
            playableURL(for: url)
        }.value
    }

    static func expectedConvertedURL(for url: URL) -> URL? {
        guard !isConverted(url) else { return nil }
        return url.appendingPathExtension(marker)
    }

    /// Caps how many `convert` calls do their actual lock work at once,
    /// GLOBALLY across every call site (fresh downloads via
    /// `finalizeAndLockDownload`, the background conversion pass, pending-
    /// download reconciliation) — independent of how many downloads the
    /// SERVER runs concurrently (`YTDLP_MAX_CONCURRENT`). Locking XORs the
    /// entire file (tens of MB for a lossless FLAC track) and then does a
    /// full unlock+decode round-trip to verify it — real, unpaced CPU/
    /// memory work on the phone. Each download pipeline already caps its
    /// OWN concurrent downloads, but that cap is per-pipeline: multiple
    /// tracked playlists (or auto-download + a manual "Download All")
    /// running at once each start their own independent pipeline, so
    /// raising server-side concurrency multiplied how many of these could
    /// all land and start locking on-device at the exact same moment —
    /// confirmed in the field as a direct contributor to crashes during
    /// heavy download bursts. This limiter is the single shared choke
    /// point that actually bounds that, regardless of how many pipelines
    /// are feeding it.
    private actor ConvertConcurrencyLimiter {
        private let limit = 2
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if active < limit {
                active += 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if !waiters.isEmpty {
                waiters.removeFirst().resume()
            } else {
                active -= 1
            }
        }
    }
    private static let convertLimiter = ConvertConcurrencyLimiter()

    /// Verify an already-present `.lms` destination and either adopt it
    /// (returns it) or delete it as a corrupt leftover (returns nil, meaning
    /// "re-lock from scratch"). Runs off-main: `unlock` XORs the whole file
    /// and the decode check reads it back, the same reason `convert`'s own
    /// lock work is pushed off the calling actor's executor.
    private static func adoptExistingLockedFile(at newURL: URL, plainURL: URL, startedAt: Date) async -> URL? {
        await Task.detached(priority: .utility) { () -> URL? in
            let fm = FileManager.default
            let verifyURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(plainURL.pathExtension)
            defer { try? fm.removeItem(at: verifyURL) }
            guard LumisoundLockFormat.unlock(lockedURL: newURL, to: verifyURL),
                  CorruptFileFinderService.isValidAudioFile(at: verifyURL) else {
                appWarn("LumisoundExclusiveExtensionService: existing \(newURL.lastPathComponent) failed round-trip verification after \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s — discarding it and re-locking", category: "background")
                try? fm.removeItem(at: newURL)
                return nil
            }
            appLog("LumisoundExclusiveExtensionService: adopted already-locked \(newURL.lastPathComponent) for \(plainURL.lastPathComponent) — no re-lock needed", category: "background")
            return newURL
        }.value
    }

    /// LOCKS `fileURL`'s existing bytes (see `LumisoundLockFormat`) as-is
    /// into `<original-name>.<original-ext>.lms` — no re-encode, so the
    /// user's actual downloaded format (opus/flac/mp3/m4a/whatever the
    /// preferred-format setting produced) is preserved on disk; only the
    /// outer marker extension changes. Verifies the locked file round-trips
    /// (unlocks correctly AND the unlocked result passes
    /// `CorruptFileFinderService.isValidAudioFile`) before removing
    /// `fileURL`, and never leaves a locked file behind that failed that
    /// check. Returns a locked, verified URL — or `nil` only when the lock/
    /// verify step genuinely FAILED (all logged, never thrown — this is
    /// always called from a best-effort background pass).
    ///
    /// "Already locked" is deliberately NOT a nil: `fileURL` already being
    /// `.lms`, or its `.lms` destination already existing and verifying, are
    /// both successful outcomes and return that locked URL. Returning nil for
    /// them made all three callers log a failure for a track that was
    /// correctly locked — in the field that was ~15 "synchronous lock failed
    /// after 0.00s" warnings per track (the 0.00s being the tell: nil came
    /// back before any work started) — and, worse, made
    /// `finalizeAndLockDownload` hand its caller the PLAIN file path while a
    /// perfectly good locked file sat right next to it, so the download was
    /// never recorded as locked and got retried again on the next pass.
    /// Extended attributes (the
    /// LumisoundTrackVault tag) are re-applied by the caller after this
    /// returns, since this produces a brand new inode rather than
    /// preserving the original's xattrs the way a rename would have.
    static func convert(fileURL: URL) async -> URL? {
        // Already a `.lms` file: nothing to do, nothing failed. Note
        // `expectedConvertedURL` returns nil for exactly this case too, so
        // handling it first means the guard below can only fail for a URL
        // that genuinely has no derivable destination.
        if isConverted(fileURL) { return fileURL }
        guard let newURL = expectedConvertedURL(for: fileURL) else { return nil }
        let fm = FileManager.default
        let startedAt = Date()

        await convertLimiter.acquire()
        defer { Task { await convertLimiter.release() } }

        // Destination already present. Re-checked AFTER taking the limiter,
        // not before: a sibling convert for the same track may have finished
        // while this call was queued behind the cap, which is precisely how
        // the duplicate-work case arises.
        //
        // Adopting it unverified would be a real hazard — an interrupted or
        // half-written lock from a previous run leaves a `.lms` of exactly
        // this name — so it gets the same unlock + decode round-trip a
        // freshly locked file does. Verified: adopt it. Corrupt: delete it
        // and fall through to lock afresh, which is strictly better than the
        // old behaviour of bailing and leaving the bad artifact in place
        // forever.
        if fm.fileExists(atPath: newURL.path) {
            if let adopted = await adoptExistingLockedFile(at: newURL, plainURL: fileURL, startedAt: startedAt) {
                return adopted
            }
        }

        // The actual lock/verify work below is synchronous CPU+I/O (XOR
        // over the WHOLE file — up to hundreds of MB for a lossless FLAC
        // track — plus a full unlock+AVAudioFile-decode round-trip to
        // verify it) with no `await` inside it, so it doesn't naturally
        // yield anywhere. `convert` itself carries no actor annotation,
        // but callers like `finalizeAndLockDownload` are on `StreamingService`
        // which IS `@MainActor` — a nonisolated async function called from
        // an actor-isolated context doesn't automatically hop off that
        // actor's executor for its synchronous stretches between
        // suspension points, so this was running ON THE MAIN THREAD,
        // blocking the entire UI for as long as the lock took. Confirmed
        // in the field: a session-ending freeze/crash landed right after a
        // 674MB FLAC lock in the log stream, with the classic "only a
        // Core-Animation-driven spinner keeps moving" symptom of a fully
        // blocked main thread. `Task.detached` forces genuine off-main
        // execution regardless of what actor called this.
        return await Task.detached(priority: .utility) {
            let beforeBytes = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int64 ?? -1
            appLog("LumisoundExclusiveExtensionService: locking \(fileURL.lastPathComponent) (\(beforeBytes) bytes, ext=\(fileURL.pathExtension.lowercased())) -> \(newURL.lastPathComponent)", category: "background")

            guard LumisoundLockFormat.lock(plainURL: fileURL, to: newURL) else {
                appWarn("LumisoundExclusiveExtensionService: lock failed for \(fileURL.lastPathComponent) after \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s", category: "background")
                return nil
            }
            let lockedBytes = (try? fm.attributesOfItem(atPath: newURL.path))?[.size] as? Int64 ?? -1

            // Verify the locked file actually round-trips before trusting it
            // with the original's removal — never delete on faith. Must keep
            // `fileURL`'s REAL extension (opus/flac/mp3/m4a/...), not a
            // hardcoded ".m4a" — AVAudioFile (which `isValidAudioFile` reads
            // through) selects its container parser from the file extension,
            // so verifying real opus/flac bytes under a fake ".m4a" name would
            // always misreport them as unreadable.
            let verifyURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileURL.pathExtension)
            defer { try? fm.removeItem(at: verifyURL) }
            guard LumisoundLockFormat.unlock(lockedURL: newURL, to: verifyURL),
                  CorruptFileFinderService.isValidAudioFile(at: verifyURL) else {
                appWarn("LumisoundExclusiveExtensionService: locked file failed round-trip verification for \(fileURL.lastPathComponent) after \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s — removing", category: "background")
                try? fm.removeItem(at: newURL)
                return nil
            }

            // Best-effort, but no longer SILENTLY best-effort: if this fails
            // (permissions, the file briefly busy, etc.), the old pre-conversion
            // file is left behind on disk alongside the new .lms one — the next
            // local documents scan used to re-import it as a brand new song,
            // permanently duplicating every track that hit this. That scan now
            // recognizes and cleans up exactly this leftover (see
            // performLocalDocumentsScan), so this failing is self-healing rather
            // than a permanent duplicate — but it's still worth knowing about.
            var originalRemoved = true
            do {
                try fm.removeItem(at: fileURL)
            } catch {
                originalRemoved = false
                appWarn("LumisoundExclusiveExtensionService: could not remove pre-conversion file \(fileURL.lastPathComponent) after successful convert: \(error.localizedDescription)", category: "background")
            }
            appLog("LumisoundExclusiveExtensionService: converted+locked \(newURL.lastPathComponent) — before=\(beforeBytes)B, locked=\(lockedBytes)B, verified=true, original-removed=\(originalRemoved), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s", category: "background")
            return newURL
        }.value
    }

    /// Migrates an already-`.lms`-marked file whose bytes are still a
    /// legacy plain (unlocked) m4a — i.e. `LumisoundLockFormat.isLocked(at:)`
    /// is `false` for it — into the real locked format, IN PLACE (same
    /// path, no re-keying of the LumisoundTrackVault xattr needed by the
    /// caller). Verifies round-trip before committing, exactly like
    /// `convert`, and never partially overwrites `url`: the lock is written
    /// to a temp file first and only swapped in via `replaceItemAt` once
    /// verified. Returns `false` (leaving `url` untouched) if `url` isn't
    /// `.lms`-marked, is already locked, or any step fails.
    static func relockLegacyFile(at url: URL) -> Bool {
        guard isConverted(url), !LumisoundLockFormat.isLocked(at: url) else { return false }
        let fm = FileManager.default
        let beforeBytes = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? -1

        let lockedTempURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("lms")
        defer { try? fm.removeItem(at: lockedTempURL) }
        guard LumisoundLockFormat.lock(plainURL: url, to: lockedTempURL) else {
            appWarn("LumisoundExclusiveExtensionService.relockLegacyFile: lock failed for \(url.lastPathComponent)", category: "background")
            return false
        }
        let lockedBytes = (try? fm.attributesOfItem(atPath: lockedTempURL.path))?[.size] as? Int64 ?? -1

        let verifyURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? fm.removeItem(at: verifyURL) }
        guard LumisoundLockFormat.unlock(lockedURL: lockedTempURL, to: verifyURL),
              CorruptFileFinderService.isValidAudioFile(at: verifyURL) else {
            appWarn("LumisoundExclusiveExtensionService.relockLegacyFile: round-trip verification failed for \(url.lastPathComponent)", category: "background")
            return false
        }

        do {
            _ = try fm.replaceItemAt(url, withItemAt: lockedTempURL)
            appLog("LumisoundExclusiveExtensionService.relockLegacyFile: migrated \(url.lastPathComponent) from legacy plain bytes to real lock — before=\(beforeBytes)B, locked=\(lockedBytes)B, verified=true", category: "background")
            return true
        } catch {
            appWarn("LumisoundExclusiveExtensionService.relockLegacyFile: replaceItemAt failed for \(url.lastPathComponent): \(error.localizedDescription)", category: "background")
            return false
        }
    }

    /// True if `fileURL` has a readable, embedded `LUMISOUND_ID`-style
    /// metadata item (the same case-insensitive substring check
    /// `DocumentImportService.refreshTags`/`makeSong` use to find it).
    /// Exists to detect files converted by the pre-fix version of
    /// `convert(fileURL:)`/`AudioEncoderService`, which re-encoded audio
    /// via `AVAssetExportSession`/`AVAssetWriter` without ever setting
    /// `.metadata` on the session/writer — silently dropping title/artist/
    /// album AND this tag from every converted file despite this very
    /// file's header promising it "MUST stay plaintext/ffprobe-readable".
    /// See `LumisoundTrackVaultService`'s one-time repair migration.
    static func hasEmbeddedSourceTag(fileURL: URL) async -> Bool {
        // Rust core (lofty) first; AVFoundation reads older mdta-keyed tags.
        if tagsReadLumisound(path: playableURL(for: fileURL).path).sourceTrackId != nil { return true }
        let asset = AVURLAsset(url: playableURL(for: fileURL))
        guard let items = try? await asset.load(.metadata) else { return false }
        return items.contains { item in
            let idRaw = item.identifier?.rawValue.lowercased() ?? ""
            let keyRaw = (item.key as? String)?.lowercased() ?? ""
            return idRaw.contains("lumisound_id") || keyRaw.contains("lumisound_id")
        }
    }

    /// Reads the actual VALUE of the embedded `LUMISOUND_ID` tag (not just
    /// whether it's present, like `hasEmbeddedSourceTag`) — the same tag
    /// `AudioTagWriter`/the server-side ffmpeg pass embed directly into the
    /// audio container, independent of `LumisoundTrackTagger`'s encrypted
    /// xattr. The xattr and this embedded tag are normally redundant (both
    /// written at download/lock time), but the xattr alone doesn't survive
    /// every path a file can take out of and back into the sandbox — an
    /// AirDrop, an iCloud Drive round-trip, or a Files app export/reimport
    /// all preserve the file's bytes (and therefore this embedded tag) while
    /// silently dropping its extended attributes. `DuplicateFinderService`
    /// uses this as a third fallback, after `Song.sourceTrackID` and the
    /// xattr vault tag, specifically for that case: a re-imported copy whose
    /// xattr is gone but whose embedded identity tag isn't.
    static func embeddedSourceTrackID(fileURL: URL) async -> String? {
        if let id = tagsReadLumisound(path: playableURL(for: fileURL).path).sourceTrackId, !id.isEmpty { return id }
        let asset = AVURLAsset(url: playableURL(for: fileURL))
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items {
            let idRaw = item.identifier?.rawValue.lowercased() ?? ""
            let keyRaw = (item.key as? String)?.lowercased() ?? ""
            guard idRaw.contains("lumisound_id") || keyRaw.contains("lumisound_id") else { continue }
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Same shape as `hasEmbeddedSourceTag`, for `LUMISOUND_THUMBNAIL` —
    /// used by `LumisoundTrackVaultService`'s repair migration to catch
    /// tracks that already have their ID/title/artist repaired but predate
    /// `AudioTagWriter` embedding a thumbnail tag (a separate, later fix —
    /// see that type's own header comment), so those tracks get a second
    /// repair pass instead of staying permanently missing artwork despite
    /// `hasEmbeddedSourceTag` alone now reporting `true` for them.
    static func hasEmbeddedThumbnailTag(fileURL: URL) async -> Bool {
        if tagsReadLumisound(path: playableURL(for: fileURL).path).thumbnailUrl != nil { return true }
        let asset = AVURLAsset(url: playableURL(for: fileURL))
        guard let items = try? await asset.load(.metadata) else { return false }
        return items.contains { item in
            let idRaw = item.identifier?.rawValue.lowercased() ?? ""
            let keyRaw = (item.key as? String)?.lowercased() ?? ""
            return idRaw.contains("lumisound_thumbnail") || keyRaw.contains("lumisound_thumbnail")
        }
    }

    /// Reads the actual embedded artwork bytes (as JPEG) from a locked
    /// track's unlocked-on-device view — the only source of real cloud
    /// artwork for a `.lms` upload, since the server's own extraction
    /// (`ffmpeg` in `/user/music/artwork`) can't decode XOR-masked bytes any
    /// more than ffprobe/loudness analysis can elsewhere in the pipeline.
    /// Called right after a successful locked upload whose
    /// `hasEmbeddedThumbnailTag` was true — see
    /// `StreamingService.uploadTrack`/`backUpLibraryIfNeeded`. Checks both
    /// `commonMetadata` and the full metadata item list (same two-pass
    /// approach `ArtworkService.fetchAssetArtwork` uses locally) since
    /// artwork surfaces under different keys depending on container/tagger.
    static func embeddedThumbnailJPEGData(fileURL: URL) async -> Data? {
        let asset = AVURLAsset(url: playableURL(for: fileURL))

        if let commonMetadata = try? await asset.load(.commonMetadata) {
            for item in commonMetadata where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), let jpeg = Self.jpegData(from: data) { return jpeg }
            }
        }
        if let allMeta = try? await asset.load(.metadata) {
            for item in allMeta {
                let idRaw = item.identifier?.rawValue.lowercased() ?? ""
                let keyRaw = (item.key as? String)?.lowercased() ?? ""
                guard idRaw.contains("lumisound_thumbnail") || keyRaw.contains("lumisound_thumbnail")
                    || idRaw.contains("artwork") || idRaw.contains("covr") || idRaw.contains("apic") else { continue }
                if let data = try? await item.load(.dataValue), let jpeg = Self.jpegData(from: data) { return jpeg }
            }
        }
        return nil
    }

    /// Re-encodes whatever image bytes were actually embedded (often PNG)
    /// to JPEG, matching what `/user/music/artwork-upload` and the server's
    /// own ffmpeg-extraction fallback both always serve.
    private static func jpegData(from raw: Data) -> Data? {
        guard raw.count > 500, let image = UIImage(data: raw) else { return nil }
        return image.jpegData(compressionQuality: 0.85)
    }
}
