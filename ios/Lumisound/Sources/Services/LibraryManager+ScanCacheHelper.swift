import Foundation
import MediaPlayer
import UIKit

extension LibraryManager {

    // MARK: - Scan Cache Helper

    /// Resolves a list of file URLs to Songs, using `ScanCacheService` for unchanged files
    /// and `DocumentImportService.makeSong` only for new or modified ones.
    func resolveSongs(for urls: [URL]) async -> [Song] {
        // Stat every candidate file off the main actor first. `stat()` is a blocking
        // syscall — running it serially on the main thread for thousands of files
        // (as a naive cache check would) is the dominant cause of UI hitches/hangs
        // when scanning or importing a large library.
        let stamps: [(url: URL, stamp: ScanCacheService.FileStamp)] = await Task.detached(priority: .userInitiated) {
            urls.compactMap { url in
                ScanCacheService.fileStamp(for: url).map { (url, $0) }
            }
        }.value

        // Individually "cheap" (a dictionary lookup) but done thousands of times
        // in a tight loop, this measured at 1.3-1.6s of synchronous main-actor
        // time in field telemetry (MainThreadActivity's "scan.cacheLookup"
        // label) on a large library — worse under thermal throttling, where
        // even per-item-cheap work adds up. `snapshotEntries()` is an O(1)
        // copy-on-write handoff of the whole cache dict, so the actual
        // per-stamp matching can run entirely off the main actor against that
        // snapshot instead of calling back into the @MainActor service once
        // per file.
        let (cachedSongs, uncached): ([Song], [(url: URL, stamp: ScanCacheService.FileStamp)]) = await Task.detached(priority: .userInitiated) {
            let split = ScanCacheService.partition(stamps.map(\.url))
            let stampByPath = Dictionary(stamps.map { ($0.url.standardizedFileURL.path, $0.stamp) }, uniquingKeysWith: { a, _ in a })
            let uncached = split.uncached.compactMap { u in stampByPath[u.path].map { (url: u, stamp: $0) } }
            return (split.cached, uncached)
        }.value

        guard !uncached.isEmpty else { return cachedSongs }

        let stampByURL = Dictionary(
            uncached.map { ($0.url.standardizedFileURL, $0.stamp) },
            uniquingKeysWith: { first, _ in first }
        )

        // Process uncached files in checkpointed batches, storing+persisting the
        // scan cache after each one completes. Previously the cache was only
        // written once at the very end — so a scan interrupted by a crash, force
        // quit, or the OS killing a backgrounded app lost ALL of its metadata
        // extraction work and started completely from zero next launch (the
        // dominant cause of "it rescans my whole library again" reports for big
        // libraries). Now an interrupted scan resumes from the last completed
        // batch — at most ~100 files of repeated work instead of thousands.
        // Concurrency within each batch is unchanged (maxConcurrent = 8).
        let checkpointSize = 100
        // The cache is written at most this often while batches complete, plus
        // once at the end. Writing it after every 100-file batch re-encoded and
        // rewrote the WHOLE cache each time, so a full rescan of N files did
        // N/100 writes of a file that grows toward N entries — quadratic CPU and
        // disk on exactly the kind of scan that already runs hot. MetricKit
        // reported this app writing several GB a day. A time-based checkpoint
        // keeps the crash-resume property (at most ~20s of work is repeated)
        // without the quadratic cost.
        let checkpointInterval: TimeInterval = 20
        var lastCheckpoint = Date()
        var newSongs: [Song] = []
        newSongs.reserveCapacity(uncached.count)
        var batchStart = 0
        while batchStart < uncached.count {
            let batchEnd = min(batchStart + checkpointSize, uncached.count)
            let batchURLs = uncached[batchStart..<batchEnd].map(\.url)

            let batchSongs: [Song] = await Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: Song?.self) { group in
                    var results: [Song] = []
                    var pending = 0
                    let maxConcurrent = 8
                    var iterator = batchURLs.makeIterator()

                    while pending < maxConcurrent, let url = iterator.next() {
                        let s = DocumentImportService()
                        group.addTask { await s.makeSong(for: url) }
                        pending += 1
                    }

                    for await song in group {
                        if let song { results.append(song) }
                        pending -= 1
                        if let url = iterator.next() {
                            let s = DocumentImportService()
                            group.addTask { await s.makeSong(for: url) }
                            pending += 1
                        }
                    }
                    return results
                }
            }.value

            for song in batchSongs {
                if let url = song.url, let stamp = stampByURL[url.standardizedFileURL] {
                    ScanCacheService.shared.store(song: song, for: url, stamp: stamp)
                }
            }
            let isLastBatch = batchEnd >= uncached.count
            if isLastBatch || Date().timeIntervalSince(lastCheckpoint) >= checkpointInterval {
                ScanCacheService.shared.persist()
                lastCheckpoint = Date()
            }

            newSongs.append(contentsOf: batchSongs)
            batchStart = batchEnd
        }

        await EnrichmentCacheStore.shared.persist()

        // One event for the whole resolve call, not per checkpoint/file —
        // this can run over thousands of files in checkpointed batches, and
        // logging inside that loop would reintroduce the exact
        // blocking-call-per-item-in-a-big-loop pattern that's previously
        // caused main-thread hangs here.
        RemoteLogger.log(category: "sync", event: "resolve_songs_completed",
                          detail: ["cached": cachedSongs.count, "resolved": newSongs.count])

        return cachedSongs + newSongs
    }
}
