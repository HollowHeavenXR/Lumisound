import SwiftUI
import UIKit

// MARK: - AppTheme

enum AppTheme {

    // MARK: Static Color Palette

    /// Base palette values for the `.default` background theme — kept as the
    /// literal fallback so `background`/`surface`/`elevatedSurface` below
    /// preserve the exact look every existing install already has.
    ///
    /// Every color below is resolved per `InterfaceEdition`: `.classic` gets
    /// the original literals untouched, `.lumen` gets `LumenPalette`'s. That
    /// one switch is what carries the redesign's palette into every screen
    /// that reads `AppTheme`, including the ones Lumen has no bespoke
    /// replacement for.
    static var accent: Color        { InterfaceEdition.isStrata ? StrataPalette.accent : InterfaceEdition.isLumen ? LumenPalette.iris : classicAccent }
    static var accentSoft: Color    { InterfaceEdition.isStrata ? StrataPalette.glow : InterfaceEdition.isLumen ? LumenPalette.azure : classicAccentSoft }
    static var textPrimary: Color   { InterfaceEdition.isStrata ? StrataPalette.ink : InterfaceEdition.isLumen ? LumenPalette.textPrimary : (Appearance.classicColor(\.textPrimary) ?? classicTextPrimary) }
    static var textSecondary: Color { InterfaceEdition.isStrata ? StrataPalette.inkDim : InterfaceEdition.isLumen ? LumenPalette.textSecondary : (Appearance.classicColor(\.textSecondary) ?? classicTextSecondary) }
    static var warning: Color       { InterfaceEdition.isLumen ? LumenPalette.warning : classicWarning }
    static var success: Color       { InterfaceEdition.isLumen ? LumenPalette.success : classicSuccess }
    static var error: Color         { InterfaceEdition.isStrata ? StrataPalette.danger : InterfaceEdition.isLumen ? LumenPalette.error : classicError }

    static let classicAccent        = Color(red: 0.925, green: 0.251, blue: 0.478)
    static let classicAccentSoft    = Color(red: 0.957, green: 0.561, blue: 0.694)
    static let classicTextPrimary   = Color(red: 0.969, green: 0.980, blue: 0.988)
    static let classicTextSecondary = Color(red: 0.796, green: 0.835, blue: 0.878)
    static let classicWarning       = Color(red: 0.965, green: 0.678, blue: 0.333)
    static let classicSuccess       = Color(red: 0.408, green: 0.827, blue: 0.569)
    static let classicError         = Color(red: 0.988, green: 0.506, blue: 0.506)

    // MARK: Background Theme

    /// Which cohesive background/surface color set is active. `background`/
    /// `surface`/`elevatedSurface` below all read through this, so changing
    /// it takes effect everywhere those three colors are used without
    /// touching any other call site.
    static var backgroundTheme: AppBackgroundTheme {
        if let raw = UserDefaults.standard.string(forKey: "app_background_theme"),
           let theme = AppBackgroundTheme(rawValue: raw) {
            return theme
        }
        return .default
    }

