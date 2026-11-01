import AVFoundation
import Foundation
import MediaPlayer
import UIKit

final class ArtworkService {
    static let shared = ArtworkService()

    /// Caps how many thumbnail decodes run at once, regardless of how many
    /// cells ask for one in the same instant.
    ///
    /// BUGFIX (reported: scrolling is fine until the grid is set to 3
    /// columns, where it lags the most): lowering the decode `Task`'s
    /// priority to `.utility` (previous fix) controls how the SCHEDULER
    /// favors this work relative to rendering, but not how MUCH of it runs
    /// at the same instant — priority is a scheduling hint, not a
    /// concurrency cap. A fast fling through a 3-column grid brings several
    /// more brand-new cells into view per scroll step than 1 or 2 columns
    /// do, each firing its own independent decode with no shared limit
    /// between them — a burst the CPU still has to absorb all at once
    /// regardless of priority, which is exactly why column count was the
    /// variable that mattered. Same actor-based semaphore shape as
    /// `LumisoundExclusiveExtensionService`'s own `ConvertConcurrencyLimiter`
    /// for its (unrelated) conversion pipeline. A low cap smooths a burst
    /// into a short queue instead of letting it all land on the CPU at once,
    /// at the cost of the tail of a big burst finishing a little later —
    /// imperceptible for a decode this cheap, unlike blocking on it.
    private actor DecodeConcurrencyLimiter {
        private let limit = 3
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
    private let thumbnailDecodeLimiter = DecodeConcurrencyLimiter()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL

    /// Small decoded-image cache for list/grid thumbnails. Rows only need
    /// ~100–540 physical px, but `memoryCache` stores full
    /// `artworkCacheDimension` decodes (~5.5 MB each) — serving rows from those
    /// churns the big cache while scrolling and re-decodes constantly.
    /// Bucketed thumbnails are 10–100× cheaper. Configured in `init`.
    private let thumbnailCache = NSCache<NSString, UIImage>()

    /// Thread-safe cache for MPMediaLibrary lookups keyed by persistentID.
    private let mediaQueryCache = NSCache<NSNumber, UIImage>()

    /// In-memory map of cache keys for which all artwork sources failed, to the
    /// moment that happened. Prevents repeated lookups (including remote API
    /// calls) for tracks that have no artwork — but only for a bounded cooldown
    /// (see `noArtworkCooldown`), not permanently.
    ///
    /// This used to be a plain `Set` with no expiry at all — a genuinely
    /// no-artwork track and one that just hit a transient network blip on its
    /// one and only YouTube-search/iTunes-search attempt (rate limit, a dropped
    /// request, momentarily poor connectivity) were treated identically:
    /// blacklisted for the rest of the session, full stop, with no way for the
    /// user to force a recheck short of relaunching the app. For anyone who
    /// keeps Lumisound open/backgrounded for hours (the common case), one bad
    /// moment on first scroll-past permanently locked a track's artwork blank
    /// for the entire session even with a perfectly good network the rest of
    /// the time — the "metadata's there but artwork just refuses to load"
    /// reports. A time-boxed cooldown keeps the original intent (don't hammer
    /// remote APIs on every single re-scroll of a track with no art) while
    /// letting a transient miss heal itself automatically within a few
    /// minutes instead of needing a full relaunch.
    ///
    /// `loadArtwork` is a plain (non-actor-isolated) async function invoked
    /// concurrently from many `ArtworkThumbnail.task` instances while scrolling
    /// plus the background `prefetch` loop, so it can run on different threads of
    /// the cooperative pool at the same time. A bare dictionary mutated from
    /// concurrent reads/inserts is a data race (unlike `memoryCache`/`mediaQueryCache`,
    /// which are `NSCache` and already thread-safe) — guard it with a lock.
    private var noArtworkKeys: [String: Date] = [:]
    private let noArtworkLock = NSLock()
    private static let noArtworkCooldown: TimeInterval = 5 * 60  // 5 minutes

    private func isKnownNoArtwork(_ key: String) -> Bool {
        noArtworkLock.lock()
        defer { noArtworkLock.unlock() }
        guard let markedAt = noArtworkKeys[key] else { return false }
        guard Date().timeIntervalSince(markedAt) < Self.noArtworkCooldown else {
            noArtworkKeys.removeValue(forKey: key)
            appLog("Artwork: no-artwork cooldown expired for key=\(key) — will retry", category: "artwork")
            return false
        }
        return true
    }

    private func markNoArtwork(_ key: String) {
        noArtworkLock.lock()
        defer { noArtworkLock.unlock() }
        noArtworkKeys[key] = Date()
    }

    private func clearNoArtworkKeys() {
        noArtworkLock.lock()
        defer { noArtworkLock.unlock() }
        noArtworkKeys.removeAll()
    }

    /// Sentinel image stored in `mediaQueryCache` to signal "already checked, no artwork".
    private let noArtworkSentinel = UIImage()

    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// Cap for cached/persisted artwork dimensions. Was 600 — visibly blurry
    /// on @3x displays where the largest artwork view (NowPlaying, 300pt) needs
    /// ~900 physical px, even when the source file embeds UHD artwork. 1200
    /// covers that with headroom across @2x/@3x without ballooning disk usage.
    private static let artworkCacheDimension: CGFloat = 1200

    /// Bump whenever `artworkCacheDimension`/JPEG quality changes — triggers a
    /// one-time purge of disk-cached artwork written under the old settings, so
    /// upgrading users see the quality improvement without having to find and
    /// tap "Clear Artwork Cache" in Settings themselves.
    // v4: resize/crop renders previously inherited the device's screen scale
    // (UIGraphicsImageRenderer's default format), so the "1200px" cap actually
    // wrote 3600×3600 files on @3x devices — 9× the intended pixels on disk and
    // ~52 MB per decoded image in memory. Purge so entries regenerate at the
    // true capped size.
    private static let cacheFormatVersion = 4
    private static let cacheVersionFileName = ".cache_format_version"

    private init() {
        // .cachesDirectory essentially never fails to resolve on a real device,
        // but ArtworkService is a singleton created the moment any artwork view
        // appears — a fatalError here would crash the app on nearly its first
        // frame. Fall back to temporaryDirectory (always available) instead.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskCacheURL = caches.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        purgeStaleArtworkCacheIfNeeded()

        // LRU eviction: cap at 200 images. NSCache evicts least-recently-used entries
        // automatically under memory pressure and when countLimit is exceeded.
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 100 * 1024 * 1024   // 100 MB (was 50; video frames are large)

        // Row/grid thumbnails are small (≤768px → ≤2.4 MB each, list rows
        // ≤0.15 MB), so a high count limit should stay well under the cost
        // cap — but the cap this used to carry (48 MB) didn't actually
        // deliver that: at ≤0.15 MB/row, 48 MB only holds ~320 list-row
        // thumbnails before NSCache's COST limit starts evicting, well
        // short of the 1000-item `countLimit` above it, and the 768px grid
        // bucket (folder/album covers — exactly what the Folders tab and
        // folder/album grids use) fit barely ~20 before the same thing. Any
        // library bigger than that re-hit disk (a visible placeholder
        // flash, not just wasted CPU) every time a folder/list scrolled
        // back into view — read as "artwork doesn't actually stay cached,"
        // and a real contributor to Folders/Songs tab scroll lag. Sized up
        // so the stated 1000-item intent is actually reachable for the
        // common (list-row) case, with real headroom left for grid-bucket
        // entries too.
        // BUGFIX (reported: track cards randomly going blank mid-scroll in a
        // large folder/library, then reloading once almost off-screen): the
        // 768px grid bucket (folder/album covers, and any grid-style list)
        // costs ~2.25 MB per entry, so 192 MB only holds ~85 of them before
        // NSCache starts evicting — easy to blow through scrolling a single
        // folder with hundreds of tracks in grid view, at which point a
        // thumbnail scrolled back into view is a genuine cache miss and has
        // to re-hit disk (a visible blank-then-reload, not just wasted CPU).
        // Raised for real headroom on that specific bucket; still well
        // within a safe mobile memory budget, and this cache is already
        // cleared outright on a memory warning or while backgrounded (below).
        thumbnailCache.countLimit = 1000
        thumbnailCache.totalCostLimit = 256 * 1024 * 1024

        // Media-library lookups were previously unbounded; cap them like the
        // main cache so a huge Apple Music library can't accumulate freely.
        mediaQueryCache.countLimit = 200
        mediaQueryCache.totalCostLimit = 100 * 1024 * 1024

        // Give memory back explicitly rather than trusting NSCache's own
        // pressure handling, which can lag behind jetsam for an app holding
        // ~250 MB of decoded art. Backgrounded, the app is usually just
        // playing audio (the lock-screen art is already handed to
        // MPNowPlayingInfoCenter), so the full-size caches go; row
        // thumbnails stay so returning to a list doesn't flash. A memory
        // warning clears everything — it all reloads from the disk cache.
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.memoryCache.removeAllObjects()
            self?.mediaQueryCache.removeAllObjects()
            self?.thumbnailCache.removeAllObjects()
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.memoryCache.removeAllObjects()
            self?.mediaQueryCache.removeAllObjects()
        }
    }

