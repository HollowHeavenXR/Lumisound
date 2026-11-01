import Foundation

/// Hum-to-search: pitch contours (8 kHz ACF, semitones vs median F0) and
/// sliding-correlation matching run in the Rust core, which also caches
/// library tracks' contours.
actor PitchContourService {
    static let shared = PitchContourService()

    struct Match: Identifiable {
        let songID: String
        let score: Float
        var id: String { songID }
    }

    private static let matchFloor: Float = 0.55
    private static let maxFreshAnalysesPerSearch = 150

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if let data = try? Data(contentsOf: caches.appendingPathComponent("pitch_contour_cache_v1.json")) {
            pitchContourImportLegacy(json: data)
        }
    }

    func search(humURL: URL, songs: [(id: String, url: URL)], limit: Int = 10) async -> [Match] {
        guard let hum = await Self.contour(url: humURL, maxSeconds: 30, cache: false) else { return [] }
        var scored: [Match] = []
        var budget = Self.maxFreshAnalysesPerSearch
        for (id, url) in songs {
            let path = url.standardizedFileURL.path
            var candidate = pitchContourCached(path: path)
            if candidate == nil, budget > 0 {
                budget -= 1
                candidate = await Self.contour(url: url, maxSeconds: 30, cache: true)
            }
            guard let candidate else { continue }
            let score = pitchMatchScore(query: hum, candidate: candidate)
            if score >= Self.matchFloor { scored.append(Match(songID: id, score: score)) }
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    private static func contour(url: URL, maxSeconds: Double, cache: Bool) async -> [Float]? {
        let path = url.standardizedFileURL.path
        var pcm: [Int16]? = nil
        if !CoreAudio.canDecode(path: path) {
            pcm = await BPMAnalyzerService.decodeMonoAV(url: url, sampleRate: 8000, maxSeconds: maxSeconds)
            if pcm == nil { return nil }
        }
        return pitchContour(path: path, cacheDir: CoreAudio.unlockDir, pcm: pcm, maxSecs: maxSeconds, cache: cache)
    }
}
