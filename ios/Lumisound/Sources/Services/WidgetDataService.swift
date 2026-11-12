import Foundation
import UIKit
import WidgetKit

/// Publishes the current track to the Home Screen / Lock Screen widgets and the
/// Live Activity as one `NowPlayingSnapshot`. Must be called on @MainActor.
///
/// Sync rules that keep both surfaces 1:1 with the player:
/// - One atomic record: title, artist, artwork file, timing and favourite are
///   written together, so a widget can't pair a new title with old artwork.
/// - Per-track artwork files: the snapshot names the file for *its* track, and
///   a track whose artwork hasn't loaded yet shows none rather than the
///   previous track's.
/// - The timeline is anchored (`position` at `anchor`, advancing at `rate`) and
///   the system animates it; `resync` compares that prediction against the
///   player every tick and re-anchors when they drift apart (stalls, seeks
///   from other paths, probed durations, speed changes).
/// - Widget reloads are throttled with a trailing reload, never dropped: the
///   last change inside a burst always reaches the widget.
@MainActor
final class WidgetDataService {
    static let shared = WidgetDataService()

    private let appGroupID = AppGroup.id
    private var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    /// What the surfaces currently show.
    private(set) var current: NowPlayingSnapshot = .empty

    private var lastReloadTime: Date = .distantPast
    private var pendingReload: Task<Void, Never>?
    private static let reloadSpacing: TimeInterval = 1.0

    /// Last time `resync` re-anchored, so a stalled stream (position frozen
    /// while the prediction runs on) re-anchors every few seconds, not every tick.
    private var lastResync: Date = .distantPast
    /// When the track last changed. For a moment after that the player's
    /// position can still be the previous track's (files load asynchronously),
    /// so `resync` waits before trusting it.
    private var trackChangedAt: Date = .distantPast

    private var loggedMissingAppGroup = false

    private init() {
        current = NowPlayingSnapshot.load(from: defaults) ?? .empty
    }

    /// Whether the shared App Group container is reachable from this process.
    ///
    /// Unlike `UserDefaults(suiteName:)` (which always returns a usable, but
    /// possibly sandbox-local and unshared, object even without the
    /// entitlement), `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// reliably returns `nil` when the App Group isn't actually provisioned
    /// for this build. `AppGroup.id` already handles the team-suffixed ID that
    /// sideloading tools register, so `false` here means the App Group is
    /// genuinely missing from signing and widgets stay on their placeholder.
    var isAppGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    // MARK: - Updates from the player

    /// The current track changed. Publishes the new title/artist at once
    /// (artwork follows from `update(song:...artwork:)` when it has loaded).
    /// The player's own position/duration can still describe the previous
    /// track at this point, so the new track starts from 0 with the song's
    /// catalogued duration; `resync` corrects both within a tick.
    func trackChanged(song: Song?, isPlaying: Bool, isFavorite: Bool) {
        guard let song else {
            publish(.empty, widgets: true)
            return
        }
        trackChangedAt = Date()
        var s = baseSnapshot(for: song, isFavorite: isFavorite)
        s.isPlaying = isPlaying
        s.position = 0
        s.duration = song.duration > 0 ? song.duration : 0
        s.anchor = Date()
        // Artwork already written for this track (replay, or skipping back).
        if let meta = Self.artworkMeta[song.id], let file = Self.artworkFileName(for: song.id),
           NowPlayingSnapshot.artworkExists(file, in: defaults) {
            s.artworkFile = file
            s.thumbFile = Self.thumbFileName(for: song.id)
            s.artworkAspect = meta.aspect
            s.tint = meta.tint
        }
        publish(s, widgets: true)
    }