    /// Wipes previously-cached artwork files once per `cacheFormatVersion` bump,
    /// so stale low-resolution/low-quality images don't linger on disk and keep
    /// being served instead of freshly (re)generated ones.
    ///
    /// Runs entirely off the main thread: `ArtworkService.shared` is first
    /// touched from `LibraryManager.init` during app launch, and synchronously
    /// deleting hundreds/thousands of cache files there would stall startup —
    /// exactly the kind of "update install freakout" users were already hitting
    /// from an unrelated full-library-rescan bug. The version-file write happens
    /// last so a process kill mid-purge re-triggers the purge next launch instead
    /// of leaving the cache in a mixed old/new state.
    private func purgeStaleArtworkCacheIfNeeded() {
        let versionFile = diskCacheURL.appendingPathComponent(Self.cacheVersionFileName)
        let storedVersion = (try? String(contentsOf: versionFile, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard storedVersion != Self.cacheFormatVersion else { return }

        let cacheURL = diskCacheURL
        let newVersion = Self.cacheFormatVersion
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(
                at: cacheURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) {
                for url in contents { try? fm.removeItem(at: url) }
            }
            try? "\(newVersion)".write(to: versionFile, atomically: true, encoding: .utf8)
        }
    }

    func artwork(for song: Song) -> UIImage? {
        let key = cacheKey(for: song)
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }
        if let onDisk = loadFromDisk(key: key) {
            setMemoryCache(onDisk, forKey: key)
            return onDisk
        }
        return nil
    }

    /// Whether cached artwork exists for `song`, without decoding anything —
    /// for "is artwork missing?" checks (e.g. LibraryManager's import
    /// maintenance pass), where calling `artwork(for:)` would decode every
    /// existing entry into the memory cache just to throw the result away.
    /// Checks the file's size (a cheap `stat`, not a decode) rather than mere
    /// existence, so a zero-byte file left by an interrupted write still
    /// reads as "missing" and gets regenerated instead of silently persisting
    /// as permanently-broken artwork.
    func hasCachedArtwork(for song: Song) -> Bool {
        let key = cacheKey(for: song)
        if memoryCache.object(forKey: key as NSString) != nil { return true }
        let path = diskPath(key: key)
        guard let size = try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int
        else { return false }
        return size > 0
    }

