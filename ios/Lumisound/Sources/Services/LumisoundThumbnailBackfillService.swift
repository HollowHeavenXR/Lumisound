import AVFoundation
import Foundation

// MARK: - LumisoundThumbnailBackfillService
//
// One-time (per-track) backfill of pre-uploaded thumbnails for locked
// (.lms) cloud tracks that were uploaded before artwork-upload existed —
// see `StreamingService.uploadTrack`'s thumbnail-upload step and
// `/user/music/artwork-upload` in main.py. That fix only runs DURING a
// fresh upload; a track that was already sitting in the cloud library
// before it shipped has `has_artwork = true` in its metadata row (correctly
// recording that the ORIGINAL file had embedded art) but no actual
// thumbnail bytes ever got stored server-side for it — the server can't
// extract them itself from locked bytes, same limitation as ever. Every
// track uploaded before this feature existed would otherwise show no
// artwork forever, no matter how long the app runs, since nothing else
// ever revisits an already-completed upload.
@MainActor
enum LumisoundThumbnailBackfillService {
    /// v2: the previous pass marked a track "done" whenever it had no embedded
    /// JPEG — which, for an Opus library, was every single track (they carry a
    /// thumbnail URL instead). That set therefore records thousands of tracks
    /// as backfilled which never had anything uploaded for them, and without a
    /// new key the URL fallback above would never get to look at any of them.
    /// Re-running costs one metadata read plus one image fetch per track,
    /// spread 20 at a time across foreground passes.
    private static let backfilledIDsKey = "thumbnailBackfill.completedSongIDs.v2"
    /// Caps real per-pass work (an AVAsset metadata load, an image fetch and
    /// an upload per track) — this runs on the same 5-minute foreground loop
    /// as the rest of LumisoundTrackVaultService's migrations.
    ///
    /// Raised 20 -> 100. The original figure assumed "a several-hundred-track
    /// backlog", which is what this was written for; the real backlog is 3,465
    /// locked tracks. At 20 per 5-minute pass — and only while the app is
    /// FOREGROUND — that is ~14 hours of active phone use, measured at 4
    /// passes over one afternoon before the app was backgrounded and progress
    /// stopped. Tracks with no server-side thumbnail show no artwork at all on
    /// tvOS (the server cannot extract art from locked bytes, so this upload is
    /// its only source), so "converges eventually" meant "most of the library
    /// has no Apple TV artwork for weeks".
    ///
    /// 100 brings the same backlog to roughly 3 hours of foreground time. It is
    /// still a cap rather than "drain it all": each track costs a metadata read
    /// plus a round trip, this shares the foreground with playback and UI, and
    /// an unbounded burst on a 3,000-track library is exactly the "tight loop
    /// over a big collection" shape that has caused main-thread stalls in this
    /// codebase before. The work itself is already off the main actor; this
    /// bounds the network burst.
    private static let maxPerPass = 100