    static func saveBackgroundTheme(_ theme: AppBackgroundTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: "app_background_theme")
    }

    static func resetBackgroundTheme() {
        UserDefaults.standard.removeObject(forKey: "app_background_theme")
    }

    // Lumen ignores the classic `AppBackgroundTheme` presets (they were
    // tuned for the classic slate look) but still honors an explicit Lua
    // preset override, which is a deliberate per-user choice.
    static var background: Color {
        customBackgroundOverride?.background
            ?? (InterfaceEdition.isStrata ? StrataPalette.ground : InterfaceEdition.isLumen ? LumenPalette.ink : (Appearance.classicColor(\.background) ?? backgroundTheme.background))
    }
    static var surface: Color {
        customBackgroundOverride?.surface
            ?? (InterfaceEdition.isStrata ? StrataPalette.layer : InterfaceEdition.isLumen ? LumenPalette.surface : (Appearance.classicColor(\.surface) ?? backgroundTheme.surface))
    }
    static var elevatedSurface: Color {
        customBackgroundOverride?.elevatedSurface
            ?? (InterfaceEdition.isStrata ? StrataPalette.raised : InterfaceEdition.isLumen ? LumenPalette.elevated : (Appearance.classicColor(\.elevated) ?? backgroundTheme.elevatedSurface))
    }

    // MARK: Lua-Driven Custom Background Override
    //
    // A Lua theme preset (see `Theme/LuaThemeEngine.swift`) can supply its own
    // arbitrary background/surface/elevated-surface hex colors instead of
    // reusing one of the fixed `AppBackgroundTheme` cases above — this is
    // where those land. `background`/`surface`/`elevatedSurface` above check
    // this FIRST, falling back to `backgroundTheme` exactly as before, so
    // every existing install (no override ever saved) is completely
    // unaffected.

    private enum LuaBackgroundKeys {
        static let background = "lua_bg_override_background"
        static let surface = "lua_bg_override_surface"
        static let elevatedSurface = "lua_bg_override_elevated"
    }

    static var customBackgroundOverride: (background: Color, surface: Color, elevatedSurface: Color)? {
        let d = UserDefaults.standard
        guard
            let bg = d.string(forKey: LuaBackgroundKeys.background),
            let sf = d.string(forKey: LuaBackgroundKeys.surface),
            let el = d.string(forKey: LuaBackgroundKeys.elevatedSurface)
        else { return nil }
        return (Color(hex: bg), Color(hex: sf), Color(hex: el))
    }

    static func saveCustomBackgroundOverride(background: String, surface: String, elevatedSurface: String) {
        let d = UserDefaults.standard
        d.set(background, forKey: LuaBackgroundKeys.background)
        d.set(surface, forKey: LuaBackgroundKeys.surface)
        d.set(elevatedSurface, forKey: LuaBackgroundKeys.elevatedSurface)
    }

    static func resetCustomBackgroundOverride() {
        let d = UserDefaults.standard
        d.removeObject(forKey: LuaBackgroundKeys.background)
        d.removeObject(forKey: LuaBackgroundKeys.surface)
        d.removeObject(forKey: LuaBackgroundKeys.elevatedSurface)
    }

    // MARK: Lua-Driven Layout Scale
    //
    // Corner-radius / spacing multipliers a Lua preset can set (e.g. a
    // "high contrast" preset using sharper corners and more breathing room,
    // or a "retro" preset using tighter spacing). Consumed by
    // `PanelStyleModifier` below — the same shared modifier every
    // `panelStyle()` call site (all 8 Now Playing sub-panels) already uses,
    // so no individual call site needs to change. `0` (UserDefaults' default
    // for a missing Double key) is treated as "unset" so the multiplier is
    // always a real, positive scale.

    private enum LuaLayoutKeys {
        static let cornerRadiusScale = "lua_layout_corner_radius_scale"
        static let spacingScale = "lua_layout_spacing_scale"
    }

    // Classic also takes the interface style's corner shape and density
    // here (Lumen applies them in its own design system).
    static var layoutCornerRadiusScale: Double {
        let v = UserDefaults.standard.double(forKey: LuaLayoutKeys.cornerRadiusScale)
        return (v > 0 ? v : 1.0) * (InterfaceEdition.isLumen ? 1.0 : Appearance.current.cornerScale)
    }

    static var layoutSpacingScale: Double {
        let v = UserDefaults.standard.double(forKey: LuaLayoutKeys.spacingScale)
        return (v > 0 ? v : 1.0) * (InterfaceEdition.isLumen ? 1.0 : Appearance.current.spacingScale)
    }

    static func saveLayoutScales(cornerRadius: Double, spacing: Double) {
        let d = UserDefaults.standard
        d.set(cornerRadius, forKey: LuaLayoutKeys.cornerRadiusScale)
        d.set(spacing, forKey: LuaLayoutKeys.spacingScale)
    }

    static func resetLayoutScales() {
        let d = UserDefaults.standard
        d.removeObject(forKey: LuaLayoutKeys.cornerRadiusScale)
        d.removeObject(forKey: LuaLayoutKeys.spacingScale)
    }

    // MARK: Dynamic Accent

    /// Reads a user-saved accent color from UserDefaults.
    /// Falls back to the default pink `accent` if nothing is stored.
    ///
    /// Each edition keeps its own saved accent (see `accentKey`), so picking
    /// a color in Lumen never repaints Classic and switching back restores
    /// whatever Classic had.
    static var dynamicAccent: Color {
        // A style with its own accent (Minimal Mono) wins in both editions.
        if let forced = Appearance.current.accentOverride { return forced.color }
        if let data = UserDefaults.standard.data(forKey: accentKey),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) {
            return Color(uiColor)
        }
        return accent
    }

    /// Persists a new accent color selection to UserDefaults.
    static func saveAccentColor(_ color: Color) {
        let uiColor = UIColor(color)
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: uiColor,
            requiringSecureCoding: true
        ) {
            UserDefaults.standard.set(data, forKey: accentKey)
        }
    }

    /// Resets the saved accent color so `dynamicAccent` returns the default pink.
    static func resetAccentColor() {
        UserDefaults.standard.removeObject(forKey: accentKey)
    }

    // MARK: Dynamic Accent — Secondary (gradient pairing)

    /// Second color used wherever the accent is rendered as a gradient
    /// (the mini-player's play button and progress fill, the launch
    /// screen's halo/equalizer, etc.) instead of a flat fill. Defaults to
    /// `accentSoft` — the exact color those gradients already used — so
    /// nothing changes visually until a user picks a custom secondary color.
    static var dynamicAccentSecondary: Color {
        if let data = UserDefaults.standard.data(forKey: accentSecondaryKey),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) {
            return Color(uiColor)
        }
        return accentSoft
    }

    static func saveAccentSecondaryColor(_ color: Color) {
        let uiColor = UIColor(color)
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: uiColor,
            requiringSecureCoding: true
        ) {
            UserDefaults.standard.set(data, forKey: accentSecondaryKey)
        }
    }

    static func resetAccentSecondaryColor() {
        UserDefaults.standard.removeObject(forKey: accentSecondaryKey)
    }

    private static var accentKey: String {
        InterfaceEdition.isStrata ? "strata_accent_color_data" : InterfaceEdition.isLumen ? "lumen_accent_color_data" : "accent_color_data"
    }

    private static var accentSecondaryKey: String {
        InterfaceEdition.isStrata ? "strata_accent_secondary_color_data" : InterfaceEdition.isLumen ? "lumen_accent_secondary_color_data" : "accent_secondary_color_data"
    }

    /// Convenience gradient combining `dynamicAccent` → `dynamicAccentSecondary`.
    static var dynamicAccentGradient: LinearGradient {
        LinearGradient(colors: [dynamicAccent, dynamicAccentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - AppBackgroundTheme

/// Cohesive background/surface color presets. `.default` reproduces the
/// app's original fixed colors exactly, so existing installs look unchanged
/// until they pick a different theme.
enum AppBackgroundTheme: String, CaseIterable, Identifiable, Codable {
    case `default`
    case trueBlack
    case midnightBlue
    case deepPurple
    case forest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default:     return "Default"
        case .trueBlack:   return "True Black"
        case .midnightBlue: return "Midnight Blue"
        case .deepPurple:  return "Deep Purple"
        case .forest:      return "Forest"
        }
    }

    var background: Color {
        switch self {
        case .default:      return Color(red: 0.176, green: 0.216, blue: 0.282)
        case .trueBlack:    return Color(red: 0.02,  green: 0.02,  blue: 0.03)
        case .midnightBlue: return Color(red: 0.05,  green: 0.08,  blue: 0.18)
        case .deepPurple:   return Color(red: 0.14,  green: 0.08,  blue: 0.20)
        case .forest:       return Color(red: 0.10,  green: 0.16,  blue: 0.14)
        }
    }

    var surface: Color {
        switch self {
        case .default:      return Color(red: 0.290, green: 0.333, blue: 0.408)
        case .trueBlack:    return Color(red: 0.12,  green: 0.12,  blue: 0.14)
        case .midnightBlue: return Color(red: 0.10,  green: 0.15,  blue: 0.28)
        case .deepPurple:   return Color(red: 0.24,  green: 0.14,  blue: 0.32)
        case .forest:       return Color(red: 0.18,  green: 0.26,  blue: 0.22)
        }
    }

    var elevatedSurface: Color {
        switch self {
        case .default:      return Color(red: 0.353, green: 0.420, blue: 0.490)
        case .trueBlack:    return Color(red: 0.18,  green: 0.18,  blue: 0.21)
        case .midnightBlue: return Color(red: 0.14,  green: 0.20,  blue: 0.36)
        case .deepPurple:   return Color(red: 0.32,  green: 0.20,  blue: 0.42)
        case .forest:       return Color(red: 0.24,  green: 0.34,  blue: 0.28)
        }
    }
}

// MARK: - AppFontStyle

enum AppFontStyle: String, CaseIterable, Identifiable, Codable {
    case system
    case rounded
    case serif
    case monospacedDisplay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:            return "System"
        case .rounded:           return "Rounded"
        case .serif:             return "Serif"
        case .monospacedDisplay: return "Monospaced"
        }
    }

    var design: Font.Design {
        switch self {
        case .system:            return .default
        case .rounded:           return .rounded
        case .serif:             return .serif
        case .monospacedDisplay: return .monospaced
        }
    }
}

