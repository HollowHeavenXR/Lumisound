//! Appearance system: interface styles beyond Liquid Glass. Every style's
//! design tokens (palette, surface treatment, borders, glow, corner and
//! spacing scales) are defined here; Swift maps tokens onto SwiftUI
//! modifiers and never hard-codes a style.

#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq)]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

const fn c(r: f64, g: f64, b: f64) -> Rgba {
    Rgba { r, g, b, a: 1.0 }
}

const fn ca(r: f64, g: f64, b: f64, a: f64) -> Rgba {
    Rgba { r, g, b, a }
}

/// How a style draws a raised surface (cards, sheets, chrome).
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SurfaceKind {
    /// iOS 26 Liquid Glass (`glassEffect`), material fallback.
    LiquidGlass,
    /// Blurred material (`.ultraThinMaterial`-style), no glass refraction.
    Frosted,
    /// Opaque fill.
    Solid,
    /// Transparent fill, border only.
    Outline,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AppearanceTokens {
    pub style_id: String,
    pub surface_kind: SurfaceKind,
    pub background: Rgba,
    pub surface: Rgba,
    pub elevated: Rgba,
    pub text_primary: Rgba,
    pub text_secondary: Rgba,
    pub text_tertiary: Rgba,
    pub hairline: Rgba,
    pub fill: Rgba,
    pub fill_strong: Rgba,
    /// Opacity applied to `surface` for raised cards.
    pub surface_opacity: f64,
    /// 0 = ultraThin … 4 = thick (Frosted styles).
    pub blur_level: u8,
    pub border_width: f64,
    /// Accent glow radius on raised surfaces (0 = none).
    pub glow_radius: f64,
    /// 0…1 how much the accent tints surfaces.
    pub accent_tint: f64,
    pub corner_scale: f64,
    pub spacing_scale: f64,
    /// Accent override (Minimal Mono forces grayscale); None = user accent.
    pub accent_override: Option<Rgba>,
    /// Strength of the backdrop's slow accent glows (0 = flat background).
    pub ambient_intensity: f64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AppearanceStyleInfo {
    pub id: String,
    pub name: String,
    pub tagline: String,
    pub symbol: String,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Density {
    Compact,
    Regular,
    Roomy,
}

const LUMEN_INK: Rgba = c(0.039, 0.035, 0.063);
const LUMEN_SURFACE: Rgba = c(0.090, 0.082, 0.122);
const LUMEN_ELEVATED: Rgba = c(0.133, 0.122, 0.176);
const TEXT1: Rgba = c(0.961, 0.953, 0.984);
const TEXT2: Rgba = c(0.663, 0.647, 0.741);
const TEXT3: Rgba = c(0.463, 0.447, 0.541);

fn base(id: &str, kind: SurfaceKind) -> AppearanceTokens {
    AppearanceTokens {
        style_id: id.into(),
        surface_kind: kind,
        background: LUMEN_INK,
        surface: LUMEN_SURFACE,
        elevated: LUMEN_ELEVATED,
        text_primary: TEXT1,
        text_secondary: TEXT2,
        text_tertiary: TEXT3,
        hairline: ca(1.0, 1.0, 1.0, 0.07),
        fill: ca(1.0, 1.0, 1.0, 0.06),
        fill_strong: ca(1.0, 1.0, 1.0, 0.11),
        surface_opacity: 0.82,
        blur_level: 1,
        border_width: 1.0,
        glow_radius: 0.0,
        accent_tint: 0.0,
        corner_scale: 1.0,
        spacing_scale: 1.0,
        accent_override: None,
        ambient_intensity: 1.0,
    }
}

pub const DEFAULT_STYLE: &str = "liquid_glass";

const STYLES: &[(&str, &str, &str, &str)] = &[
    ("liquid_glass", "Liquid Glass", "Refractive glass that bends whatever's behind it.", "drop.fill"),
    ("frosted", "Frosted", "Soft blurred panes, calmer than glass.", "snowflake"),
    ("solid", "Solid", "Opaque cards with crisp edges. Fastest to draw.", "square.fill"),
    ("midnight_oled", "Midnight OLED", "True black with hairline borders. Easy on OLED batteries.", "moon.stars.fill"),
    ("neon", "Neon", "Dark panels outlined in your accent, with a soft glow.", "bolt.fill"),
    ("aurora", "Aurora", "Surfaces tinted by a slow gradient of your accent colors.", "sparkles"),
    ("minimal_mono", "Minimal Mono", "Flat grayscale. No tint, no glow, just the music.", "circle.lefthalf.filled"),
];

/// Every selectable style, in picker order.
#[uniffi::export]
pub fn appearance_styles() -> Vec<AppearanceStyleInfo> {
    STYLES.iter().map(|(id, name, tag, sym)| AppearanceStyleInfo { id: (*id).into(), name: (*name).into(), tagline: (*tag).into(), symbol: (*sym).into() }).collect()
}

/// Tokens for `style_id` (unknown ids fall back to Liquid Glass) at `density`.
#[uniffi::export]
pub fn appearance_tokens(style_id: String, density: Density) -> AppearanceTokens {
    let mut t = match style_id.as_str() {
        "frosted" => AppearanceTokens { surface_opacity: 0.35, blur_level: 2, ..base("frosted", SurfaceKind::Frosted) },
        "solid" => AppearanceTokens { surface_opacity: 1.0, blur_level: 0, border_width: 0.5, ambient_intensity: 0.6, ..base("solid", SurfaceKind::Solid) },
        "midnight_oled" => AppearanceTokens {
            background: c(0.0, 0.0, 0.0),
            surface: c(0.0, 0.0, 0.0),
            elevated: c(0.055, 0.055, 0.063),
            hairline: ca(1.0, 1.0, 1.0, 0.14),
            fill: ca(1.0, 1.0, 1.0, 0.05),
            fill_strong: ca(1.0, 1.0, 1.0, 0.10),
            surface_opacity: 1.0,
            blur_level: 0,
            border_width: 1.0,
            ambient_intensity: 0.0,
            ..base("midnight_oled", SurfaceKind::Outline)
        },
        "neon" => AppearanceTokens {
            background: c(0.020, 0.016, 0.039),
            surface: c(0.051, 0.039, 0.090),
            elevated: c(0.078, 0.063, 0.133),
            surface_opacity: 0.92,
            blur_level: 0,
            border_width: 1.5,
            glow_radius: 10.0,
            accent_tint: 0.10,
            ambient_intensity: 0.5,
            ..base("neon", SurfaceKind::Solid)
        },
        "aurora" => AppearanceTokens { surface_opacity: 0.55, blur_level: 2, accent_tint: 0.22, ambient_intensity: 1.6, ..base("aurora", SurfaceKind::Frosted) },
        "minimal_mono" => AppearanceTokens {
            background: c(0.071, 0.071, 0.075),
            surface: c(0.110, 0.110, 0.118),
            elevated: c(0.153, 0.153, 0.161),
            text_secondary: c(0.667, 0.667, 0.682),
            text_tertiary: c(0.463, 0.463, 0.478),
            hairline: ca(1.0, 1.0, 1.0, 0.09),
            surface_opacity: 1.0,
            blur_level: 0,
            border_width: 0.0,
            corner_scale: 0.6,
            accent_override: Some(c(0.902, 0.902, 0.918)),
            ambient_intensity: 0.0,
            ..base("minimal_mono", SurfaceKind::Solid)
        },
        _ => base(DEFAULT_STYLE, SurfaceKind::LiquidGlass),
    };
    let (cs, ss) = match density {
        Density::Compact => (0.85, 0.8),
        Density::Regular => (1.0, 1.0),
        Density::Roomy => (1.1, 1.2),
    };
    t.corner_scale *= cs;
    t.spacing_scale *= ss;
    t
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_style_resolves() {
        for s in appearance_styles() {
            let t = appearance_tokens(s.id.clone(), Density::Regular);
            assert_eq!(t.style_id, s.id);
        }
        assert_eq!(appearance_tokens("nope".into(), Density::Regular).style_id, DEFAULT_STYLE);
        assert!(appearance_tokens("solid".into(), Density::Compact).corner_scale < 1.0);
    }
}
