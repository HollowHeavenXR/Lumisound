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
    @Published var blurRadius: Double = 16.0 { didSet { settingsChanged() } }
    @Published var kenBurnsEnabled: Bool = false { didSet { settingsChanged() } }
    /// Shuffled order (each photo once per round) instead of gallery order.
    @Published var shuffleOrder: Bool = false { didSet { settingsChanged() } }

    var imageCount: Int { entries.count }
    var hasImages: Bool { !entries.isEmpty }

    // MARK: Private

    private var ticker: Timer?
    private var prefetched: (id: String, image: UIImage)?
    private var foregroundObserver: NSObjectProtocol?
    private var cloudSyncTask: Task<Void, Never>?
    private var didAttemptCloudRestore = false
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
        if isEnabled, !hasImages { isEnabled = false }
        showCurrent(animated: false)
        if isEnabled, hasImages { startShuffling() }
        appLog("loadSettings: enabled=\(isEnabled) images=\(entries.count) interval=\(shuffleIntervalSeconds)s shuffle=\(shuffleOrder)", category: "background")
        restoreGalleryFromCloudIfNeeded()
        resumeIncompleteCloudGallerySyncIfNeeded()
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
            if let p = self.prefetched, p.id == entry.id {
                image = p.image
            } else {
                image = await Self.decode(entry)
            }
            guard let image else { return }
            let apply = {
                self.currentImage = image
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
            if let img = await Self.decode(next) { self?.prefetched = (next.id, img) }
        }
    }

    /// Screen-sized decode (GIFs stay animated, frames capped).
    nonisolated private static func decode(_ entry: GalleryEntry) async -> UIImage? {
        let maxSide = await MainActor.run {
            let b = UIScreen.main.bounds
            return max(b.width, b.height) * UIScreen.main.scale
        }
        return await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: entry.path)
            if entry.animated {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return UIImage.gifImage(data: data, maxDimension: 1280)
            }
            return ImageDownsampler.downsampled(at: url, maxPixelSize: min(maxSide, 2048))
        }.value
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
        guard !items.isEmpty else { return (0, 0, 0) }
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
        return (added.count, dupes, rejected)
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
        scheduleCloudGallerySync(newEntries: nil)
    }

    func clearAll() {
        engine.clear()
        reloadEntries()
        prefetched = nil
        stopShuffling()
        currentImage = nil
        currentEntryID = nil
        scheduleCloudGallerySync(newEntries: nil)
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
                        _ = try await streaming.uploadGalleryImage(image, token: token, displayOrder: order)
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

    /// Re-uploads whatever an interrupted backup didn't finish.
    func resumeIncompleteCloudGallerySyncIfNeeded() {
        guard AccountService.shared?.isLoggedIn == true else { return }
        let synced = UserDefaults.standard.integer(forKey: Keys.cloudSyncedCount)
        guard synced < entries.count else { return }
        scheduleCloudGallerySync(newEntries: Array(entries[synced...]))
    }

    /// Fresh install with an empty gallery: bring the account's backup back.
    func restoreGalleryFromCloudIfNeeded() {
        guard !didAttemptCloudRestore else { return }
        guard !hasImages else { didAttemptCloudRestore = true; return }
        guard AccountService.shared?.isLoggedIn == true, let token = AccountService.shared?.token, !token.isEmpty,
              let streaming = StreamingService.shared else { return }
        didAttemptCloudRestore = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let cloud = try await streaming.fetchGalleryImages(token: token)
                var items: [NewImage] = []
                for entry in cloud.sorted(by: { $0.displayOrder < $1.displayOrder }) {
                    if let img = await streaming.fetchGalleryImageData(entry, token: token),
                       let data = img.jpegData(compressionQuality: 0.92) {
                        items.append(NewImage(data: data, assetID: nil))
                    }
                }
                guard !items.isEmpty else { return }
                let r = await self.addImages(items, uploadToCloud: false)
                // Came from the cloud: already backed up.
                UserDefaults.standard.set(self.entries.count, forKey: Keys.cloudSyncedCount)
                if r.added > 0 {
                    ToastCenter.shared.show("Restored \(r.added) background image\(r.added == 1 ? "" : "s") from your account", category: .success, icon: "icloud.and.arrow.down")
                }
            } catch {
                appWarn("Gallery: cloud restore failed: \(error.localizedDescription)", category: "background")
            }
        }
    }
}
