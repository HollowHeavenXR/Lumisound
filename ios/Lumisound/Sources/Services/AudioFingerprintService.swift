import Foundation

/// Acoustic fingerprints for the duplicate finder: 18 × 48-band spectral
/// segments from 45 s after an 8 s skip, compared with shift-tolerant
/// cosine similarity. Computed, cached and compared by the Rust core.
actor AudioFingerprintService {
    static let shared = AudioFingerprintService()
    static let matchThreshold: Float = 0.99

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if let data = try? Data(contentsOf: caches.appendingPathComponent("audio_fingerprint_cache_v6.json")) {
            audioFingerprintImportLegacy(json: data)
        }
    }

    func fingerprint(for url: URL) async -> [[Float]]? {
        let path = url.standardizedFileURL.path
        var pcm: [Int16]? = nil
        if !CoreAudio.canDecode(path: path) {
            pcm = await BPMAnalyzerService.decodeMonoAV(url: url, sampleRate: 11025, maxSeconds: 53)
            if let p = pcm, p.count > 11025 * 13 { pcm = Array(p.dropFirst(11025 * 8)) }
            if pcm == nil { return nil }
        }
        let v = audioFingerprint(path: path, cacheDir: CoreAudio.unlockDir, pcm: pcm)
        if v == nil { appWarn("AudioFingerprintService: could not fingerprint \(url.lastPathComponent)", category: "audio") }
        return v
    }

    static func sequenceSimilarity(_ a: [[Float]], _ b: [[Float]]) -> Float {
        fingerprintSimilarity(a: a, b: b)
    }
}
