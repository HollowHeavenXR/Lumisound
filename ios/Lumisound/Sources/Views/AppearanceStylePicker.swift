import SwiftUI

/// Interface style + density picker (Settings → Appearance). The styles and
/// their tokens come from the Rust core; each tile previews its own tokens.
struct AppearanceStylePicker: View {
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(appearance.styles, id: \.id) { style in
                    tile(style)
                }
            }
            Picker("Density", selection: Binding(get: { appearance.density }, set: { appearance.select(density: $0) })) {
                Text("Compact").tag(Density.compact)
                Text("Regular").tag(Density.regular)
                Text("Roomy").tag(Density.roomy)
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 6)
    }

    private func tile(_ style: AppearanceStyleInfo) -> some View {
        let t = appearanceTokens(styleId: style.id, density: .regular)
        let selected = appearance.styleID == style.id
        let accent = t.accentOverride?.color ?? AppTheme.dynamicAccent
        return Button {
            withAnimation(LumiMotion.fade(0.2)) { appearance.select(style: style.id) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12 * t.cornerScale, style: .continuous)
                        .fill(t.background.color)
                    RoundedRectangle(cornerRadius: 9 * t.cornerScale, style: .continuous)
                        .fill(t.surface.color.opacity(max(t.surfaceOpacity, 0.6)))
                        .overlay(RoundedRectangle(cornerRadius: 9 * t.cornerScale, style: .continuous)
                            .stroke(t.glowRadius > 0 ? accent : t.hairline.color, lineWidth: max(t.borderWidth, 0.5)))
                        .shadow(color: t.glowRadius > 0 ? accent.opacity(0.5) : .clear, radius: t.glowRadius / 2)
                        .padding(10)
                    Image(systemName: style.symbol)
                        .font(.title3)
                        .foregroundStyle(accent)
                }
                .frame(height: 70)
                Text(style.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(style.tagline)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.name) style")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
