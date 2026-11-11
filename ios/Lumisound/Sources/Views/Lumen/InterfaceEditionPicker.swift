import SwiftUI

// MARK: - Interface edition picker
//
// Shown in both editions (Classic: Settings → Appearance → Interface; Lumen:
// Settings, You, and the welcome card), so either interface can always reach
// the other. Writing the shared `@AppStorage` key is all it takes —
// `ContentView` swaps the whole interface on the change.

struct InterfaceEditionPicker: View {
    @AppStorage(InterfaceEdition.storageKey) private var editionRaw: String = InterfaceEdition.current.rawValue

    private var selected: InterfaceEdition { InterfaceEdition(rawValue: editionRaw) ?? .lumen }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(InterfaceEdition.allCases) { edition in
                Button {
                    guard edition != selected else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.35)) { editionRaw = edition.rawValue }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        // The preview fills whatever width the card gets; it
                        // never sets the width itself (that made the row wider
                        // than the screen).
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 150)
                            .overlay { EditionPreview(edition: edition) }
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        HStack(spacing: 5) {
                            Image(systemName: edition == selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(edition == selected ? Color(red: 0.608, green: 0.482, blue: 1) : .secondary)
                            Text(edition.displayName)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Text(edition.tagline)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white.opacity(edition == selected ? 0.08 : 0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(
                                edition == selected
                                    ? AnyShapeStyle(LinearGradient(colors: [LumenPalette.iris, LumenPalette.azure],
                                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.white.opacity(0.08)),
                                lineWidth: edition == selected ? 2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(edition.displayName) interface")
                .accessibilityHint(edition.tagline)
                .accessibilityAddTraits(edition == selected ? .isSelected : [])
            }
        }
    }
}

/// Miniature of each edition's look, drawn with that edition's literal
/// colors (not `AppTheme`, which follows whichever edition is active).
private struct EditionPreview: View {
    let edition: InterfaceEdition

    var body: some View {
        switch edition {
        case .strata:  strata
        case .lumen:   lumen
        case .classic: classic
        }
    }

    private var lumen: some View {
        VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(LumenPalette.textPrimary).frame(width: 40, height: 8)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [LumenPalette.iris, LumenPalette.azure], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 46)
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.1)).frame(height: 26)
                    }
                }
                Spacer(minLength: 0)
                Capsule().fill(Color.white.opacity(0.1)).frame(height: 16)
                    .overlay(Capsule().fill(LinearGradient(colors: [LumenPalette.iris, LumenPalette.azure], startPoint: .leading, endPoint: .trailing)).frame(width: 22), alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                LumenPalette.ink
                Circle().fill(RadialGradient(colors: [LumenPalette.iris.opacity(0.6), .clear], center: .center, startRadius: 0, endRadius: 70))
                    .frame(width: 140, height: 140).offset(x: -40, y: -50)
                Circle().fill(RadialGradient(colors: [LumenPalette.azure.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 60))
                    .frame(width: 120, height: 120).offset(x: 50, y: 40)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Strata: graphite ground, the Now band on top, layered offset cards,
    /// a numbered ledger and the command capsule — no tab bar.
    private var strata: some View {
        let accent = Color(red: 1.0, green: 0.42, blue: 0.3)
        return ZStack {
            Color(red: 0.07, green: 0.065, blue: 0.065)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 14, height: 14)
                    RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.85)).frame(width: 30, height: 5)
                    Spacer(minLength: 0)
                }
                .padding(4)
                .overlay(Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1), alignment: .bottom)
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.9)).frame(width: 50, height: 9)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)).frame(width: 50, height: 28).offset(x: 12, y: 8)
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.14)).frame(width: 50, height: 28).offset(x: 6, y: 4)
                    RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.8)).frame(width: 50, height: 28)
                }
                .frame(height: 38, alignment: .topLeading)
                ForEach(1..<3, id: \.self) { i in
                    HStack(spacing: 5) {
                        Text("0\(i)").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(accent)
                        RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.6)).frame(width: 36, height: 4)
                    }
                }
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.25), lineWidth: 1).frame(height: 14)
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var classic: some View {
        ZStack {
            Color(red: 0.176, green: 0.216, blue: 0.282)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(i == 0 ? AppTheme.classicAccent.opacity(0.35) : Color(red: 0.29, green: 0.333, blue: 0.408))
                            .frame(height: 10)
                    }
                }
                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.353, green: 0.42, blue: 0.49)).frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            RoundedRectangle(cornerRadius: 2).fill(AppTheme.classicTextPrimary.opacity(0.85)).frame(width: 36, height: 5)
                            RoundedRectangle(cornerRadius: 2).fill(AppTheme.classicTextSecondary.opacity(0.6)).frame(width: 24, height: 4)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    ForEach(0..<5, id: \.self) { i in
                        Circle().fill(i == 0 ? AppTheme.classicAccent : AppTheme.classicTextSecondary.opacity(0.5)).frame(width: 8)
                        if i < 4 { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(Capsule().fill(Color(red: 0.29, green: 0.333, blue: 0.408)))
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Standalone screen (pushed from Classic's Settings → Appearance).
struct InterfaceEditionView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose how Lumisound looks. Your library, playlists, settings and playback carry over either way — only the interface changes, and you can switch back at any time.")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                InterfaceEditionPicker()
            }
            .padding(20)
        }
        .navigationTitle("Interface")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Welcome

/// One-time card on Lumen's first launch: what's new, and the way back.
struct LumenWelcomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(InterfaceEdition.storageKey) private var editionRaw: String = InterfaceEdition.current.rawValue

    private let features: [(icon: String, title: String, detail: String)] = [
        ("sparkles", "Lit by your music", "Every screen picks up the colors of whatever's playing."),
        ("house.fill", "A new Home", "Jump back in, quick tiles, and shelves built from your listening."),
        ("play.circle.fill", "A new player", "Cover, synced lyrics and Up Next on one stage, with the controls below."),
        ("magnifyingglass", "One search", "Songs, artists, albums and playlists — plus the cloud — from one field."),
    ]

    var body: some View {
        ZStack {
            LumenBackdrop(intensity: 1.4)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 26) {
                        ZStack {
                            Circle().fill(LumenPalette.glow).frame(width: 96, height: 96).blur(radius: 24).opacity(0.7)
                            Image("AppIconDisplay")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .padding(.top, 36)

                        VStack(spacing: 8) {
                            Text("MEET LUMEN")
                                .font(LumenType.eyebrow())
                                .tracking(2)
                                .foregroundStyle(LumenPalette.accent)
                            Text("Lumisound, redesigned")
                                .font(LumenType.display(30))
                                .foregroundStyle(LumenPalette.textPrimary)
                                .multilineTextAlignment(.center)
                        }

                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(features, id: \.title) { feature in
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: feature.icon)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 42, height: 42)
                                        .background(LumenPalette.glow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(feature.title)
                                            .font(LumenType.headline(16))
                                            .foregroundStyle(LumenPalette.textPrimary)
                                        Text(feature.detail)
                                            .font(LumenType.body(14))
                                            .foregroundStyle(LumenPalette.textSecondary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                    .padding(.bottom, 20)
                }

                VStack(spacing: 10) {
                    LumenPrimaryButton(title: "Start Exploring", expands: true) { dismiss() }
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            withAnimation { editionRaw = InterfaceEdition.classic.rawValue }
                        }
                    } label: {
                        Text("Keep the Classic interface")
                            .font(LumenType.headline(15))
                            .foregroundStyle(LumenPalette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    Text("You can switch anytime in Settings → Interface.")
                        .font(LumenType.caption(12))
                        .foregroundStyle(LumenPalette.textTertiary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }
}
