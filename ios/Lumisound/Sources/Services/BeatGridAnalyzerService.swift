import Foundation

/// Beat grid (onset times quantised to the dominant pulse, first 12 min) for
/// beat-synced visuals and smart transitions. Analysed and cached by the
/// Rust core; concurrent requests for the same file share one analysis.
actor BeatGridAnalyzerService {
    static let shared = BeatGridAnalyzerService()
    private static let maxAnalysisSeconds = 12 * 60.0
    private var inFlight: [String: Task<[Double], Never>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if let data = try? Data(contentsOf: caches.appendingPathComponent("beat_grid_cache_v4.json")) {
            beatGridImportLegacy(json: data)
        }
    }

    func beatGrid(for url: URL) async -> [Double]? {
        let path = url.standardizedFileURL.path
        if let cached = beatGridCached(path: path) { return cached.isEmpty ? nil : cached }
        if let existing = inFlight[path] {
            let r = await existing.value
            return r.isEmpty ? nil : r
        }
        let task = Task<[Double], Never> {
            var pcm: [Int16]? = nil
            if !CoreAudio.canDecode(path: path) {
                pcm = await BPMAnalyzerService.decodeMonoAV(url: url, sampleRate: 11025, maxSeconds: Self.maxAnalysisSeconds)
                if pcm == nil { return [] }
            }
            return LumisoundCoreBeat.grid(path: path, pcm: pcm)
        }
        inFlight[path] = task
        let onsets = await task.value
        inFlight[path] = nil
        return onsets.isEmpty ? nil : onsets
    }

    func cachedBeatGrid(for url: URL) -> [Double]? {
        guard let c = beatGridCached(path: url.standardizedFileURL.path), !c.isEmpty else { return nil }
        return c
    }
}

/// Outside the actor so its `beatGrid` member doesn't shadow the core function.
enum LumisoundCoreBeat {
    static func grid(path: String, pcm: [Int16]?) -> [Double] {
        beatGrid(path: path, cacheDir: CoreAudio.unlockDir, pcm: pcm)
    }
}