    /// Stores `image` in both memory and disk cache under `key`.
    /// Used by DocumentImportService to persist video-frame thumbnails so they
    /// survive app restarts and NSCache evictions.
    func cacheImage(_ image: UIImage, forKey key: String) {
        // Square-crop + downscale once, then use the SAME processed image for
        // both caches so the in-memory and on-disk copies match (previously the
        // raw, possibly non-square image went into memory while the squared one
        // went to disk — the artwork appeared to "re-crop" after a relaunch).
        _ = persistFullArtwork(image, forKey: key)
    }

    /// Fetches a remote image and writes it to both memory and disk cache under `key`.
    /// Call this before `scanLocalDocuments()` when you know the artwork URL in advance
    /// (e.g. after a YouTube/SoundCloud download to pre-seed the thumbnail).
    func prefetchRemoteImage(url: URL, forKey key: String) async {
        // Skip if already on disk.
        if loadFromDisk(key: key) != nil { return }
        guard let image = await fetchRemoteImage(url: url) else { return }
        cacheImage(image, forKey: key)
    }

    /// Full async artwork load: memory → disk → remote URL → media library →
    /// embedded asset metadata → video frame extraction → iTunes Search API.
    func loadArtwork(for song: Song) async -> UIImage? {
        let key = cacheKey(for: song)
        let startedAt = Date()
        // Logged once per full pipeline run (not on memory/disk cache hits,
        // which fire constantly during ordinary scrolling and would drown
        // out everything else) — the elapsed-time warning below is what
        // actually matters diagnostically: which songs are slow, and why.
        defer {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 2.0 {
                appWarn(
                    "Artwork: pipeline for \"\(song.displayName)\" took \(String(format: "%.1f", elapsed))s "
                    + "(key=\(key), hasURL=\(song.url != nil), hasPersistentID=\(song.persistentID != nil), "
                    + "hasCacheKey=\(song.artworkCacheKey != nil), sourceTrackID=\(song.sourceTrackID ?? "nil"))",
                    category: "artwork"
                )
            }
        }

        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        if let onDisk = loadFromDisk(key: key) {
            setMemoryCache(onDisk, forKey: key)
            return onDisk
        }

        // Negative cache: skip all network/API sources for keys we already know
        // have no artwork. Previously silent — a track short-circuiting here
        // looked identical to one that was simply never asked for, which made
        // "why didn't this even try to load" impossible to tell apart from
        // "this hasn't been requested yet" purely from the log stream.
        if isKnownNoArtwork(key) {
            appLog("Artwork: skipping \"\(song.displayName)\" — still within no-artwork cooldown (key=\(key))", category: "artwork")
            return nil
        }

        // Streaming tracks store their thumbnail URL as the artworkCacheKey.
        if let cacheKeyStr = song.artworkCacheKey,
           cacheKeyStr.hasPrefix("http"),
           let thumbnailURL = URL(string: cacheKeyStr) {
            appLog("Artwork: fetching remote thumbnail for \"\(song.displayName)\"", category: "artwork")
            if let image = await fetchRemoteImage(url: thumbnailURL, headers: song.httpHeaders) {
                appLog("Artwork: remote thumbnail found for \"\(song.displayName)\"", category: "artwork")
                return persistFullArtwork(image, forKey: key)
            }
            appWarn("Artwork: remote fetch failed for \"\(song.displayName)\"", category: "artwork")
        }

        if let persistentID = song.persistentID {
            if let image = await fetchMediaLibraryArtwork(persistentID: persistentID) {
                appLog("Artwork: media library hit for \"\(song.displayName)\"", category: "artwork")
                return persistFullArtwork(image, forKey: key)
            }
            appLog("Artwork: media library miss for \"\(song.displayName)\"", category: "artwork")
            return nil
        }

        if let url = song.url {
            // Reads embedded tags/artwork below need `playableURL` — a
            // `.lms`-locked track's on-disk bytes are XOR-masked (see
            // LumisoundLockFormat's header comment) and are NOT a valid
            // audio container to AVFoundation at all, so every embedded-
            // metadata read against the raw `url` silently failed for any
            // track that had gone through the exclusive-lock pipeline —
            // this was the "metadata and artwork data is bugged, nothing
            // is showing" report. A no-op for anything not `.lms`-marked.
            let readableURL = LumisoundExclusiveExtensionService.playableURL(for: url)

            // Try embedded asset artwork (works for m4a, mp3, flac with embedded tags).
            if let image = await fetchAssetArtwork(url: readableURL) {
                appLog("Artwork: embedded tag found for \"\(song.displayName)\"", category: "artwork")
                return persistFullArtwork(image, forKey: key)
            }
            appLog("Artwork: no embedded tag artwork for \"\(song.displayName)\" (ext=\(readableURL.pathExtension))", category: "artwork")

            // Tracks downloaded via the bridge are tagged with the original
            // YouTube/SoundCloud thumbnail URL (LUMISOUND_THUMBNAIL) since
            // --embed-thumbnail isn't available. If the disk cache entry seeded
            // at download time was ever cleared, recover the same thumbnail here
            // instead of falling through to a guess-based iTunes Search lookup.
            if let thumbnailURL = await fetchEmbeddedThumbnailURL(url: readableURL),
               let image = await fetchRemoteImage(url: thumbnailURL) {
                appLog("Artwork: recovered embedded LUMISOUND_THUMBNAIL for \"\(song.displayName)\"", category: "artwork")
                return persistFullArtwork(image, forKey: key)
            }

            // Both branches above read embedded file metadata via
            // AVFoundation — which, for Ogg/Opus's vorbis-comment-based
            // picture/tag blocks, is far less reliable than for MP4/ID3
            // (confirmed: several Opus tracks downloaded through this
            // exact pipeline show no artwork despite yt-dlp's
            // --embed-thumbnail having run at download time). For a
            // YouTube-sourced track this doesn't need to depend on reading
            // the file at all: YouTube's hqdefault.jpg is deterministic
            // from the video ID alone and virtually always exists — the
            // same guaranteed fallback the download-time prefetch
            // (StreamingService+DownloadToLibrary's
            // prefetchArtworkWithFallback) already reaches for when a
            // track's *actual* thumbnail URL 404s. Tried before iTunes
            // Search since a real (if lower-resolution) match beats a
            // guess-based text search that a niche fan remix/game-rip
            // upload was never going to match in iTunes's commercial
            // catalog anyway.
            if let sourceTrackID = song.sourceTrackID, sourceTrackID.hasPrefix("youtube:") {
                let videoID = String(sourceTrackID.dropFirst("youtube:".count))
                if let thumbnailURL = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
                   let image = await fetchRemoteImage(url: thumbnailURL) {
                    appLog("Artwork: recovered via YouTube hqdefault fallback for \"\(song.displayName)\"", category: "artwork")
                    return persistFullArtwork(image, forKey: key)
                }
                appWarn("Artwork: hqdefault fallback fetch failed for \"\(song.displayName)\" (videoID=\(videoID))", category: "artwork")
            } else {
                // No embedded tag AND no sourceTrackID to fall back on — this
                // is the single most useful line for diagnosing "metadata's
                // there but artwork never loads": it tells us the file's own
                // tags never carried a recoverable trackID at all (import-time
                // tag read failed, or the file predates tagging), so the only
                // paths left are the two fuzzy text-search fallbacks below.
                appLog("Artwork: no sourceTrackID for \"\(song.displayName)\" — skipping deterministic hqdefault fallback", category: "artwork")
            }

            // For local video files, extract the first frame as artwork.
            if Self.videoExtensions.contains(LumisoundExclusiveExtensionService.effectiveExtension(for: url)) {
                appLog("Artwork: extracting video frame for \"\(song.displayName)\"", category: "artwork")
                if let image = await extractVideoFrame(url: readableURL) {
                    return persistFullArtwork(image, forKey: key)
                }
                appWarn("Artwork: video frame extraction failed for \"\(song.displayName)\"", category: "artwork")
            }
        }

        // Last resort #1: search the bridge (YouTube) by title + artist and
        // use the top result's thumbnail. Tried before iTunes Search since
        // this app's library skews toward fan remixes/game-rips/niche
        // content that YouTube actually hosts and iTunes's commercial
        // catalog never will — and unlike iTunes, this device may not have
        // any iTunes/Apple Music account or usage at all, so that fallback
        // alone left plenty of tracks with no recoverable artwork.
        appLog("Artwork: searching YouTube for \"\(song.displayName)\" by \(song.artistName)", category: "artwork")
        if let image = await fetchYouTubeSearchArtwork(title: song.title, artist: song.artist) {
            appLog("Artwork: YouTube search match found for \"\(song.displayName)\"", category: "artwork")
            return persistFullArtwork(image, forKey: key)
        }

        // Last resort #2: iTunes Search API — still worth trying for
        // legitimately commercial tracks the YouTube search above didn't
        // resolve a usable thumbnail for.
        appLog("Artwork: querying iTunes for \"\(song.displayName)\" by \(song.artistName)", category: "artwork")
        if let image = await fetchITunesArtwork(title: song.title, artist: song.artist) {
            appLog("Artwork: iTunes match found for \"\(song.displayName)\"", category: "artwork")
            return persistFullArtwork(image, forKey: key)
        }

        markNoArtwork(key)
        appWarn(
            "Artwork: no source found for \"\(song.displayName)\" — exhausted all fallbacks "
            + "(key=\(key), hasURL=\(song.url != nil), hasPersistentID=\(song.persistentID != nil), "
            + "sourceTrackID=\(song.sourceTrackID ?? "nil"), ext=\(song.url.map { LumisoundExclusiveExtensionService.effectiveExtension(for: $0) } ?? "n/a"), "
            + "blacklisting for \(Int(Self.noArtworkCooldown))s",
            category: "artwork"
        )
        return nil
    }

