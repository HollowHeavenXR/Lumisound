import SwiftUI

// MARK: - Liquid Glass compatibility helpers
//
// iOS 26 introduced the "Liquid Glass" material (`.glassEffect()` /
// `GlassEffectContainer`), which floating chrome (mini-player, toasts,
// FABs) should adopt for visual parity with system UI. Lumisound's
// deployment target is iOS 16, so every use is gated behind
// `#available(iOS 26, *)` with the existing `Material` look as the
// fallback on older OS versions.
//
// All variants composite a user-customizable tint (see `GlassSettings`) into
// the BACKGROUND layer — behind the view's own content — so the "Liquid Glass"
// Settings sliders tint the card chrome without washing over foreground
// content like song-card album artwork.
//
// `GlassSettings.translucency` (the pre-iOS-26 fallback's own opacity slider
// in GlassSettingsView) previously only drove that screen's own local live
// preview swatch — every real `adaptiveGlass` call site across the app
// (mini-player, toasts, FABs, song cards) ignored it entirely and always
// rendered the fallback material/style at full opacity. Dragging the slider
// visibly changed the preview but nothing else in the app, which is exactly
// what "Liquid Glass... needs fixing" describes. Now applied to every
// fallback branch below.

extension View {
    /// `material` in Classic under Liquid Glass; the selected interface
    /// style's surface otherwise (and always in Lumen). For Classic views
    /// that paint a material directly.
    @ViewBuilder
    func styleAwareMaterial<S: Shape>(_ material: Material, in shape: S) -> some View {
        if InterfaceEdition.isLumen || !Appearance.isLiquidGlass {
            self.styledSurface(in: shape, tint: nil)
        } else {
            self.background(material, in: shape)
        }
    }

    /// The configured glass tint as a shape fill, sized to fill the background.
    /// Returns an empty view when the tint is effectively clear.
    @ViewBuilder
    fileprivate func glassTintLayer<S: Shape>(in shape: S) -> some View {
        let tint = GlassSettings.shared.tintColor
        if tint != .clear {
            shape.fill(tint)
        } else {
            Color.clear
        }
    }

    /// Applies Liquid Glass on iOS 26+, falling back to the given `Material`.
    /// The user tint is layered behind the content (over the glass/material),
    /// never in front of it.
    @ViewBuilder
    func adaptiveGlass<S: Shape>(in shape: S, fallback: Material = .ultraThinMaterial) -> some View {
        if InterfaceEdition.isLumen || !Appearance.isLiquidGlass {
            self.lumenSurfaceBackground(in: shape, tint: nil)
        } else {
            if #available(iOS 26.0, *) {
                self.background(glassTintLayer(in: shape)).glassEffect(.regular, in: shape)
            } else {
                self.background(glassTintLayer(in: shape)).background(fallback.opacity(GlassSettings.shared.translucency), in: shape)
            }
        }
    }

    /// Applies Liquid Glass on iOS 26+, falling back to an arbitrary
    /// `ShapeStyle` (e.g. a flat tint `Color`) rather than just a `Material`
    /// — for call sites (like song cards) whose pre-iOS 26 look used a solid
    /// tint instead of a translucent material.
    @ViewBuilder
    func adaptiveGlass<S: Shape, F: ShapeStyle>(in shape: S, fallback: F) -> some View {
        if InterfaceEdition.isLumen || !Appearance.isLiquidGlass {
            self.lumenSurfaceBackground(in: shape, tint: nil)
        } else {
            if #available(iOS 26.0, *) {
                self.background(glassTintLayer(in: shape)).glassEffect(.regular, in: shape)
            } else {
                self.background(glassTintLayer(in: shape)).background(fallback.opacity(GlassSettings.shared.translucency), in: shape)
            }
        }
    }

    /// Tinted Liquid Glass that is deliberately NOT `.interactive()` — for
    /// surfaces that carry a colour identity but aren't themselves a control,
    /// specifically Settings' per-section row backgrounds.
    ///
    /// Needed as its own overload because neither existing pair fits: the
    /// untinted ones apply only `GlassSettings`' global user tint, so routing a
    /// per-section colour through their `fallback:` would silently drop it
    /// (this app's deployment target is iOS 26, so the fallback branch is
    /// unreachable and a colour passed there renders never) — and the
    /// `tint:`-labelled ones add `.interactive()`, whose press-response
    /// behaviour is wrong under a row that is often just a toggle or a slider.
    @ViewBuilder
    func adaptiveGlass<S: Shape, F: ShapeStyle>(sectionTint: Color, in shape: S, fallback: F) -> some View {
        if InterfaceEdition.isLumen || !Appearance.isLiquidGlass {
            self.lumenSurfaceBackground(in: shape, tint: sectionTint.opacity(0.25))
        } else {
            if #available(iOS 26.0, *) {
                self.background(glassTintLayer(in: shape)).glassEffect(.regular.tint(sectionTint), in: shape)
            } else {
                self.background(glassTintLayer(in: shape)).background(fallback.opacity(GlassSettings.shared.translucency), in: shape)
            }
        }
    }

    /// Applies a tinted, interactive Liquid Glass effect on iOS 26+ (for
    /// tappable floating controls), falling back to the given `Material`.
    @ViewBuilder
    func adaptiveGlass<S: Shape>(tint: Color, in shape: S, fallback: Material = .ultraThinMaterial) -> some View {
        if InterfaceEdition.isLumen || !Appearance.isLiquidGlass {
            self.lumenSurfaceBackground(in: shape, tint: tint)
        } else {
            if #available(iOS 26.0, *) {
                self.background(glassTintLayer(in: shape)).glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                self.background(glassTintLayer(in: shape)).background(fallback.opacity(GlassSettings.shared.translucency), in: shape)
            }
        }
    }

    /// Tinted, interactive Liquid Glass on iOS 26+ (e.g. for a "now playing"
    /// highlighted card), falling back to an arbitrary `ShapeStyle`.
    @ViewBuilder
    func adaptiveGlass<S: Shape, F: ShapeStyle>(tint: Color, in shape: S, fallback: F) -> some View {
        if InterfaceEdition.isLumen || !Appearance.isLiquidGlass {
            self.lumenSurfaceBackground(in: shape, tint: tint)
        } else {
            if #available(iOS 26.0, *) {
                self.background(glassTintLayer(in: shape)).glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                self.background(glassTintLayer(in: shape)).background(fallback.opacity(GlassSettings.shared.translucency), in: shape)
            }
        }
    }

    // MARK: Styled surfaces
    //
    // In the Lumen edition — and in Classic whenever an interface style other
    // than Liquid Glass is selected — every card these helpers draw becomes
    // the selected style's surface — lifted ink with a hairline top light, the tint (when there
    // is one) laid over it — so the classic screens' glass cards read as
    // part of the redesign. Lumen's own floating chrome, which should stay
    // real glass, uses `lumenGlass` instead.

    fileprivate func lumenSurfaceBackground<S: Shape>(in shape: S, tint: Color?) -> some View {
        self.styledSurface(in: shape, tint: tint)
    }

    /// Liquid Glass for Lumen's own floating chrome (dock, mini player,
    /// selection bar), independent of the edition switch above.
    @ViewBuilder
    func lumenGlass<S: Shape, F: ShapeStyle>(in shape: S, fallback: F) -> some View {
        if !Appearance.isLiquidGlass {
            self.styledSurface(in: shape, tint: nil)
        } else if #available(iOS 26.0, *) {
            self.background(glassTintLayer(in: shape)).glassEffect(.regular, in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }
}
