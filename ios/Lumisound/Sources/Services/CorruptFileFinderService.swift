import AVFoundation
import Foundation
import UIKit

// MARK: - CorruptFileFinderService

@MainActor
final class CorruptFileFinderService: ObservableObject {

    // MARK: Singleton

    static let shared = CorruptFileFinderService()
    private init() {}

    // MARK: Published State

    @Published private(set) var isScanning = false
    @Published private(set) var corruptFiles: [CorruptFileEntry] = []
    @Published private(set) var lastScanDate: Date? = {
        let ts = UserDefaults.standard.double(forKey: "corruptFinder_lastScanTimestamp")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }()

    private var periodicTimer: Timer?
    private static let periodicScanInterval: TimeInterval = 60 * 60

    // MARK: - Scan

    /// Whether a successful scan should auto-trash whatever it finds instead
    /// of just listing it for manual review — see `autoDeleteEnabled`.
    @Published var autoDeleteEnabled: Bool = UserDefaults.standard.object(forKey: "corruptFinder_autoDelete") == nil
        ? true // default on, per product decision: Aria should keep the library clean without being asked
        : UserDefaults.standard.bool(forKey: "corruptFinder_autoDelete") {
        didSet { UserDefaults.standard.set(autoDeleteEnabled, forKey: "corruptFinder_autoDelete") }
    }

    /// Scans all audio files inside `directory` for corruption.
    /// Tries to open each file with AVAudioFile; also checks minimum file size
    /// (1 KB) and that the file extension is a recognised audio type.
    ///
    /// A file that passed validation on a previous scan and hasn't changed
    /// since (same `ValidatedFileCache.FileStamp`) is skipped rather than
    /// re-opened/re-decoded — without this, the periodic scan
    /// (`startPeriodicScanning`, every hour for the life of the app) redid
    /// a full `AVAudioFile` open + tail-read of EVERY audio file in
    /// Documents on every tick, forever, regardless of whether anything had
    /// actually changed. At a few thousand songs that's real, recurring
    /// CPU/disk work competing with playback and downloads — same class of
    /// fix as `ScanCacheService` uses for the main library scan.
    func runScan(in directory: URL) async {
        guard !isScanning else { return }
        isScanning = true
        corruptFiles = []

        // The library's own tagged/scanned duration for each URL — sourced
        // from the same metadata layer `sourceTrackID`/vault-tag dedup uses
        // in DuplicateFinderService — lets the tail-read check below also
        // catch a file that's well-formed but truncated (e.g. a dropped
        // download that still produced a valid, readable, just much-shorter
        // file), which a bare "does AVAudioFile open it" check can't.
        var expectedDurations: [URL: TimeInterval] = [:]
        if let songs = LibraryManager.shared?.allSongs {
            for song in songs {
                guard let url = song.url, url.isFileURL, song.duration > 0 else { continue }
                expectedDurations[url] = song.duration
            }
        }

        let knownGood = ValidatedFileCache.shared.stamps
        let (found, nowGood) = await Task.detached(priority: .utility) { [directory, expectedDurations, knownGood] in
            CorruptFileFinderService.scanDirectory(directory, expectedDurations: expectedDurations, knownGood: knownGood)
        }.value

        ValidatedFileCache.shared.replaceAll(nowGood)
        corruptFiles = found
        let now = Date()
        lastScanDate = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "corruptFinder_lastScanTimestamp")
        isScanning = false