    /// Resizes, memory-caches, disk-caches, and invalidates any stale bucketed
    /// thumbnails for `image` under `key` — the common tail of every
    /// `loadArtwork` source branch. Centralizing this also fixes a case the
    /// branches used to handle inconsistently: media-library-sourced artwork
    /// was never written to disk (so `loadThumbnail`'s cheap ImageIO disk path
    /// could never engage for it, forcing a full `MPMediaQuery` on every
    /// bucket-cache miss), and none of the branches invalidated stale
    /// bucketed thumbnails when re-fetching art for a key that already had
    /// some cached.
    private func persistFullArtwork(_ image: UIImage, forKey key: String) -> UIImage {
        let resized = resizedImage(image, maxDimension: Self.artworkCacheDimension)
        setMemoryCache(resized, forKey: key)
        saveToDisk(image: resized, key: key)
        invalidateThumbnails(forKey: key)
        return resized
    }

    // MARK: - Cache Management

    /// Evicts all in-memory artwork entries immediately.
    /// The disk cache is left intact so artwork can be reloaded on next access.
    func clearCache() {
        memoryCache.removeAllObjects()
        mediaQueryCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        clearNoArtworkKeys()
    }

    /// Warms the thumbnail cache — and, for songs with no disk entry yet, the
    /// full pipeline that seeds it — at background priority. Used for
    /// scroll-ahead prefetch in list/grid views, which display bucketed
    /// thumbnails; warming full `artworkCacheDimension` decodes here (the old
    /// behaviour) churned ~5.5 MB decodes per row the visible cells never read.
    /// Skips songs already warmed; NSCache evicts as needed at capacity.
    ///
    /// `pixelSize` has no default — callers must pass the actual physical
    /// pixel size their cells render at (a mismatched default previously
    /// warmed a bucket no visible cell read, defeating the prefetch).
    func prefetch(songs: [Song], pixelSize: CGFloat) {
        Task(priority: .background) {
            for song in songs {
                guard thumbnail(for: song, pixelSize: pixelSize) == nil else { continue }
                _ = await loadThumbnail(for: song, pixelSize: pixelSize)
            }
        }
    }

