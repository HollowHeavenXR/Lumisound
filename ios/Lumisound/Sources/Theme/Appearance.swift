import SwiftUI

/// The selected interface style (Liquid Glass, Frosted, Solid, Midnight
/// OLED, Neon, Aurora, Minimal Mono) and density. Style definitions and
/// their design tokens live in the Rust core (`appearance_tokens`); this
/// only persists the choice and converts tokens to SwiftUI colors.
@MainActor
final class Appearance: ObservableObject {
    static let shared = Appearance()
    static let styleKey = "appearance_style"
    static let densityKey = "appearance_density"

    @Published private(set) var styleID: String
    @Published private(set) var density: Density
    @Published private(set) var tokens: AppearanceTokens
    /// Bumped when a style change should repaint screens that read colors
    /// through static getters (`AppTheme`); `ContentView` rebuilds on it.
    @Published private(set) var paletteStamp = 0
    private var paletteDirty = false

    /// Snapshot readable from non-isolated contexts (static color getters).
    nonisolated(unsafe) static var current: AppearanceTokens = appearanceTokens(
        styleId: UserDefaults.standard.string(forKey: styleKey) ?? "liquid_glass",
        density: Appearance.storedDensity())

    let styles: [AppearanceStyleInfo] = appearanceStyles()

    private init() {
        let id = UserDefaults.standard.string(forKey: Self.styleKey) ?? "liquid_glass"
        let d = Self.storedDensity()
        styleID = id
        density = d
        tokens = appearanceTokens(styleId: id, density: d)
        Self.current = tokens
    }

    nonisolated static func storedDensity() -> Density {
        switch UserDefaults.standard.string(forKey: densityKey) {
        case "compact": return .compact
        case "roomy": return .roomy
        default: return .regular
        }
    }

    static func densityName(_ d: Density) -> String {
        switch d {
        case .compact: return "compact"
        case .regular: return "regular"
        case .roomy: return "roomy"
        }
    }

    func select(style: String) {
        apply(style: style, density: density, push: true)
    }

    func select(density: Density) {
        apply(style: styleID, density: density, push: true)
    }

    /// Applies a style (also used when the account's synced choice arrives).
    func apply(style: String, density: Density, push: Bool) {
        UserDefaults.standard.set(style, forKey: Self.styleKey)
        UserDefaults.standard.set(Self.densityName(density), forKey: Self.densityKey)
        styleID = style
        self.density = density
        tokens = appearanceTokens(styleId: style, density: density)
        Self.current = tokens
        paletteDirty = true
        if push {
            onChange?(style, Self.densityName(density))
        } else {
            commitPalette() // synced from another device: repaint now
        }
    }

    /// Repaints every screen with the current style (called when the user
    /// leaves the Appearance screen, so picking doesn't throw them out of it;
    /// cards and panels already repaint live).
    func commitPalette() {
        guard paletteDirty else { return }
        paletteDirty = false
        paletteStamp += 1
    }

    /// Set by AccountService to sync the choice to the account.
    var onChange: ((String, String) -> Void)?

    nonisolated static var isLiquidGlass: Bool { current.surfaceKind == .liquidGlass }

    /// Liquid Glass tokens: Classic's look is its own palette under Liquid
    /// Glass, so another style only replaces the colors it actually changes.
    nonisolated(unsafe) static let liquidGlassBase = appearanceTokens(styleId: "liquid_glass", density: .regular)

    /// For Classic: the selected style's color for `pick`, or nil when the
    /// style keeps the base color (Classic then keeps its own).
    nonisolated static func classicColor(_ pick: (AppearanceTokens) -> Rgba) -> Color? {
        guard !isLiquidGlass else { return nil }
        let v = pick(current)
        return v == pick(liquidGlassBase) ? nil : v.color
    }
}

extension Rgba {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

extension Color {
    /// sRGB components for handing an accent to the core.
    var rgba: Rgba {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Rgba(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }
}

extension View {
    /// A raised surface drawn the way the selected style says (glass,
    /// frosted material, solid fill or outline, with optional accent tint,
    /// border and glow). Observes the style so a switch repaints live.
    func styledSurface<S: Shape>(in shape: S, tint: Color?) -> some View {
        modifier(StyledSurfaceModifier(shape: shape, tint: tint))
    }
}

private struct StyledSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    @ObservedObject private var appearance = Appearance.shared

    func body(content: Content) -> some View {
        let t = appearance.tokens
        let accent = t.accentOverride?.color ?? AppTheme.dynamicAccent
        let border = t.glowRadius > 0 ? accent.opacity(0.75) : t.hairline.color
        content.background {
            ZStack {
                switch t.surfaceKind {
                case .liquidGlass, .solid:
                    shape.fill(t.surface.color.opacity(t.surfaceOpacity))
                case .frosted:
                    shape.fill(Appearance.material(t.blurLevel))
                    shape.fill(t.surface.color.opacity(t.surfaceOpacity))
                case .outline:
                    shape.fill(t.surface.color)
                }
                if t.accentTint > 0 { shape.fill(accent.opacity(t.accentTint)) }
                if let tint { shape.fill(tint) }
                if t.borderWidth > 0 { shape.stroke(border, lineWidth: t.borderWidth) }
            }
            .shadow(color: t.glowRadius > 0 ? accent.opacity(0.45) : .clear, radius: t.glowRadius)
        }
    }
}

extension Appearance {
    nonisolated static func material(_ level: UInt8) -> Material {
        switch level {
        case 0: return .ultraThinMaterial
        case 1: return .thinMaterial
        case 2: return .regularMaterial
        case 3: return .thickMaterial
        default: return .ultraThickMaterial
        }
    }
}