        if autoDeleteEnabled, !found.isEmpty {
            await ariaAutoDeleteCorruptFiles()
        }
    }

    // MARK: - Aria auto-delete

    /// Aria Lumi's autonomous cleanup pass: trashes (never hard-deletes —
    /// same revertibility contract as `LibraryManager.ariaRemoveDuplicate`)
    /// every file currently flagged corrupt, logs each removal to
    /// `AriaActivityLog` (toast + server audit trail — see its doc comment
    /// for why this one has no "Revert Aria's Change" menu item the way a
    /// duplicate-removal does). Runs automatically
    /// after every scan that finds something (both the periodic background
    /// scan and a manual "Scan Now") as long as `autoDeleteEnabled` is on;
    /// also callable directly for a user-initiated "let Aria clean this up"
    /// action on the current `corruptFiles` list.
    func ariaAutoDeleteCorruptFiles() async {
        let toDelete = corruptFiles
        guard !toDelete.isEmpty else { return }
        var removed: [CorruptFileEntry] = []
        for entry in toDelete {
            guard LibraryManager.shared?.ariaRemoveCorruptFile(at: entry.url) ?? false else { continue }
            removed.append(entry)
        }
        guard !removed.isEmpty else { return }
        corruptFiles.removeAll { entry in removed.contains { $0.id == entry.id } }
        AriaActivityLog.shared.logCorruptFilesDeleted(removed)
        let fileWord = removed.count == 1 ? "file" : "files"
        ToastCenter.shared.show("Aria cleaned up \(removed.count) corrupt \(fileWord)", category: .info, icon: "sparkles")
    }

    // MARK: - Delete

    /// Deletes every file currently in `corruptFiles`. Files that cannot be
    /// deleted are silently skipped; the list is cleared on completion.
    func deleteCorruptFiles() async {
        let toDelete = corruptFiles
        await Task.detached(priority: .utility) {
            for entry in toDelete {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }.value
        corruptFiles = []
        let fileWord = toDelete.count == 1 ? "file" : "files"
        ToastCenter.shared.show("Deleted \(toDelete.count) corrupt \(fileWord)", category: .info, icon: "trash")
    }

    // MARK: - Periodic Auto-Check

    /// Call once on app launch. Runs an immediate scan of the app's Documents
    /// directory, then re-scans automatically every hour while the app
    /// process is alive — for every user, no opt-in required. Aria Lumi
    /// Primary: every corrupt file this scan finds is handed straight to
    /// `ariaAutoDeleteCorruptFiles()` (when `autoDeleteEnabled`, on by
    /// default) — Aria decides and acts, this timer just keeps her looking.
    func startPeriodicScanning() {
        guard periodicTimer == nil else { return }

        scanDocumentsDirectory()

        let interval = Self.periodicScanInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Skip the (file-I/O heavy) scan while the app is backgrounded —
                // during background audio playback the process stays alive and
                // this would otherwise keep churning the disk every 5 min for no
                // user-visible benefit. It runs again on the next foreground tick.
                guard UIApplication.shared.applicationState == .active else { return }
                self?.scanDocumentsDirectory()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }

    /// Stops the periodic scan timer started by `startPeriodicScanning()`.
    func stopPeriodicScanning() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    private func scanDocumentsDirectory() {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }

        Task { await runScan(in: docs) }
    }

    // MARK: - Single-File Integrity Check

    /// Returns `true` if `url` points to a regular, non-empty audio file that
    /// `AVAudioFile` can open AND whose last chunk of declared audio data can
    /// actually be decoded. Used right after downloads, right after
    /// `AudioEncoderService` conversions, and by the periodic post-conversion
    /// re-check (`LumisoundTrackVaultService.runConversionIntegrityPassIfNeeded`)
    /// to catch corrupt or truncated files before they're adopted into (or
    /// left sitting in) the library — the single shared integrity check every
    /// one of those call sites uses, rather than each keeping its own
    /// ad-hoc/weaker version that drifts out of sync with this one.
    ///
    /// The tail-read is the important part: a merely-opened `AVAudioFile`
    /// only proves the container's HEADER parses — a dropped connection
    /// mid-download, or a re-encode that got interrupted after writing a
    /// valid header/duration but before finishing the sample data, both
    /// produce a file that opens fine here but silently has no (or garbage)
    /// audio for some trailing portion. Reading a real buffer from the very
    /// end of the file's declared length catches exactly that class of
    /// corruption a header-only check misses.
    ///
    /// `expectedDuration` (the track's known real length, when the caller
    /// has one — e.g. `StreamTrack.durationSeconds` right after a fresh
    /// download) catches a DIFFERENT failure mode the checks above can't:
    /// a file whose header/moov atom is entirely well-formed and internally
    /// consistent, just short — a dropped connection that cut a download off
    /// mid-stream can still leave behind a perfectly valid, tail-readable
    /// file that's simply 30 seconds of a 3:45 track. Generous tolerance
    /// (15%, floored at 10s) absorbs ordinary metadata imprecision (a
    /// search result's reported duration vs. the actual decoded stream
    /// length routinely differ by a second or two) without flagging real,
    /// complete downloads. Only applied when the caller actually passes an
    /// expected duration — every other call site (checking an EXISTING file
    /// for reuse, where "expected" duration isn't independently known)
    /// passes `nil` and gets exactly the previous behavior.
    nonisolated static func isValidAudioFile(at url: URL, expectedDuration: TimeInterval? = nil) -> Bool {
        if case .valid = validateAudioFile(at: url, expectedDuration: expectedDuration) { return true }
        return false
    }

    /// Shared validation core behind both `isValidAudioFile` (the boolean
    /// convenience callers elsewhere use) and `scanDirectory` (the Corrupt
    /// File Finder screen's own scan) — previously `scanDirectory` only did
    /// a bare `try AVAudioFile(forReading:)`, missing both the tail-read
    /// check (catches a header that parses fine but has garbage/missing
    /// audio at the end — a dropped connection mid-download or an
    /// interrupted re-encode) and the expected-duration check (catches a
    /// perfectly well-formed file that's simply much shorter than the track
    /// actually is) that `isValidAudioFile` already had. Factored out so the
    /// UI-facing scan gets the exact same thoroughness as the post-download/
    /// post-conversion check instead of a weaker one silently drifting out
    /// of sync with it.
    nonisolated private static func validateAudioFile(at url: URL, expectedDuration: TimeInterval?) -> AudioValidationResult {
        // Rust core (symphonia) first; AVAudioFile only for what it can't decode.
        switch validateAudio(path: url.path, cacheDir: CoreAudio.unlockDir, expectedDuration: expectedDuration) {
        case .valid: return .valid
        case .tooSmall: return .tooSmall
        case .unreadable(let reason): return .unreadable(reason)
        case .truncated(let actual, let expected): return .truncated(actual: actual, expected: expected)
        case .unsupported: break
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return .unreadable("could not read file attributes")
        }
        guard size >= 1_024 else { return .tooSmall }

        // See LumisoundExclusiveExtensionService.playableURL's doc comment —
        // without this, every `.lms`-converted track in the library would
        // read as "corrupt" here for the same extension-recognition reason
        // playback itself hit, not any actual corruption.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: LumisoundExclusiveExtensionService.playableURL(for: url))
        } catch {
            return .unreadable(error.localizedDescription)
        }
        guard file.length > 0 else { return .unreadable("zero-length audio stream") }

        let tailFrameCount = AVAudioFrameCount(min(file.length, 4_096))
        guard tailFrameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: tailFrameCount) else {
            return .unreadable("could not allocate a read buffer")
        }
        file.framePosition = max(0, file.length - AVAudioFramePosition(tailFrameCount))
        do {
            try file.read(into: buffer, frameCount: tailFrameCount)
        } catch {
            return .unreadable("tail read failed: \(error.localizedDescription)")
        }
        guard buffer.frameLength > 0 else { return .unreadable("tail read produced no audio frames") }

        // Opus/WebM/OGG containers skip the duration-mismatch check —
        // `AVAudioFile.duration`/`.length` is not trustworthy for these on
        // iOS: it's exactly why AudioEncoderService exists at all ("many
        // formats open directly on iOS 16+" is its own doc comment's
        // hedge — opening successfully doesn't mean the reported length is
        // correct). Confirmed in the field: EVERY single file this
        // truncation check had ever flagged as corrupt (1,697 of them, one
        // real user's library) was a `.opus.lms` track, spanning dozens of
        // unrelated source videos with wildly different "percent
        // truncated" — a pattern consistent with an unreliable duration
        // read for this format family, not systematically bad downloads.
        // Aria was auto-deleting fully playable tracks. The tail-read
        // above still runs for every format (catches a genuinely
        // zero-length/unreadable file), just not this specific
        // expected-vs-actual-duration comparison for formats where the
        // "actual" side of that comparison can't be trusted.
        let effectiveExt = LumisoundExclusiveExtensionService.effectiveExtension(for: url)
        let durationCheckApplies = !["opus", "webm", "ogg"].contains(effectiveExt)

        if durationCheckApplies, let expectedDuration, expectedDuration > 0 {
            let tolerance = max(10.0, expectedDuration * 0.15)
            if file.duration < expectedDuration - tolerance {
                return .truncated(actual: file.duration, expected: expectedDuration)
            }
        }
        return .valid
    }

    // MARK: - Private Scan Worker (nonisolated, runs off main actor)

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif",
        "ogg", "opus", "wma", "caf", "alac", "mp4", "webm",
        LumisoundExclusiveExtensionService.marker  // "lms" — converted tracks, see that type
    ]

    /// - Parameter knownGood: paths (see `ScanCacheService.documentsRelativePath`)
    ///   that validated as `.valid` on a previous scan, keyed to the
    ///   `ScanCacheService.FileStamp` they had then. A file whose current
    ///   stamp still matches is trusted without re-opening/re-decoding it —
    ///   see `runScan`'s doc comment for why this matters at library scale.
    /// - Returns: the flagged files, plus the full set of paths that
    ///   validated `.valid` THIS scan (becomes next scan's `knownGood`).
    nonisolated static func scanDirectory(
        _ directory: URL,
        expectedDurations: [URL: TimeInterval] = [:],
        knownGood: [String: ScanCacheService.FileStamp] = [:]
    ) -> (flagged: [CorruptFileEntry], validated: [String: ScanCacheService.FileStamp]) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], [:]) }

        var results: [CorruptFileEntry] = []
        var validated: [String: ScanCacheService.FileStamp] = [:]

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }

            // Check it is a regular file
            guard let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  attrs.isRegularFile == true else { continue }

            let fileSize = attrs.fileSize ?? 0
            let key = ScanCacheService.documentsRelativePath(for: fileURL) ?? fileURL.standardizedFileURL.path
            let stamp = ScanCacheService.fileStamp(for: fileURL)

            // A file with no expected-duration entry that matched its
            // known-good stamp last scan is unchanged since it last passed —
            // trust it and skip the AVAudioFile open/tail-read entirely.
            // Files WITH an expected duration are always re-checked even if
            // unchanged, since `expectedDurations` itself can change scan to
            // scan (e.g. metadata re-enrichment learning a real duration
            // after the fact) in a way the file's own stamp wouldn't reflect.
            if expectedDurations[fileURL] == nil, let stamp, knownGood[key] == stamp {
                validated[key] = stamp
                continue
            }

            switch validateAudioFile(at: fileURL, expectedDuration: expectedDurations[fileURL]) {
            case .valid:
                if let stamp { validated[key] = stamp }
            case .tooSmall:
                results.append(CorruptFileEntry(url: fileURL, fileSizeBytes: Int64(fileSize), reason: .tooSmall))
            case .unreadable(let detail):
                results.append(CorruptFileEntry(url: fileURL, fileSizeBytes: Int64(fileSize), reason: .unreadable(detail: detail)))
            case .truncated(let actual, let expected):
                results.append(CorruptFileEntry(url: fileURL, fileSizeBytes: Int64(fileSize), reason: .truncated(actualDuration: actual, expectedDuration: expected)))
            }
        }

        return (results, validated)
    }
}

