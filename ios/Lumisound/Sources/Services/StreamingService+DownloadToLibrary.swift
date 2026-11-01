import Foundation
import UIKit

extension StreamingService {

    // MARK: - Download to Library

    /// Downloads a stream track's audio permanently to `downloadDirectory` (or
    /// `destinationDir` if provided — used by folder-structure restore to place
    /// redownloaded tracks back into their original watched-folder path) using
    /// the `/api/download` endpoint (which embeds metadata and thumbnail into
    /// the file). If the file already exists it is returned immediately without
    /// re-downloading.
    ///
    /// `existingSongs` (typically `LibraryManager.allSongs`) enables pre-download
    /// dedupe: if a song in `existingSongs` shares this track's `sourceTrackID`
    /// ("\(track.source):\(track.id)") and its local file passes
    /// `CorruptFileFinderService.isValidAudioFile(at:)`, the download is skipped
    /// entirely and that song's existing file URL is returned. If the matching
    /// local file is missing or corrupt, the download proceeds normally to
    /// replace it. Pass `[]` (the default) to disable this check.
    ///
    /// `destinationFolderName` (e.g. a `TrackedPlaylist.destinationFolder`)
    /// is sent to the bridge as the job-based path's `destination_folder`
    /// param purely so it's recorded on `ios_pending_downloads` — this is
    /// what lets `reconcilePendingDownloads` put a track back into the
    /// right folder if this job finishes after the app was closed/crashed,
    /// rather than always falling back to the default. Independent of
    /// `destinationDir`, which controls where THIS call writes the file if
    /// it completes normally in the foreground.
    func downloadToLibrary(
        track: StreamTrack,
        destinationDir: URL? = nil,
        existingSongs: [Song] = [],
        destinationFolderName: String? = nil,
        reportExistingAsSkipped: Bool = false
    ) async throws -> URL {
        // Single chokepoint every download path in the app funnels through
        // (foreground downloads, background job reconciliation, tracked
        // playlist auto-download), so gating Wi-Fi Only Downloads here
        // covers all of them at once rather than needing a check at each
        // call site.
        if UserDefaults.standard.bool(forKey: "wifiOnlyDownloads.enabled"), NetworkPathMonitor.shared.isCellularOnly {
            throw StreamingError.wifiRequired
        }

        let sourceTrackID = "\(track.source):\(track.id)"

        // Tracks the bridge has told us are gone (removed, private, terminated
        // channel) are left alone for a while — see DownloadFailureStore. Placed
        // at this same chokepoint, before any network work, so every download path
        // in the app inherits it: with no memory of failure, a dead video was
        // re-requested by every pass forever — 9,842 attempts across 2,223 such
        // tracks in one measured week, which is both wasted work and part of what
        // provokes the bot wall that breaks the downloads that COULD succeed.
        if DownloadFailureStore.shared.shouldSkip(sourceTrackID: sourceTrackID) {
            appLog("downloadToLibrary: skipping \"\(track.title)\" — known unavailable, still in cool-off", category: "network")
            throw StreamingError.permanentlyUnavailable
        }

        // Pre-download dedupe — skip entirely if we already have a valid copy
        // of this exact source track (matched by sourceTrackID/LUMISOUND_ID).
        if let match = existingSongs.first(where: { $0.sourceTrackID == sourceTrackID }),
           let existingURL = match.url,
           FileManager.default.fileExists(atPath: existingURL.path) {
            let isValid = await Task.detached(priority: .utility) {
                CorruptFileFinderService.isValidAudioFile(at: existingURL)
            }.value
            if isValid {
               if let preparedURL = await prepareExistingLocalCopy(existingURL, track: track) {
                   appLog("downloadToLibrary: skipping \"\(track.title)\" — valid locked copy at \(preparedURL.lastPathComponent)", category: "network")
                   DownloadLedgerStore.shared.record(sourceTrackID: sourceTrackID, filename: preparedURL.lastPathComponent)
                   if reportExistingAsSkipped { throw StreamingError.alreadyDownloaded }
                   return preparedURL
               }
               appWarn("downloadToLibrary: existing copy of \"\(track.title)\" could not be locked — downloading a replacement", category: "network")
           } else {
               appWarn("downloadToLibrary: existing copy of \"\(track.title)\" is corrupt — redownloading to replace it", category: "network")
           }
        }

        appLog("Download started: \"\(track.title)\" [fmt: \(preferredFormat)]", category: "network")
        let fmt = preferredFormat
        let requestedExt = fileExtension(for: fmt)

        let importDir = destinationDir ?? downloadDirectory
        do {
            try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        } catch {
            appWarn("downloadToLibrary: could not create download dir: \(error)", category: "network")
        }

        // Build a filesystem-safe filename from the track title (max 100 chars).
        let safeName = String(
            track.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(100)
        )

        // Check for an existing download under the requested extension before hitting
        // the network — the actual extension is only known after the response arrives
        // (see below), so this is just the common-case fast path. Titles routinely
        // collide across different tracks (covers, remasters, two different artists'
        // same-titled songs), so a bare filename match here is NOT proof this is the
        // same source track — only trust it if the ledger confirms *this exact*
        // sourceTrackID produced *this exact* filename (see resolveDownloadDestination).
        // Otherwise fall through to a real download; the move-into-place step below
        // will pick a disambiguated name instead of silently adopting or clobbering
        // whatever's already there.
        let provisionalDestURL = importDir.appendingPathComponent("\(safeName).\(requestedExt)")
        let provisionalIsValid = FileManager.default.fileExists(atPath: provisionalDestURL.path)
            ? await Task.detached(priority: .utility) {
                CorruptFileFinderService.isValidAudioFile(at: provisionalDestURL)
            }.value
            : false
        // Trust WHATEVER filename the ledger recorded for this source id, not
        // just the provisional one.
        //
        // This compared the ledger entry against `provisionalDestURL` — the
        // plain, pre-lock name ("Song.opus"). But the ledger is written with
        // the name the file ends up under, and a locked track ends up as
        // "Song.opus.lms", so for any track that had been locked the two could
        // never be equal and this check could never fire. Combined with the
        // source-id check above missing too (`Song.sourceTrackID` comes from
        // the embedded LUMISOUND_ID tag, read via AVFoundation, which has no
        // Ogg demuxer at all — so it is always nil for the .opus downloads
        // this library is full of), NOTHING deduped: measured over 12 hours,
        // 245 downloads started and not one dedup hit of any kind, which is
        // why tracked playlists kept re-fetching tracks already owned and
        // locked.
        //
        // Resolving the ledger's own filename fixes both: it is recorded at
        // download time, so it needs neither a readable tag nor a guess about
        // what the file is called now.
        if let ledgerName = DownloadLedgerStore.shared.filename(for: sourceTrackID) {
            let ledgerURL = importDir.appendingPathComponent(ledgerName)
            let ledgerIsValid = FileManager.default.fileExists(atPath: ledgerURL.path)
                ? await Task.detached(priority: .utility) {
                    CorruptFileFinderService.isValidAudioFile(at: ledgerURL)
                }.value
                : false
            if ledgerIsValid {
                if let preparedURL = await prepareExistingLocalCopy(ledgerURL, track: track) {
                    appLog("downloadToLibrary: already have \"\(track.title)\" per ledger (\(preparedURL.lastPathComponent)), skipping", category: "network")
                    DownloadLedgerStore.shared.record(sourceTrackID: sourceTrackID, filename: preparedURL.lastPathComponent)
                    if reportExistingAsSkipped { throw StreamingError.alreadyDownloaded }
                    return preparedURL
                }
                appWarn("downloadToLibrary: ledger copy of \"\(track.title)\" could not be locked — continuing with download", category: "network")
            }
        }
        if provisionalIsValid, DownloadLedgerStore.shared.filename(for: sourceTrackID) == provisionalDestURL.lastPathComponent {
            if let preparedURL = await prepareExistingLocalCopy(provisionalDestURL, track: track) {
                appLog("downloadToLibrary: already exists and is locked, skipping \(preparedURL.lastPathComponent)", category: "network")
                DownloadLedgerStore.shared.record(sourceTrackID: sourceTrackID, filename: preparedURL.lastPathComponent)
                if reportExistingAsSkipped { throw StreamingError.alreadyDownloaded }
                return preparedURL
            }
            appWarn("downloadToLibrary: existing provisional copy could not be locked — continuing with download", category: "network")
        }

        // Cross-process in-flight guard — everything above only catches a
        // track that's ALREADY on disk (or already recorded as such). It
        // does nothing for two downloads of the same sourceTrackID that
        // start within moments of each other and are BOTH still in
        // progress — the exact scenario `TrackedPlaylistStore
        // .runAutoDownloads`'s own doc comment describes (a background
        // refresh task and a foreground launch, often two separate process
        // instances, both seeing the same track as "missing" before either
        // has written it to disk). Claim this sourceTrackID before doing
        // any real network work; if something else already holds it,
        // there's a download for this exact track in flight elsewhere —
        // skip rather than duplicate it.
        guard DownloadLedgerStore.shared.beginDownload(sourceTrackID: sourceTrackID) else {
            appLog("downloadToLibrary: skipping \"\(track.title)\" — another download of \(sourceTrackID) is already in flight", category: "network")
            throw StreamingError.alreadyInFlight
        }
        defer { DownloadLedgerStore.shared.endDownload(sourceTrackID: sourceTrackID) }

        // Faster transports, tried before the job-based /api/download flow below —
        // each is best-effort and falls straight through to the proven job-based
        // path on ANY failure, so worst case behavior is unchanged from before
        // these existed. Only apply to m4a: mp3/flac/opus/wav need server-side
        // transcoding, which neither of these paths does (see the /api/download/relay
        // doc comment on the bridge for why — no live-subprocess-piping infra exists
        // there yet). "best" is deliberately excluded too, even though it sounds like
        // a plain remux: YouTube's actual "best" audio is frequently a webm/opus
        // stream, which AVFoundation can't demux at all — every attempt would
        // silently fail after downloading the whole file, wasting bandwidth for
        // anyone on "Best Quality" before falling back anyway. See the matching
        // comment on _RELAY_INCOMPATIBLE_FORMATS in main.py.
        //
        // Also skipped when the user has opted into aria2 (Settings → yt-dlp):
        // both faster paths fetch over a single connection (attemptDirectFetch via
        // URLSession, attemptRelayDownload via the bridge's single urllib.urlopen).
        // aria2 is specifically for networks that throttle single connections —
        // silently downgrading those users to a single connection here would
        // undo the exact thing they opted in for. Job-based /api/download is the
        // only path that honors use_aria2, so that preference routes there.
        // Computed here (rather than just before the job-based request below) so
        // the fast paths can also hand it to /api/download/relay — that endpoint
        // has no yt-dlp job to naturally slot an ownership check into, so without
        // this it would have no server-side dedupe backstop at all, unlike the
        // job-based path. Exclude this track's own ID — if we got this far the
        // pre-download check above either found no local copy or a corrupt one
        // that needs replacing, so the server must not skip *this* download.
        let manifest = existingTrackManifest(songs: existingSongs.filter { $0.sourceTrackID != sourceTrackID })

        let aria2Enabled = UserDefaults.standard.bool(forKey: "ytdlp_use_aria2")
        if fmt == "m4a" && aria2Enabled {
            appLog("downloadToLibrary: skipping faster transport for \"\(track.title)\" — aria2 enabled, routing to job-based /api/download", category: "network")
        }
        if fmt == "m4a" && !aria2Enabled {
            appLog("downloadToLibrary: attempting faster transport for \"\(track.title)\" [source: \(track.source), fmt: \(fmt)]", category: "network")
            if track.source == "soundcloud" || track.source == "bandcamp" {
                let attemptStart = Date()
                do {
                    let destURL = try await attemptDirectFetch(track: track, safeName: safeName, importDir: importDir)
                    let elapsed = Date().timeIntervalSince(attemptStart)
                    appLog("downloadToLibrary: succeeded via direct CDN fetch for \"\(track.title)\" in \(String(format: "%.2f", elapsed))s", category: "network")
                    DownloadLedgerStore.shared.record(sourceTrackID: sourceTrackID, filename: destURL.lastPathComponent)
                    return await finalizeAndLockDownload(destURL: destURL, track: track)
                } catch {
                    let elapsed = Date().timeIntervalSince(attemptStart)
                    appWarn("downloadToLibrary: direct CDN fetch failed for \"\(track.title)\" after \(String(format: "%.2f", elapsed))s: \(error) — falling back to relay", category: "network")
                }
            }
            let relayStart = Date()
            do {
                let destURL = try await attemptRelayDownload(track: track, safeName: safeName, importDir: importDir, existingIDs: manifest)
                let elapsed = Date().timeIntervalSince(relayStart)
                appLog("downloadToLibrary: succeeded via server relay for \"\(track.title)\" in \(String(format: "%.2f", elapsed))s", category: "network")
                DownloadLedgerStore.shared.record(sourceTrackID: sourceTrackID, filename: destURL.lastPathComponent)
                return await finalizeAndLockDownload(destURL: destURL, track: track)
            } catch {
                let elapsed = Date().timeIntervalSince(relayStart)
                appWarn("downloadToLibrary: server relay failed for \"\(track.title)\" after \(String(format: "%.2f", elapsed))s: \(error) — falling back to job-based download", category: "network")
            }
        }

        // Hit the /api/download endpoint which runs yt-dlp with metadata embedding.
        // `title` is `safeName` — a filesystem-safe, length-capped filename hint
        // ONLY. `full_title` carries the real, untruncated track title separately,
        // so the bridge's download history/pending-downloads/notifications/embedded
        // metadata tag always reflect the full title rather than a filename-safe
        // truncation of it (previously the bridge had no way to tell the two
        // apart, since only `title` — already shortened here — was ever sent, so
        // every title-consuming surface downstream silently inherited the
        // truncation meant only for the on-disk filename).
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "id",       value: track.id),
            URLQueryItem(name: "source",   value: track.source),
            URLQueryItem(name: "format",   value: fmt),
            URLQueryItem(name: "title",    value: safeName),
            URLQueryItem(name: "full_title", value: track.title),
            URLQueryItem(name: "artist",   value: track.artist),
            URLQueryItem(name: "thumbnail", value: track.thumbnailURL),
            URLQueryItem(name: "duration", value: String(track.durationSeconds)),
        ]
        if track.source == "soundcloud" || track.source == "bandcamp" {
            queryItems.append(URLQueryItem(name: "url", value: track.youtubeURL))
        }
        if let destinationFolderName, !destinationFolderName.isEmpty {
            queryItems.append(URLQueryItem(name: "destination_folder", value: destinationFolderName))
        }
        // Per-user aria2 preference (Settings → yt-dlp). Off by default — the
        // bridge uses its native downloader unless this is true. Only send when
        // enabled to keep the default request unchanged.
        if UserDefaults.standard.bool(forKey: "ytdlp_use_aria2") {
            queryItems.append(URLQueryItem(name: "use_aria2", value: "true"))
        }
        // Per-user download tuning (Settings → yt-dlp). Throttle controls the
        // anti-bot sleep (0 = fastest); concurrent fragments parallelises large
        // downloads. Only send when they differ from the bridge defaults.
        let throttle = UserDefaults.standard.object(forKey: "ytdlp_throttle_seconds") as? Int ?? 5
        if throttle != 5 {
            queryItems.append(URLQueryItem(name: "throttle_seconds", value: String(max(0, min(60, throttle)))))
        }
        let concurrentFrags = UserDefaults.standard.object(forKey: "ytdlp_concurrent_fragments") as? Int ?? 8
        appLog("downloadToLibrary: job-based /api/download for \"\(track.title)\" [fmt: \(fmt), aria2: \(aria2Enabled), throttle: \(throttle)s, concurrentFrags: \(concurrentFrags)]", category: "network")
        if concurrentFrags != 8 {
            queryItems.append(URLQueryItem(name: "concurrent_fragments", value: String(max(1, min(16, concurrentFrags)))))
        }
        // Defense-in-depth: also tell the bridge what the client already has, so
        // a stale/incomplete `existingSongs` snapshot still gets server-side dedupe.
        // (manifest computed earlier, alongside the fast-path block above.)
        if !manifest.isEmpty {
            queryItems.append(URLQueryItem(name: "existing_ids", value: manifest))
        }

        var components = URLComponents()
        components.path = "/api/download"
        components.queryItems = queryItems

        guard var request = makeRequest(components.string ?? "/api/download") else {
            throw StreamingError.invalidURL
        }
        // Lets the bridge record this download in the account's server-side
        // download history (My Library search, previously-downloaded restore).
        if let accountToken = AccountService.shared?.token {
            request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }

        // Big playlists hammer the bridge's yt-dlp pipeline hard enough that some
        // tracks come back truncated or with invalid audio data even though the
        // HTTP transfer "succeeds". Retry the whole download a few times — with a
        // fresh temp file and a full integrity check each time — before giving up,
        // so a single flaky fetch doesn't leave a corrupt file in the library.
        let maxAttempts = 3
        var lastError: Error = StreamingError.corruptDownload

        for attempt in 1...maxAttempts {
            do {
                let attemptStartedAt = Date()
                let destURL = try await attemptDownload(
                    track: track,
                    request: request,
                    safeName: safeName,
                    requestedExt: requestedExt,
                    importDir: importDir,
                    reportExistingAsSkipped: reportExistingAsSkipped
                )
                if attempt != 1 {
                    appLog("downloadToLibrary: succeeded for \"\(track.title)\" on attempt \(attempt)/\(maxAttempts)", category: "network")
                }
                appLog("downloadToLibrary: verified result for \"\(track.title)\" in \(String(format: "%.2f", Date().timeIntervalSince(attemptStartedAt)))s [attempt \(attempt)/\(maxAttempts)]", category: "network")
                DownloadLedgerStore.shared.record(sourceTrackID: sourceTrackID, filename: destURL.lastPathComponent)
                return await finalizeAndLockDownload(destURL: destURL, track: track)
            } catch let error as StreamingError {
                switch error {
                case .incompleteDownload, .corruptDownload:
                    lastError = error
                    appWarn("downloadToLibrary: attempt \(attempt)/\(maxAttempts) failed for \"\(track.title)\": \(error.localizedDescription)", category: "network")
                    continue
                default:
                    // Not-found / timeout / HTTP errors are unlikely to be fixed by retrying.
                    throw error
                }
            }
        }

        throw lastError
    }

    /// Tags a freshly-downloaded plain file, then converts+locks it to the
    /// real Lumisound-exclusive format (see `LumisoundLockFormat`)
    /// SYNCHRONOUSLY, right here, before the caller ever hands the returned
    /// URL back to the library/UI — this is the "hold until conversion +
    /// metadata finishes" the vault system was originally supposed to do:
    /// a track becomes visible/playable in the library already locked, not
    /// as a plain, unmasked file that only gets converted (and the original
    /// only gets deleted) on some later background pass. Falls back to
    /// returning the plain, tagged-but-not-yet-converted `destURL` if the
    /// convert/lock/verify step fails for any reason (network hiccup mid
    /// re-encode, disk pressure, etc.) — that's still fully playable and
    /// self-healing: `LumisoundTrackVaultService.runExtensionConversionPass`
    /// picks up any tagged-not-converted track on its next pass, same
    /// safety net as before this change, just no longer the ONLY path a
    /// normal download takes to get there.
    func finalizeAndLockDownload(destURL: URL, track: StreamTrack) async -> URL {
        let lockStartedAt = Date()
        LumisoundTrackVaultService.tagNewDownload(fileURL: destURL, trackID: track.sourceTrackID, sourceURL: track.youtubeURL)
        // `convert` itself logs the detailed before/after (sizes, verify
        // result) on success and the specific failing step on failure — this
        // just marks the fallback so it's visible in the log stream that
        // THIS track missed the synchronous hold and will only pick up the
        // real lock on the next background `runExtensionConversionPass`.
        guard let lockedURL = await LumisoundExclusiveExtensionService.convert(fileURL: destURL) else {
            appWarn("finalizeAndLockDownload: synchronous lock failed for \"\(track.title)\" after \(String(format: "%.2f", Date().timeIntervalSince(lockStartedAt)))s — returning plain file, will retry on next background conversion pass", category: "network")
            return destURL
        }
        appLog("finalizeAndLockDownload: \"\(track.title)\" locked synchronously at download time -> \(lockedURL.lastPathComponent) in \(String(format: "%.2f", Date().timeIntervalSince(lockStartedAt)))s", category: "network")
        // `convert` writes a brand new inode — re-apply the xattr vault tag
        // here using the trackID/sourceURL we just tagged `destURL` with,
        // same as `LibraryManager.convertToLumisoundExclusiveExtension`
        // does for the background-pass path — otherwise every synchronously
        // -locked download would silently lose its dedup fallback tag.
        await Task.detached(priority: .utility) {
            LumisoundTrackTagger.tag(fileURL: lockedURL, trackID: track.sourceTrackID, sourceURL: track.youtubeURL)
        }.value
        // Every caller of this function (attemptDownload's job-based path,
        // both faster-transport paths, and prepareExistingLocalCopy) records
        // the ledger with destURL's PRE-lock filename right before calling
        // this — but `convert` above just deleted that file and created a
        // differently-named one (see LumisoundExclusiveExtensionService's
        // header comment: outer ".lms" marker appended on top of the real
        // extension). Re-point the ledger at the actual post-lock filename
        // here, unconditionally, or the stale pre-lock entry left behind
        // fails BOTH `resolveDownloadDestination`'s ledger check and
        // `presentSourceIDs`'s "is the recorded filename still on disk"
        // filter the moment this returns — since that filename no longer
        // exists, both report the track as missing despite a perfectly
        // good locked copy sitting right there, and the next tracked-
        // playlist/subscription auto-download check re-downloads it via
        // yt-dlp from scratch. Confirmed as the actual cause of "keeps
        // re-downloading tracks that already exist locally as locked
        // files" — this is the common/happy path (see this function's own
        // header comment), so essentially every synchronously-locked
        // download hit it. `reconcilePendingDownloads.importPendingDownload`
        // already gets this right (records AFTER its own inline convert
        // call) — this brings the foreground path in line with that.
        DownloadLedgerStore.shared.record(sourceTrackID: track.sourceTrackID, filename: lockedURL.lastPathComponent)
        return lockedURL
    }

    /// Performs a single download attempt for `downloadToLibrary`, including the
    /// HTTP request, completeness check, move-into-place, and an `AVAudioFile`
    /// integrity check on the final file. Throws `.incompleteDownload` or
    /// `.corruptDownload` on failure so the caller can retry.
    func attemptDownload(
        track: StreamTrack,
        request: URLRequest,
        safeName: String,
        requestedExt: String,
        importDir: URL,
        reportExistingAsSkipped: Bool
    ) async throws -> URL {
        // /api/download is async: it returns a job_id immediately (status 202)
        // instead of holding the connection open for the whole yt-dlp run. A
        // synchronous design here routinely exceeded the Cloudflare Tunnel's
        // ~100s edge timeout for normal-length tracks, causing 524s followed by
        // from-scratch retries that piled onto the bridge and made every
        // subsequent request slower (a runaway retry storm).
        var startRequest = request
        startRequest.timeoutInterval = 30

        let startData: Data
        let startResponse: URLResponse
        do {
            (startData, startResponse) = try await Core.data(for: startRequest)
        } catch {
            // A raw URLError (e.g. .timedOut) here isn't a StreamingError, so the
            // outer retry loop's `catch let error as StreamingError` wouldn't see
            // it — the whole downloadToLibrary call would abort with no retry at
            // all. Map it to .incompleteDownload so a flaky/slow start request
            // (the bridge under load) gets retried like any other transient failure.
            appWarn("downloadToLibrary: network error starting job for \"\(track.title)\": \(error.localizedDescription) — will retry", category: "network")
            throw StreamingError.incompleteDownload
        }
        guard let startHTTP = startResponse as? HTTPURLResponse else {
            throw StreamingError.invalidURL
        }

        switch startHTTP.statusCode {
        case 202:
            break
        case 408:
            appWarn("downloadToLibrary: timeout for \"\(track.title)\"", category: "network")
            throw StreamingError.timeout
        case 404:
            appWarn("downloadToLibrary: not found for \"\(track.title)\"", category: "network")
            throw StreamingError.notFound(track.title)
        case 502, 503, 504, 524:
            appWarn("downloadToLibrary: gateway error \(startHTTP.statusCode) for \"\(track.title)\" — will retry", category: "network")
            throw StreamingError.incompleteDownload
        default:
            // Includes 204 ("client already has this track" per existing_ids) —
            // this track's own id is excluded from that manifest, so 204 here
            // would be unexpected; treat it like an incomplete result so the
            // retry loop re-fetches rather than adopting an empty file.
            appWarn("downloadToLibrary: unexpected start status \(startHTTP.statusCode) for \"\(track.title)\"", category: "network")
            throw StreamingError.incompleteDownload
        }

        struct StartPayload: Decodable { let job_id: String }
        guard let start = try? JSONDecoder().decode(StartPayload.self, from: startData) else {
            throw StreamingError.incompleteDownload
        }
        appLog("downloadToLibrary: yt-dlp job started job=\(start.job_id) source=\(track.source):\(track.id) title=\"\(track.title)\"", category: "network")

        guard let statusURL = jobPollURL(from: startRequest, path: "/api/download/status", jobID: start.job_id),
              let resultURL = jobPollURL(from: startRequest, path: "/api/download/result", jobID: start.job_id) else {
            throw StreamingError.invalidURL
        }

        var statusRequest = startRequest
        statusRequest.url = statusURL

        struct StatusPayload: Decodable {
            let status: String
            let code: Int?
            let detail: String?
            /// Set by the bridge when the failure is a property of the VIDEO
            /// (removed, private, terminated channel) rather than of our session
            /// or the network — see `_ytdlp_failure_is_permanent` there. Both
            /// cases arrive as a 404, so this flag is the only way to tell them
            /// apart; absent on an older bridge, which is read as "not
            /// permanent" so nothing is suppressed on a guess.
            let permanent: Bool?
        }

        // Poll for up to 5 minutes — matches the previous client-side timeout,
        // and each poll is a trivial dict lookup (<1s), so this never approaches
        // the tunnel's ~100s edge timeout regardless of how long yt-dlp itself
        // takes on the bridge.
        //
        // The interval RAMPS rather than sitting flat at 3s. The first poll is
        // immediate either way, so what a flat interval cost was the tail: a job
        // that finished just after a poll went unnoticed for the remainder of the
        // interval, averaging 1.5s of pure dead time per download and up to 3s.
        // With the bridge's own per-download time now around 9s rather than 17s
        // (the anti-bot sleep moved out of the download — see _LaunchPacer
        // there), that stopped being noise: it is a sixth of the remaining wall
        // time, charged once per track across a several-hundred-track playlist.
        //
        // Ramping keeps that responsiveness for the fast case without making a
        // genuinely slow job expensive to wait on: a download that really takes
        // minutes settles at the same 3s cadence it always used, so the poll
        // count for slow jobs is unchanged.
        let pollIntervals: [TimeInterval] = [0.4, 0.6, 1.0, 1.5, 2.0, 2.5]
        let maxPollInterval: TimeInterval = 3.0
        var pollAttempt = 0
        func nextPollDelay() -> TimeInterval {
            defer { pollAttempt += 1 }
            return pollAttempt < pollIntervals.count ? pollIntervals[pollAttempt] : maxPollInterval
        }

        let deadline = Date().addingTimeInterval(300)
        var lastLoggedStatus: String?
        pollLoop: while true {
            if Date() > deadline {
                appWarn("downloadToLibrary: job poll timed out for \"\(track.title)\"", category: "network")
                throw StreamingError.incompleteDownload
            }
            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await Core.data(for: statusRequest)
            } catch {
                // A single slow/timed-out status poll (the bridge can be briefly
                // CPU-busy under load) shouldn't abort the whole job — wait and
                // poll again rather than letting a raw URLError escape uncaught.
                appWarn("downloadToLibrary: network error polling status for \"\(track.title)\": \(error.localizedDescription) — retrying poll", category: "network")
                // A failed poll deliberately waits the full cap rather than a
                // ramp step: the bridge being briefly unreachable is the one case
                // where polling harder is actively unhelpful.
                try await Task.sleep(nanoseconds: UInt64(maxPollInterval * 1_000_000_000))
                continue pollLoop
            }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let status = try? JSONDecoder().decode(StatusPayload.self, from: data) else {
                throw StreamingError.incompleteDownload
            }
            switch status.status {
            case "pending":
                if lastLoggedStatus != "pending" {
                    appLog("downloadToLibrary: yt-dlp job=\(start.job_id) status=pending", category: "network")
                    lastLoggedStatus = "pending"
                }
                try await Task.sleep(nanoseconds: UInt64(nextPollDelay() * 1_000_000_000))
                continue pollLoop
            case "done":
                appLog("downloadToLibrary: yt-dlp job=\(start.job_id) status=done after \(String(format: "%.2f", 300 - deadline.timeIntervalSinceNow))s", category: "network")
                break pollLoop
            case "error":
                appWarn("downloadToLibrary: yt-dlp job=\(start.job_id) status=error code=\(status.code ?? 0) detail=\(status.detail ?? "")", category: "network")
                switch status.code {
                case 408:
                    appWarn("downloadToLibrary: timeout for \"\(track.title)\"", category: "network")
                    throw StreamingError.timeout
                case 404:
                    if status.permanent == true {
                        // Remembered so every later pass stops asking. Only ever
                        // on the bridge's say-so — see DownloadFailureStore.
                        // Built from `track` rather than reusing an outer
                        // binding: this poll loop lives in its own function which
                        // declares its own `sourceTrackID` further down, so
                        // referring to that one here would read it before its
                        // declaration.
                        DownloadFailureStore.shared.recordPermanentFailure(
                            sourceTrackID: "\(track.source):\(track.id)")
                        appWarn("downloadToLibrary: \"\(track.title)\" is permanently unavailable (\(status.detail ?? "no detail")) — suppressing future attempts", category: "network")
                    } else {
                        appWarn("downloadToLibrary: not found for \"\(track.title)\" — \(status.detail ?? "no detail")", category: "network")
                    }
                    throw StreamingError.notFound(track.title)
                case 502, 503, 504, 524:
                    appWarn("downloadToLibrary: job failed with gateway error \(status.code ?? 0) for \"\(track.title)\" — will retry", category: "network")
                    throw StreamingError.incompleteDownload
                case 422:
                    // Bridge-confirmed "this specific track can't be extracted" — a
                    // specific, non-retryable, user-actionable reason rather than a
                    // generic failure.
                    let detail = status.detail ?? "This track can't be downloaded due to a YouTube content restriction."
                    appWarn("downloadToLibrary: unavailable for \"\(track.title)\": \(detail)", category: "network")
                    throw StreamingError.serverDetail(detail)
                default:
                    appError("downloadToLibrary: job failed (\(status.code ?? 0)) for \"\(track.title)\": \(status.detail ?? "")", category: "network")
                    throw StreamingError.httpError(status.code ?? 500)
                }
            default:
                throw StreamingError.incompleteDownload
            }
        }

        var resultRequest = startRequest
        resultRequest.url = resultURL
        resultRequest.timeoutInterval = 120

        let downloadedURL: URL
        let response: URLResponse
        do {
            (downloadedURL, response) = try await BackgroundDownloadManager.run(
                named: "lumisound.download.\(safeName)"
            ) {
                try await StreamingService.bulkTransferSession.download(for: resultRequest)
            }
        } catch {
            // Same as the start/poll requests: a raw URLError here would otherwise
            // escape uncaught and abort the whole pipeline instead of retrying.
            appWarn("downloadToLibrary: network error fetching result for \"\(track.title)\": \(error.localizedDescription) — will retry", category: "network")
            throw StreamingError.incompleteDownload
        }
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200..<300:
                break
            case 404:
                // The bridge deletes a finished job's durable copy the first
                // time it's served (see /api/download/result). If the app
                // was backgrounded (not killed) while this exact poll loop
                // was in flight, iOS can suspend and later resume it well
                // after the job finished — by then, StreamingService's own
                // background reconciliation (see
                // StreamingService+PendingDownloads.swift, fired on app
                // launch/foreground) may have already claimed and imported
                // this same job first. Blindly retrying here would both
                // waste a full re-download AND risk a duplicate copy under
                // a slightly different filename, since the retry loop
                // doesn't re-run this function's own pre-download dedupe
                // check. Check the ledger for a copy that landed via that
                // path before concluding this was a real failure.
                try? FileManager.default.removeItem(at: downloadedURL)
                let sourceTrackID = "\(track.source):\(track.id)"
                if let existingName = DownloadLedgerStore.shared.filename(for: sourceTrackID) {
                    let existingURL = importDir.appendingPathComponent(existingName)
                    let existingIsValid = await Task.detached(priority: .utility) {
                        FileManager.default.fileExists(atPath: existingURL.path) &&
                            CorruptFileFinderService.isValidAudioFile(at: existingURL)
                    }.value
                    if existingIsValid {
                        appLog("downloadToLibrary: \"\(track.title)\" was already imported via background reconciliation while this poll was in flight — adopting it", category: "network")
                        if let preparedURL = await prepareExistingLocalCopy(existingURL, track: track) {
                            if reportExistingAsSkipped { throw StreamingError.alreadyDownloaded }
                            return preparedURL
                        }
                    }
                }
                appWarn("downloadToLibrary: HTTP 404 fetching result for \"\(track.title)\" and no reconciled copy found — will retry", category: "network")
                throw StreamingError.incompleteDownload
            default:
                appError("downloadToLibrary: HTTP \(httpResponse.statusCode) fetching result for \"\(track.title)\"", category: "network")
                throw StreamingError.incompleteDownload
            }
        }

        // Verify the downloaded file is complete before adopting it into the library.
        // A truncated download (dropped connection, app suspended mid-transfer, etc.)
        // would otherwise sit in the library as a track that shows "0:00" forever.
        let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: downloadedURL.path))?[.size] as? Int64 ?? 0
        let expectedSize = (response as? HTTPURLResponse)?.expectedContentLength ?? -1
        if downloadedSize <= 0 || (expectedSize > 0 && downloadedSize != expectedSize) {
            try? FileManager.default.removeItem(at: downloadedURL)
            appWarn("downloadToLibrary: incomplete download for \"\(track.title)\" (\(downloadedSize)/\(expectedSize) bytes)", category: "network")
            throw StreamingError.incompleteDownload
        }

        // The bridge can fall back to a different container than requested (e.g. yt-dlp
        // has no native m4a stream for this video and serves webm/opus instead while
        // `format=m4a` was requested) — `_download_format_args` on the bridge already
        // reflects this in the `Content-Type` header. Saving such a file with a `.m4a`
        // extension makes AVAudioFile misparse it (it picks a decoder based on the file
        // extension): playback's timer keeps advancing from the engine's render clock
        // while no audio is actually decoded, which is the "silently lands ~1 minute in"
        // bug. Trust the response's actual content type over the requested format.
        let actualExt = extensionForContentType(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        ) ?? requestedExt
        let sourceTrackID = "\(track.source):\(track.id)"
        let (destURL, alreadyComplete) = await resolveDownloadDestination(
            preferred: importDir.appendingPathComponent("\(safeName).\(actualExt)"),
            sourceTrackID: sourceTrackID
        )

        if alreadyComplete {
            try? FileManager.default.removeItem(at: downloadedURL)
            appLog("downloadToLibrary: already exists, skipping \(destURL.lastPathComponent)", category: "network")
            if let preparedURL = await prepareExistingLocalCopy(destURL, track: track) {
                if reportExistingAsSkipped { throw StreamingError.alreadyDownloaded }
                return preparedURL
            }
            appWarn("downloadToLibrary: resolved existing copy could not be locked — continuing with downloaded file", category: "network")
        }

        do {
            try FileManager.default.moveItem(at: downloadedURL, to: destURL)
        } catch {
            // Records WHAT it tried to move to, not just that it failed. The
            // previous message named only the track, which was not enough to tell
            // a name collision from a destination that had collapsed to a
            // directory — the two look identical in the error text and need
            // completely different fixes.
            var isDir: ObjCBool = false
            let destExists = FileManager.default.fileExists(atPath: destURL.path, isDirectory: &isDir)
            appError("downloadToLibrary: move failed for \"\(track.title)\" -> \(destURL.path) "
                     + "(exists: \(destExists), isDirectory: \(isDir.boolValue), "
                     + "ext: \(destURL.pathExtension), dir: \(importDir.lastPathComponent)): \(error)",
                     category: "network")
            throw error
        }
        if actualExt != requestedExt {
            appLog("downloadToLibrary: bridge returned .\(actualExt) instead of requested .\(requestedExt) for \"\(track.title)\" — saved with correct extension", category: "network")
        }

        // Final integrity check: the byte count matched what the server promised, but
        // yt-dlp can still emit a file AVAudioFile can't decode (corrupt remux, dropped
        // moov atom, etc.) — exactly what CorruptFileFinderService flags later. Catch it
        // immediately so the retry loop can re-fetch instead of leaving a dead file behind.
        // `expectedDuration` additionally catches a well-formed-but-truncated file —
        // see that parameter's doc comment on CorruptFileFinderService.isValidAudioFile.
        let isValid = await Task.detached(priority: .utility) {
            CorruptFileFinderService.isValidAudioFile(at: destURL, expectedDuration: track.duration)
        }.value
        guard isValid else {
            try? FileManager.default.removeItem(at: destURL)
            appWarn("downloadToLibrary: corrupt/unreadable/truncated file for \"\(track.title)\" — discarding", category: "network")
            throw StreamingError.corruptDownload
        }

        appLog("Download complete: \(destURL.lastPathComponent)", category: "network")

        // Pre-seed the artwork cache with the track's thumbnail so it's immediately
        // available when scanLocalDocuments() creates the Song for this file.
        await prefetchArtworkWithFallback(for: track, cacheKey: destURL.lastPathComponent)

        return destURL
    }

    /// Makes every dedupe hit pass through the same vault-tag/convert/lock
    /// pipeline as a newly downloaded file. Older `.lms` files may have the
    /// marker extension without the real lock, so relock those off-main.
    private func prepareExistingLocalCopy(_ url: URL, track: StreamTrack) async -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if LumisoundExclusiveExtensionService.isConverted(url) {
            if LumisoundLockFormat.isLocked(at: url) { return url }
            let relocked = await Task.detached(priority: .utility) {
                LumisoundExclusiveExtensionService.relockLegacyFile(at: url)
            }.value
            return relocked && LumisoundLockFormat.isLocked(at: url) ? url : nil
        }

        let lockedURL = await finalizeAndLockDownload(destURL: url, track: track)
        guard LumisoundExclusiveExtensionService.isConverted(lockedURL),
              LumisoundLockFormat.isLocked(at: lockedURL)
        else { return nil }
        return lockedURL
    }

    // MARK: - Faster transports (tried before the job-based flow above)

    /// SoundCloud/Bandcamp only: resolves the raw CDN URL via `/api/stream`
    /// (already used elsewhere for playback resolution) and fetches it
    /// DIRECTLY from the phone — no bridge hop for the actual bytes at all.
    /// Unlike YouTube's `googlevideo` URLs, SoundCloud/Bandcamp CDN URLs are
    /// not confirmed to be IP-locked to the resolving server (nothing in the
    /// bridge asserts either way) — this is a genuine "try it" attempt. Any
    /// failure (including a 403 if it turns out these ARE IP-locked too)
    /// throws, and the caller falls through to `attemptRelayDownload`.
    private func attemptDirectFetch(track: StreamTrack, safeName: String, importDir: URL) async throws -> URL {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "id", value: track.id),
            URLQueryItem(name: "source", value: track.source),
            URLQueryItem(name: "format", value: preferredFormat),
        ]
        queryItems.append(URLQueryItem(name: "url", value: track.youtubeURL))

        var components = URLComponents()
        components.path = "/api/stream"
        components.queryItems = queryItems

        guard var resolveRequest = makeRequest(components.string ?? "/api/stream") else {
            throw StreamingError.invalidURL
        }
        if let accountToken = AccountService.shared?.token {
            resolveRequest.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }
        resolveRequest.timeoutInterval = 15

        let (resolveData, resolveResponse) = try await Core.data(for: resolveRequest)
        guard let resolveHTTP = resolveResponse as? HTTPURLResponse, resolveHTTP.statusCode == 200 else {
            throw StreamingError.invalidURL
        }
        struct ResolvedURL: Decodable { let url: String }
        guard let resolved = try? JSONDecoder().decode(ResolvedURL.self, from: resolveData),
              let rawURL = URL(string: resolved.url) else {
            throw StreamingError.invalidURL
        }

        var fetchRequest = URLRequest(url: rawURL)
        fetchRequest.timeoutInterval = 120
        let (rawFileURL, fetchResponse) = try await BackgroundDownloadManager.run(
            named: "lumisound.download.direct.\(safeName)"
        ) {
            try await StreamingService.bulkTransferSession.download(for: fetchRequest)
        }
        guard let fetchHTTP = fetchResponse as? HTTPURLResponse, (200..<300).contains(fetchHTTP.statusCode) else {
            try? FileManager.default.removeItem(at: rawFileURL)
            throw StreamingError.incompleteDownload
        }

        return try await finalizeRelayedFile(
            rawFileURL: rawFileURL, track: track, safeName: safeName, importDir: importDir
        )
    }

    /// Any source, m4a format only (see the exclusion of "best" above): fetches
    /// `/api/download/relay` — the bridge resolves the CDN URL and streams bytes
    /// through as they arrive, instead of the job-based flow's "server downloads
    /// the whole file, THEN the client downloads that" sequential double-transfer.
    /// No metadata is embedded by this endpoint (see its doc comment on the
    /// bridge) — `finalizeRelayedFile` handles tagging on-device.
    private func attemptRelayDownload(track: StreamTrack, safeName: String, importDir: URL, existingIDs: String) async throws -> URL {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "id", value: track.id),
            URLQueryItem(name: "source", value: track.source),
            URLQueryItem(name: "format", value: preferredFormat),
            URLQueryItem(name: "title", value: safeName),
        ]
        if track.source == "soundcloud" || track.source == "bandcamp" {
            queryItems.append(URLQueryItem(name: "url", value: track.youtubeURL))
        }
        // Defense-in-depth dedupe, mirroring the job-based path below — this
        // endpoint has no yt-dlp job to naturally slot an ownership check into,
        // so without this the relay path would re-fetch from the CDN even for a
        // track the server-side inventory already knows is owned (e.g. synced
        // from another device, not yet reflected in this device's local library).
        if !existingIDs.isEmpty {
            queryItems.append(URLQueryItem(name: "existing_ids", value: existingIDs))
        }

        var components = URLComponents()
        components.path = "/api/download/relay"
        components.queryItems = queryItems

        guard var request = makeRequest(components.string ?? "/api/download/relay") else {
            throw StreamingError.invalidURL
        }
        if let accountToken = AccountService.shared?.token {
            request.setValue(accountToken, forHTTPHeaderField: "X-Account-Token")
        }
        request.timeoutInterval = 180

        let (rawFileURL, response) = try await BackgroundDownloadManager.run(
            named: "lumisound.download.relay.\(safeName)"
        ) {
            try await StreamingService.bulkTransferSession.download(for: request)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: rawFileURL)
            throw StreamingError.incompleteDownload
        }
        let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: rawFileURL.path))?[.size] as? Int64 ?? 0
        let expectedSize = http.expectedContentLength
        if downloadedSize <= 0 || (expectedSize > 0 && downloadedSize != expectedSize) {
            try? FileManager.default.removeItem(at: rawFileURL)
            throw StreamingError.incompleteDownload
        }

        return try await finalizeRelayedFile(
            rawFileURL: rawFileURL, track: track, safeName: safeName, importDir: importDir
        )
    }

    /// Shared tail for both faster-transport paths above: tags the raw
    /// downloaded file on-device (see `AudioTagWriter`), moves it into place,
    /// validates it, and pre-seeds the artwork cache — mirroring the
    /// equivalent steps in `attemptDownload` for the job-based path. Both
    /// faster paths only ever produce m4a-compatible containers.
    private func finalizeRelayedFile(
        rawFileURL: URL, track: StreamTrack, safeName: String, importDir: URL
    ) async throws -> URL {
        let sourceTrackID = "\(track.source):\(track.id)"
        let taggedURL = await AudioTagWriter.tag(
            fileAt: rawFileURL,
            title: track.title,
            artist: track.artist,
            album: nil,
            sourceTrackID: sourceTrackID,
            thumbnailURL: track.thumbnailURL
        )
        let finalRawURL = taggedURL ?? rawFileURL
        if taggedURL != nil {
            try? FileManager.default.removeItem(at: rawFileURL)
        } else {
            appWarn("finalizeRelayedFile: on-device tagging failed for \"\(track.title)\" — importing untagged", category: "network")
        }

        let (destURL, alreadyComplete) = await resolveDownloadDestination(
            preferred: importDir.appendingPathComponent("\(safeName).m4a"),
            sourceTrackID: sourceTrackID
        )
        if alreadyComplete {
            try? FileManager.default.removeItem(at: finalRawURL)
            return destURL
        }
        do {
            try FileManager.default.moveItem(at: finalRawURL, to: destURL)
        } catch {
            appError("finalizeRelayedFile: move failed for \"\(track.title)\": \(error)", category: "network")
            throw error
        }

        let isValid = await Task.detached(priority: .utility) {
            CorruptFileFinderService.isValidAudioFile(at: destURL, expectedDuration: track.duration)
        }.value
        guard isValid else {
            try? FileManager.default.removeItem(at: destURL)
            appWarn("finalizeRelayedFile: corrupt/unreadable/truncated file for \"\(track.title)\" — discarding", category: "network")
            throw StreamingError.corruptDownload
        }

        appLog("Download complete: \(destURL.lastPathComponent)", category: "network")
        await prefetchArtworkWithFallback(for: track, cacheKey: destURL.lastPathComponent)
        return destURL
    }

    /// Resolves a safe, non-colliding destination path for a track about to be
    /// moved into place. A filename collision at `preferred` does NOT necessarily
    /// mean "we already have this track" — titles routinely collide (different
    /// artists' same-titled songs, covers, remasters), and a stale/partial file
    /// from an interrupted previous download can share the same name too.
    /// Trusting a bare filename match here was the cause of two user-visible
    /// bugs: a different track silently never downloading because it happened to
    /// share a sanitized filename with something already on disk, and the app
    /// reporting a track as "downloaded" when the file at that path was actually
    /// corrupt or belonged to a different track entirely.
    ///
    /// Only treats an existing file as "this exact track, already downloaded" if
    /// the download ledger confirms *this* `sourceTrackID` is the one that
    /// produced that exact filename, AND the file still passes an audio
    /// integrity check. Otherwise returns a disambiguated sibling path
    /// ("Title (2).ext", "Title (3).ext", ...) so the real download can proceed
    /// without clobbering or being silently mistaken for something else.
    func resolveDownloadDestination(preferred: URL, sourceTrackID: String) async -> (url: URL, alreadyComplete: Bool) {
        let fm = FileManager.default
        let dir = preferred.deletingLastPathComponent()

        // Consult the ledger BEFORE checking whether `preferred`'s own path
        // exists — a track that's already been downloaded AND converted
        // (LumisoundExclusiveExtensionService.convert re-encodes to a fresh
        // "<name>.m4a.lms" and deletes the original) no longer has anything
        // at `preferred`'s original requested extension at all, even though
        // it's fully, correctly downloaded. Checking `preferred` first (as
        // this used to) made every already-converted track look
        // undownloaded here, so a later reconciliation pass for the same
        // pending job re-downloaded and re-converted it from scratch —
        // confirmed from real client logs: the same 2 tracks re-imported and
        // re-converted 4 times over ~2 minutes, fully wasted bandwidth/CPU
        // each time since the result was identical. The ledger's recorded
        // filename is the only thing that still points at where a track
        // actually lives post-conversion.
        // A name that resolves back to `dir` itself is rejected rather than used.
        // `appendingPathComponent("")` and `appendingPathComponent(".")` both
        // return the DIRECTORY, and a directory passes `fileExists`, so a bad
        // entry here could hand back the folder as though it were the track — and
        // the caller would then try to move a download onto its own destination
        // folder. Field logs show exactly that shape: a move refused because
        // "an item with the same name already exists", where the name given was a
        // folder, not a file. The origin of such an entry is still unaccounted
        // for, so this refuses the impossible value instead of assuming where it
        // came from.
        if let ledgerName = DownloadLedgerStore.shared.filename(for: sourceTrackID),
           !ledgerName.isEmpty,
           dir.appendingPathComponent(ledgerName).standardizedFileURL != dir.standardizedFileURL {
            let ledgerURL = dir.appendingPathComponent(ledgerName)
            let ledgerIsValid = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: ledgerURL.path) &&
                    CorruptFileFinderService.isValidAudioFile(at: ledgerURL)
            }.value
            if ledgerIsValid {
                return (ledgerURL, true)
            }
        }

        guard fm.fileExists(atPath: preferred.path) else {
            return (preferred, false)
        }
        return (URL(fileURLWithPath: uniqueDestination(preferred: preferred.path)), false)
    }

    /// Builds the `/api/download/status` or `/api/download/result` URL for a given
    /// job, reusing the scheme/host/port/auth of the original `/api/download`
    /// request but replacing the path and query with `job_id=`.
    func jobPollURL(from request: URLRequest, path: String, jobID: String) -> URL? {
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.queryItems = [URLQueryItem(name: "job_id", value: jobID)]
        return components.url
    }

    /// Maps a format value to the appropriate file extension.
    func fileExtension(for format: String) -> String {
        downloadExtension(format: format)
    }

    func extensionForContentType(_ contentType: String?) -> String? {
        contentTypeExtension(contentType: contentType)
    }

    // MARK: - Artwork prefetch with fallback

    /// Prefetches thumbnail artwork for a freshly-downloaded track, verifying
    /// the primary thumbnail URL is actually reachable first and falling back
    /// to YouTube's guaranteed-to-exist `hqdefault.jpg` when it isn't.
    ///
    /// The bridge already picks a sensible thumbnail (`_pick_youtube_thumbnail`
    /// in main.py prefers dimensioned/confirmed entries over yt-dlp's raw
    /// guesses), but a URL that was valid at search/resolve time can still be
    /// stale/expired by the time a download finishes, and non-YouTube
    /// extractors don't get the same server-side treatment — so this is a
    /// second, client-side safety net rather than a duplicate of that fix.
    /// Without it, a 404/expired thumbnail silently left the track with no
    /// artwork at all instead of degrading to a lower-quality-but-working image.
    func prefetchArtworkWithFallback(for track: StreamTrack, cacheKey: String) async {
        guard !track.thumbnailURL.isEmpty, let primaryURL = URL(string: track.thumbnailURL) else {
            return
        }
        if await urlIsReachable(primaryURL) {
            await ArtworkService.shared.prefetchRemoteImage(url: primaryURL, forKey: cacheKey)
            return
        }
        appWarn("prefetchArtworkWithFallback: primary thumbnail unreachable for \"\(track.title)\" (\(primaryURL)) — trying fallback", category: "network")
        if track.source == "youtube", let fallbackURL = URL(string: "https://i.ytimg.com/vi/\(track.id)/hqdefault.jpg"),
           await urlIsReachable(fallbackURL) {
            await ArtworkService.shared.prefetchRemoteImage(url: fallbackURL, forKey: cacheKey)
            return
        }
        appWarn("prefetchArtworkWithFallback: no working thumbnail found for \"\(track.title)\" — leaving artwork empty", category: "network")
    }

    /// Lightweight, short-timeout, best-effort HEAD-request reachability check.
    private func urlIsReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        do {
            let (_, response) = try await Core.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
