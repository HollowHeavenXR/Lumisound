import Foundation

struct CachedResolution {
    let title: String
    let artist: String
    let memoryID: Int?
}

/// Aria metadata-resolve answers per filename, stored in the Rust core.
actor IntelligenceSuggestionCache {
    static let shared = IntelligenceSuggestionCache()
    private static let legacyKey = "intelligence_metadata_resolve_v1"

    private init() {
        if let legacy = UserDefaults.standard.dictionary(forKey: Self.legacyKey) as? [String: [String: String]],
           let data = try? JSONSerialization.data(withJSONObject: legacy) {
            suggestionsImportLegacy(json: data)
        }
    }

    func lookup(_ filename: String) -> CachedResolution? {
        suggestionLookup(filename: filename).map { CachedResolution(title: $0.title, artist: $0.artist, memoryID: $0.memoryId.map(Int.init)) }
    }

    func store(_ filename: String, title: String, artist: String, memoryID: Int?) {
        suggestionStore(filename: filename, title: title, artist: artist, memoryId: memoryID.map(Int64.init))
    }

    /// Writes happen immediately in the core; kept for existing callers.
    func persist() {}
}