// MARK: - ValidatedFileCache

/// Persisted `path → FileStamp` set of files that passed
/// `CorruptFileFinderService`'s integrity check on their most recent scan —
/// lets `runScan` skip re-validating anything that hasn't changed since.
/// Deliberately separate from `ScanCacheService` (which caches extracted
/// `Song` metadata, a different concern) even though it reuses its
/// `FileStamp`/path-keying helpers.
@MainActor
final class ValidatedFileCache {
    static let shared = ValidatedFileCache()

    private(set) var stamps: [String: ScanCacheService.FileStamp] = [:]
    private let cacheURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheURL = caches.appendingPathComponent("corrupt_finder_validated_v1.json")
        load()
    }

    /// Wholesale-replaces the known-good set with the result of a just-
    /// completed scan and persists it off-actor.
    func replaceAll(_ newStamps: [String: ScanCacheService.FileStamp]) {
        stamps = newStamps
        let snapshot = newStamps
        let destination = cacheURL
        Task.detached(priority: .utility) {
            struct Entry: Codable { let mtime: TimeInterval; let size: Int64 }
            let encodable = snapshot.mapValues { Entry(mtime: $0.mtime, size: $0.size) }
            guard let data = try? JSONEncoder().encode(encodable) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func load() {
        struct Entry: Codable { let mtime: TimeInterval; let size: Int64 }
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        stamps = decoded.mapValues { ScanCacheService.FileStamp(mtime: $0.mtime, size: $0.size) }
    }
}

// MARK: - CorruptFileEntry

struct CorruptFileEntry: Identifiable {
    let id = UUID()
    let url: URL
    let fileSizeBytes: Int64
    let reason: CorruptionReason

    var fileName: String { url.lastPathComponent }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var reasonText: String {
        switch reason {
        case .tooSmall:
            return "File is smaller than 1 KB — likely an incomplete download."
        case .unreadable(let detail):
            return "Could not open with AVAudioFile: \(detail)"
        case .truncated(let actual, let expected):
            let actualStr = String(format: "%.0f", actual)
            let expectedStr = String(format: "%.0f", expected)
            return "Opens fine but only decodes \(actualStr)s of an expected ~\(expectedStr)s — likely a dropped download or interrupted conversion."
        }
    }
}

// MARK: - CorruptionReason

enum CorruptionReason {
    case tooSmall
    case unreadable(detail: String)
    case truncated(actualDuration: TimeInterval, expectedDuration: TimeInterval)
}

/// Internal result of `CorruptFileFinderService.validateAudioFile` — richer
/// than a plain Bool so `scanDirectory` can report which specific check
/// failed, not just that one did.
private enum AudioValidationResult {
    case valid
    case tooSmall
    case unreadable(String)
    case truncated(actual: TimeInterval, expected: TimeInterval)
}
