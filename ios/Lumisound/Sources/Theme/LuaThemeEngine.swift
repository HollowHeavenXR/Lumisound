import Foundation
import SwiftUI

// MARK: - LuaThemeEngine
//
// The Lua-scripted config/theming/logic layer. A "preset" is a single .lua
// script (bundled under Lumisound/Resources/LuaPresets/, see `LuaPreset`
// below) that computes and returns a `theme` table covering everything
// AppearanceView otherwise lets a user set by hand: accent/background
// colors, font/panel/artwork/seeker/card styles, Liquid Glass tuning, a
// handful of feature flags, and a couple of library display-logic hooks.
//
// This deliberately does NOT introduce a second, parallel place the rest of
// the app has to check for its look — `apply(_:)` below fans a resolved
// preset straight out into the SAME UserDefaults keys AppTheme/GlassSettings/
// AppearanceView's own `@AppStorage` properties already read (see
// `applyToAppTheme(_:)`). Once applied, a Lua preset is indistinguishable
// from a user having manually picked each of those values themselves — the
// rest of the app needs zero awareness that Lua was involved.

@MainActor
final class LuaThemeEngine: ObservableObject {
    static let shared = LuaThemeEngine()

    /// The currently-applied preset, if any. `nil` means the app is using
    /// whichever individual settings AppearanceView/GlassSettingsView/etc.
    /// already had saved (i.e. no preset has ever been applied, or the user
    /// cleared one).
    @Published private(set) var activePresetID: String?

    /// Set when the most recent `apply(_:)` call failed — surfaced by
    /// `LuaThemePresetsView` so a bad/edited-by-hand script doesn't fail
    /// silently.
    @Published private(set) var lastError: String?

    /// The currently-applied USER-imported preset's file URL, if any —
    /// mutually exclusive with `activePresetID` (applying one clears the
    /// other). See "Community preset sharing" below.
    @Published private(set) var activeUserScriptURL: URL?

    /// The raw accent hex string from whichever preset (bundled or user) is
    /// currently active, `nil` if none — read directly off the resolved
    /// `LuaThemeConfig` rather than round-tripped back out of the `Color`/
    /// `UIColor` `saveAccentColor(_:)` archives into UserDefaults, so
    /// `PhoneWatchSync` can mirror it to the watch without a lossy
    /// Color->hex conversion.
    @Published private(set) var activeAccentHex: String?

