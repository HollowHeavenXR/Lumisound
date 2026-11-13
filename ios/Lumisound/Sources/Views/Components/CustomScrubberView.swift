import SwiftUI

// MARK: - CustomSeekerSettings
//
// "Open up Custom Seeker Style Possibilities" — the 11 fixed presets
// (Classic/Ring/Bars/Digital/Pill/Neon Line/Dot Track/Waveform/Segmented/
// Minimal/Ruler) are each their own hand-designed look; this is the
// opposite: ONE genuinely parametric style a user tunes to their own taste
// instead of picking the closest preset. Every knob is `@AppStorage`-backed
// so it survives relaunch and applies immediately without a separate Save
// step, matching how every other Now Playing preference in this app works.
enum SeekerTrackShape: String, CaseIterable, Identifiable {
    case capsule
    case sharp

    var id: String { rawValue }
    var displayName: String { self == .capsule ? "Rounded" : "Sharp" }
    var cornerRadius: CGFloat { self == .capsule ? .infinity : 0 }
}

enum SeekerColorMode: String, CaseIterable, Identifiable {
    case accent
    case gradient
    case monochrome

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .accent:     return "Accent"
        case .gradient:   return "Gradient"
        case .monochrome: return "White"
        }
    }
}

@MainActor
enum CustomSeekerSettings {
    static var height: Double {
        get { UserDefaults.standard.object(forKey: "nowPlaying_customSeeker_height") as? Double ?? 4 }
        set { UserDefaults.standard.set(newValue, forKey: "nowPlaying_customSeeker_height") }
    }
    static var shape: SeekerTrackShape {
        get { SeekerTrackShape(rawValue: UserDefaults.standard.string(forKey: "nowPlaying_customSeeker_shape") ?? "") ?? .capsule }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nowPlaying_customSeeker_shape") }
    }
    static var colorMode: SeekerColorMode {
        get { SeekerColorMode(rawValue: UserDefaults.standard.string(forKey: "nowPlaying_customSeeker_colorMode") ?? "") ?? .accent }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nowPlaying_customSeeker_colorMode") }
    }
    static var showThumb: Bool {
        get { UserDefaults.standard.object(forKey: "nowPlaying_customSeeker_showThumb") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nowPlaying_customSeeker_showThumb") }
    }
    static var glowIntensity: Double {
        get { UserDefaults.standard.object(forKey: "nowPlaying_customSeeker_glow") as? Double ?? 0.4 }
        set { UserDefaults.standard.set(newValue, forKey: "nowPlaying_customSeeker_glow") }
    }
}

struct CustomScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void

    @AppStorage("nowPlaying_customSeeker_height") private var height: Double = 4
    @AppStorage("nowPlaying_customSeeker_shape") private var shapeRaw: String = SeekerTrackShape.capsule.rawValue
    @AppStorage("nowPlaying_customSeeker_colorMode") private var colorModeRaw: String = SeekerColorMode.accent.rawValue
    @AppStorage("nowPlaying_customSeeker_showThumb") private var showThumb: Bool = true
    @AppStorage("nowPlaying_customSeeker_glow") private var glowIntensity: Double = 0.4

    @State private var dragFraction: Double? = nil

    private var shape: SeekerTrackShape { SeekerTrackShape(rawValue: shapeRaw) ?? .capsule }
    private var colorMode: SeekerColorMode { SeekerColorMode(rawValue: colorModeRaw) ?? .accent }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, dragFraction ?? (position / duration))
    }

    private var displayPosition: TimeInterval {
        dragFraction.map { $0 * duration } ?? position
    }

    private var fillShading: AnyShapeStyle {
        switch colorMode {
        case .accent:
            return AnyShapeStyle(AppTheme.dynamicAccent)
        case .gradient:
            return AnyShapeStyle(LinearGradient(
                colors: [AppTheme.dynamicAccent, AppTheme.dynamicAccentSecondary],
                startPoint: .leading, endPoint: .trailing
            ))
        case .monochrome:
            return AnyShapeStyle(Color.white)
        }
    }

    private var glowColor: Color {
        colorMode == .monochrome ? .white : AppTheme.dynamicAccent
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: shape.cornerRadius, style: .continuous)
                        .fill(AppTheme.surface)
                        .frame(height: height)

                    RoundedRectangle(cornerRadius: shape.cornerRadius, style: .continuous)
                        .fill(fillShading)
                        .frame(width: geo.size.width * CGFloat(progress), height: height)
                        .shadow(color: glowColor.opacity(glowIntensity), radius: 4 + height)
                        .animation(LumiMotion.glide(0.15), value: progress)

                    if showThumb {
                        Circle()
                            .fill(colorMode == .monochrome ? Color.white : AppTheme.dynamicAccent)
                            .frame(width: height + 10, height: height + 10)
                            .offset(x: max(0, geo.size.width * CGFloat(progress) - (height + 10) / 2))
                            .animation(LumiMotion.glide(0.15), value: progress)
                    }
                }
                .frame(height: max(24, height + 12))
                .contentShape(Rectangle().inset(by: -16))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            dragFraction = min(max(val.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { val in
                            let frac = min(max(val.location.x / geo.size.width, 0), 1)
                            onSeek(frac * duration)
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 40)

            HStack {
                Text(formatTime(displayPosition))
                    .monospacedDigit()
                Spacer()
                Text("-" + formatTime(max(0, duration - displayPosition)))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        t.formattedAsMinutesSeconds
    }
}

// MARK: - CustomScrubberSettingsPanel

/// Shown only while the "Custom" seeker style is selected — the actual
/// tuning controls for every knob `CustomScrubberView` reads.
struct CustomScrubberSettingsPanel: View {
    @AppStorage("nowPlaying_customSeeker_height") private var height: Double = 4
    @AppStorage("nowPlaying_customSeeker_shape") private var shapeRaw: String = SeekerTrackShape.capsule.rawValue
    @AppStorage("nowPlaying_customSeeker_colorMode") private var colorModeRaw: String = SeekerColorMode.accent.rawValue
    @AppStorage("nowPlaying_customSeeker_showThumb") private var showThumb: Bool = true
    @AppStorage("nowPlaying_customSeeker_glow") private var glowIntensity: Double = 0.4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Track Height").font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $height, in: 2...12, step: 1)
                    .tint(AppTheme.dynamicAccent)
            }

            Picker("Shape", selection: Binding(
                get: { SeekerTrackShape(rawValue: shapeRaw) ?? .capsule },
                set: { shapeRaw = $0.rawValue }
            )) {
                ForEach(SeekerTrackShape.allCases) { s in Text(s.displayName).tag(s) }
            }
            .pickerStyle(.segmented)

            Picker("Color", selection: Binding(
                get: { SeekerColorMode(rawValue: colorModeRaw) ?? .accent },
                set: { colorModeRaw = $0.rawValue }
            )) {
                ForEach(SeekerColorMode.allCases) { c in Text(c.displayName).tag(c) }
            }
            .pickerStyle(.segmented)

            Toggle("Show Thumb", isOn: $showThumb)
                .tint(AppTheme.dynamicAccent)
                .font(.caption)

            VStack(alignment: .leading, spacing: 4) {
                Text("Glow").font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $glowIntensity, in: 0...1)
                    .tint(AppTheme.dynamicAccent)
            }
        }
        .padding(.top, 4)
    }
}
