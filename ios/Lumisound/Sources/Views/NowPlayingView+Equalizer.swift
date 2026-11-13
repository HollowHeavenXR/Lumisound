import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - LumiEQ

    var equalizerSection: some View {
        DisclosureGroup(
            isExpanded: $showEQ,
            content: {
                LumiEQPanel(player: player, haptic: selectHaptic)
                    .padding(.top, 10)
            },
            label: {
                HStack(spacing: 8) {
                    Text("LumiEQ")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    if player.audioSettings.equalizerEnabled {
                        Text(player.audioSettings.eqPreset.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.dynamicAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(AppTheme.dynamicAccent.opacity(0.15), in: Capsule())
                    }
                }
            }
        )
        .tint(AppTheme.dynamicAccent)
        .panelStyle()
    }
}

/// The equalizer panel: the engine's actual response curve on top, the
/// preset library grouped by what it's for, and the ten bands underneath.
private struct LumiEQPanel: View {
    @ObservedObject var player: AudioPlayerManager
    let haptic: UISelectionFeedbackGenerator
    @State private var category: String = "Signature"

    private var settings: AudioSettings { player.audioSettings }
    private static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(
                get: { settings.equalizerEnabled },
                set: { on in edit { $0.equalizerEnabled = on } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Equalizer").font(.subheadline.weight(.medium))
                    Text("Runs inside the Lumisound engine").font(.caption2).foregroundStyle(AppTheme.textSecondary)
                }
            }
            .tint(AppTheme.dynamicAccent)

            EQCurveView(gains: settings.eqBands,
                        enabled: settings.equalizerEnabled,
                        loudnessMatch: settings.eqLoudnessMatch ?? true,
                        accent: AppTheme.dynamicAccent)
                .frame(height: 92)
                .opacity(settings.equalizerEnabled ? 1 : 0.45)
                .animation(LumiMotion.fade(0.25), value: settings.eqBands)

            if settings.equalizerEnabled {
                presetLibrary
                bandSliders
                Toggle(isOn: Binding(
                    get: { settings.eqLoudnessMatch ?? true },
                    set: { on in edit { $0.eqLoudnessMatch = on } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Loudness Match").font(.caption.weight(.semibold))
                        Text("Presets change the tone, not the volume.")
                            .font(.caption2).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .tint(AppTheme.dynamicAccent)
            } else {
                Text("Turn on to shape the sound with LumiEQ presets or your own curve.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .onAppear {
            let current = settings.eqPreset
            if current != .custom { category = current.category }
        }
    }

    // MARK: Presets

    private var presetLibrary: some View {
        let groups = EQPreset.grouped
        let selected = settings.eqPreset
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(groups.map(\.category), id: \.self) { cat in
                    Button {
                        haptic.selectionChanged()
                        category = cat
                    } label: {
                        Text(cat)
                            .font(.caption2.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(category == cat ? AppTheme.textPrimary : AppTheme.textSecondary)
                            .padding(.vertical, 4)
                            .overlay(alignment: .bottom) {
                                Capsule()
                                    .fill(category == cat ? AppTheme.dynamicAccent : .clear)
                                    .frame(height: 2)
                                    .offset(y: 4)
                            }
                    }
                    .buttonStyle(.plain)
                    if cat != groups.last?.category { Spacer(minLength: 4) }
                }
            }
            .padding(.horizontal, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groups.first(where: { $0.category == category })?.presets ?? []) { preset in
                        presetCard(preset, selected: preset == selected)
                    }
                    if selected == .custom {
                        presetCard(.custom, selected: true)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func presetCard(_ preset: EQPreset, selected: Bool) -> some View {
        Button {
            haptic.selectionChanged()
            player.applyEQPreset(preset)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                MiniCurve(gains: preset == .custom ? settings.eqBands : preset.bands)
                    .stroke(selected ? Color.white : AppTheme.dynamicAccent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(height: 18)
                Text(preset.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? .white : AppTheme.textPrimary)
                    .lineLimit(1)
                Text(preset.tagline)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .white.opacity(0.85) : AppTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 128, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AppTheme.dynamicAccent : AppTheme.elevatedSurface)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.displayName). \(preset.tagline)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Bands

    private var bandSliders: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(settings.eqBands.indices, id: \.self) { index in
                VStack(spacing: 4) {
                    Text(String(format: "%+.0f", settings.eqBands[index]))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(abs(settings.eqBands[index]) < 0.5 ? AppTheme.textSecondary : AppTheme.dynamicAccent)
                        .frame(height: 12)
                    VerticalSlider(
                        value: Binding(
                            get: { settings.eqBands[index] },
                            set: { val in
                                // Detents at 0 dB and whole decibels.
                                let snapped = abs(val) < 0.35 ? 0 : (val * 2).rounded() / 2
                                edit {
                                    $0.eqBands[index] = snapped
                                    $0.eqPreset = .custom
                                }
                            }
                        ),
                        range: -12...12
                    )
                    .frame(height: 110)
                    Text(Self.labels[index])
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(height: 14)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 150)
    }

    private func edit(_ change: (inout AudioSettings) -> Void) {
        var s = player.audioSettings
        change(&s)
        player.audioSettings = s
    }
}

/// The curve the engine will actually play (from the Rust filter bank,
/// level match included), with a 0 dB line.
private struct EQCurveView: View {
    let gains: [Float]
    let enabled: Bool
    let loudnessMatch: Bool
    let accent: Color

    var body: some View {
        let curve = enabled ? EQPreset.responseCurve(gains, points: 96, loudnessMatch: loudnessMatch) : Array(repeating: 0, count: 96)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let range: Float = 15
            let y: (Float) -> CGFloat = { db in h / 2 - CGFloat(max(-range, min(range, db)) / range) * (h / 2 - 4) }
            ZStack {
                ForEach([-12, -6, 6, 12], id: \.self) { db in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y(Float(db))))
                        p.addLine(to: CGPoint(x: w, y: y(Float(db))))
                    }
                    .stroke(AppTheme.textSecondary.opacity(0.12), lineWidth: 0.5)
                }
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h / 2))
                    p.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(AppTheme.textSecondary.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                let line = Path { p in
                    for (i, db) in curve.enumerated() {
                        let pt = CGPoint(x: w * CGFloat(i) / CGFloat(max(curve.count - 1, 1)), y: y(db))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                let fill = Path { p in
                    p.addPath(line)
                    p.addLine(to: CGPoint(x: w, y: h / 2))
                    p.addLine(to: CGPoint(x: 0, y: h / 2))
                    p.closeSubpath()
                }
                fill.fill(LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                line.stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                HStack {
                    ForEach(["20", "100", "1k", "10k"], id: \.self) { label in
                        Text(label).font(.system(size: 8)).foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                        if label != "10k" { Spacer() }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A tiny shape of a preset's band gains for the preset cards.
private struct MiniCurve: Shape {
    let gains: [Float]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard gains.count > 1 else { return p }
        for (i, g) in gains.enumerated() {
            let pt = CGPoint(x: rect.width * CGFloat(i) / CGFloat(gains.count - 1),
                             y: rect.midY - CGFloat(max(-12, min(12, g)) / 12) * rect.height / 2)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
