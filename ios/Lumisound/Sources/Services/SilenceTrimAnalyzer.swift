import Foundation

/// Skip Silent Intros: where each track's music starts, from the Rust core
/// (rust/core/src/intro.rs). Silence and steady hiss before the music are
/// skipped; quiet musical intros and fade-ins are kept. Cached per file.
enum SilenceTrimAnalyzer {
    /// Cached start offset, never decodes: nil when the file isn't analysed yet.
    static func cachedStart(for url: URL) -> TimeInterval? {
        introSkipCached(path: url.standardizedFileURL.path)
    }

    /// Start offset (analysed off the main thread on a cache miss).
    static func start(for url: URL) async -> TimeInterval {
        let path = url.standardizedFileURL.path
        if let hit = introSkipCached(path: path) { return hit }
        var pcm: [Int16]? = nil
        if !CoreAudio.canDecode(path: path) {
            // Opus in WebM and the like: AVFoundation decodes, the core analyses.
            pcm = await BPMAnalyzerService.decodeMonoAV(url: url, sampleRate: 11025, maxSeconds: 40)
            if pcm == nil { return 0 }
        }
        let samples = pcm
        return await Task.detached(priority: .utility) { introSkip(path: path, pcm: samples) }.value
    }
}