    /// Full update once the track's artwork has loaded (or is known to be
    /// missing). Writes the per-track artwork files, then publishes.
    func update(song: Song?, isPlaying: Bool, artwork: UIImage?, position: TimeInterval = 0, duration: TimeInterval = 0, isFavorite: Bool = false) {
        guard let song else {
            publish(.empty, widgets: true)
            return
        }
        var s = baseSnapshot(for: song, isFavorite: isFavorite)
        s.isPlaying = isPlaying
        if current.trackID == song.id, Date().timeIntervalSince(trackChangedAt) <= 1.0 {
            // Artwork came back before the player's timing can be trusted.
            s.position = current.elapsed()
            s.duration = current.duration
        } else {
            s.position = position
            s.duration = duration > 0 ? duration : song.duration
        }
        s.anchor = Date()
        if let artwork, let meta = writeArtwork(artwork, trackID: song.id) {
            s.artworkFile = Self.artworkFileName(for: song.id)
            s.thumbFile = Self.thumbFileName(for: song.id)
            s.artworkAspect = meta.aspect
            s.tint = meta.tint
        }
        publish(s, widgets: true)
        appLog("WidgetDataService: pushed \"\(song.displayName)\" (playing=\(isPlaying), art=\(s.artworkFile != nil))", category: "widget")
    }

    /// Same track, corrected title/artist (e.g. a metadata fix).
    func retitle(song: Song) {
        guard current.trackID == song.id else { return }
        var s = current
        s.title = song.displayName
        s.artist = song.artistName
        publish(s, widgets: true)
    }

    /// Play/pause, seek, or a corrected position/duration on the same track.
    func updatePlayState(isPlaying: Bool, position: TimeInterval = 0, duration: TimeInterval = 0) {
        guard current.hasTrack else { return }
        var s = current
        s.isPlaying = isPlaying
        s.position = position
        if duration > 0 { s.duration = duration }
        s.rate = Self.playerRate
        s.anchor = Date()
        publish(s, widgets: true)
    }

    func updateFavoriteState(isFavorite: Bool) {
        // Also compared with the stored copy: a widget's favourite button
        // writes an optimistic guess there that this must overwrite.
        guard current.hasTrack, current.isFavorite != isFavorite || NowPlayingSnapshot.load(from: defaults)?.isFavorite != isFavorite else { return }
        var s = current
        s.isFavorite = isFavorite
        publish(s, widgets: true)
    }

    /// Called every player tick (0.5 s). Re-anchors the surfaces when the
    /// player has drifted from the published timeline, or when duration,
    /// speed, play state or engine details changed without an explicit call.
    func resync(isPlaying: Bool, position: TimeInterval, duration: TimeInterval, detail: String?) {
        guard current.hasTrack else { return }
        LiveActivityManager.verify()
        let now = Date()
        guard now.timeIntervalSince(trackChangedAt) > 1.0 else { return }
        let rate = Self.playerRate
        let drift = abs(current.elapsed(at: now) - position)
        let durationChanged = duration > 0 && abs(duration - current.duration) > 0.5
        let structural = isPlaying != current.isPlaying || durationChanged || abs(rate - current.rate) > 0.001 || (detail != nil && detail != current.detail)
        guard structural || drift > 1.0 else { return }
        // A frozen position (buffering) keeps "drifting": re-anchor at most
        // every 3 s for that, immediately for everything else.
        if !structural, now.timeIntervalSince(lastResync) < 3 { return }
        lastResync = now
        var s = current
        s.isPlaying = isPlaying
        s.position = position
        if duration > 0 { s.duration = duration }
        s.rate = rate
        if let detail { s.detail = detail }
        s.anchor = now
        // The Live Activity always follows; widgets (reload budget) only for
        // changes a viewer would notice, not sub-3 s nudges.
        publish(s, widgets: structural || drift > 3)
    }

    /// Re-sends the current snapshot, e.g. when the app returns to the
    /// foreground and can start a Live Activity it couldn't from the background.
    func republish() {
        guard current.hasTrack else { return }
        publish(current, widgets: false)
    }

    // MARK: - Publishing

