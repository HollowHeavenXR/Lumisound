import Foundation
import MediaPlayer
import UIKit

extension LibraryManager {

    // MARK: - Periodic Local Metadata Refresh

    /// Number of tracks re-read from disk per 3-minute tick. `refreshTags` is
    /// local-only (no network, no artwork extraction — see its doc comment),
    /// so this can afford to be large: at the old value of 5, a genuinely
    /// multi-thousand-track library took (trackCount / 5) * 3 minutes to
    /// complete one full pass — 50+ hours for a 5,000-track library, not the
    /// "few minutes" this comment used to (incorrectly) claim. 200 keeps a
    /// single tick's work well under a second while cutting a full-library
    /// convergence pass to well under an hour even at 10k+ tracks.
    private static let metadataRefreshBatchSize = 200

    /// Call once on app launch. Every 3 minutes, re-reads the embedded tags of
    /// a small rotating batch of imported tracks directly from disk and updates
    /// the library if anything changed (e.g. the bridge re-tagged a file after
    /// a metadata re-check, or the user edited tags externally).
    ///
    /// Deliberately separate from `startPeriodicMetadataReenrichment`: that
    /// sweep only targets tracks with *missing* fields and hits online lookup
    /// services every 10 minutes. This sweep covers *all* imported tracks but
    /// only re-reads local file tags — no network calls, no artwork extraction —
    /// so it stays cheap even on a full pass.
    func startPeriodicMetadataRefresh() {
        guard metadataRefreshTimer == nil else { return }

        let interval: TimeInterval = 3 * 60
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Skip while backgrounded — re-reading file tags is wasted work
                // when the user can't see the library (e.g. background audio
                // playback keeps the process alive). Resumes on next foreground tick.
                guard UIApplication.shared.applicationState == .active else { return }
                await self?.refreshNextMetadataBatch()
            }
        }
        // Lets iOS batch this wake-up with others (battery).
        timer.tolerance = (interval) * 0.1
        RunLoop.main.add(timer, forMode: .common)
        metadataRefreshTimer = timer
    }

    /// Re-reads embedded tags for the next rotating batch of imported tracks
    /// (starting at `metadataRefreshCursor`, wrapping around the array) and
    /// updates any that changed on disk since they were last scanned.
    ///
    /// The actual `AVAsset` reads (`importer.refreshTags`) and file-existence/
    /// stamp `stat()` calls run off the main actor, concurrently, in a
    /// `Task.detached` — only the snapshot beforehand and the merge back into
    /// `importedSongs` afterward touch the main actor. At `metadataRefreshBatchSize`
    /// 200 (raised from 5 specifically to make a full-library pass finish in a
    /// reasonable time — see that constant's doc comment), running everything
    /// inline on the main actor the way this used to would mean 200 sequential
    /// `stat()` calls plus 200 sequential `AVAsset` metadata-load resumptions
    /// all landing on the main thread every 3 minutes — enough to be a real,
    /// user-visible stutter, exactly the kind of per-item-in-a-big-loop
    /// pattern `resolveSongs`/`performLocalDocumentsScan` already avoid for
    /// the same reason.
    func refreshNextMetadataBatch() async {
        // Optional upkeep: skip this round while the device is hot.
        guard await HeatGovernor.waitForHeadroom(job: "metadata refresh") else { return }
        guard !isRefreshingMetadata, !importedSongs.isEmpty else { return }

        isRefreshingMetadata = true
        defer { isRefreshingMetadata = false }

        let count = min(Self.metadataRefreshBatchSize, importedSongs.count)
        // Snapshot (index, id, url) for this batch on the main actor — cheap,
        // no I/O — before handing off to the detached worker below.
        var batch: [(index: Int, id: String, url: URL, song: Song)] = []
        batch.reserveCapacity(count)
        for offset in 0..<count {
            let index = (metadataRefreshCursor + offset) % importedSongs.count
            let song = importedSongs[index]
            guard let url = song.url else { continue }
            batch.append((index, song.id, url, song))
        }
        metadataRefreshCursor = (metadataRefreshCursor + count) % importedSongs.count

        let importer = self.importer
        let results: [(index: Int, id: String, url: URL, refreshed: Song, stamp: ScanCacheService.FileStamp)] =
            await Task.detached(priority: .utility) {
                await withTaskGroup(of: (Int, String, URL, Song, ScanCacheService.FileStamp)?.self) { group in
                    var results: [(Int, String, URL, Song, ScanCacheService.FileStamp)] = []
                    var pending = 0
                    let maxConcurrent = 8
                    var iterator = batch.makeIterator()

                    func launchNext() {
                        guard let entry = iterator.next() else { return }
                        pending += 1
                        group.addTask {
                            guard FileManager.default.fileExists(atPath: entry.url.path),
                                  let stamp = ScanCacheService.fileStamp(for: entry.url),
                                  let refreshed = await importer.refreshTags(for: entry.url, current: entry.song)
                            else { return nil }
                            return (entry.index, entry.id, entry.url, refreshed, stamp)
                        }
                    }
                    while pending < maxConcurrent { launchNext() }
                    for await result in group {
                        pending -= 1
                        if let result { results.append(result) }
                        launchNext()
                    }
                    return results
                }
            }.value

        var updatedCount = 0
        for result in results {
            // Re-validate against the live array — it may have mutated
            // (deletions, other passes) while this batch was off-actor.
            guard result.index < importedSongs.count, importedSongs[result.index].id == result.id else { continue }
            importedSongs[result.index] = result.refreshed
            updatedCount += 1
            ScanCacheService.shared.store(song: result.refreshed, for: result.url, stamp: result.stamp)
        }

        guard updatedCount > 0 else { return }

        appLog("Periodic metadata refresh: updated \(updatedCount) song(s)", category: "library")
        // One event for the whole batch (never per-track — this loop already
        // covers up to metadataRefreshBatchSize tracks, and logging inside
        // it would repeat the exact per-item-in-a-loop pattern that's caused
        // main-thread hangs here before).
        RemoteLogger.log(category: "sync", event: "metadata_refresh_batch",
                          detail: ["updated": updatedCount, "batchSize": count])
        ScanCacheService.shared.persist()
        rebuildAllSongs()
    }
}