    // MARK: - Thumbnails

    /// Pixel-size buckets thumbnails are rendered at, so one cached copy is
    /// shared by every row/grid size that maps into the same bucket. Requests
    /// larger than the biggest bucket fall through to the full-size pipeline.
    ///
    /// 192 covers every `SongRow` style (32–60pt) at @2x and @3x, so all list
    /// rows share ONE bucket. 384 covers 3-column grid cells; 768 covers
    /// 2-column grid cells and the 256pt album/folder grids at @3x (which
    /// would otherwise fall through to full ~5.5 MB decodes per visible cell).
    private static let thumbnailBuckets: [CGFloat] = [192, 384, 768]

    private func thumbnailBucket(forPixelSize pixelSize: CGFloat) -> CGFloat? {
        Self.thumbnailBuckets.first { $0 >= pixelSize }
    }

    private func thumbnailCacheKey(_ key: String, bucket: CGFloat) -> NSString {
        "\(key)#thumb\(Int(bucket))" as NSString
    }

    /// Synchronous, memory-only thumbnail lookup — the fast path views use to
    /// avoid a placeholder flash for artwork that's already been rendered.
    /// `pixelSize` is in physical pixels (point size × display scale). Falls
    /// back to downscaling a full-size image already resident in
    /// `memoryCache` (e.g. loaded for Now Playing) rather than reporting a
    /// miss — cheap relative to a disk read + decode, and avoids a
    /// placeholder flash for art the app already has decoded.
    func thumbnail(for song: Song, pixelSize: CGFloat) -> UIImage? {
        let key = cacheKey(for: song)
        guard let bucket = thumbnailBucket(forPixelSize: pixelSize) else {
            return memoryCache.object(forKey: key as NSString)
        }
        return thumbnailFromCaches(key: key, bucket: bucket)
    }

    /// Async thumbnail load for list/grid cells. Downsamples straight from the
    /// disk-cache JPEG via ImageIO (never decodes the full-size image) off the
    /// main thread; only falls back to the full `loadArtwork` pipeline when no
    /// disk entry exists yet. `pixelSize` is in physical pixels.
    func loadThumbnail(for song: Song, pixelSize: CGFloat) async -> UIImage? {
        let key = cacheKey(for: song)
        guard let bucket = thumbnailBucket(forPixelSize: pixelSize) else {
            return await loadArtwork(for: song)
        }
        if let cached = thumbnailFromCaches(key: key, bucket: bucket) { return cached }

        // ImageIO returns nil for a missing/unreadable file, so there's no
        // need to `fileExists`-check first — this saves a stat per miss on
        // the scroll hot path.
        //
        // BUGFIX (reported: scrolling still jank/stutters through a large
        // library, confirmed in a screen recording as a continuous ragged
        // frame cadence during a fast flick through the Folders grid, not a
        // multi-hundred-ms freeze): this was `.userInitiated` — the highest
        // background QoS, scheduled with near-interactive urgency, directly
        // competing with the scroll view's own rendering for CPU time. Every
        // OTHER decode path in this file already uses `.utility` for exactly
        // this reason; this was the one spot that didn't, and it's the
        // highest-traffic one — a cell for every song scrolling into view
        // fires one of these. A fast fling through a grid surfaces half a
        // dozen-plus brand new cells at once, each spawning a `.userInitiated`
        // decode that fights the renderer for the same CPU cycles frame by
        // frame — exactly the shape of dropped-frame scroll jank, as opposed
        // to a dead stop. `.utility` is the same priority UIKit's own
        // prefetch APIs recommend for scroll-driven image decode for this
        // exact reason.
        // Caps how many of these run AT ONCE — see `DecodeConcurrencyLimiter`'s
        // doc comment for why priority alone (the fix above) wasn't enough
        // once the grid holds more simultaneous cells (3 columns): a burst
        // of new cells all requesting a decode in the same instant still
        // lands on the CPU all at once regardless of what priority they're
        // scheduled at.
        await thumbnailDecodeLimiter.acquire()
        defer { Task { await thumbnailDecodeLimiter.release() } }
        let path = diskPath(key: key)
        let thumb = await Task.detached(priority: .utility) {
            ImageDownsampler.downsampled(at: path, maxPixelSize: bucket)
        }.value
        if let thumb {
            setThumbnailCache(thumb, forKey: thumbnailCacheKey(key, bucket: bucket))
            return thumb
        }

        // No disk entry yet — run the full pipeline (which seeds the disk
        // cache), then scale its result down to the bucket.
        guard let full = await loadArtwork(for: song) else { return nil }
        let thumb2 = ImageDownsampler.downscaled(full, maxPixelSize: bucket)
        setThumbnailCache(thumb2, forKey: thumbnailCacheKey(key, bucket: bucket))
        return thumb2
    }