    /// BUG FIXED (2026-09-30): this was a COMPUTED property whose getter read
    /// the whole `stringArray` out of `UserDefaults` and built a fresh
    /// `Set<String>` from it — and `runIfNeeded`'s candidate `filter` below
    /// called it once PER SONG. That is O(songs x backfilled-IDs) string
    /// hashes plus one `UserDefaults` round trip per song, all on the main
    /// actor, every single 5-minute foreground pass — so on a library of a few
    /// thousand tracks it lands in the millions of operations. Field telemetry
    /// caught it exactly: 24 logged main-thread stalls of 12.9-18.0s in 13
    /// hours, 19 of which start in the instruction right after
    /// `LumisoundTrackVaultService`'s conversion pass returns — i.e. here —
    /// and the duration grew steadily (12.89s -> 17.74s) as the set filled,
    /// which is the O(n*m) signature. The set is now read ONCE per pass into a
    /// local, mutated in memory, and written back once
    /// (`persistBackfilledIDs`).
    private static func loadBackfilledIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: backfilledIDsKey) ?? [])
    }

    private static func persistBackfilledIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: backfilledIDsKey)
    }

    static func runIfNeeded() async {
        guard let library = LibraryManager.shared, let streaming = StreamingService.shared,
              let account = AccountService.shared, let token = account.token, account.isLoggedIn
        else { return }

        // Read once, not once per song (see `loadBackfilledIDs`). Every
        // mutation below goes into this local set; `persist` writes it back.
        var backfilledIDs = loadBackfilledIDs()
        var backfilledIDsDirty = false
        // One write per pass instead of one per insert (the old setter
        // re-serialized the entire array to `UserDefaults` on every single
        // `insert`, up to `maxPerPass` times). `defer` so progress is still
        // persisted on every exit path — the early returns below and the
        // `break` once `maxPerPass` is reached.
        defer {
            if backfilledIDsDirty { persistBackfilledIDs(backfilledIDs) }
        }

        let candidates = library.importedSongs.filter { song in
            guard let url = song.url, LumisoundExclusiveExtensionService.isConverted(url) else { return false }
            return !backfilledIDs.contains(song.id)
        }
        guard !candidates.isEmpty else { return }

        // One metadata fetch for the whole pass rather than one per track —
        // this is how a local song's already-uploaded server-side id (what
        // the artwork-upload endpoint keys on) gets resolved, matched by
        // the destination filename `uploadTrack` originally used.
        guard let cloudTracks = try? await streaming.fetchUserMusicMetadata(token: token, maxAge: 30) else { return }
        let cloudByFilename = Dictionary(cloudTracks.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })

        var processed = 0
        for song in candidates {
            guard processed < maxPerPass else { break }
            guard let url = song.url else { continue }

            guard let cloudTrack = cloudByFilename[url.lastPathComponent] else {
                // Not uploaded yet (or upload still in flight) — leave
                // unmarked so a future pass picks it up once it is.
                continue
            }
            processed += 1
            guard cloudTrack.hasArtwork else {
                backfilledIDs.insert(song.id); backfilledIDsDirty = true  // genuinely nothing to backfill
                continue
            }
            // Embedded JPEG bytes first, then the embedded thumbnail URL.
            //
            // The URL fallback is what actually carries this library: tracks
            // downloaded as Opus have NO embedded picture at all — they carry a
            // `LUMISOUND_THUMBNAIL` tag holding the source thumbnail's URL
            // (e.g. https://i.ytimg.com/vi/<id>/maxresdefault.jpg) instead.
            // Verified against the real cloud library: every locked track
            // sampled had that tag and no picture data.
            //
            // With only the JPEG path, `embeddedThumbnailJPEGData` correctly
            // returned nil for all of them and this loop marked each one
            // backfilled and moved on — so nothing was ever uploaded. Measured
            // server-side: 0 stored thumbnails against 3465 locked tracks, and
            // 0 artwork-upload requests ever received, while the client had
            // logged "processed 20 track(s)" 347 times. That is why locked
            // tracks show no artwork on tvOS, which has no other source for it:
            // the server cannot extract art from locked bytes itself, so a
            // pre-uploaded thumbnail is the ONLY thing `/user/music/artwork`
            // can serve for them.
            //
            // ArtworkService already resolves this same tag for local display
            // (its "recovered embedded LUMISOUND_THUMBNAIL" path); this makes
            // the backfill agree with it rather than giving up one step early.
            var jpeg = await LumisoundExclusiveExtensionService.embeddedThumbnailJPEGData(fileURL: url)
            if jpeg == nil {
                jpeg = await Self.thumbnailDataFromEmbeddedURL(fileURL: url)
            }
            guard let jpeg else {
                backfilledIDs.insert(song.id); backfilledIDsDirty = true  // genuinely no artwork of any kind
                continue
            }
            do {
                try await streaming.uploadArtworkThumbnail(jpeg, forMetadataID: cloudTrack.id, token: token)
                backfilledIDs.insert(song.id); backfilledIDsDirty = true
            } catch {
                appWarn("LumisoundThumbnailBackfillService: upload failed for \(url.lastPathComponent): \(error.localizedDescription)", category: "network")
                // Left unmarked — retried on the next pass.
            }
        }

        if processed > 0 {
            appLog("LumisoundThumbnailBackfillService: processed \(processed) track(s)", category: "network")
        }
    }

    /// Resolves a track's `LUMISOUND_THUMBNAIL` tag (a URL, not image bytes)
    /// and downloads it. Mirrors `ArtworkService.fetchEmbeddedThumbnailURL` —
    /// the tag surfaces under either the identifier or the key depending on
    /// container, so both are checked.
    ///
    /// The file is unlocked first: a `.lms` track's bytes are XOR-masked and
    /// AVURLAsset can't read metadata off them directly.
    private static func thumbnailDataFromEmbeddedURL(fileURL: URL) async -> Data? {
        // BUG FIXED (2026-09-30): `playableURL(for:)` was called HERE, in this
        // `@MainActor`-isolated function's own body, rather than inside the
        // detached task below. It is a synchronous full-file XOR unlock that
        // writes a complete unlocked copy of the track to disk on a cold
        // cache — so it ran on the main thread, up to `maxPerPass` (100) times
        // per 5-minute pass. This is the same main-thread-unlock bug
        // `runLegacyRelockPass` and `convert(fileURL:)` were each fixed for;
        // this call site never got it. Moved inside the detached task so the
        // unlock genuinely happens off-main.
        let remoteURL: URL? = await Task.detached(priority: .utility) {
            let readableURL = LumisoundExclusiveExtensionService.playableURL(for: fileURL)
            let asset = AVURLAsset(url: readableURL)
            guard let allMeta = try? await asset.load(.metadata) else { return nil as URL? }
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
        guard let remoteURL else { return nil }
        guard let (data, response) = try? await Core.data(from: remoteURL),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return data
    }
}
