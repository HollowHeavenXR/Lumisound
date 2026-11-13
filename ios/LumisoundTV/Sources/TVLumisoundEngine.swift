import AVFoundation
import Foundation

// MARK: - TVLumisoundEngine
//
// The Lumisound audio engine on Apple TV. Decoding, gapless hand-over,
// crossfades, EQ and effects all run in the Rust core (rust/core/src/engine),
// the same engine as the iPhone app. cpal has no tvOS backend, so audio leaves
// the engine by pull: an AVAudioSourceNode's realtime callback asks the core
// for samples through `engineRenderInto` (rust `engine::pull`). Apple's
// part is only the speaker.

/// Engine events back on the main actor.
final class TVEngineRelay: EngineListener, @unchecked Sendable {
    weak var player: TVPlayerModel?

    func onTrackEnded(id: UInt64) {
        Task { @MainActor [weak self] in self?.player?.engineTrackEnded(id: id) }
    }

    func onTrackStarted(id: UInt64) {
        Task { @MainActor [weak self] in self?.player?.engineTrackStarted(id: id) }
    }

    func onTrackFailed(id: UInt64) {
        Task { @MainActor [weak self] in self?.player?.engineTrackFailed(id: id) }
    }
}

@MainActor
final class TVLumisoundEngine {
    static let shared = TVLumisoundEngine()

    let relay = TVEngineRelay()
    let core: AudioEngine
    private let graph = AVAudioEngine()
    private var source: AVAudioSourceNode?
    /// Interleaved scratch for the render callback (allocated once; the
    /// callback must not allocate).
    private let scratch: UnsafeMutablePointer<Float>
    private static let maxFrames = 8192
    private(set) var isRunning = false

    private init() {
        core = AudioEngine(listener: relay)
        scratch = .allocate(capacity: Self.maxFrames * 2)
        scratch.initialize(repeating: 0, count: Self.maxFrames * 2)
    }

    /// Starts the engine's output (registers the pull) and the system graph.
    func start() {
        guard !isRunning else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try core.startOutput()
        } catch {
            tvError("Engine output failed to start: \(error)", category: "playback")
        }
        let rate = Double(core.outputRate())
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let node = Self.makeSource(format: format, scratch: scratch, maxFrames: Self.maxFrames)
        graph.attach(node)
        graph.connect(node, to: graph.mainMixerNode, format: format)
        source = node
        do {
            try graph.start()
            isRunning = true
        } catch {
            tvError("Audio graph failed to start: \(error.localizedDescription)", category: "playback")
        }
    }

    /// The realtime callback, built outside the main actor so it carries
    /// no actor isolation: it runs on the audio thread and only pulls
    /// samples from the core into the system's buffers.
    nonisolated private static func makeSource(format: AVAudioFormat, scratch: UnsafeMutablePointer<Float>, maxFrames: Int) -> AVAudioSourceNode {
        let address = UInt64(UInt(bitPattern: scratch))
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let src = UnsafeMutablePointer<Float>(bitPattern: UInt(address))!
            var done = 0
            let total = Int(frameCount)
            while done < total {
                let n = min(total - done, maxFrames)
                _ = engineRenderInto(ptr: address, frames: UInt32(n))
                // Standard format is de-interleaved float: one buffer per channel.
                for (ch, buffer) in abl.enumerated() where ch < 2 {
                    guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<n { dst[done + i] = src[i * 2 + ch] }
                }
                done += n
            }
            return noErr
        }
    }

    /// Restarts the system graph after an interruption or route change.
    func restartIfNeeded() {
        guard source != nil, !graph.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? graph.start()
        isRunning = graph.isRunning
    }
}

// MARK: - TVTrackFiles

