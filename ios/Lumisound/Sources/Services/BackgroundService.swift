import Foundation
import UIKit
import PhotosUI
import SwiftUI

// MARK: - BackgroundAnimation

enum BackgroundAnimation: String, CaseIterable, Codable, Identifiable {
    case fade       = "Fade"
    case slideLeft  = "Slide Left"
    case slideRight = "Slide Right"
    case slideUp    = "Slide Up"
    case slideDown  = "Slide Down"
    case zoomIn     = "Zoom In"
    case zoomOut    = "Zoom Out"
    case zoomBlur   = "Zoom Blur"
    case flip       = "Flip"
    case twist      = "Twist"
    case blur       = "Blur In"
    case none       = "Cut"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var sfSymbol: String {
        switch self {
        case .fade:       return "circle.lefthalf.filled"
        case .slideLeft:  return "arrow.left"
        case .slideRight: return "arrow.right"
        case .slideUp:    return "arrow.up"
        case .slideDown:  return "arrow.down"
        case .zoomIn:     return "magnifyingglass.circle.fill"
        case .zoomOut:    return "minus.magnifyingglass"
        case .zoomBlur:   return "circle.hexagongrid.fill"
        case .flip:       return "rotate.3d"
        case .twist:      return "arrow.triangle.2.circlepath"
        case .blur:       return "aqi.medium"
        case .none:       return "scissors"
        }
    }
}


// MARK: - BackgroundService

/// The gallery background, as the app sees it. The photo store, import rules,
/// slideshow timing and order all live in the Rust core's `GalleryEngine`
/// (rust/core/src/gallery.rs); this class keeps the UI state (the decoded
/// current image, transitions), the settings mirror in UserDefaults that
/// account sync reads, and cloud backup.
///
/// Memory: only the image on screen (and the next one, pre-decoded) is ever
/// held decoded — the previous implementation decoded every photo in the
/// gallery at launch.
@MainActor
final class BackgroundService: ObservableObject {

    /// Weak ref to the single `@StateObject` instance, so account sync can
    /// push pulled settings into the running instance (see `loadSettings()`).
    static weak var shared: BackgroundService?

    let engine: GalleryEngine

    // MARK: Published State

    /// Gallery contents, in order (file + thumbnail paths, sizes, ids).
    @Published private(set) var entries: [GalleryEntry] = []
    /// The decoded image on screen, and its entry id (the transition key).
    @Published private(set) var currentImage: UIImage?
    @Published private(set) var currentEntryID: String?
    @Published private(set) var currentIndex: Int = 0
    /// Length of the transition into `currentImage`.
    @Published private(set) var transitionSeconds: Double = 0.6
    @Published private(set) var isActive: Bool = false
    @Published private(set) var isImporting = false

    @Published var isEnabled: Bool = false { didSet { settingsChanged(restart: true) } }
    @Published var shuffleIntervalSeconds: Double = 30.0 { didSet { settingsChanged(restart: true) } }
    @Published var animation: BackgroundAnimation = .fade { didSet { settingsChanged() } }
    @Published var opacity: Double = 0.35 { didSet { settingsChanged() } }
    @Published var blurRadius: Double = 16.0 {
        didSet {
            settingsChanged()
            // Re-render the current still with the new blur baked in.
            if oldValue != blurRadius, !isLoadingSettings { refreshBlur() }
        }
    }
    /// Blur radius (points) already baked into `currentImage` by the core
    /// (stills only); the view blurs live only for whatever is left.
    @Published private(set) var currentImageBlur: Double = 0
    @Published var kenBurnsEnabled: Bool = false { didSet { settingsChanged() } }
    /// Shuffled order (each photo once per round) instead of gallery order.
    @Published var shuffleOrder: Bool = false { didSet { settingsChanged() } }

    var imageCount: Int { entries.count }
    var hasImages: Bool { !entries.isEmpty }

    // MARK: Private

    private var ticker: Timer?
    private var prefetched: (id: String, image: UIImage, blur: Double)?
    private var foregroundObserver: NSObjectProtocol?
    private var cloudSyncTask: Task<Void, Never>?
    /// A cloud → device sync is running (one at a time).
    private var isSyncingFromCloud = false
    private var isLoadingSettings = false

