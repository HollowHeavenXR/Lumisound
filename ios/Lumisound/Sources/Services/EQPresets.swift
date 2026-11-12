import Foundation

/// A LumiEQ preset: an id into the Rust engine's catalogue
/// (rust/core/src/engine/eq.rs), which designs every curve against the
/// engine's own filter bank and owns names, taglines, gains and Auto EQ.
///
/// Stored as its id. Settings saved before LumiEQ hold the old display names
/// ("Bass Boost", "Hip-Hop"…); decoding resolves those to their successors
/// through `eqPresetResolve`, so nobody's choice is lost.
struct EQPreset: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    /// Always succeeds: unknown ids resolve to Reference ("flat").
    init?(rawValue: String) {
        self.rawValue = eqPresetResolve(stored: rawValue)
    }

    private init(id: String) { self.rawValue = id }

    // Stored as a bare string, exactly like the enum it replaced.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.rawValue = eqPresetResolve(stored: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    var id: String { rawValue }

    static let flat = EQPreset(id: "flat")
    static let custom = EQPreset(id: "custom")

    /// The engine's catalogue, read once.
    nonisolated(unsafe) static let catalogue: [EqPresetInfo] = eqPresets()

    /// Every preset in display order, Custom last.
    static var allCases: [EQPreset] { catalogue.map { EQPreset(id: $0.id) } + [.custom] }

    /// Categories in display order with their presets.
    static var grouped: [(category: String, presets: [EQPreset])] {
        var order: [String] = []
        var map: [String: [EQPreset]] = [:]
        for info in catalogue {
            if map[info.category] == nil { order.append(info.category) }
            map[info.category, default: []].append(EQPreset(id: info.id))
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private var info: EqPresetInfo? { Self.catalogue.first { $0.id == rawValue } }

    var displayName: String { self == .custom ? "Custom" : (info?.name ?? rawValue) }
    var tagline: String { self == .custom ? "Your own curve." : (info?.tagline ?? "") }
    var category: String { info?.category ?? "Custom" }

    /// Ten gains (dB) for 32 Hz…16 kHz. Custom has none of its own.
    var bands: [Float] { info?.gains ?? Array(repeating: 0, count: 10) }

    /// Auto EQ: genre tag first, tempo as the fallback (engine rules).
    static func auto(forBPM bpm: Double?, genre: String? = nil) -> EQPreset? {
        eqAutoPreset(bpm: bpm, genre: genre).map(EQPreset.init(id:))
    }

    /// Genre-only lookup (nil when the tag isn't recognised).
    static func preset(forGenre genre: String?) -> EQPreset? {
        guard let genre, !genre.isEmpty else { return nil }
        return eqAutoPreset(bpm: nil, genre: genre).map(EQPreset.init(id:))
    }

    /// The curve the engine will play for `gains`, in dB at `points`
    /// log-spaced frequencies 20 Hz…20 kHz (including its level match).
    static func responseCurve(_ gains: [Float], points: Int = 96, loudnessMatch: Bool = true) -> [Float] {
        eqResponseCurve(gains: gains, points: UInt32(points), loudnessMatch: loudnessMatch)
    }
}