    private func publish(_ snapshot: NowPlayingSnapshot, widgets: Bool) {
        let snapshot = snapshot.sanitized
        current = snapshot
        // The shared defaults can work even when the App Group *folder* isn't
        // reachable (seen on sideloaded installs), so always write them: the
        // widget then shows the track, just without artwork files.
        if !isAppGroupAvailable { logMissingAppGroupOnce() }
        if let ud = defaults {
            if !snapshot.save(to: ud) {
                appError("WidgetDataService: could not encode snapshot for \"\(snapshot.title)\"", category: "widget")
            }
            if widgets { reloadTimelines() }
        }
        LiveActivityManager.publish(snapshot)
    }

    private func baseSnapshot(for song: Song, isFavorite: Bool) -> NowPlayingSnapshot {
        let player = AudioPlayerManager.shared
        var s = NowPlayingSnapshot.empty
        s.trackID = song.id
        s.title = song.displayName
        s.artist = song.artistName
        s.bpm = (song.bpm ?? player?.bpmCache[song.id]).flatMap { $0 > 0 ? $0 : nil }
        s.detail = player?.engineSummary
        s.rate = Self.playerRate
        s.isFavorite = isFavorite
        // Keep the current track's art while its own artwork call is pending.
        if current.trackID == song.id {
            s.artworkFile = current.artworkFile
            s.thumbFile = current.thumbFile
            s.artworkAspect = current.artworkAspect
            s.tint = current.tint
        }
        return s
    }

    private static var playerRate: Double {
        let r = Double(AudioPlayerManager.shared?.audioSettings.speed ?? 1)
        return r.isFinite && r > 0.05 ? r : 1
    }