    /// Shared fast path for both `thumbnail(for:)` and `loadThumbnail(for:)`:
    /// checks the bucketed cache, then falls back to downscaling a resident
    /// full-size image rather than reporting a miss.
    private func thumbnailFromCaches(key: String, bucket: CGFloat) -> UIImage? {
        let tKey = thumbnailCacheKey(key, bucket: bucket)
        if let cached = thumbnailCache.object(forKey: tKey) { return cached }
        guard let full = memoryCache.object(forKey: key as NSString) else { return nil }
        let thumb = ImageDownsampler.downscaled(full, maxPixelSize: bucket)
        setThumbnailCache(thumb, forKey: tKey)
        return thumb
    }

    private func setThumbnailCache(_ image: UIImage, forKey key: NSString) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        thumbnailCache.setObject(image, forKey: key, cost: cost)
    }

    /// Drops every bucketed thumbnail derived from `key` — called when the
    /// full-size artwork under that key is replaced, so rows don't keep
    /// serving a stale rendition.
    private func invalidateThumbnails(forKey key: String) {
        for bucket in Self.thumbnailBuckets {
            thumbnailCache.removeObject(forKey: thumbnailCacheKey(key, bucket: bucket))
        }
    }

    // MARK: - Private Helpers

    private func cacheKey(for song: Song) -> String {
        song.artworkCacheKey ?? song.id
    }

    private func sanitizedKey(_ key: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|")
        return key.components(separatedBy: illegal).joined(separator: "_")
    }

    private func diskPath(key: String) -> URL {
        diskCacheURL.appendingPathComponent("\(sanitizedKey(key)).jpg")
    }

    private func loadFromDisk(key: String) -> UIImage? {
        let path = diskPath(key: key)
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let image = UIImage(data: data)
        else { return nil }
        return image
    }

    private func saveToDisk(image: UIImage, key: String) {
        let path = diskPath(key: key)
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            appWarn("Artwork: saveToDisk encode failed for key \(key)", category: "artwork")
            return
        }
        do {
            try data.write(to: path, options: .atomic)
        } catch {
            appWarn("Artwork: saveToDisk write failed for key \(key): \(error)", category: "artwork")
        }
    }

    private func setMemoryCache(_ image: UIImage, forKey key: String) {
        // Cost in real pixels — `size` is in points, so ignoring `scale` would
        // undercount a @3x image's decoded footprint by 9× and let the cache
        // blow far past `totalCostLimit`.
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func resizedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        // Letterbox trim, square crop, downscale + JPEG in the Rust core
        // (same rules as below, which remain the fallback).
        if let data = image.jpegData(compressionQuality: 0.95) ?? image.pngData(),
           let out = artworkProcess(imageData: data, maxDim: UInt32(max(16, maxDimension))),
           let processed = UIImage(data: out) {
            return processed
        }
        // 1) Trim solid letterbox/pillarbox bars (e.g. a 16:9 video frame padded
        //    into a 4:3 `hqdefault` YouTube thumbnail, which a plain square crop
        //    would otherwise keep — the "artwork still shows 16:9 with black
        //    bars" symptom). 2) center-crop the remaining content to a square so
        //    it fills the square frames used everywhere. Already-square art with
        //    no bars passes through both steps unchanged.
        let trimmed = trimmedLetterbox(image)
        let squared = squareCropped(trimmed)
        // `ImageDownsampler.downscaled` works in real pixels (size × scale)
        // and renders at scale 1 — `UIImage.size` alone is in points, so a
        // scale-3 image measured against a pixel cap without this would slip
        // through at 3× the intended pixel count (e.g. MPMediaItemArtwork
        // returns screen-scale images).
        return ImageDownsampler.downscaled(squared, maxPixelSize: maxDimension)
    }

    /// Returns the largest centered square crop of `image`. A no-op for images
    /// that are already square. Operates in the image's own pixel space and
    /// preserves orientation by rendering through `UIGraphicsImageRenderer`.
    private func squareCropped(_ image: UIImage) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0, abs(w - h) > 0.5 else { return image }
        let side = min(w, h)
        // Preserve the source's scale so cropping never *increases* pixel count
        // (the default renderer format would re-render at screen scale).
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            // Center the source so equal amounts are cropped from both edges of
            // the longer dimension.
            let origin = CGPoint(x: (side - w) / 2, y: (side - h) / 2)
            image.draw(in: CGRect(origin: origin, size: CGSize(width: w, height: h)))
        }
    }

    /// Detects and crops away near-uniform horizontal (letterbox) and vertical
    /// (pillarbox) bars around an image's real content — the matte/black bars
    /// baked into padded thumbnails (e.g. a 16:9 still inside a 4:3
    /// `hqdefault.jpg`). Scans a small downsampled copy for speed, maps the
    /// content rect back to the original, and crops. Returns the original
    /// unchanged when no significant bars are found.
    private func trimmedLetterbox(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let origW = cg.width, origH = cg.height
        guard origW > 8, origH > 8 else { return image }

        // Downsample to a small buffer (max 64px on the long edge) for a cheap scan.
        let maxScan = 64
        let scale = min(1.0, Double(maxScan) / Double(max(origW, origH)))
        let sw = max(2, Int(Double(origW) * scale))
        let sh = max(2, Int(Double(origH) * scale))
        let bytesPerRow = sw * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * sh)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sw, height: sh))

        // A row/column is a "bar" if every pixel is near-uniform AND close to the
        // corner color (the matte). Uniform: low spread from the line's first px.
        func brightness(_ i: Int) -> Int { Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2]) }
        let tol = 48  // per-channel-sum tolerance (~16/channel)

        func rowIsBar(_ y: Int) -> Bool {
            let base = y * bytesPerRow
            let ref = brightness(base)
            if ref > 170 * 3 { return false }  // bars are dark; skip bright rows
            for x in 0..<sw {
                if abs(brightness(base + x * 4) - ref) > tol { return false }
            }
            return true
        }
        func colIsBar(_ x: Int) -> Bool {
            let ref = brightness(x * 4)
            if ref > 170 * 3 { return false }
            for y in 0..<sh {
                if abs(brightness(y * bytesPerRow + x * 4) - ref) > tol { return false }
            }
            return true
        }

        var top = 0; while top < sh && rowIsBar(top) { top += 1 }
        var bottom = sh - 1; while bottom > top && rowIsBar(bottom) { bottom -= 1 }
        var left = 0; while left < sw && colIsBar(left) { left += 1 }
        var right = sw - 1; while right > left && colIsBar(right) { right -= 1 }

        let contentW = right - left + 1
        let contentH = bottom - top + 1
        // Ignore tiny trims (noise) — only act when a real bar (>4% of a side) exists.
        let trimmedX = (left + (sw - 1 - right))
        let trimmedY = (top + (sh - 1 - bottom))
        guard contentW > sw / 2, contentH > sh / 2,
              (trimmedY > sh / 25 || trimmedX > sw / 25) else { return image }

        // Map the content rect back to original pixel coordinates.
        let fx = Double(origW) / Double(sw)
        let fy = Double(origH) / Double(sh)
        let cropRect = CGRect(
            x: Double(left) * fx, y: Double(top) * fy,
            width: Double(contentW) * fx, height: Double(contentH) * fy
        ).integral
        guard let cropped = cg.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Fetch methods

    private func fetchMediaLibraryArtwork(persistentID: UInt64) async -> UIImage? {
        let cacheKey = NSNumber(value: persistentID)
        if let cached = mediaQueryCache.object(forKey: cacheKey) {
            return cached.size == .zero ? nil : cached
        }

        let raw = await Task.detached(priority: .utility) {
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: persistentID),
                forProperty: MPMediaItemPropertyPersistentID
            )
            let query = MPMediaQuery()
            query.addFilterPredicate(predicate)
            guard let item = query.items?.first else { return nil as UIImage? }
            return item.artwork?.image(at: CGSize(width: Self.artworkCacheDimension, height: Self.artworkCacheDimension))
        }.value

        // MPMediaItemArtwork interprets the requested size in points and returns
        // a screen-scale image — cap it to real pixels like every other source.
        let image = raw.map { resizedImage($0, maxDimension: Self.artworkCacheDimension) }
        // Cost in real pixels, matching `setMemoryCache` — otherwise every
        // entry defaults to cost 0 and `totalCostLimit` never triggers
        // eviction; only `countLimit` would bound this cache.
        let cost = image.map { Int($0.size.width * $0.scale * $0.size.height * $0.scale * 4) } ?? 0
        mediaQueryCache.setObject(image ?? noArtworkSentinel, forKey: cacheKey, cost: cost)
        return image
    }

    func fetchRemoteImage(url: URL, headers: [String: String]? = nil) async -> UIImage? {
        var req = URLRequest(url: url)
        headers?.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Core.data(for: req)
        } catch {
            appWarn("Artwork: fetchRemoteImage request failed for \(url.absoluteString): \(error.localizedDescription)", category: "artwork")
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            appWarn(
                "Artwork: fetchRemoteImage got HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.absoluteString)",
                category: "artwork"
            )
            return nil
        }
        guard let image = UIImage(data: data) else {
            appWarn("Artwork: fetchRemoteImage got 200 but undecodable data (\(data.count) bytes) for \(url.absoluteString)", category: "artwork")
            return nil
        }
        return image
    }

    /// Reads embedded artwork from the file's metadata — checks both commonMetadata
    /// and all format-specific metadata items to maximise coverage across m4a, mp3, flac, etc.
    private func fetchAssetArtwork(url: URL) async -> UIImage? {
        // Embedded pictures via the Rust core (lofty, every container).
        if url.isFileURL,
           let data = await Task.detached(priority: .utility, operation: { artworkEmbedded(path: url.path, cacheDir: CoreAudio.unlockDir) }).value,
           let image = UIImage(data: data) {
            return image
        }
        return await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)

            // Pass 1: commonMetadata (works for most formats, fastest path)
            if let commonMetadata = try? await asset.load(.commonMetadata) {
                for item in commonMetadata where item.commonKey == .commonKeyArtwork {
                    if let data = try? await item.load(.dataValue),
                       let image = UIImage(data: data) { return image }
                    if let value = try? await item.load(.value) as? Data,
                       let image = UIImage(data: value) { return image }
                }
            }

            // Pass 2: all metadata items — catches artwork in format-specific tags
            // that AVFoundation doesn't surface via commonMetadata (e.g. some FLAC files).
            if let allMeta = try? await asset.load(.metadata) {
                for item in allMeta {
                    guard let identifierRaw = item.identifier?.rawValue else { continue }
                    let id = identifierRaw.lowercased()
                    guard id.contains("artwork") || id.contains("covr") ||
                          id.contains("apic") || id.contains("picture") else { continue }
                    if let data = try? await item.load(.dataValue),
                       data.count > 500,
                       let image = UIImage(data: data) { return image }
                    if let value = try? await item.load(.value) as? Data,
                       value.count > 500,
                       let image = UIImage(data: value) { return image }
                }
            }

            return nil as UIImage?
        }.value
    }

    /// Reads the `LUMISOUND_THUMBNAIL` metadata tag (embedded by the bridge at
    /// download time — see `_do_download_job`'s `tag_cmd`) and returns it as a URL.
    private func fetchEmbeddedThumbnailURL(url: URL) async -> URL? {
        return await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let allMeta = try? await asset.load(.metadata) else { return nil as URL? }
            // Surfaces under different identifier forms depending on container —
            // check both the identifier and key, matching the LUMISOUND_ID lookup
            // in DocumentImportService.
            for item in allMeta {
                let idRaw = item.identifier?.rawValue.lowercased() ?? ""
                let keyRaw = (item.key as? String)?.lowercased() ?? ""
                guard idRaw.contains("lumisound_thumbnail") || keyRaw.contains("lumisound_thumbnail") else { continue }
                if let value = try? await item.load(.stringValue), let url = URL(string: value) {
                    return url
                }
            }
            return nil as URL?
        }.value
    }

    /// Extracts the first frame of a video file as a thumbnail.
    /// Uses the modern async `image(at:)` API on iOS 16+ with sync fallback.
    private func extractVideoFrame(url: URL) async -> UIImage? {
        return await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: Self.artworkCacheDimension, height: Self.artworkCacheDimension)
            let time = CMTime(seconds: 1, preferredTimescale: 600)

            if #available(iOS 16, *) {
                if let result = try? await generator.image(at: time) {
                    return UIImage(cgImage: result.image)
                }
            } else {
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    return UIImage(cgImage: cgImage)
                }
            }
            return nil as UIImage?
        }.value
    }

    /// Searches the bridge (YouTube, via `StreamingService.searchSilently` —
    /// the same silent/non-UI-disturbing search `DeadLinkHealingService`
    /// uses) for `title` + `artist` and fetches the top result's thumbnail.
    /// `StreamingService` is `@MainActor`-isolated; this function isn't, so
    /// the call hops there explicitly rather than requiring every caller of
    /// `loadArtwork` to already be on the main actor.
    private func fetchYouTubeSearchArtwork(title: String, artist: String) async -> UIImage? {
        let query = [title, artist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { return nil }

        guard let streaming = await MainActor.run(body: { StreamingService.shared }) else {
            appWarn("Artwork: YouTube search skipped — StreamingService unavailable (query=\"\(query)\")", category: "artwork")
            return nil
        }
        let results = await streaming.searchSilently(query: query)
        guard !results.isEmpty else {
            appLog("Artwork: YouTube search returned zero results (query=\"\(query)\")", category: "artwork")
            return nil
        }
        // The first hit for an unrestricted "title artist" YouTube search is
        // NOT necessarily the actual track — unlike the iTunes Search API
        // just below (which at least scopes to entity=song and tends to be
        // reliable for catalogued music), a plain YouTube search can easily
        // top-rank a cover, a reaction video, a completely different song
        // that happens to share words, or a same-titled track by another
        // artist. This is a last-resort artwork fallback specifically for
        // tracks the more targeted sources couldn't find anything for, so
        // blindly trusting result #1 here is exactly the kind of thing that
        // produces "wrong/unrelated thumbnail" reports. Reject anything
        // whose own reported title doesn't at least textually overlap with
        // what was actually searched for — same normalization
        // DuplicateFinderService already uses to decide "is this the same
        // song" elsewhere in this app.
        guard let match = results.first(where: { candidate in
            let normalizedQueryTitle = DuplicateFinderService.normalize(title)
            let normalizedResultTitle = DuplicateFinderService.normalize(candidate.title)
            guard !normalizedQueryTitle.isEmpty, !normalizedResultTitle.isEmpty else { return false }
            return normalizedResultTitle.contains(normalizedQueryTitle)
                || normalizedQueryTitle.contains(normalizedResultTitle)
        }) else {
            appLog(
                "Artwork: YouTube search got \(results.count) result(s) but none passed the title-overlap "
                + "guard (query=\"\(query)\", topResultTitle=\"\(results.first?.title ?? "")\")",
                category: "artwork"
            )
            return nil
        }
        guard !match.thumbnailURL.isEmpty, let thumbnailURL = URL(string: match.thumbnailURL) else {
            appWarn("Artwork: YouTube search matched \"\(match.title)\" but it has no usable thumbnail URL", category: "artwork")
            return nil
        }
        return await fetchRemoteImage(url: thumbnailURL)
    }

    /// Queries the iTunes Search API for artwork matching `title` + `artist`.
    /// Used as a last resort for tracks that have no embedded art and are not video files.
    private func fetchITunesArtwork(title: String, artist: String) async -> UIImage? {
        let query = [title, artist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let apiURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=1&country=US")
        else {
            appWarn("Artwork: iTunes lookup skipped — empty query or malformed URL (title=\"\(title)\", artist=\"\(artist)\")", category: "artwork")
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: apiURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                appWarn(
                    "Artwork: iTunes lookup got HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) (query=\"\(query)\")",
                    category: "artwork"
                )
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first
            else {
                appLog("Artwork: iTunes lookup returned zero results (query=\"\(query)\")", category: "artwork")
                return nil
            }

            // Prefer 600×600 artwork; fall back to 100×100 upscaled.
            let artStr = (first["artworkUrl600"] as? String)
                ?? (first["artworkUrl100"] as? String ?? "").replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let artURL = URL(string: artStr) else {
                appWarn("Artwork: iTunes matched a result for \"\(query)\" but it has no usable artwork URL", category: "artwork")
                return nil
            }
            return await fetchRemoteImage(url: artURL)
        } catch {
            appWarn("Artwork: iTunes lookup request failed for \"\(query)\": \(error.localizedDescription)", category: "artwork")
            return nil
        }
    }
}