    private enum Keys {
        static let activePreset = "lua_active_preset"
        static let activeUserScriptPath = "lua_active_user_script_path"
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Keys.activePreset),
           let preset = LuaPreset(rawValue: raw) {
            // Re-resolve at launch rather than trusting whatever the
            // individual keys already contain — keeps a preset's look
            // reproducible even if something else in Settings wrote to one
            // of the same keys in between launches.
            apply(preset, persist: false)
        } else if let path = UserDefaults.standard.string(forKey: Keys.activeUserScriptPath) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                applyUserScript(at: url, persist: false)
            }
        }
    }

    /// Runs `preset`'s script and fans its resolved values out across the
    /// app. Returns `false` (and sets `lastError`) if the script fails to
    /// load, run, or decode — the previously-applied look is left untouched
    /// in that case.
    @discardableResult
    func apply(_ preset: LuaPreset, persist: Bool = true) -> Bool {
        do {
            let config = try resolve(preset)
            applyToAppTheme(config)
            activePresetID = preset.rawValue
            activeUserScriptURL = nil
            activeAccentHex = config.colors.accent
            lastError = nil
            if persist {
                UserDefaults.standard.set(preset.rawValue, forKey: Keys.activePreset)
                UserDefaults.standard.removeObject(forKey: Keys.activeUserScriptPath)
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Community preset sharing
    //
    // A bundled `LuaPreset` is one of the fixed 10 baked into the app; a
    // USER preset is any other `.lua` script (pasted from a friend, saved
    // from a file, or hand-written) living under `userPresetsDirectory`.
    // Both run through the exact same `theme` table contract, so a shared
    // preset is indistinguishable from a bundled one once applied.

    private static let userPresetsSubdirectory = "LuaThemePresets"

    /// Documents/LuaThemePresets — where imported/community theme scripts
    /// live, created lazily on first import.
    static var userPresetsDirectory: URL {
        LuaUserScriptLibrary.directory(named: userPresetsSubdirectory)
    }

    /// User-imported theme preset scripts, alongside the bundled `LuaPreset` enum.
    func userPresetScripts() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: Self.userPresetsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "lua" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Imports preset script source text (pasted from a friend, or read from
    /// a file picked in the Files app) into the user presets directory.
    @discardableResult
    func importUserPreset(source: String, suggestedName: String) throws -> URL {
        let dir = Self.userPresetsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = suggestedName.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_").lowercased()
        let base = safeName.isEmpty ? "custom_theme" : safeName
        var candidate = dir.appendingPathComponent("\(base).lua")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_\(suffix).lua")
            suffix += 1
        }
        try source.write(to: candidate, atomically: true, encoding: .utf8)
        return candidate
    }

    func deleteUserPreset(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        if activeUserScriptURL == url { clearPreset() }
    }

    /// Runs and applies a user-imported preset script — same contract as a
    /// bundled one (assigns a global `theme` table), but read straight off
    /// disk instead of from the app bundle.
    @discardableResult
    func applyUserScript(at url: URL, persist: Bool = true) -> Bool {
        do {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw LuaThemeEngineError.scriptNotFound(url.lastPathComponent)
            }
            let wrapped = source + "\nreturn json.encode(theme)\n"
            let config = try LuaJSONBridge.run(wrapped, chunkName: url.lastPathComponent, as: LuaThemeConfig.self)
            applyToAppTheme(config)
            activePresetID = nil
            activeUserScriptURL = url
            activeAccentHex = config.colors.accent
            lastError = nil
            if persist {
                UserDefaults.standard.set(url.path, forKey: Keys.activeUserScriptPath)
                UserDefaults.standard.removeObject(forKey: Keys.activePreset)
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Clears the active-preset marker and the two Lua-only knobs that have
    /// no other UI (the custom background override + layout scale). Every
    /// individual style key a preset also wrote (accent color, font style,
    /// panel material, …) is left as-is — exactly like switching
    /// `AppBackgroundTheme` doesn't "unset" the font style — since
    /// AppearanceView's own "Reset to Default" already covers restoring
    /// those wholesale.
    func clearPreset() {
        UserDefaults.standard.removeObject(forKey: Keys.activePreset)
        UserDefaults.standard.removeObject(forKey: Keys.activeUserScriptPath)
        activePresetID = nil
        activeUserScriptURL = nil
        activeAccentHex = nil
        lastError = nil
        AppTheme.resetCustomBackgroundOverride()
        AppTheme.resetLayoutScales()
    }

    // MARK: - Script execution
    //
    // Every call into the third-party `LuaSwift` package (github.com/ChrisGVE/
    // LuaSwift) is isolated to this one method. API confirmed directly against
    // the package's README/docs (docs/core-api.md, docs/modules/json.md):
    // `LuaEngine()` is a throwing initializer, `ModuleRegistry.install(in:)`
    // installs the JSON module (not a per-module `JSONModule` type), and
    // `evaluate(_:)` returns a `LuaValue` with a direct `.stringValue`
    // accessor — no reflection needed to unwrap it.
    private func resolve(_ preset: LuaPreset) throws -> LuaThemeConfig {
        guard let url = Bundle.main.url(forResource: preset.filename, withExtension: "lua", subdirectory: "LuaPresets") else {
            throw LuaThemeEngineError.scriptNotFound(preset.filename)
        }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw LuaThemeEngineError.scriptNotFound(preset.filename)
        }


        // Every preset script (Resources/LuaPresets/*.lua) is expected to
        // finish by assigning a global table named `theme` — see any of the
        // 10 bundled scripts for the exact shape. Appending the encode call
        // here, rather than requiring every preset author to remember it,
        // keeps preset scripts focused purely on values.
        let wrapped = source + "\nreturn json.encode(theme)\n"

        let jsonString = try luaEvalString(source: wrapped, chunkName: preset.filename)

        guard let data = jsonString.data(using: .utf8) else {
            throw LuaThemeEngineError.unexpectedResult
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(LuaThemeConfig.self, from: data)
        } catch {
            throw LuaThemeEngineError.decodeFailed(error)
        }
    }

    /// Fans a decoded preset out to every existing UserDefaults key the rest
    /// of the app already reads — see the file header for why this is the
    /// integration point rather than a parallel "current Lua theme" object
    /// views would need to additionally consult.
    private func applyToAppTheme(_ config: LuaThemeConfig) {
        let d = UserDefaults.standard

        // Colors — same save functions AppearanceView's color pickers call.
        AppTheme.saveAccentColor(Color(hex: config.colors.accent))
        AppTheme.saveAccentSecondaryColor(Color(hex: config.colors.accentSecondary))
        AppTheme.saveCustomBackgroundOverride(
            background: config.colors.background,
            surface: config.colors.surface,
            elevatedSurface: config.colors.elevatedSurface
        )

        // Style choices — written straight to the exact UserDefaults keys
        // AppearanceView's own @AppStorage properties are bound to, so every
        // screen reading one of those keys (including views that read it
        // directly via @AppStorage rather than through AppTheme) picks the
        // change up immediately.
        AppTheme.saveFontStyle(AppFontStyle(rawValue: config.style.fontStyle) ?? .system)
        AppTheme.savePanelMaterialStyle(PanelMaterialStyle(rawValue: config.style.panelMaterial) ?? .solid)
        d.set(config.style.launchScreenStyle, forKey: "launch_screen_style")
        d.set(config.style.tabTransitionStyle, forKey: "tab_transition_style")
        d.set(config.style.artworkStyle, forKey: "nowPlaying_artworkStyle")
        d.set(config.style.seekerStyle, forKey: "nowPlaying_seekerStyle")
        d.set(config.style.cardStyle, forKey: "library_cardStyle")
        d.set(config.style.panelOpacity, forKey: "panel_opacity")
        AppTheme.saveLayoutScales(cornerRadius: config.style.cornerRadiusScale, spacing: config.style.spacingScale)

        // Liquid Glass — GlassSettings is an ObservableObject singleton, not
        // UserDefaults-key based from the outside, so its own published
        // properties are set directly (each `didSet` persists itself).
        GlassSettings.shared.tintStrength = config.glass.tintStrength
        GlassSettings.shared.tintHue = config.glass.tintHue
        GlassSettings.shared.useAccentTint = config.glass.useAccentTint
        GlassSettings.shared.translucency = config.glass.translucency

        // Feature flags.
        d.set(config.flags.reduceMotion, forKey: "app_reduce_motion")
        d.set(config.flags.showBpmBadges, forKey: LuaFeatureFlags.Keys.showBpmBadges)
        d.set(config.flags.aggressivePrefetch, forKey: LuaFeatureFlags.Keys.aggressivePrefetch)
        d.set(config.flags.hapticFeedback, forKey: LuaFeatureFlags.Keys.hapticFeedback)

        // Logic hooks (see SongsTab.swift's `sortedSongs`).
        d.set(config.hooks.libraryDefaultSort, forKey: "library_songs_sort")
        d.set(config.hooks.pinFavoritesFirst, forKey: "lua_pin_favorites_first")
        d.set(config.hooks.libraryDefaultColumns, forKey: "library_songs_columns")

        // Now Playing layout (see NowPlayingView.swift's `selectedPanel`/
        // `displayMode`/`showEQ` initial-value reads). Absent for presets
        // that don't set a `layout` table — those three keys are simply
        // left untouched, so NowPlayingView's own hardcoded fallback
        // (Controls / artwork / EQ expanded) applies exactly as before.
        if let layout = config.layout {
            d.set(layout.defaultPanel, forKey: "lua_layout_default_panel")
            d.set(layout.defaultDisplayMode, forKey: "lua_layout_default_display_mode")
            d.set(layout.showQueuePreview, forKey: "nowPlaying_showQueuePreview")
            d.set(layout.eqExpandedByDefault, forKey: "lua_layout_eq_expanded")
        }
    }
}

// MARK: - LuaThemeEngineError

enum LuaThemeEngineError: LocalizedError {
    case scriptNotFound(String)
    case unexpectedResult
    case decodeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let name):
            return "Couldn't find the “\(name).lua” preset script in the app bundle."
        case .unexpectedResult:
            return "The Lua preset script didn't return the expected JSON result."
        case .decodeFailed(let error):
            return "Couldn't parse the preset's theme data: \(error.localizedDescription)"
        }
    }
}