// MARK: - Font Helpers

extension AppTheme {
    /// Which `Font.Design` `headlineFont`/`bodyFont` render with. `monoFont`
    /// deliberately does NOT follow this — it's used for numeric/tabular
    /// displays (durations, BPM, dB values) where actual monospacing is
    /// functionally important, not just decorative.
    static var fontStyle: AppFontStyle {
        if let raw = UserDefaults.standard.string(forKey: "app_font_style"),
           let style = AppFontStyle(rawValue: raw) {
            return style
        }
        // Lumen's type is set in SF Rounded unless the user picked a style.
        return InterfaceEdition.isLumen ? .rounded : .system
    }

    static func saveFontStyle(_ style: AppFontStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: "app_font_style")
    }

    static func resetFontStyle() {
        UserDefaults.standard.removeObject(forKey: "app_font_style")
    }

    static func headlineFont(size: CGFloat = 17) -> Font {
        .system(size: size, weight: .semibold, design: fontStyle.design)
    }

    static func bodyFont(size: CGFloat = 15) -> Font {
        .system(size: size, weight: .regular, design: fontStyle.design)
    }

    static func monoFont(size: CGFloat = 12) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

// MARK: - View Modifiers

extension View {
    /// Applies the standard primary text color.
    /// Background is intentionally omitted here so that GalleryBackgroundView
    /// (rendered in ContentView's ZStack behind the TabView) can show through.
    /// Views that need an opaque background on top of the gallery (e.g. sheets,
    /// standalone NavigationStack roots) must set .background(AppTheme.background
    /// .ignoresSafeArea()) themselves.
    func appScreenBackground() -> some View {
        self
            .foregroundStyle(AppTheme.textPrimary)
    }

