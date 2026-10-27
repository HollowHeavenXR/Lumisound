import ImageIO
import SwiftUI
import UIKit

/// Decoded, downsampled remote-image cache shared by every `CachedAsyncImage`.
///
/// Stock `AsyncImage` keeps nothing in memory: every row that scrolls back on
/// screen restarts its load, flashes the placeholder and re-decodes a full-size
/// image on the main thread. This loads off-main, decodes straight to a
/// thumbnail-sized bitmap (ImageIO), dedupes in-flight requests and remembers the
/// result, so scrolling back is an instant synchronous hit.
final class RemoteImageLoader: @unchecked Sendable {
    static let shared = RemoteImageLoader()

    private let memory: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 400
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                diskCapacity: 256 * 1024 * 1024)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()
    private let lock = NSLock()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    /// Longest edge, in pixels, images are decoded to. Plenty for list rows and
    /// cards on a 3x display without holding multi-megapixel bitmaps.
    private let maxPixelSize: CGFloat = 720

    init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.memory.removeAllObjects() }
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }

        let task = inflightTask(for: url)
        return await task.value
    }

    private func inflightTask(for url: URL) -> Task<UIImage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inflight[url] { return existing }
        let task = Task.detached(priority: .userInitiated) { [self] in
            let image = await fetch(url)
            finish(url)
            return image
        }
        inflight[url] = task
        return task
    }

    private func finish(_ url: URL) {
        lock.lock()
        inflight[url] = nil
        lock.unlock()
    }

    private func fetch(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = downsample(data) else { return nil }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    private func downsample(_ data: Data) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,   // decode now, off-main
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Fire-and-forget warm-up for images about to scroll into view.
    func prefetch(_ urls: [URL]) {
        for url in urls where cached(url) == nil {
            Task(priority: .utility) { _ = await load(url) }
        }
    }
}

/// Drop-in replacement for `AsyncImage` backed by `RemoteImageLoader`.
struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    private let content: (AsyncImagePhase) -> Content
    @State private var phase: AsyncImagePhase

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        if let url, let hit = RemoteImageLoader.shared.cached(url) {
            _phase = State(initialValue: .success(Image(uiImage: hit)))
        } else {
            _phase = State(initialValue: .empty)
        }
    }

    init<I: View, P: View>(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == _ConditionalContent<I, P> {
        self.init(url: url) { phase in
            if case .success(let image) = phase { content(image) } else { placeholder() }
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) { await reload() }
    }

    private func reload() async {
        guard let url else { phase = .empty; return }
        if let hit = RemoteImageLoader.shared.cached(url) {
            phase = .success(Image(uiImage: hit))
            return
        }
        // Keep showing the previous image until the new one is ready only when
        // the URL actually changed; otherwise start from the placeholder.
        if case .success = phase {} else { phase = .empty }
        if let image = await RemoteImageLoader.shared.load(url) {
            guard !Task.isCancelled else { return }
            phase = .success(Image(uiImage: image))
        } else if !Task.isCancelled {
            phase = .failure(URLError(.cannotDecodeContentData))
        }
    }
}