// MARK: - LuaThemeConfig
//
// Mirrors the `theme` table every preset script assigns, after it's been
// round-tripped through `json.encode`/`JSONDecoder` (with
// `.convertFromSnakeCase`, hence the snake_case Lua keys ↔ camelCase
// properties below).

struct LuaThemeConfig: Codable, Equatable {
    struct Meta: Codable, Equatable {
        var id: String
        var name: String
        var description: String
    }

    struct Colors: Codable, Equatable {
        var accent: String
        var accentSecondary: String
        var textPrimary: String
        var textSecondary: String
        var background: String
        var surface: String
        var elevatedSurface: String
    }

    struct Style: Codable, Equatable {
        /// One of `AppFontStyle`'s rawValues.
        var fontStyle: String
        /// One of `PanelMaterialStyle`'s rawValues.
        var panelMaterial: String
        /// One of `LaunchScreenStyle`'s rawValues.
        var launchScreenStyle: String
        /// One of `TabTransitionStyle`'s rawValues.
        var tabTransitionStyle: String
        /// One of `NowPlayingArtworkStyle`'s rawValues.
        var artworkStyle: String
        /// One of `SeekerStyle`'s rawValues.
        var seekerStyle: String
        /// One of `SongCardStyle`'s rawValues.
        var cardStyle: String
        var panelOpacity: Double
        var cornerRadiusScale: Double
        var spacingScale: Double
    }