    /// Trailing-edge throttle: at most one reload per `reloadSpacing`, and a
    /// change that lands inside the window is reloaded when it ends instead of
    /// being dropped (the old throttle dropped it, leaving widgets a track or
    /// a play/pause behind).
    private func reloadTimelines() {
        let since = Date().timeIntervalSince(lastReloadTime)
        if since >= Self.reloadSpacing {
            pendingReload?.cancel()
            pendingReload = nil
            lastReloadTime = Date()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        guard pendingReload == nil else { return }
        let wait = Self.reloadSpacing - since
        pendingReload = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingReload = nil
            self.lastReloadTime = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Artwork

    private struct ArtworkMeta { let aspect: Double; let tint: UInt32 }
    /// Aspect/tint of artwork written this session, by track ID.
    private static var artworkMeta: [String: ArtworkMeta] = [:]
    /// How many tracks' artwork files are kept (current + recent, so skipping
    /// back shows art at once).
    private static let keptArtwork = 4

    private static func fileStem(for trackID: String) -> String {
        // FNV-1a: stable across launches (unlike `hashValue`) and file-name safe.
        var h: UInt64 = 0xcbf29ce484222325
        for b in trackID.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    private static func artworkFileName(for trackID: String) -> String? {
        trackID.isEmpty ? nil : "art-\(fileStem(for: trackID)).jpg"
    }

    private static func thumbFileName(for trackID: String) -> String? {
        trackID.isEmpty ? nil : "thumb-\(fileStem(for: trackID)).jpg"
    }

    /// Writes the widget-size (640 px) and Live Activity (180 px) copies for a
    /// track and prunes old tracks' files.
    private func writeArtwork(_ image: UIImage, trackID: String) -> ArtworkMeta? {
        guard let artName = Self.artworkFileName(for: trackID), let thumbName = Self.thumbFileName(for: trackID) else { return nil }
        let pw = image.size.width * image.scale, ph = image.size.height * image.scale
        guard pw > 0, ph > 0 else { return nil }
        guard let artURL = NowPlayingSnapshot.artworkURL(artName), let thumbURL = NowPlayingSnapshot.artworkURL(thumbName) else {
            return writeArtworkToDefaults(image, trackID: trackID, artName: artName, thumbName: thumbName, aspect: Double(pw / ph))
        }
        guard let big = ImageDownsampler.jpegData(image, maxPixelSize: 640, compressionQuality: 0.85),
              let small = ImageDownsampler.jpegData(image, maxPixelSize: 180, compressionQuality: 0.8)
        else { return nil }
        let dir = artURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try big.write(to: artURL, options: .atomic)
            try small.write(to: thumbURL, options: .atomic)
        } catch {
            appWarn("WidgetDataService: failed to write artwork: \(error.localizedDescription)", category: "widget")
            return nil
        }
        let meta = ArtworkMeta(aspect: Double(pw / ph), tint: Self.averageTint(image))
        Self.artworkMeta[trackID] = meta
        pruneArtwork(in: dir, keeping: trackID)
        return meta
    }

    /// No App Group folder: keep small copies of the current and previous
    /// track's artwork in the shared defaults instead.
    private func writeArtworkToDefaults(_ image: UIImage, trackID: String, artName: String, thumbName: String, aspect: Double) -> ArtworkMeta? {
        guard let ud = defaults,
              let big = ImageDownsampler.jpegData(image, maxPixelSize: 400, compressionQuality: 0.75),
              let small = ImageDownsampler.jpegData(image, maxPixelSize: 180, compressionQuality: 0.75)
        else { return nil }
        let prefix = NowPlayingSnapshot.defaultsArtPrefix
        let listKey = prefix + "files"
        var files = (ud.stringArray(forKey: listKey) ?? []).filter { $0 != artName && $0 != thumbName }
        // Previous track's pair stays (skipping back); anything older goes.
        while files.count > 2 { ud.removeObject(forKey: prefix + files.removeFirst()) }
        ud.set(big, forKey: prefix + artName)
        ud.set(small, forKey: prefix + thumbName)
        ud.set(files + [artName, thumbName], forKey: listKey)
        let meta = ArtworkMeta(aspect: aspect, tint: Self.averageTint(image))
        Self.artworkMeta[trackID] = meta
        return meta
    }

    private func pruneArtwork(in dir: URL, keeping trackID: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let stem = Self.fileStem(for: trackID)
        let byStem = Dictionary(grouping: files) { url -> String in
            let name = url.deletingPathExtension().lastPathComponent
            return String(name.drop(while: { $0 != "-" }).dropFirst())
        }
        let date = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let ordered = byStem.keys.filter { $0 != stem }.sorted { a, b in
            (byStem[a]?.map(date).max() ?? .distantPast) > (byStem[b]?.map(date).max() ?? .distantPast)
        }
        for old in ordered.dropFirst(Self.keptArtwork - 1) {
            byStem[old]?.forEach { try? fm.removeItem(at: $0) }
        }
        // The legacy single-file artwork from older builds.
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            try? fm.removeItem(at: container.appendingPathComponent("widget_artwork.jpg"))
        }
    }

    /// Average colour of the artwork, lifted so it reads as an accent on dark
    /// backgrounds (very dark or grey art would otherwise give a black bar).
    private static func averageTint(_ image: UIImage) -> UInt32 {
        var px = [UInt8](repeating: 0, count: 4)
        guard let cg = image.cgImage,
              let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0x5CD9F2 }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let lifted = UIColor(hue: h, saturation: min(1, max(s, 0.35) * 1.15), brightness: max(b, 0.82), alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
        lifted.getRed(&r, green: &g, blue: &bl, alpha: &a)
        return (UInt32(r * 255) << 16) | (UInt32(g * 255) << 8) | UInt32(bl * 255)
    }

    private func logMissingAppGroupOnce() {
        guard !loggedMissingAppGroup else { return }
        loggedMissingAppGroup = true
        appError("WidgetDataService: App Group folder '\(appGroupID)' is unavailable — widgets get track info but no artwork", category: "widget")
    }
}
