import BackgroundTasks
import Foundation

// MARK: - LumisoundTrackVaultService
//
// Drives the "reinject encrypted Lumisound metadata into every track, then
// re-encode it into the Lumisound-exclusive format" pipeline, for the WHOLE
// local library — downloaded tracks and plain local imports alike (widened
// 2026-08; previously local imports were skipped entirely and could never
// get re-encoded):
//  1. Tags newly-completed downloads immediately (`tagNewDownload`, called
//     right after a file lands on disk — see StreamingService+DownloadToLibrary).
//  2. Backfills the rest of the existing library — including tracks the
//     user imported locally rather than downloaded through the app — in
//     small batches via a `BGProcessingTask` (longer-running/lower-priority
//     than `BackgroundRefreshService`'s `BGAppRefreshTask`, appropriate for
//     a bulk one-time-per-track sweep rather than a periodic check), plus
//     an in-app fallback pass so the backfill also makes progress for users
//     who rarely background the app long enough for BGProcessingTask to
//     fire — the same real-world caveat BackgroundRefreshService documents:
//     iOS, not this code, decides if/when a submitted request actually runs.
//  3. Every 5 minutes in the foreground (`startFiveMinuteForegroundLoop`),
//     plus whenever the BGProcessingTask above actually gets to run, forces
//     a fresh sweep for anything tagged-but-not-yet-converted and re-encodes
//     it (`runExtensionConversionPass`) — so a track that failed to convert
//     on an earlier pass, or was just tagged by the backfill above, doesn't
//     have to wait indefinitely.
enum LumisoundTrackVaultService {
    static let taskIdentifier = "com.lumisound.ios.trackvault"

    /// Tracks in a single library scan can number in the thousands; tagging
    /// (an xattr syscall) is cheap per-file, but batching with a `Task.yield`
    /// between chunks keeps a long backfill from monopolizing the run loop.
    private static let batchSize = 40