    struct Glass: Codable, Equatable {
        var tintStrength: Double
        var tintHue: Double
        var useAccentTint: Bool
        var translucency: Double
    }

    struct Flags: Codable, Equatable {
        var reduceMotion: Bool
        var showBpmBadges: Bool
        var aggressivePrefetch: Bool
        var hapticFeedback: Bool
    }

    struct Hooks: Codable, Equatable {
        /// One of the (private) `SongSortOrder` rawValues in SongsTab.swift:
        /// "title" | "artist" | "dateAdded" | "playCount" | "duration".
        var libraryDefaultSort: String
        var pinFavoritesFirst: Bool
        /// 1...3 — matches the Songs tab's list/2-grid/3-grid layout toggle.
        var libraryDefaultColumns: Int
    }

    /// Now Playing screen layout — which panel/hero mode it opens to and
    /// whether a couple of its sections start expanded. `nil` for any
    /// preset (all 10 bundled ones, and any community script written before
    /// this existed) that doesn't set a `layout` table — decodes to `nil`
    /// automatically since this property is `Optional`, rather than failing
    /// the whole preset's decode over one missing table.
    struct Layout: Codable, Equatable {
        /// One of `NowPlayingPanel`'s rawValues: "Controls" | "Sound" |
        /// "Queue" | "Lyrics" | "Marks".
        var defaultPanel: String
        /// One of `NowPlayingDisplayMode`'s rawValues: "artwork" | "lyrics".
        var defaultDisplayMode: String
        var showQueuePreview: Bool
        var eqExpandedByDefault: Bool
    }

    var meta: Meta
    var colors: Colors
    var style: Style
    var glass: Glass
    var flags: Flags
    var hooks: Hooks
    var layout: Layout?
}

// MARK: - LuaPreset

/// The 10 bundled preset identities (Resources/LuaPresets/<filename>.lua).
/// A static, exhaustive enum — matching how every other style choice in this
/// codebase (`AppBackgroundTheme`, `SongCardStyle`, …) is modeled — rather
/// than scanning the bundle at runtime.
enum LuaPreset: String, CaseIterable, Identifiable {
    case highContrast
    case minimalist
    case vibrantEnergetic
    case amoledDark
    case retroSkeuo
    case pastelDream
    case forestCalm
    case cyberpunkNeon
    case monochromeEditorial
    case synthwaveSunset

    var id: String { rawValue }

    /// The bundled script's filename, without extension.
    var filename: String {
        switch self {
        case .highContrast:         return "high_contrast"
        case .minimalist:           return "minimalist"
        case .vibrantEnergetic:     return "vibrant_energetic"
        case .amoledDark:           return "amoled_dark"
        case .retroSkeuo:           return "retro_skeuomorphic"
        case .pastelDream:          return "pastel_dream"
        case .forestCalm:           return "forest_calm"
        case .cyberpunkNeon:        return "cyberpunk_neon"
        case .monochromeEditorial:  return "monochrome_editorial"
        case .synthwaveSunset:      return "synthwave_sunset"
        }
    }

    var displayName: String {
        switch self {
        case .highContrast:         return "High Contrast"
        case .minimalist:           return "Minimalist"
        case .vibrantEnergetic:     return "Vibrant Pulse"
        case .amoledDark:           return "AMOLED Midnight"
        case .retroSkeuo:           return "Retro Cassette"
        case .pastelDream:          return "Pastel Dream"
        case .forestCalm:           return "Forest Calm"
        case .cyberpunkNeon:        return "Neon Cyberdeck"
        case .monochromeEditorial:  return "Monochrome Editorial"
        case .synthwaveSunset:      return "Synthwave Sunset"
        }
    }