    static let intervalPresets: [(label: String, seconds: Double)] = [
        ("5 sec", 5), ("10 sec", 10), ("15 sec", 15), ("30 sec", 30),
        ("1 min", 60), ("2 min", 120), ("5 min", 300)
    ]

    private enum Keys {
        static let isEnabled        = "bgService.isEnabled"
        static let shuffleInterval  = "bgService.shuffleInterval"
        static let animation        = "bgService.animation"
        static let opacity          = "bgService.opacity"
        static let blurRadius       = "bgService.blurRadius"
        static let kenBurnsEnabled  = "bgService.kenBurnsEnabled"
        static let shuffleOrder     = "bgService.shuffleOrder"
        static let isBlurredLegacy  = "bgService.isBlurred"
        /// Old Swift gallery manifest (migrated once into the engine).
        static let legacyFilenames  = "bg_image_filenames_v1"
        static let legacyAssetIDs   = "bg_image_asset_ids_v1"
        static let migrated         = "bg_gallery_engine_migrated_v1"
        /// How many entries (from the front) are confirmed uploaded to the cloud.
        static let cloudSyncedCount = "bg_gallery_cloud_synced_count"
        /// Local entry id -> cloud image id, so removing a photo deletes ITS
        /// cloud copy (not just "the last one").
        static let cloudMap         = "bg_gallery_cloud_map_v1"
        /// Cloud image ids this device already has (or adopted, or can't use).
        static let cloudHandled     = "bg_gallery_cloud_handled_v1"
    }

