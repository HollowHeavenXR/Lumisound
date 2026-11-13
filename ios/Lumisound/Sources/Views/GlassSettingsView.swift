import SwiftUI

// MARK: - GlassSettingsView
//
// Customizes the app-wide Liquid Glass look (see GlassSettings / adaptiveGlass)
// — tint tone, tint strength, and (pre-iOS 26) translucency — with a live
// preview card that updates as the sliders move. Other glass surfaces across
// the app pick up the changes on their next redraw.

struct GlassSettingsView: View {
    @ObservedObject private var glass = GlassSettings.shared

    var body: some View {
        LKPage(title: "Liquid Glass", subtitle: "Tint and translucency of every glass surface.", icon: "circle.hexagongrid.fill", tint: .cyan, showsHero: false) {
            // Preview floats over a colourful backdrop so translucency is visible.
            ZStack {
                LinearGradient(colors: [.pink, .purple, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(
                        HStack(spacing: 18) {
                            ForEach(0..<6, id: \.self) { i in
                                Image(systemName: ["music.note", "waveform", "headphones", "star.fill", "heart.fill", "play.fill"][i])
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    )
                previewCard.padding(28)
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: LK.corner, style: .continuous))

            LKCard(title: "Tint") {
                LKToggle(icon: "paintpalette", tint: AppTheme.dynamicAccent, title: "Follow the app accent", isOn: $glass.useAccentTint)
                if !glass.useAccentTint {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            ForEach(Array(stride(from: 0.0, to: 1.0, by: 1.0 / 9)), id: \.self) { h in
                                Button { glass.tintHue = h } label: {
                                    Circle()
                                        .fill(Color(hue: h, saturation: 0.55, brightness: 0.92))
                                        .frame(width: 26, height: 26)
                                        .overlay(Circle().strokeBorder(.white, lineWidth: abs(glass.tintHue - h) < 0.02 ? 2.5 : 0))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Slider(value: $glass.tintHue, in: 0...1)
                            .tint(Color(hue: glass.tintHue, saturation: 0.55, brightness: 0.92))
                            .background(
                                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map { Color(hue: $0, saturation: 0.55, brightness: 0.92) },
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(height: 4).clipShape(Capsule()).padding(.horizontal, 2)
                            )
                    }
                    .padding(.leading, 42)
                    .padding(.vertical, 6)
                }
                LKDivider()
                LKControlRow(icon: "circle.lefthalf.filled", tint: .cyan, title: "Tint strength", value: "\(Int(glass.tintStrength * 100))%") {
                    Slider(value: $glass.tintStrength, in: 0...1)
                }
            }
            LKCard(title: "Material", footer: "Translucency applies on iOS versions before the system Liquid Glass material.") {
                LKControlRow(icon: "square.on.square.dashed", tint: .cyan, title: "Translucency", value: "\(Int(glass.translucency * 100))%") {
                    Slider(value: $glass.translucency, in: 0...1)
                }
            }
            LKPrimaryButton(title: "Reset to Defaults", icon: "arrow.counterclockwise", tint: .gray, prominent: false) {
                glass.resetToDefaults()
            }
        }
        .animation(LumiMotion.fade(0.2), value: glass.useAccentTint)
    }

    private var previewCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text("Glass Preview")
                .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("This card uses your Liquid Glass settings.")
                .font(AppTheme.bodyFont(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        // Re-evaluated whenever the observed GlassSettings change, so the
        // preview reflects slider moves immediately.
        .background(
            previewBackground,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(glass.tintColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 8)
    }

    private var previewBackground: some ShapeStyle {
        AppTheme.elevatedSurface.opacity(0.4 + glass.translucency * 0.4)
    }

    private func sliderRow(title: String, icon: String, value: Binding<Double>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(AppTheme.textPrimary)
                    .font(AppTheme.bodyFont(size: 14))
                Spacer()
                Text(label)
                    .font(AppTheme.monoFont(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Slider(value: value, in: 0...1)
                .tint(AppTheme.dynamicAccent)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