    /// How often the extension-conversion pass runs while the app is in the
    /// foreground. iOS gives no way to guarantee an exact background
    /// cadence — BGProcessingTask's `earliestBeginDate` is only a floor, not
    /// a promise (see `scheduleNext`'s doc comment) — so a genuine 5-minute
    /// check is only achievable while the app is actually open; this loop is
    /// the primary driver, with the BGProcessingTask backfill (§ below)
    /// picking up the same work opportunistically whenever iOS actually
    /// runs it in the background.
    private static let extensionConversionInterval: UInt64 = 5 * 60 * 1_000_000_000
    private static var extensionConversionLoop: Task<Void, Never>?

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: processingTask)
        }
    }

    static func scheduleNext() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            appWarn("LumisoundTrackVaultService: submit failed: \(error.localizedDescription)", category: "background")
        }
    }

    private static func handle(task: BGProcessingTask) {
        scheduleNext()
        let work = Task {
            await runBackfill()
            await runExtensionConversionPass()
            await runMetadataRepairMigrationIfNeeded()
            await runConversionIntegrityPassIfNeeded()
            await DeadLinkHealingService.runIfNeeded()
            await LumisoundThumbnailBackfillService.runIfNeeded()
            await PodcastAutoDownloadService.runIfNeeded()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    /// Starts the foreground 5-minute repeating check: tag anything on disk
    /// that isn't tagged yet (`runBackfill`, covering plain local imports as
    /// well as downloads — see that method), then re-encode anything tagged
    /// but not yet converted (`runExtensionConversionPass`). Runs both every
    /// tick (not just the conversion pass) so a freshly-imported local file
    /// doesn't have to wait for the app to background before it's even
    /// eligible for conversion — previously tagging only ran on backgrounding
    /// (see LumisoundApp's scenePhase handler) while this loop only
    /// converted, so a local import's first tag could be delayed well past
    /// 5 minutes. Idempotent — safe to call from every `.onAppear`/`.task`
    /// site that might race at launch, since a second call while the loop is
    /// already running is a no-op. Call once from app launch; the loop keeps
    /// firing for as long as the process is alive (it isn't tied to
    /// scenePhase — `Task.sleep` just doesn't advance while the app is
    /// suspended, so it naturally resumes on the next tick after returning
    /// to the foreground rather than needing its own scenePhase observer).
    static func startFiveMinuteForegroundLoop() {
        guard extensionConversionLoop == nil else { return }
        extensionConversionLoop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: extensionConversionInterval)
                guard !Task.isCancelled else { break }
                await runBackfill()
                await runExtensionConversionPass()
                await runMetadataRepairMigrationIfNeeded()
                await runConversionIntegrityPassIfNeeded()
                await DeadLinkHealingService.runIfNeeded()
                await LumisoundThumbnailBackfillService.runIfNeeded()
                await PodcastAutoDownloadService.runIfNeeded()
            }
        }
    }

    /// Tags a single just-downloaded file immediately, so newly-downloaded
    /// tracks don't have to wait for the next backfill pass. Best-effort —
    /// failure just leaves the file for the next backfill to pick up.
    static func tagNewDownload(fileURL: URL, trackID: String, sourceURL: String) {
        guard !trackID.isEmpty else { return }
        LumisoundTrackTagger.tag(fileURL: fileURL, trackID: trackID, sourceURL: sourceURL)
    }

    /// Sweeps the ENTIRE local library — downloaded tracks and plain local
    /// imports alike — for anything that doesn't have the tag yet and tags
    /// it. Widened (2026-08) from downloaded-only: the exclusive-extension
    /// re-encode pass only ever picks up tagged tracks, so a track's local
    /// origin used to mean it would never get swept into the re-encode
    /// pipeline at all. Safe to call repeatedly/concurrently-ish since
    /// `isTagged`/`needsTagging` make every unit of work idempotent; also
    /// called as an in-app fallback (e.g. app entering background) since
    /// BGProcessingTask timing is not guaranteed.
    @MainActor
    static func runBackfill() async {
        // Whole-file lock/decode work: skip this round while the device is hot
        // (the five-minute loop and background task retry).
        guard await HeatGovernor.waitForHeadroom(job: "vault backfill") else { return }
        guard let library = LibraryManager.shared else { return }

        let candidatesToCheck = library.importedSongs.compactMap { song -> (String, URL, String)? in
            guard let url = song.url else { return nil }
            return (song.id, url, expectedTrackID(for: song))
        }
        // xattr reads are filesystem I/O. Do not perform one for every
        // imported track on the main actor during the five-minute pass.
        let candidateIDs = await Task.detached(priority: .utility) {
            Set(candidatesToCheck.compactMap { id, url, expectedID in
                LumisoundTrackTagger.needsTagging(fileURL: url, expectedTrackID: expectedID) ? id : nil
            })
        }.value
        let candidates = library.importedSongs.filter { candidateIDs.contains($0.id) }
        guard !candidates.isEmpty else { return }

        let allowedIDs = loadUserRuleScript().flatMap { script in
            LumisoundTrackVaultEngine.filterSongIDs(script: script, songs: candidates, favorites: library.favoriteSongIDs)
        }

        appLog("LumisoundTrackVaultService: backfilling \(candidates.count) untagged/mistagged track(s)", category: "background")

        var tagged = 0
        for (index, song) in candidates.enumerated() {
            if Task.isCancelled { break }
            if let allowedIDs, !allowedIDs.contains(song.id) { continue }
            guard let url = song.url else { continue }
            // BUG FIXED (2026-08): this used to pass `song.id` — an internal,
            // path-derived identifier like "local:Imported Music/.../track.m4a"
            // — as `trackID`, instead of `sourceTrackID` ("source:id", e.g.
            // "youtube:aqGXCQ_5WOc"), for DOWNLOADED tracks specifically.
            // Every consumer of this tag (duplicate detection's vault
            // fallback, hasLocalCopy/localSourceIDs) compares the decrypted
            // trackID against a real sourceTrackID, so the wrong value meant
            // the fallback could never match anything for those tracks.
            // `expectedTrackID(for:)` below still uses the real
            // sourceTrackID whenever one exists — it only falls back to
            // song.id for plain local imports that never had a
            // sourceTrackID to begin with, so there's no real ID for a
            // future re-download to mismatch against.
            let trackID = expectedTrackID(for: song)
            let sourceURL = trackID.hasPrefix("youtube:")
                ? "https://www.youtube.com/watch?v=\(trackID.dropFirst("youtube:".count))"
                : ""
            if LumisoundTrackTagger.tag(fileURL: url, trackID: trackID, sourceURL: sourceURL) {
                tagged += 1
            }
            if (index + 1) % batchSize == 0 {
                await Task.yield()
            }
        }
        appLog("LumisoundTrackVaultService: tagged \(tagged)/\(candidates.count) track(s)", category: "background")
    }

    /// The trackID a song's vault tag should carry: its real
    /// `sourceTrackID` when it has one (a downloaded/streamed track), or its
    /// own `id` for a plain local import with no known source — giving
    /// every on-disk track SOME expected value so the re-encode pass below
    /// can pick it up, without ever inventing a fake `source:id`-shaped
    /// value that could collide with a real one.
    private static func expectedTrackID(for song: Song) -> String {
        if let sourceTrackID = song.sourceTrackID, !sourceTrackID.isEmpty {
            return sourceTrackID
        }
        return song.id
    }

    /// Re-encodes every vault-tagged track that isn't already converted into
    /// the Lumisound-exclusive AAC container (see
    /// `LumisoundExclusiveExtensionService`), re-keying favorites/playlists/
    /// play-history as it goes (see
    /// `LibraryManager.convertToLumisoundExclusiveExtension`). Runs on the
    /// same 5-minute foreground loop as the rest of this pipeline, plus
    /// whenever the BGProcessingTask backfill above actually gets to run.
    /// Only tagged tracks are eligible, so this always runs strictly after
    /// tagging has had a chance to catch up — a just-downloaded track gets
    /// tagged immediately (`tagNewDownload`) but its extension conversion
    /// waits for the next pass, same as backfilled-tag tracks do.
    @MainActor
    static func runExtensionConversionPass() async {
        // Whole-file lock/decode work: skip this round while the device is hot
        // (the five-minute loop and background task retry).
        guard await HeatGovernor.waitForHeadroom(job: ".lms conversion pass") else { return }
        guard let library = LibraryManager.shared else { return }
        let passStartedAt = Date()
        let currentlyPlayingID = AudioPlayerManager.shared?.currentSong?.id

        // Logged unconditionally (not just on success) — this pass previously
        // logged nothing at all when it converted zero tracks, which made a
        // real bug (candidates always empty, or every conversion silently
        // failing) indistinguishable from "nothing to do yet" in the field.
        // Broken out by extension AND by tagged-vs-converted specifically —
        // "0 tagged-not-converted" is ambiguous on its own (could mean
        // "already all converted" OR "never got tagged in the first place",
        // e.g. if only one container format's downloads were actually
        // reaching tagNewDownload) — this makes that distinguishable.
        let conversionSnapshot = library.importedSongs.compactMap { song -> (String, URL)? in
            guard let url = song.url else { return nil }
            return (song.id, url)
        }
        let conversionState = await Task.detached(priority: .utility) {
            conversionSnapshot.map { id, url in
                (
                    id: id,
                    ext: LumisoundExclusiveExtensionService.effectiveExtension(for: url),
                    converted: LumisoundExclusiveExtensionService.isConverted(url),
                    tagged: LumisoundTrackTagger.isTagged(fileURL: url)
                )
            }
        }.value
        var extBreakdown: [String: (total: Int, tagged: Int, converted: Int)] = [:]
        for state in conversionState {
            var entry = extBreakdown[state.ext] ?? (0, 0, 0)
            entry.total += 1
            if state.converted {
                entry.converted += 1
            } else if state.tagged {
                entry.tagged += 1
            }
            extBreakdown[state.ext] = entry
        }
        let breakdownText = extBreakdown.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.total)tot/\($0.value.tagged)tagged-not-converted/\($0.value.converted)converted" }
            .joined(separator: ", ")
        appLog("LumisoundTrackVaultService: conversion pass — \(library.importedSongs.count) imported [\(breakdownText)], currentlyPlaying=\(currentlyPlayingID ?? "nil")", category: "background")

        let candidateIDs = Set(conversionState.compactMap { state in
            state.converted || !state.tagged ? nil : state.id
        })
        let candidates = library.importedSongs.filter { candidateIDs.contains($0.id) }
        guard !candidates.isEmpty else {
            appLog("LumisoundTrackVaultService: conversion pass complete — no candidates, elapsed=\(String(format: "%.2f", Date().timeIntervalSince(passStartedAt)))s", category: "background")
            return
        }

        var converted = 0
        var failedSongIDs: [String] = []
        for (index, song) in candidates.enumerated() {
            if Task.isCancelled { break }
            if await library.convertToLumisoundExclusiveExtension(songID: song.id, currentlyPlayingID: currentlyPlayingID) {
                converted += 1
            } else if failedSongIDs.count < 5 {
                failedSongIDs.append(song.id)
            }
            if (index + 1) % batchSize == 0 {
                await Task.yield()
            }
        }
        appLog("LumisoundTrackVaultService: converted \(converted)/\(candidates.count) track(s) to the Lumisound-exclusive extension" + (failedSongIDs.isEmpty ? "" : "; sample failures: \(failedSongIDs)") + ", elapsed=\(String(format: "%.2f", Date().timeIntervalSince(passStartedAt)))s", category: "background")

        await runLegacyRelockPass(library: library)
    }

    /// Upgrades already-`.lms`-marked tracks whose bytes are still the
    /// legacy plain (unlocked) format — i.e. converted before
    /// `LumisoundLockFormat` existed — into the real locked format, in
    /// place, via `LumisoundExclusiveExtensionService.relockLegacyFile`.
    /// Runs every pass (not gated behind a one-time flag) since it's cheap
    /// per-file (an 8-byte header read for anything already migrated) and,
    /// same reasoning as every other pass in this file, self-healing beats
    /// a permanently-stuck track if a given relock attempt fails once.
    @MainActor
    private static func runLegacyRelockPass(library: LibraryManager) async {
        let legacyCandidates = library.importedSongs.compactMap { song -> URL? in
            guard let url = song.url,
                  LumisoundExclusiveExtensionService.isConverted(url),
                  !LumisoundLockFormat.isLocked(at: url) else { return nil }
            return url
        }
        guard !legacyCandidates.isEmpty else { return }

        // `relockLegacyFile` is a plain synchronous function (full-file XOR
        // lock + a decode round-trip to verify) with no `await` inside it, so
        // calling it directly here -- from this @MainActor function -- ran it
        // ON THE MAIN THREAD with no natural yield point, exactly the bug
        // `convert(fileURL:)` was fixed for elsewhere in this same file (see
        // that function's doc comment: a 674MB FLAC lock froze the whole UI
        // and was implicated in a session-ending crash). This loop had the
        // identical shape and never got the same fix -- confirmed as the
        // root cause of reported "track stops for 2+ seconds, UI freezes at
        // the same time" symptoms, which fits exactly: this pass runs every
        // 5 minutes regardless of playback state, and a multi-second
        // synchronous block on the shared main actor stalls SwiftUI
        // rendering AND any pending `@MainActor` audio-scheduling
        // continuation at the same time. `Task.detached` forces genuine
        // off-main execution for the heavy part; only the final tally/log
        // stays on the main actor.
        var relocked = 0
        for (index, url) in legacyCandidates.enumerated() {
            if Task.isCancelled { break }
            let didRelock = await Task.detached(priority: .utility) {
                LumisoundExclusiveExtensionService.relockLegacyFile(at: url)
            }.value
            if didRelock {
                relocked += 1
            }
            if (index + 1) % batchSize == 0 {
                await Task.yield()
            }
        }
        appLog("LumisoundTrackVaultService: relocked \(relocked)/\(legacyCandidates.count) legacy .lms track(s) into the real locked format", category: "background")
    }

    /// Repair pass for tracks that ended up "converted" (see
    /// `LumisoundExclusiveExtensionService.isConverted`) but missing their
    /// embedded title/artist/album/`LUMISOUND_ID` — a track in this state
    /// is stuck permanently: `runExtensionConversionPass` above only ever
    /// looks at NOT-yet-converted tracks, so nothing else in this pipeline
    /// will ever revisit it. Originally written as a strict one-time
    /// migration for tracks converted before the AudioEncoderService fix
    /// that stopped this from happening going forward — changed to a
    /// periodic (`_metadataRepairMigrationInterval`) re-check instead of
    /// permanently-once after confirming (from real device files) that
    /// freshly-converted tracks could still come out tag-less even on a
    /// build that includes that fix. Whatever the exact remaining cause
    /// turns out to be, a strictly one-time repair pass means any track
    /// that hits it AFTER the one run completes is broken forever with no
    /// self-healing — same reasoning as this pipeline's other passes.
    /// Checking `hasEmbeddedSourceTag` is an async AVAsset metadata load
    /// per file — not free — which is why this still isn't folded into the
    /// plain 5-minute loop like the rest of this pipeline.
    private static let metadataRepairMigrationLastRunKey = "lumisoundTrackVault.metadataRepairMigration.lastRun"
    private static let metadataRepairMigrationInterval: TimeInterval = 24 * 60 * 60
    /// Per-track count of failed repair attempts, so a track that cannot be
    /// repaired stops being retried (and stops holding `lastRun` back).
    private static let metadataRepairStrikesKey = "lumisoundTrackVault.metadataRepair.strikes"
    private static let maxMetadataRepairAttempts = 3

    @MainActor
    static func runMetadataRepairMigrationIfNeeded() async {
        // Whole-file lock/decode work: skip this round while the device is hot
        // (the five-minute loop and background task retry).
        guard await HeatGovernor.waitForHeadroom(job: "metadata repair migration") else { return }
        let lastRun = UserDefaults.standard.double(forKey: metadataRepairMigrationLastRunKey)
        guard Date().timeIntervalSince1970 - lastRun >= metadataRepairMigrationInterval else { return }
        guard let library = LibraryManager.shared else { return }
        let currentlyPlayingID = AudioPlayerManager.shared?.currentSong?.id

        let convertedByID: [String: (url: URL, sourceTrackID: String?)] = library.importedSongs.reduce(into: [:]) { acc, song in
            guard let url = song.url, LumisoundExclusiveExtensionService.isConverted(url) else { return }
            acc[song.id] = (url, song.sourceTrackID)
        }
        guard !convertedByID.isEmpty else {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: metadataRepairMigrationLastRunKey)
            return
        }

        appLog("LumisoundTrackVaultService: metadata repair migration — checking \(convertedByID.count) already-converted track(s)", category: "background")

        // Check phase: `hasEmbeddedSourceTag` for every already-converted
        // track, run concurrently off the main actor — after this fix, the
        // overwhelming majority of a library will already have its tag
        // (only tracks converted before this migration shipped don't), so
        // this scan itself is the expensive part and must not run as a
        // sequential main-actor loop (that's exactly the pattern that made
        // this migration a lag source when it was first written).
        let idsNeedingRepair: [String] = await Task.detached(priority: .utility) {
            await withTaskGroup(of: String?.self) { group in
                var needsRepair: [String] = []
                var pending = 0
                let maxConcurrent = 8
                var iterator = convertedByID.makeIterator()

                func launchNext() {
                    guard let (id, entry) = iterator.next() else { return }
                    pending += 1
                    group.addTask {
                        // A container AVFoundation cannot tag can never be
                        // repaired, so it must not be queued. Without this the
                        // repair phase below failed on it every pass, `allResolved`
                        // stayed false, `lastRun` never advanced, and this whole
                        // 24-hour migration re-ran on every 5-minute tick doing
                        // full-file lock/unlock I/O — 29,436 logged failures over
                        // 340 Ogg/Opus files, none of which could ever succeed.
                        guard AudioTagWriter.canTag(fileAt: entry.url) else { return nil }
                        guard await LumisoundExclusiveExtensionService.hasEmbeddedSourceTag(fileURL: entry.url) else {
                            return id
                        }
                        // Second condition: catches tracks already repaired
                        // once (title/artist/ID present, so the check above
                        // passes) before AudioTagWriter started embedding a
                        // thumbnail tag — only for YouTube sources, since
                        // that's the only case a thumbnail URL can be
                        // deterministically reconstructed for (see
                        // repairEmbeddedMetadata).
                        if let sourceTrackID = entry.sourceTrackID, sourceTrackID.hasPrefix("youtube:") {
                            let hasThumbnail = await LumisoundExclusiveExtensionService.hasEmbeddedThumbnailTag(fileURL: entry.url)
                            if !hasThumbnail { return id }
                        }
                        return nil
                    }
                }
                while pending < maxConcurrent { launchNext() }
                for await result in group {
                    pending -= 1
                    if let result { needsRepair.append(result) }
                    launchNext()
                }
                return needsRepair
            }
        }.value

        guard !idsNeedingRepair.isEmpty else {
            appLog("LumisoundTrackVaultService: metadata repair migration — nothing to repair", category: "background")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: metadataRepairMigrationLastRunKey)
            return
        }
        appLog("LumisoundTrackVaultService: metadata repair migration — \(idsNeedingRepair.count) track(s) need repair", category: "background")

        // Repair phase: comparatively rare (only tracks actually missing
        // the tag) and each repair is a real file write, so this part stays
        // sequential on the main actor like every other mutating pass in
        // this pipeline — but it's operating on a small subset now, not the
        // whole library.
        var repaired = 0
        var allResolved = true
        var strikes = UserDefaults.standard.dictionary(forKey: metadataRepairStrikesKey) as? [String: Int] ?? [:]
        var gaveUp = 0
        for (index, id) in idsNeedingRepair.enumerated() {
            if Task.isCancelled { allResolved = false; break }
            if id == currentlyPlayingID {
                allResolved = false
                continue
            }
            // A track that has failed repair this many times is not going to
            // start working, and must stop holding the migration open.
            //
            // `allResolved` gating `lastRun` is right for a transient failure —
            // retry on the next tick rather than waiting out 24 hours — but it
            // gave a single permanently-unrepairable track the power to keep the
            // entire pass due forever, re-running every 5 minutes with real
            // file I/O. The Ogg/Opus case that caused this in the field is now
            // excluded before it gets here; this is the general backstop for
            // whatever else turns out to be unrepairable.
            if (strikes[id] ?? 0) >= maxMetadataRepairAttempts {
                gaveUp += 1
                continue
            }
            if await library.repairEmbeddedMetadata(songID: id, currentlyPlayingID: currentlyPlayingID) {
                repaired += 1
                strikes[id] = nil
            } else {
                strikes[id] = (strikes[id] ?? 0) + 1
                allResolved = false
            }
            if (index + 1) % batchSize == 0 {
                await Task.yield()
            }
        }

        // Pruned to the tracks still in play, so the record cannot grow forever.
        strikes = strikes.filter { idsNeedingRepair.contains($0.key) }
        UserDefaults.standard.set(strikes, forKey: metadataRepairStrikesKey)

        appLog("LumisoundTrackVaultService: metadata repair migration — repaired \(repaired)/\(idsNeedingRepair.count) track(s)"
               + (gaveUp > 0 ? ", gave up on \(gaveUp) after \(maxMetadataRepairAttempts) failed attempts" : ""),
               category: "background")
        // Only advances lastRun once every converted track either already
        // had its tag or was successfully repaired this pass — anything
        // left unresolved (currently playing, or a repair that failed)
        // means this stays due so the very next periodic tick retries it
        // instead of waiting out the full interval. hasEmbeddedSourceTag
        // makes re-running cheap: already-fixed tracks are skipped instantly.
        if allResolved {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: metadataRepairMigrationLastRunKey)
        }
    }

    /// Periodic re-verification of every already-converted (`.lms`) track's
    /// on-disk integrity — catches files that passed
    /// `AudioEncoderService.convertPermanently`'s verification at conversion
    /// time but were corrupted afterward (a disk/iCloud sync glitch, or —
    /// for anything converted before this session's fix — a truncated
    /// re-encode that the OLD, weaker ad-hoc check missed but
    /// `isValidAudioFile`'s tail-read now catches), so a broken file doesn't
    /// sit silently unplayable in the library forever. Same periodic-not-
    /// one-time reasoning as `runMetadataRepairMigrationIfNeeded` above: a
    /// one-time pass gives no protection against corruption that happens
    /// (or is only detectable) after it runs.
    ///
    /// Deliberately deletes rather than attempts to auto-redownload +
    /// reconvert: nothing else in this codebase auto-redownloads on its own
    /// initiative (`CorruptFileFinderService` is delete-only too), and
    /// `removeImportedSong` trashes to `RecentlyDeletedService` (30-day
    /// recovery) rather than hard-deleting, so this doesn't lose data
    /// outright — it just stops presenting a broken file as if it were a
    /// working track. Re-downloading it is one tap away for the user.
    private static let conversionIntegrityLastRunKey = "lumisoundTrackVault.conversionIntegrityPass.lastRun"
    private static let conversionIntegrityInterval: TimeInterval = 24 * 60 * 60

    @MainActor
    static func runConversionIntegrityPassIfNeeded() async {
        // Whole-file lock/decode work: skip this round while the device is hot
        // (the five-minute loop and background task retry).
        guard await HeatGovernor.waitForHeadroom(job: "conversion integrity pass") else { return }
        let lastRun = UserDefaults.standard.double(forKey: conversionIntegrityLastRunKey)
        guard Date().timeIntervalSince1970 - lastRun >= conversionIntegrityInterval else { return }
        guard let library = LibraryManager.shared else { return }
        let currentlyPlayingID = AudioPlayerManager.shared?.currentSong?.id

        let convertedURLsByID: [String: URL] = library.importedSongs.reduce(into: [:]) { acc, song in
            guard let url = song.url, LumisoundExclusiveExtensionService.isConverted(url) else { return }
            acc[song.id] = url
        }
        guard !convertedURLsByID.isEmpty else {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: conversionIntegrityLastRunKey)
            return
        }

        appLog("LumisoundTrackVaultService: conversion integrity pass — checking \(convertedURLsByID.count) already-converted track(s)", category: "background")

        // isValidAudioFile is synchronous but does real file I/O (a tail-read
        // of up to 4096 frames per file) — run the whole scan off the main
        // actor, concurrently, same shape as the metadata repair pass above.
        let corruptIDs: [String] = await Task.detached(priority: .utility) {
            await withTaskGroup(of: String?.self) { group in
                var corrupt: [String] = []
                var pending = 0
                let maxConcurrent = 8
                var iterator = convertedURLsByID.makeIterator()

                func launchNext() {
                    guard let (id, url) = iterator.next() else { return }
                    pending += 1
                    group.addTask {
                        CorruptFileFinderService.isValidAudioFile(at: url) ? nil : id
                    }
                }
                while pending < maxConcurrent { launchNext() }
                for await result in group {
                    pending -= 1
                    if let result { corrupt.append(result) }
                    launchNext()
                }
                return corrupt
            }
        }.value

        guard !corruptIDs.isEmpty else {
            appLog("LumisoundTrackVaultService: conversion integrity pass — all converted tracks verified OK", category: "background")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: conversionIntegrityLastRunKey)
            return
        }

        appWarn("LumisoundTrackVaultService: conversion integrity pass — \(corruptIDs.count) converted track(s) failed re-verification, removing", category: "background")
        RemoteLogger.logError(
            category: "library",
            event: "conversion_integrity_failure",
            message: "post-conversion file(s) failed integrity re-check",
            detail: ["count": corruptIDs.count]
        )

        var allResolved = true
        for id in corruptIDs {
            if Task.isCancelled { allResolved = false; break }
            if id == currentlyPlayingID {
                // Don't yank a file out from under an open player — same
                // "leave it for the next tick" reasoning as every other
                // pass in this pipeline. Its `.lms` extension means nothing
                // else will re-attempt conversion on it in the meantime, so
                // this is safe to simply retry later.
                allResolved = false
                continue
            }
            library.removeImportedSong(id: id)
        }

        if allResolved {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: conversionIntegrityLastRunKey)
        }
    }

    /// Optional user-authored policy script — no bundled/picker UI for this
    /// (unlike Effects/Visualizers), just an opt-in advanced override: drop a
    /// `.lua` file defining `should_tag(track)` at this path to exclude
    /// specific tracks from tagging. Absent by default, which means "tag
    /// everything" (see runBackfill's `allowedIDs` handling above).
    private static func loadUserRuleScript() -> String? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumisoundTrackVaultRule.lua")
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
