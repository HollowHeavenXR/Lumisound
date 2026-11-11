import SwiftUI
import UIKit

// MARK: - Lumen skin
//
// The layer that carries Lumen into every screen that has no bespoke Lumen
// replacement. Three parts:
//
// 1. `lumenGlobalSkin()` — environment styling applied once at Lumen's root,
//    so it reaches every descendant screen and sheet: SF Rounded for every
//    system text style, capsule buttons, prominent list headers, compact
//    section spacing.
// 2. `LumenUIKitSkin` — UIKit appearance for the controls SwiftUI draws
//    through UIKit (segmented pickers, switches, bar buttons, steppers, page
//    dots, lists' scroll backgrounds). Applied before the interface is built
//    and reverted when switching back to Classic.
// 3. Lumen branches inside the shared building blocks classic screens are
//    made of (`SongRow`, `EmptyStateView`, `tintedRowBackground`, settings
//    section headers, the result rows in Cloud) — see `LumenSongRowContent`
//    and `LumenListHeader` below.

extension View {
    func lumenGlobalSkin() -> some View {
        self
            .fontDesign(.rounded)
            .buttonBorderShape(.capsule)
            .headerProminence(.increased)
            .listSectionSpacing(.compact)
            .tint(LumenPalette.accent)
    }
}

enum LumenUIKitSkin {
    private static var applied: InterfaceEdition?

    /// Idempotent; cheap enough to call from `ContentView.body`.
    static func apply(_ edition: InterfaceEdition) {
        guard applied != edition else { return }
        applied = edition

        let segmented = UISegmentedControl.appearance()
        let switches = UISwitch.appearance()
        let barButton = UIBarButtonItem.appearance()
        let pageControl = UIPageControl.appearance()
        let collection = UICollectionView.appearance()

        switch edition {
        case .lumen, .strata:
            let accent = UIColor(edition == .strata ? StrataPalette.accent : LumenPalette.accent)
            segmented.selectedSegmentTintColor = accent
            segmented.backgroundColor = UIColor.white.withAlphaComponent(0.06)
            segmented.setTitleTextAttributes([
                .font: roundedFont(13, .semibold),
                .foregroundColor: UIColor(LumenPalette.textSecondary),
            ], for: .normal)
            segmented.setTitleTextAttributes([
                .font: roundedFont(13, .bold),
                .foregroundColor: UIColor.white,
            ], for: .selected)
            switches.onTintColor = accent
            barButton.setTitleTextAttributes([.font: roundedFont(17, .semibold)], for: .normal)
            pageControl.currentPageIndicatorTintColor = accent
            pageControl.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.25)
            collection.backgroundColor = .clear
        case .classic:
            segmented.selectedSegmentTintColor = nil
            segmented.backgroundColor = nil
            segmented.setTitleTextAttributes(nil, for: .normal)
            segmented.setTitleTextAttributes(nil, for: .selected)
            switches.onTintColor = nil
            barButton.setTitleTextAttributes(nil, for: .normal)
            pageControl.currentPageIndicatorTintColor = nil
            pageControl.pageIndicatorTintColor = nil
            collection.backgroundColor = nil
        }
    }

    private static func roundedFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

// MARK: - Shared pieces used by classic screens' Lumen branches

/// Section header for lists and forms in Lumen: a small gradient glyph and a
/// tracked eyebrow label.
struct LumenListHeader: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = LumenPalette.accent

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(
                        LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
            Text(title.uppercased())
                .font(LumenType.eyebrow(11))
                .tracking(1.4)
                .foregroundStyle(LumenPalette.textSecondary)
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }
}

/// Display-only track row (no tap handling) for classic lists that wrap
/// `SongRow` in their own buttons — Lumen's look, the caller's behavior.
struct LumenSongRowContent: View {
    let song: Song
    let isCurrent: Bool
    var showArtwork: Bool = true
    var subtitle: String? = nil

    @EnvironmentObject private var player: AudioPlayerManager

    var body: some View {
        HStack(spacing: 14) {
            if showArtwork {
                ZStack {
                    LumenArtwork(song: song, size: 48, radius: 10)
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 48, height: 48)
                        LumenEqualizerGlyph(isAnimating: player.isPlaying, color: .white)
                    }
                }
            } else if isCurrent {
                LumenEqualizerGlyph(isAnimating: player.isPlaying)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(song.displayName)
                    .font(LumenType.headline(15))
                    .foregroundStyle(isCurrent ? LumenPalette.accent : LumenPalette.textPrimary)
                    .lineLimit(1)
                Text(subtitle ?? "\(song.artistName) · \(song.albumName)")
                    .font(LumenType.caption(12.5))
                    .foregroundStyle(LumenPalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(song.durationText)
                .font(LumenType.mono(12))
                .foregroundStyle(LumenPalette.textTertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }
}

/// Display-only grid cell (Lumen's look for `SongGridCell`).
struct LumenSongGridContent: View {
    let song: Song
    let isCurrent: Bool
    let subtitle: String
    var trackNumber: Int? = nil

    @EnvironmentObject private var player: AudioPlayerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    LumenArtwork(song: song, size: geo.size.width, radius: 14)
                    if let trackNumber, trackNumber > 0 {
                        Text("\(trackNumber)")
                            .font(LumenType.mono(11))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(7)
                    }
                    if isCurrent {
                        LumenEqualizerGlyph(isAnimating: player.isPlaying, color: .white)
                            .padding(8)
                            .background(.black.opacity(0.5), in: Circle())
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    SongFormatBadge(song: song)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
            Text(song.displayName)
                .font(LumenType.headline(13))
                .foregroundStyle(isCurrent ? LumenPalette.accent : LumenPalette.textPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(LumenType.caption(11.5))
                .foregroundStyle(LumenPalette.textSecondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// Lumen's launch mark: the app icon floating in a slow-breathing glow,
/// with a ring of light orbiting it while the app loads.
struct LumenLaunchMark: View {
    var animate: Bool
    @State private var breathe = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(LumenPalette.glow)
                .frame(width: 150, height: 150)
                .blur(radius: 40)
                .opacity(breathe ? 0.85 : 0.45)
                .scaleEffect(breathe ? 1.08 : 0.92)
            Circle()
                .trim(from: 0, to: 0.32)
                .stroke(
                    AngularGradient(colors: [.clear, LumenPalette.azure, LumenPalette.iris], center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 150, height: 150)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .opacity(animate ? 1 : 0)
            Image("AppIconDisplay")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .shadow(color: LumenPalette.iris.opacity(0.5), radius: 24, y: 10)
        }
        .frame(width: 180, height: 180)
        .onAppear {
            guard animate else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathe = true }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { spin = true }
        }
        .onChange(of: animate) { _, now in
            guard now else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathe = true }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { spin = true }
        }
        .accessibilityHidden(true)
    }
}

/// Full-screen background for classic screens and sheets: the flat
/// `AppTheme.background` it always was in Classic, Lumen's lit backdrop in
/// Lumen.
struct EditionScreenBackground: View {
    var body: some View {
        if InterfaceEdition.isLumen {
            LumenBackdrop()
        } else {
            AppTheme.background.ignoresSafeArea()
        }
    }
}