    /// Applies the standard rounded panel surface style.
    /// Panel opacity is controlled by the "panel_opacity" UserDefaults key (set in AppearanceView).
    func panelStyle() -> some View {
        modifier(PanelStyleModifier())
    }
}

/// Panel background look — the standard flat, opacity-controlled surface
/// tint, or a frosted-glass (`.ultraThinMaterial`) treatment with a light
/// tint on top. Applies to the 8 Now Playing sub-panels that use `panelStyle()`.
enum PanelMaterialStyle: String, CaseIterable, Identifiable, Codable {
    case solid
    case frostedGlass

    var id: String { rawValue }
    var displayName: String { self == .solid ? "Solid" : "Frosted Glass" }
}

extension AppTheme {
    static var panelMaterialStyle: PanelMaterialStyle {
        if let raw = UserDefaults.standard.string(forKey: "panel_material_style"),
           let style = PanelMaterialStyle(rawValue: raw) {
            return style
        }
        return .solid
    }

    static func savePanelMaterialStyle(_ style: PanelMaterialStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: "panel_material_style")
    }
}

private struct PanelStyleModifier: ViewModifier {
    @ObservedObject private var appearance = Appearance.shared
    @AppStorage("panel_opacity") private var opacity: Double = 1.0
    @AppStorage("panel_material_style") private var materialStyleRaw: String = PanelMaterialStyle.solid.rawValue

    private var isFrostedGlass: Bool {
        PanelMaterialStyle(rawValue: materialStyleRaw) == .frostedGlass
    }

    func body(content: Content) -> some View {
        // Scaled by AppTheme.layoutCornerRadiusScale/layoutSpacingScale — both
        // default to 1.0 (reproducing the original 8pt/14pt literals exactly)
        // until a Lua theme preset sets them to something else.
        let isLumen = InterfaceEdition.isLumen
        let radius = CGFloat((isLumen ? 20 : 8) * AppTheme.layoutCornerRadiusScale)
        let pad = CGFloat((isLumen ? 16 : 14) * AppTheme.layoutSpacingScale)
        if isLumen {
            // Lumen panels: a lifted surface with a hairline top light,
            // instead of a flat tint.
            content
                .padding(pad)
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(isFrostedGlass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(AppTheme.surface.opacity(max(opacity, 0.55))))
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(LumenPalette.hairline, lineWidth: 1)
                        )
                }
        } else if !Appearance.isLiquidGlass {
            // Classic with another interface style: the style's own surface.
            content
                .padding(pad)
                .styledSurface(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: nil)
        } else if isFrostedGlass {
            content
                .padding(pad)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .background(AppTheme.surface.opacity(opacity * 0.35), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
                .padding(pad)
                .background(
                    AppTheme.surface.opacity(opacity),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
        }
    }
}