    var subtitle: String {
        switch self {
        case .highContrast:        return "Accessibility-first — max contrast, no motion"
        case .minimalist:          return "Clean, quiet, paper-light"
        case .vibrantEnergetic:    return "Bright, bold, high-energy"
        case .amoledDark:          return "True black, battery-friendly"
        case .retroSkeuo:          return "Warm, analog, cassette-era"
        case .pastelDream:         return "Soft lavender, gentle motion"
        case .forestCalm:          return "Calm greens, natural tones"
        case .cyberpunkNeon:       return "Dark, neon, monospaced"
        case .monochromeEditorial: return "Grayscale, editorial, serif"
        case .synthwaveSunset:     return "Retrowave pink & orange gradient"
        }
    }

    var iconName: String {
        switch self {
        case .highContrast:        return "circle.lefthalf.filled"
        case .minimalist:          return "square"
        case .vibrantEnergetic:    return "bolt.fill"
        case .amoledDark:          return "moon.stars.fill"
        case .retroSkeuo:          return "cassettetape"
        case .pastelDream:         return "cloud.fill"
        case .forestCalm:          return "leaf.fill"
        case .cyberpunkNeon:       return "cpu"
        case .monochromeEditorial: return "textformat"
        case .synthwaveSunset:     return "sun.horizon.fill"
        }
    }

    /// A representative swatch pair for the preset picker's preview circles —
    /// intentionally the same literal hex values as each script's `colors`
    /// table so the picker looks right even before a preset is applied
    /// (evaluating all 10 scripts just to render the picker would be
    /// wasteful — these mirror them by hand instead).
    var previewColors: (background: Color, accent: Color) {
        switch self {
        case .highContrast:        return (Color(hex: "#000000"), Color(hex: "#FFD400"))
        case .minimalist:          return (Color(hex: "#F2F1EC"), Color(hex: "#2B2B2B"))
        case .vibrantEnergetic:    return (Color(hex: "#1A0B2E"), Color(hex: "#FF3D7A"))
        case .amoledDark:          return (Color(hex: "#000000"), Color(hex: "#00E5FF"))
        case .retroSkeuo:          return (Color(hex: "#2A1D14"), Color(hex: "#D97B3F"))
        case .pastelDream:         return (Color(hex: "#F5EEFB"), Color(hex: "#B497D6"))
        case .forestCalm:          return (Color(hex: "#12211B"), Color(hex: "#5FA777"))
        case .cyberpunkNeon:       return (Color(hex: "#060014"), Color(hex: "#FF2AF0"))
        case .monochromeEditorial: return (Color(hex: "#121212"), Color(hex: "#FFFFFF"))
        case .synthwaveSunset:     return (Color(hex: "#1B0A2E"), Color(hex: "#FF6AD5"))
        }
    }
}

// MARK: - LuaFeatureFlags
//
// Small, centralized read-side for the boolean feature flags a Lua preset
// can set (`applyToAppTheme(_:)` above is the write side). Kept separate
// from `AppTheme` since these gate *behavior*, not look.
enum LuaFeatureFlags {
    enum Keys {
        static let showBpmBadges = "lua_flag_show_bpm_badges"
        static let aggressivePrefetch = "lua_flag_aggressive_prefetch"
        static let hapticFeedback = "lua_flag_haptic_feedback"
    }

    /// Whether the BPM badge next to the artist name on Now Playing shows.
    /// Defaults to on (matches the pre-existing, always-on behavior) until a
    /// preset turns it off.
    static var showBpmBadges: Bool {
        UserDefaults.standard.object(forKey: Keys.showBpmBadges) as? Bool ?? true
    }

    /// Widens the Songs tab's artwork-prefetch window when on. Defaults off.
    static var aggressivePrefetch: Bool {
        UserDefaults.standard.object(forKey: Keys.aggressivePrefetch) as? Bool ?? false
    }

    /// Whether the mini player's play/pause/skip/favorite taps fire haptics.
    /// Defaults to on (matches the pre-existing, always-on behavior).
    static var hapticFeedback: Bool {
        UserDefaults.standard.object(forKey: Keys.hapticFeedback) as? Bool ?? true
    }
}