    private var cloudMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Keys.cloudMap) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.cloudMap) }
    }

    private var handledCloudIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Keys.cloudHandled) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Keys.cloudHandled) }
    }

    private static var storeDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Gallery", isDirectory: true)
    }

    private static var legacyDir: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("BackgroundImages", isDirectory: true)
    }

    init() {
        engine = GalleryEngine(dir: Self.storeDir.path)
        Self.shared = self
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, self.hasImages, !self.isActive else { return }
                self.startShuffling()
            }
        }
    }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    // MARK: Settings

    private var engineSettings: GallerySettings {
        GallerySettings(enabled: isEnabled, intervalSecs: shuffleIntervalSeconds, animation: animation.rawValue,
                        opacity: opacity, blurRadius: blurRadius, kenBurns: kenBurnsEnabled, shuffle: shuffleOrder)
    }

    private func settingsChanged(restart: Bool = false) {
        guard !isLoadingSettings else { return }
        saveSettings()
        if restart { isEnabled && hasImages ? startShuffling() : stopShuffling() }
    }

    /// Persists to UserDefaults (read by account sync) and the engine.
    func saveSettings() {
        guard !isLoadingSettings else { return }
        let d = UserDefaults.standard
        d.set(isEnabled, forKey: Keys.isEnabled)
        d.set(shuffleIntervalSeconds, forKey: Keys.shuffleInterval)
        d.set(animation.rawValue, forKey: Keys.animation)
        d.set(opacity, forKey: Keys.opacity)
        d.set(blurRadius, forKey: Keys.blurRadius)
        d.set(kenBurnsEnabled, forKey: Keys.kenBurnsEnabled)
        d.set(shuffleOrder, forKey: Keys.shuffleOrder)
        engine.setSettings(settings: engineSettings)
    }

    /// Reads settings (also after account sync pulled new ones), migrates the
    /// old gallery once, loads the gallery and starts the slideshow.
    func loadSettings() {
        let d = UserDefaults.standard
        isLoadingSettings = true
        isEnabled = d.bool(forKey: Keys.isEnabled)
        if let v = d.object(forKey: Keys.shuffleInterval) as? Double { shuffleIntervalSeconds = v }
        if let raw = d.string(forKey: Keys.animation), let a = BackgroundAnimation(rawValue: raw) { animation = a }
        if let v = d.object(forKey: Keys.opacity) as? Double { opacity = v }
        kenBurnsEnabled = d.bool(forKey: Keys.kenBurnsEnabled)
        shuffleOrder = d.bool(forKey: Keys.shuffleOrder)
        if let v = d.object(forKey: Keys.blurRadius) as? Double {
            blurRadius = v
        } else if let legacy = d.object(forKey: Keys.isBlurredLegacy) as? Bool {
            blurRadius = legacy ? 16 : 0
            d.removeObject(forKey: Keys.isBlurredLegacy)
        }
        isLoadingSettings = false
        engine.setSettings(settings: engineSettings)
        migrateLegacyGalleryIfNeeded()
        reloadEntries()
        // Not switched off for an empty gallery: on a fresh install the
        // photos are still on their way down from the cloud, and saving
        // "off" here (then syncing it to the account) left them unapplied
        // once they arrived. startShuffling() already waits for images.
        showCurrent(animated: false)
        if isEnabled, hasImages { startShuffling() }
        appLog("loadSettings: enabled=\(isEnabled) images=\(entries.count) interval=\(shuffleIntervalSeconds)s shuffle=\(shuffleOrder)", category: "background")
        syncGalleryWithCloud()
    }

    /// The old Swift gallery kept its files in Documents/BackgroundImages with
    /// a UserDefaults manifest: import them (in order) into the engine once.
    private func migrateLegacyGalleryIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Keys.migrated) else { return }
        defer { d.set(true, forKey: Keys.migrated) }
        let fm = FileManager.default
        let dir = Self.legacyDir
        guard fm.fileExists(atPath: dir.path), engine.count() == 0 else { return }
        var names = d.stringArray(forKey: Keys.legacyFilenames) ?? []
        if names.isEmpty {
            let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "gif"]
            names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        }
        let ids = d.stringArray(forKey: Keys.legacyAssetIDs) ?? []
        var paths: [String] = []
        var assetIDs: [String?] = []
        for (i, name) in names.enumerated() {
            let url = dir.appendingPathComponent(name)
            // HEIC isn't readable by the core: hand it a JPEG.
            if url.pathExtension.lowercased() == "heic" {
                guard let img = UIImage(contentsOfFile: url.path), let jpg = img.jpegData(compressionQuality: 0.9) else { continue }
                let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                try? jpg.write(to: tmp)
                paths.append(tmp.path)
            } else {
                paths.append(url.path)
            }
            assetIDs.append(ids.indices.contains(i) ? ids[i] : nil)
        }
        let added = engine.importFiles(paths: paths, assetIds: assetIDs)
        appLog("Gallery: migrated \(added)/\(names.count) image(s) into the gallery engine", category: "background")
        if added > 0 {
            try? fm.removeItem(at: dir)
            d.removeObject(forKey: Keys.legacyFilenames)
            d.removeObject(forKey: Keys.legacyAssetIDs)
        }
    }

    private func reloadEntries() {
        entries = engine.entries()
    }

    // MARK: Slideshow

    func startShuffling() {
        ticker?.invalidate()
        guard isEnabled, hasImages else { isActive = false; return }
        engine.restartTimer(nowSecs: Date().timeIntervalSince1970)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        isActive = true
        if currentImage == nil { showCurrent(animated: false) }
    }

    func stopShuffling() {
        ticker?.invalidate()
        ticker = nil
        isActive = false
    }

    func nextImage() {
        guard let frame = engine.advance(nowSecs: Date().timeIntervalSince1970) else { return }
        present(frame)
    }

    private func tick() {
        guard let frame = engine.tick(nowSecs: Date().timeIntervalSince1970), frame.advanced else { return }
        present(frame)
    }

    private func showCurrent(animated: Bool) {
        guard let frame = engine.current() else {
            currentImage = nil
            currentEntryID = nil
            return
        }
        present(frame, animated: animated)
    }

    /// Decodes the frame's image off the main thread, then swaps it in with
    /// the chosen transition; pre-decodes the next one.
    private func present(_ frame: GalleryFrame, animated: Bool = true) {
        let entry = frame.entry
        Task { [weak self] in
            guard let self else { return }
            let image: UIImage?
            let baked: Double
            if let p = self.prefetched, p.id == entry.id, p.blur == self.blurRadius {
                (image, baked) = (p.image, p.blur)
            } else {
                (image, baked) = await Self.decode(entry, blur: self.blurRadius)
            }
            guard let image else { return }
            let apply = {
                self.currentImage = image
                self.currentImageBlur = baked
                self.currentEntryID = entry.id
                self.currentIndex = Int(frame.index)
                self.transitionSeconds = frame.transitionSecs
            }
            if animated {
                withAnimation(.easeInOut(duration: frame.transitionSecs)) { apply() }
            } else {
                apply()
            }
            self.prefetchNext()
        }
    }

    private func prefetchNext() {
        guard let next = engine.peekNext(), prefetched?.id != next.id else { return }
        Task { [weak self] in
            guard let blur = self?.blurRadius else { return }
            let (img, baked) = await Self.decode(next, blur: blur)
            if let img { self?.prefetched = (next.id, img, baked) }
        }
    }

    /// Screen-sized decode (GIFs stay animated, frames capped). A still
    /// with a blur set comes back already blurred by the core (small,
    /// since blur hides detail), with the radius it carries; the view then
    /// moves a plain image instead of re-blurring a full-screen photo on
    /// every frame of the Ken Burns pan.
    nonisolated private static func decode(_ entry: GalleryEntry, blur: Double) async -> (UIImage?, Double) {
        let (maxSide, longPts) = await MainActor.run {
            let b = UIScreen.main.bounds
            return (max(b.width, b.height) * UIScreen.main.scale, max(b.width, b.height))
        }
        return await Task.detached(priority: .utility) { () -> (UIImage?, Double) in
            let url = URL(fileURLWithPath: entry.path)
            if entry.animated {
                guard let data = try? Data(contentsOf: url) else { return (nil, 0) }
                return (UIImage.gifImage(data: data, maxDimension: 1280), 0)
            }
            if blur >= 1 {
                // Blur strength as a share of the screen, so it looks the same
                // at any image size; 720 px is plenty under a blur.
                let frac = Float(blur / Double(longPts))
                if let data = galleryBlurredStill(path: entry.path, maxLong: 720, sigmaFrac: frac),
                   let img = UIImage(data: Data(data)) {
                    return (img, blur)
                }
            }
            return (ImageDownsampler.downsampled(at: url, maxPixelSize: min(maxSide, 2048)), 0)
        }.value
    }

    /// The blur setting changed: show the current still again with it baked in.
    private func refreshBlur() {
        prefetched = nil
        guard let id = currentEntryID, let frame = engine.current(), frame.entry.id == id else { return }
        present(frame, animated: false)
    }

    /// ImageIO downsample of encoded bytes (used by other image pickers).
    nonisolated static func downsampledImage(from data: Data, maxDimension: CGFloat = 1280) -> UIImage? {
        ImageDownsampler.downsampled(from: data, maxPixelSize: maxDimension)
    }

    /// Thumbnail for the management grid (small file written by the engine).
    nonisolated static func thumbnail(for entry: GalleryEntry) -> UIImage? {
        UIImage(contentsOfFile: entry.thumbPath) ?? ImageDownsampler.downsampled(at: URL(fileURLWithPath: entry.path), maxPixelSize: 240)
    }

    // MARK: Image Management

    /// One picked/downloaded image: raw bytes (GIFs keep animating) and the
    /// Photos asset id when known.
    struct NewImage: Sendable {
        let data: Data
        let assetID: String?
    }

    func isAssetAlreadyAdded(_ assetIdentifier: String) -> Bool {
        engine.containsAsset(assetId: assetIdentifier)
    }

    /// Adds images through the engine (validation, dedupe, normalizing run
    /// off the main thread). Returns (added, duplicates, rejected).
    @discardableResult
    func addImages(_ items: [NewImage], uploadToCloud: Bool = true) async -> (added: Int, duplicates: Int, rejected: Int) {
        let results = await addImagesDetailed(items, uploadToCloud: uploadToCloud)
        var a = 0, d = 0, r = 0
        for res in results {
            switch res {
            case .added: a += 1
            case .duplicate: d += 1
            case .rejected: r += 1
            }
        }
        return (a, d, r)
    }

    /// `addImages` with one result per item, in order.
    private func addImagesDetailed(_ items: [NewImage], uploadToCloud: Bool) async -> [GalleryAddResult] {
        guard !items.isEmpty else { return [] }
        isImporting = true
        defer { isImporting = false }
        let engine = self.engine
        let results: [GalleryAddResult] = await Task.detached(priority: .userInitiated) {
            items.map { item in engine.add(data: Self.coreReadable(item.data), assetId: item.assetID) }
        }.value
        var added: [GalleryEntry] = []
        var dupes = 0, rejected = 0
        for r in results {
            switch r {
            case .added(let entry): added.append(entry)
            case .duplicate: dupes += 1
            case .rejected(let reason):
                rejected += 1
                appWarn("Gallery: image rejected — \(reason)", category: "background")
            }
        }
        reloadEntries()
        if !added.isEmpty {
            if !isEnabled { isEnabled = true }
            if currentImage == nil { showCurrent(animated: true) }
            startShuffling()
            if uploadToCloud { scheduleCloudGallerySync(newEntries: added) }
        }
        appLog("Gallery: added \(added.count), duplicates \(dupes), rejected \(rejected) (total \(entries.count))", category: "background")
        return results
    }

    /// The core reads JPEG/PNG/WebP/GIF: anything else (HEIC from Photos)
    /// becomes a high-quality JPEG first.
    nonisolated private static func coreReadable(_ data: Data) -> Data {
        let b = [UInt8](data.prefix(12))
        let jpeg = b.starts(with: [0xFF, 0xD8, 0xFF])
        let png = b.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let gif = b.starts(with: Array("GIF8".utf8))
        let webp = b.count >= 12 && b[0...3] == [0x52, 0x49, 0x46, 0x46] && b[8...11] == [0x57, 0x45, 0x42, 0x50]
        if jpeg || png || gif || webp { return data }
        guard let img = ImageDownsampler.downsampled(from: data, maxPixelSize: 2048) ?? UIImage(data: data),
              let jpg = img.jpegData(compressionQuality: 0.92) else { return data }
        return jpg
    }

    func removeImage(id: String) {
        engine.remove(id: id)
        reloadEntries()
        if prefetched?.id == id { prefetched = nil }
        if !hasImages {
            stopShuffling()
            currentImage = nil
            currentEntryID = nil
        } else if currentEntryID == id {
            showCurrent(animated: true)
        }
        // Delete this photo's own cloud copy. (This used to delete "however
        // many the cloud has over the local count" from the END of the cloud
        // list, so the cloud drifted away from what's on screen.) A photo
        // with no linked copy was never uploaded: nothing to delete.
        var map = cloudMap
        if let cloudID = map.removeValue(forKey: id) {
            cloudMap = map
            deleteCloudImages(ids: [cloudID])
        }
    }

    func clearAll() {
        engine.clear()
        reloadEntries()
        prefetched = nil
        stopShuffling()
        currentImage = nil
        currentEntryID = nil
        cloudSyncTask?.cancel()
        cloudMap = [:]
        handledCloudIDs = []
        cloudOnlyCount = 0
        UserDefaults.standard.set(0, forKey: Keys.cloudSyncedCount)
        // Everything in the cloud, not "the excess over the local count":
        // with an empty or out-of-sync gallery that deleted nothing, so
        // photos stuck in the cloud could only be cleared by adding one
        // first.
        guard AccountService.shared?.isLoggedIn == true, let token = AccountService.shared?.token, !token.isEmpty,
              let streaming = StreamingService.shared else { return }
        Task {
            do {
                let cloud = try await streaming.fetchGalleryImages(token: token)
                for image in cloud { try? await streaming.deleteGalleryImage(id: image.id, token: token) }
                appLog("Gallery: cleared \(cloud.count) cloud image(s)", category: "background")
            } catch {
                appWarn("Gallery: cloud clear failed: \(error.localizedDescription)", category: "background")
            }
        }
    }

    /// Photos in the account's cloud gallery this device hasn't got (shown in
    /// Settings so they can be cleared even with none local).
    @Published private(set) var cloudOnlyCount: Int = 0

    private func deleteCloudImages(ids: [String]) {
        guard !ids.isEmpty, let token = AccountService.shared?.token, !token.isEmpty,
              let streaming = StreamingService.shared else { return }
        // The ids stay in handledCloudIDs, so a sync running meanwhile
        // can't download them again before the deletes land.
        Task {
            for id in ids { try? await streaming.deleteGalleryImage(id: id, token: token) }
        }
    }

    func moveImage(from: Int, to: Int) {
        engine.moveEntry(from: UInt32(from), to: UInt32(to))
        reloadEntries()
    }

    // MARK: Cloud Gallery Backup (automatic for logged-in users)

    /// 2 s after the last change: uploads `newEntries`, or (removal/clear)
    /// prunes the cloud copy down to the local count.
    private func scheduleCloudGallerySync(newEntries: [GalleryEntry]?) {
        guard AccountService.shared?.isLoggedIn == true, let streaming = StreamingService.shared else { return }
        cloudSyncTask?.cancel()
        cloudSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, let token = AccountService.shared?.token, !token.isEmpty else { return }
            if let newEntries, !newEntries.isEmpty {
                let bgTask = BackgroundTaskToken(name: "GalleryCloudUpload")
                defer { bgTask.end() }
                for entry in newEntries {
                    guard !Task.isCancelled else { return }
                    guard let order = self.entries.firstIndex(where: { $0.id == entry.id }),
                          let image = UIImage(contentsOfFile: entry.path) else { continue }
                    do {
                        let cloudID = try await streaming.uploadGalleryImage(image, token: token, displayOrder: order)
                        var map = self.cloudMap
                        map[entry.id] = cloudID
                        self.cloudMap = map
                        var handled = self.handledCloudIDs
                        handled.insert(cloudID)
                        self.handledCloudIDs = handled
                        if order + 1 > UserDefaults.standard.integer(forKey: Keys.cloudSyncedCount) {
                            UserDefaults.standard.set(order + 1, forKey: Keys.cloudSyncedCount)
                        }
                    } catch {
                        appWarn("Gallery: cloud upload failed: \(error.localizedDescription)", category: "background")
                        return // resumed from the first unconfirmed image next launch
                    }
                }
                appLog("Gallery: backed up \(newEntries.count) image(s) to the cloud", category: "background")
                return
            }
            do {
                let cloud = try await streaming.fetchGalleryImages(token: token)
                let excess = cloud.count - self.entries.count
                if excess > 0 {
                    for image in cloud.sorted(by: { $0.displayOrder > $1.displayOrder }).prefix(excess) {
                        guard !Task.isCancelled else { return }
                        try? await streaming.deleteGalleryImage(id: image.id, token: token)
                    }
                }
                UserDefaults.standard.set(self.entries.count, forKey: Keys.cloudSyncedCount)
            } catch {
                appWarn("Gallery: cloud reconcile failed: \(error.localizedDescription)", category: "background")
            }
        }
    }

    /// Two-way gallery sync, run at launch and after account sync:
    /// - photos in the account's cloud gallery that this device doesn't have
    ///   are downloaded (4 at a time) and applied as they arrive — a fresh
    ///   install gets its backgrounds back, and photos added on another
    ///   device show up here;
    /// - local photos with no cloud copy are uploaded.
    ///
    /// Replaces a restore that only ran on an empty gallery, fetched all
    /// photos one by one, added nothing until the last one was in, and
    /// silently dropped everything if the app was closed or suspended
    /// part-way (116 photos listed, 0 restored, nothing logged).
    func syncGalleryWithCloud() {
        guard !isSyncingFromCloud, AccountService.shared?.isLoggedIn == true,
              let token = AccountService.shared?.token, !token.isEmpty,
              let streaming = StreamingService.shared else { return }
        isSyncingFromCloud = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isSyncingFromCloud = false }
            let cloud: [GalleryImageInfo]
            do {
                cloud = try await streaming.fetchGalleryImages(token: token).sorted { $0.displayOrder < $1.displayOrder }
            } catch {
                appWarn("Gallery: cloud sync failed to list images: \(error.localizedDescription)", category: "background")
                return
            }
            let d = UserDefaults.standard
            if d.object(forKey: Keys.cloudMap) == nil {
                // First run with per-photo tracking. A gallery that already
                // exists here was backed up in order: pair photos by
                // position instead of downloading them again (the cloud
                // copies are re-encoded, so they would not dedupe).
                var map: [String: String] = [:]
                if self.hasImages {
                    for (entry, image) in zip(self.entries, cloud) { map[entry.id] = image.id }
                    self.handledCloudIDs = Set(cloud.map(\.id))
                    appLog("Gallery: linked \(map.count) local photo(s) to their cloud copies", category: "background")
                }
                self.cloudMap = map
            }
            // Drop links to local photos that no longer exist.
            let localIDs = Set(self.entries.map(\.id))
            let liveCloud = Set(cloud.map(\.id))
            self.cloudMap = self.cloudMap.filter { localIDs.contains($0.key) && liveCloud.contains($0.value) }

            let missing = cloud.filter { !self.handledCloudIDs.contains($0.id) }
            self.cloudOnlyCount = missing.count
            if !missing.isEmpty {
                await self.download(missing, streaming: streaming, token: token)
            }
            let handledNow = self.handledCloudIDs
            self.cloudOnlyCount = cloud.filter { !handledNow.contains($0.id) }.count
            await self.uploadUnbackedEntries(streaming: streaming, token: token)
        }
    }

    private func download(_ missing: [GalleryImageInfo], streaming: StreamingService, token: String) async {
        appLog("Gallery: restoring \(missing.count) photo(s) from the cloud", category: "background")
        let bgTask = BackgroundTaskToken(name: "GalleryCloudRestore")
        defer { bgTask.end() }
        var restored = 0, failed = 0
        for start in stride(from: 0, to: missing.count, by: 4) {
            let batch = Array(missing[start..<min(start + 4, missing.count)])
            let data: [Int: Data] = await withTaskGroup(of: (Int, Data?).self) { group in
                for (i, info) in batch.enumerated() {
                    group.addTask { (i, await streaming.fetchGalleryImageBytes(info, token: token)) }
                }
                var out: [Int: Data] = [:]
                for await (i, d) in group { if let d { out[i] = d } }
                return out
            }
            var items: [NewImage] = []
            var infos: [GalleryImageInfo] = []
            for (i, info) in batch.enumerated() {
                if let d = data[i] { items.append(NewImage(data: d, assetID: nil)); infos.append(info) } else { failed += 1 }
            }
            // Added (and applied) batch by batch, and recorded as we go, so
            // an interrupted restore keeps what it got and resumes next time.
            let results = await addImagesDetailed(items, uploadToCloud: false)
            var map = cloudMap
            var handled = handledCloudIDs
            for (info, result) in zip(infos, results) {
                switch result {
                case .added(let entry): map[entry.id] = info.id; restored += 1
                case .duplicate(let id): if map[id] == nil { map[id] = info.id }
                case .rejected: break
                }
                handled.insert(info.id)
            }
            cloudMap = map
            handledCloudIDs = handled
            cloudOnlyCount = max(0, cloudOnlyCount - batch.count)
        }
        if failed > 0 {
            appWarn("Gallery: \(failed) cloud photo(s) could not be downloaded — will retry next launch", category: "background")
        }
        appLog("Gallery: restored \(restored) photo(s) from the cloud", category: "background")
        if restored > 0 {
            ToastCenter.shared.show("Restored \(restored) background image\(restored == 1 ? "" : "s") from your account", category: .success, icon: "icloud.and.arrow.down")
        }
    }

    /// Uploads local photos that have no cloud copy yet (also finishes an
    /// interrupted backup).
    private func uploadUnbackedEntries(streaming: StreamingService, token: String) async {
        let map = cloudMap
        let pending = entries.filter { map[$0.id] == nil }
        guard !pending.isEmpty else { return }
        scheduleCloudGallerySync(newEntries: pending)
    }
}
