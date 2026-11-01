import Foundation

// MARK: - TVLockedTrackCache
//
// Downloads and unlocks a Lumisound-locked (`.lms`) Personal Cloud Library
// track to a local temp file, so `TVPlayerModel` can hand AVFoundation
// something it can actually decode — see `TVLockFormat`'s header comment for
// why the raw bytes aren't playable as-is. Full-file, not incremental
// streaming (same tradeoff the native iOS app already makes for its own
// local `.lms` files — the XOR transform needs the whole payload up front),
// so this is consistent with existing behavior elsewhere in this app family,
// not a new architectural compromise introduced here.
//
// An `actor` rather than a plain class: `playableURL(for:)` is called from
// both `loadCurrent()` and `beginCrossfade()`, which can legitimately
// overlap (a crossfade starting into the next track while the current one is
// still resolving) — the actor serializes access to `inFlight` so two
// concurrent requests for the SAME track share one download instead of
// racing two separate ones.
actor TVLockedTrackCache {
    static let shared = TVLockedTrackCache()

    private var inFlight: [String: Task<URL?, Never>] = [:]

    /// Returns a local file URL AVFoundation can actually play. For a
    /// non-locked item this is just `item.streamURL` unchanged (no I/O). For
    /// a locked item, returns a cached unlocked copy if one already exists,
    /// otherwise downloads+unlocks (joining an in-flight request for the
    /// same track id rather than starting a second one), or `nil` if the
    /// download or unlock fails.
    func playableURL(for item: TVPlayable) async -> URL? {
        guard item.isLocked else { return item.streamURL }

        if let existing = inFlight[item.id] {
            return await existing.value
        }
        let task = Task<URL?, Never> {
            await Self.downloadAndUnlock(item: item)
        }
        inFlight[item.id] = task
        let result = await task.value
        inFlight[item.id] = nil
        return result
    }

    private static func downloadAndUnlock(item: TVPlayable) async -> URL? {
        let fm = FileManager.default
        // Caches directory, not temporaryDirectory: this is used as a
        // persistent-across-calls cache (the fileExists check below treats a
        // prior download as reusable), but tmp can be purged by the system
        // at ANY time, including mid-session — not just between launches the
        // way Caches is. A purge landing between this existence check and
        // AVFoundation actually reading the file would silently fall through
        // to the raw, undecodable stream in TVPlayerModel.resolvedAsset.
        // Caches is still purgeable under disk pressure, but only while the
        // app isn't running, which is the guarantee this cache actually needs.
        guard let cachesBase = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = cachesBase.appendingPathComponent("lumisound_tv_cloud_lms_playable", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let realExt = item.ext.isEmpty ? "m4a" : item.ext
        let outURL = dir.appendingPathComponent(item.id).appendingPathExtension(realExt)
        // Guard against a zero-byte leftover from an interrupted previous
        // write (e.g. the app was killed mid-unlock) being trusted as valid.
        if let size = try? fm.attributesOfItem(atPath: outURL.path)[.size] as? Int, size > 0 {
            TVRemoteLogger.log(category: "playback", event: "locked_track_cache_hit",
                               detail: ["title": item.title, "ext": realExt, "bytes": size],
                               authToken: item.authToken)
            return outURL
        }

        var request = URLRequest(url: item.streamURL)
        if let token = item.authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120

        let data: Data
        do {
            let (responseData, response) = try await Core.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                tvWarn("TVLockedTrackCache: bad response (\(status)) fetching \(item.title)", category: "playback")
                // The status code is the whole diagnosis here and the old
                // warning threw it away: 401 means the account token never
                // reached the request, 404 means the cloud path is wrong, 5xx
                // means the bridge failed — three different bugs that all
                // surfaced as a track that simply refused to play.
                TVRemoteLogger.logError(category: "playback", event: "locked_track_fetch_failed",
                                        message: "HTTP \(status)",
                                        detail: ["title": item.title, "status": status,
                                                 "hadAuthToken": item.authToken != nil,
                                                 "url": item.streamURL.path],
                                        authToken: item.authToken)
                return nil
            }
            data = responseData
        } catch {
            tvWarn("TVLockedTrackCache: download failed for \(item.title): \(error.localizedDescription)", category: "playback")
            let ns = error as NSError
            TVRemoteLogger.logError(category: "playback", event: "locked_track_download_failed",
                                    message: error.localizedDescription,
                                    detail: ["title": item.title, "errorDomain": ns.domain,
                                             "errorCode": ns.code, "hadAuthToken": item.authToken != nil],
                                    authToken: item.authToken)
            return nil
        }

        let lockedTempURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("lms")
        defer { try? fm.removeItem(at: lockedTempURL) }
        do {
            try data.write(to: lockedTempURL, options: .atomic)
        } catch {
            tvWarn("TVLockedTrackCache: write failed for \(item.title): \(error.localizedDescription)", category: "playback")
            TVRemoteLogger.logError(category: "playback", event: "locked_track_write_failed",
                                    message: error.localizedDescription,
                                    detail: ["title": item.title, "bytes": data.count],
                                    authToken: item.authToken)
            return nil
        }
        guard TVLockFormat.unlock(lockedURL: lockedTempURL, to: outURL) else {
            tvWarn("TVLockedTrackCache: unlock failed for \(item.title)", category: "playback")
            // Unlock failing on bytes that downloaded fine means the payload
            // wasn't actually a locked container — e.g. the bridge served an
            // error page, or the file was stored unlocked. Recording the first
            // bytes' shape distinguishes those without logging audio content.
            let head = (try? Data(contentsOf: lockedTempURL, options: .mappedIfSafe).prefix(8)) ?? Data()
            TVRemoteLogger.logError(category: "playback", event: "locked_track_unlock_failed",
                                    message: "TVLockFormat.unlock returned false",
                                    detail: ["title": item.title, "bytes": data.count,
                                             "looksLocked": head.starts(with: Array("LMSLOCK1".utf8)),
                                             "ext": realExt],
                                    authToken: item.authToken)
            return nil
        }
        let outSize = (try? fm.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        TVRemoteLogger.log(category: "playback", event: "locked_track_ready",
                           detail: ["title": item.title, "ext": realExt,
                                    "downloadedBytes": data.count, "unlockedBytes": outSize],
                           authToken: item.authToken)
        return outURL
    }
}
