import Foundation

/// Leading-silence detection for "Skip Silent Intros" — analysed and cached
/// by the Rust core (20 ms RMS windows vs 1% of the opening peak / -50 dBFS).
actor SilenceTrimAnalyzer {
    static let shared = SilenceTrimAnalyzer()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if let data = try? Data(contentsOf: caches.appendingPathComponent("silence_trim_cache_v3.json")) {
            analysisImportLegacy(namespace: "silence_trim", json: data)
        }
    }

    func leadingSilence(for url: URL) async -> TimeInterval {
        let path = url.standardizedFileURL.path
        var pcm: [Int16]? = nil
        if !CoreAudio.canDecode(path: path) {
            // Opus/WebM: decoded by AVFoundation, analysed by the core.
            pcm = await BPMAnalyzerService.decodeMonoAV(url: url, sampleRate: 11025, maxSeconds: 15)
            if pcm == nil { return 0 }
        }
        return leadingSilence(path: path, cacheDir: CoreAudio.unlockDir, pcm: pcm)
    }
}