/// Every track the engine plays is a local file: this downloads it (with
/// the right auth for the bridge endpoint it came from) into Caches and
/// hands back the path. Locked `.lms` tracks stay locked on disk — the core
/// decodes them in place, so there is no unlocked copy anymore. Concurrent
/// requests for one track share a download; old files are trimmed.
actor TVTrackFiles {
    static let shared = TVTrackFiles()

    private var inFlight: [String: Task<URL?, Never>] = [:]
    private let keep = 60

    private var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("lumisound_tv_tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func file(for item: TVPlayable) async -> URL? {
        if item.streamURL.isFileURL { return item.streamURL }
        if let existing = cached(item) { return existing }
        if let t = inFlight[item.id] { return await t.value }
        let t = Task<URL?, Never> { await self.download(item) }
        inFlight[item.id] = t
        let url = await t.value
        inFlight[item.id] = nil
        return url
    }

    /// Starts fetching without waiting (the next track in the queue).
    func prefetch(_ item: TVPlayable) {
        guard cached(item) == nil, inFlight[item.id] == nil, !item.streamURL.isFileURL else { return }
        inFlight[item.id] = Task<URL?, Never> { await self.download(item) }
    }

    private func stem(_ item: TVPlayable) -> String {
        let safe = item.id.map { c -> Character in "/:\\*?\"<>| ".contains(c) ? "_" : c }
        return String(safe.prefix(120))
    }

    private func cached(_ item: TVPlayable) -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let prefix = stem(item) + "."
        guard let name = names.first(where: { $0.hasPrefix(prefix) && !$0.hasSuffix(".part") }) else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 0 else { return nil }
        // Touch so trimming keeps recently played files.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    private func request(for item: TVPlayable) -> URLRequest {
        var r = URLRequest(url: item.streamURL)
        r.timeoutInterval = 180
        // /api/stream/proxy authenticates with the bridge API key and reads
        // the user's token from X-Account-Token; /user/music/stream wants
        // the user token as the bearer. Both headers go on every request.
        let isStreamProxy = item.streamURL.path == "/api/stream/proxy"
        if isStreamProxy {
            r.setValue("Bearer \(TVBridgeClient.officialBridgeAPIKey)", forHTTPHeaderField: "Authorization")
        } else if let token = item.authToken {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let token = item.authToken { r.setValue(token, forHTTPHeaderField: "X-Account-Token") }
        return r
    }

    private func download(_ item: TVPlayable) async -> URL? {
        let started = Date()
        do {
            let (data, response) = try await Core.data(for: request(for: item))
            let http = response as? HTTPURLResponse
            guard let status = http?.statusCode, (200..<300).contains(status), !data.isEmpty else {
                TVRemoteLogger.logError(category: "playback", event: "track_download_failed",
                                        message: "HTTP \(http?.statusCode ?? -1) for \(item.title)")
                return nil
            }
            let ext = Self.ext(for: item, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
            // Locked: keep the real container one level in ("x.opus.lms"),
            // which is how the core finds its format.
            let name = stem(item) + "." + (item.isLocked ? "\(ext).lms" : ext)
            let final = dir.appendingPathComponent(name)
            let part = final.appendingPathExtension("part")
            try data.write(to: part, options: .atomic)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
            TVRemoteLogger.log(category: "playback", event: "track_downloaded",
                               detail: ["title": item.title, "bytes": data.count, "locked": item.isLocked,
                                        "ms": Int(Date().timeIntervalSince(started) * 1000)])
            trim()
            return final
        } catch {
            TVRemoteLogger.logError(category: "playback", event: "track_download_failed", message: error.localizedDescription)
            return nil
        }
    }

    private static func ext(for item: TVPlayable, contentType: String?) -> String {
        if !item.ext.isEmpty { return item.ext.lowercased() }
        let fromURL = item.streamURL.pathExtension.lowercased()
        if ["m4a", "mp3", "opus", "webm", "ogg", "flac", "wav", "aac", "mp4"].contains(fromURL) { return fromURL }
        switch (contentType ?? "").lowercased() {
        case let t where t.contains("webm"): return "webm"
        case let t where t.contains("ogg") || t.contains("opus"): return "opus"
        case let t where t.contains("mpeg"): return "mp3"
        case let t where t.contains("flac"): return "flac"
        case let t where t.contains("wav"): return "wav"
        default: return "m4a"   // the core probes the bytes; this is only a hint
        }
    }

    /// Keeps the newest `keep` files.
    private func trim() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        guard urls.count > keep else { return }
        let dated = urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) {
            try? fm.removeItem(at: url)
        }
    }
}
