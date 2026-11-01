import Foundation

/// Loudness normalization gain (dB) to bring a track to -18 LUFS, measured
/// over its middle 60 s with ITU-R BS.1770 K-weighting and gating. Computed
/// and cached by the Rust core (verified against ffmpeg's ebur128).
actor NormalizationService {
    static let shared = NormalizationService()

    private init() {
        // One-time import of the UserDefaults-era cache (same key format).
        if let legacy = UserDefaults.standard.dictionary(forKey: "normalization_gain_cache_v2") as? [String: Float],
           let data = try? JSONSerialization.data(withJSONObject: legacy) {
            normalizationImportLegacy(json: data)
        }
    }

    func gain(for url: URL) async -> Float {
        let path = url.path
        return await Task.detached(priority: .utility) {
            normalizationGain(path: path, cacheDir: CoreAudio.unlockDir)
        }.value
    }
}
