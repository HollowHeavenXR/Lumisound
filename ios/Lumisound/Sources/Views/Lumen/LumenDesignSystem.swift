import SwiftUI
import UIKit

// MARK: - Lumen design system
//
// The visual language of the redesigned interface (`InterfaceEdition.lumen`).
//
// - Ground: near-black ink with a faint violet cast. The app is "lit" by the
//   current track: `LumenAmbience` samples its artwork and `LumenBackdrop`
//   lets those colors glow in from the corners of every screen.
// - Surfaces: lifted cards with a one-pixel top light (`hairline`), never a
//   flat tint. Corners are continuous and generous (20pt cards, 12pt art).
// - Color: the brand iris → azure gradient appears only where something is
//   primary or selected (play buttons, the active tab, progress).
// - Type: SF Rounded throughout; big heavy display titles, quiet captions.

// MARK: - Palette

enum LumenPalette {
    static let iris          = Color(red: 0.608, green: 0.482, blue: 1.000)
    static let azure         = Color(red: 0.310, green: 0.765, blue: 1.000)
    static let ember         = Color(red: 1.000, green: 0.478, blue: 0.396)

    static var ink           : Color { Appearance.current.background.color }
    static var surface       : Color { Appearance.current.surface.color }
    static var elevated      : Color { Appearance.current.elevated.color }

    static var textPrimary   : Color { Appearance.current.textPrimary.color }
    static var textSecondary : Color { Appearance.current.textSecondary.color }
    static var textTertiary  : Color { Appearance.current.textTertiary.color }

    static var hairline      : Color { Appearance.current.hairline.color }
    static var fill          : Color { Appearance.current.fill.color }
    static var fillStrong    : Color { Appearance.current.fillStrong.color }

    static let warning       = Color(red: 1.000, green: 0.706, blue: 0.329)
    static let success       = Color(red: 0.290, green: 0.871, blue: 0.608)
    static let error         = Color(red: 1.000, green: 0.420, blue: 0.506)

    /// The user's accent (defaults to iris) — what "selected" looks like.
    static var accent: Color { Appearance.current.accentOverride?.color ?? AppTheme.dynamicAccent }
    static var accentSecondary: Color { Appearance.current.accentOverride?.color.opacity(0.7) ?? AppTheme.dynamicAccentSecondary }

    static var glow: LinearGradient {
        LinearGradient(colors: [accent, accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var glowHorizontal: LinearGradient {
        LinearGradient(colors: [accent, accentSecondary], startPoint: .leading, endPoint: .trailing)
    }

    /// Stable two-color gradient derived from any string — used for art that
    /// has no image (empty playlists, genres, artists without a photo) so the
    /// same name always gets the same colors.
    static func generated(for seed: String) -> [Color] {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let hue = Double(hash % 360) / 360
        let shift = 0.08 + Double((hash >> 9) % 10) / 100
        return [
            Color(hue: hue, saturation: 0.62, brightness: 0.86),
            Color(hue: (hue + shift).truncatingRemainder(dividingBy: 1), saturation: 0.78, brightness: 0.46),
        ]
    }
}

// MARK: - Type

enum LumenType {
    static func display(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func headline(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .regular, design: .rounded) }
    static func caption(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    static func eyebrow(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func mono(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .medium, design: .rounded).monospacedDigit() }
}

enum LumenMetrics {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 22
    static let artRadius: CGFloat = 12
    static let tabBarHeight: CGFloat = 64
    static let miniPlayerHeight: CGFloat = 64
    /// Space the floating dock (mini player + tab bar) takes at the bottom of
    /// every Lumen screen; content insets by this so nothing hides under it.
    static func dockHeight(hasMiniPlayer: Bool) -> CGFloat {
        tabBarHeight + (hasMiniPlayer ? miniPlayerHeight + 8 : 0) + 12
    }
}

// MARK: - Ambience

/// The colors of whatever is playing, softened into glow colors. Every
/// `LumenBackdrop` reads this, so the whole interface shifts hue with the
/// music. Falls back to the brand iris/azure when nothing is playing.
@MainActor
final class LumenAmbience: ObservableObject {
    static let shared = LumenAmbience()

    @Published private(set) var primary: Color = LumenPalette.iris
    @Published private(set) var secondary: Color = LumenPalette.azure

    private var songID: String?

    func update(for song: Song?) async {
        guard song?.id != songID else { return }
        songID = song?.id
        guard let song else {
            withAnimation(.easeInOut(duration: 1.2)) {
                primary = LumenPalette.iris
                secondary = LumenPalette.azure
            }
            return
        }
        guard let palette = await ArtworkPaletteLoader.palette(for: song), songID == song.id else { return }
        withAnimation(.easeInOut(duration: 1.4)) {
            primary = palette.primary.lumenGlow()
            secondary = palette.secondary.lumenGlow(hueShift: 0.04)
        }
    }
}

extension Color {
    /// Lifts an averaged artwork color (often muddy) into something that
    /// reads as light on the ink ground: floor the saturation, clamp the
    /// brightness into a glowing band.
    func lumenGlow(hueShift: CGFloat = 0) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let hue = (h + hueShift).truncatingRemainder(dividingBy: 1)
        // Near-greyscale art has no meaningful hue; let it glow brand iris.
        if s < 0.12 { return LumenPalette.iris }
        return Color(hue: hue, saturation: min(max(s, 0.5), 0.9), brightness: min(max(b, 0.6), 0.92))
    }
}

// MARK: - Backdrop

/// The ground every Lumen screen sits on: ink, plus two slow-drifting glows
/// tinted by `LumenAmbience`.
struct LumenBackdrop: View {
    var intensity: Double = 1
    @ObservedObject private var ambience = LumenAmbience.shared
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("app_reduce_motion") private var appReduceMotion = false
    @State private var drift = false

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        let intensity = intensity * appearance.tokens.ambientIntensity
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                LumenPalette.ink
                Circle()
                    .fill(RadialGradient(colors: [ambience.primary.opacity(0.42 * intensity), .clear],
                                         center: .center, startRadius: 0, endRadius: w * 0.75))
                    .frame(width: w * 1.5, height: w * 1.5)
                    .position(x: drift ? w * 0.05 : w * 0.2, y: drift ? h * 0.02 : h * 0.1)
                Circle()
                    .fill(RadialGradient(colors: [ambience.secondary.opacity(0.30 * intensity), .clear],
                                         center: .center, startRadius: 0, endRadius: w * 0.7))
                    .frame(width: w * 1.4, height: w * 1.4)
                    .position(x: drift ? w * 0.95 : w * 0.8, y: drift ? h * 0.62 : h * 0.5)
                LinearGradient(colors: [.clear, LumenPalette.ink.opacity(0.85)],
                               startPoint: .center, endPoint: .bottom)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { drift = true }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Surfaces

struct LumenCardModifier: ViewModifier {
    var radius: CGFloat = LumenMetrics.cardRadius
    var padding: CGFloat = 16
    /// nil = the selected appearance style's own surface.
    var fill: Color? = nil

    func body(content: Content) -> some View {
        let t = Appearance.current
        let shape = RoundedRectangle(cornerRadius: radius * CGFloat(t.cornerScale), style: .continuous)
        if let fill {
            content
                .padding(padding * CGFloat(t.spacingScale))
                .background {
                    shape.fill(fill)
                        .overlay(shape.strokeBorder(LumenPalette.hairline, lineWidth: max(t.borderWidth, 0.5)))
                }
        } else {
            content
                .padding(padding * CGFloat(t.spacingScale))
                .styledSurface(in: shape, tint: nil)
        }
    }
}

extension View {
    func lumenCard(radius: CGFloat = LumenMetrics.cardRadius, padding: CGFloat = 16,
                   fill: Color? = nil) -> some View {
        modifier(LumenCardModifier(radius: radius, padding: padding, fill: fill))
    }

    /// A pushed Lumen screen: transparent inline bar over the backdrop.
    func lumenScreen(title: String = "", backdrop: Bool = true) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { if backdrop { LumenBackdrop() } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .foregroundStyle(LumenPalette.textPrimary)
    }
}

// MARK: - Buttons

struct LumenPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct LumenPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var expands: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .bold)) }
                Text(title).font(LumenType.headline(15))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(LumenPalette.glow, in: Capsule())
            .shadow(color: LumenPalette.accent.opacity(0.35), radius: 14, y: 6)
        }
        .buttonStyle(LumenPressStyle())
    }
}

struct LumenSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var expands: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .bold)) }
                Text(title).font(LumenType.headline(15))
            }
            .foregroundStyle(LumenPalette.textPrimary)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(LumenPalette.fillStrong, in: Capsule())
            .overlay(Capsule().strokeBorder(LumenPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(LumenPressStyle())
    }
}

struct LumenIconButton: View {
    let systemName: String
    var size: CGFloat = 38
    var tint: Color = LumenPalette.textPrimary
    var filled: Bool = true
    var accessibilityLabel: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background {
                    if filled {
                        Circle().fill(LumenPalette.fill)
                            .overlay(Circle().strokeBorder(LumenPalette.hairline, lineWidth: 1))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(LumenPressStyle(scale: 0.9))
        .accessibilityLabel(accessibilityLabel ?? systemName)
    }
}

struct LumenChip: View {
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .bold)) }
                Text(title).font(LumenType.caption(13)).lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : LumenPalette.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background {
                if isSelected {
                    Capsule().fill(LumenPalette.glowHorizontal)
                } else {
                    Capsule().fill(LumenPalette.fill)
                        .overlay(Capsule().strokeBorder(LumenPalette.hairline, lineWidth: 1))
                }
            }
        }
        .buttonStyle(LumenPressStyle())
    }
}

/// Capsule segmented control with a sliding gradient thumb.
struct LumenSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(LumenType.headline(14))
                        .foregroundStyle(selected ? Color.white : LumenPalette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if selected {
                                Capsule().fill(LumenPalette.glowHorizontal)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(LumenPalette.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(LumenPalette.hairline, lineWidth: 1))
    }
}

// MARK: - Headers

struct LumenSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LumenType.title(21))
                    .foregroundStyle(LumenPalette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(LumenType.caption(13))
                        .foregroundStyle(LumenPalette.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    }
                    .font(LumenType.caption(13))
                    .foregroundStyle(LumenPalette.accent)
                }
                .buttonStyle(LumenPressStyle())
            }
        }
        .padding(.horizontal, LumenMetrics.gutter)
    }
}

/// Big top-of-screen header used by every Lumen tab root in place of a
/// navigation bar title.
struct LumenScreenHeader<Trailing: View>: View {
    var eyebrow: String? = nil
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(LumenType.eyebrow())
                        .tracking(1.6)
                        .foregroundStyle(LumenPalette.accent)
                }
                Text(title)
                    .font(LumenType.display(34))
                    .foregroundStyle(LumenPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, LumenMetrics.gutter)
        .padding(.top, 8)
    }
}

extension LumenScreenHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

// MARK: - Art

/// Square art for a song (its artwork) with Lumen's rounding and top light.
struct LumenArtwork: View {
    let song: Song?
    var size: CGFloat
    var radius: CGFloat = LumenMetrics.artRadius
    var fallbackSeed: String = "Lumisound"

    var body: some View {
        Group {
            if let song {
                ArtworkThumbnail(song: song, size: size, showsScrim: false)
            } else {
                LumenGeneratedArt(seed: fallbackSeed, symbol: "music.note")
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Gradient art generated from a name, with an optional glyph and monogram.
struct LumenGeneratedArt: View {
    let seed: String
    var symbol: String? = nil
    var showsMonogram: Bool = false

    var body: some View {
        GeometryReader { geo in
            let colors = LumenPalette.generated(for: seed)
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: geo.size.width * 0.9)
                    .offset(x: geo.size.width * 0.35, y: -geo.size.height * 0.35)
                if showsMonogram, let first = seed.first(where: { $0.isLetter || $0.isNumber }) {
                    Text(String(first).uppercased())
                        .font(.system(size: geo.size.width * 0.42, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: geo.size.width * 0.32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
    }
}

/// 2×2 mosaic of up to four songs' artwork (one fills the square; none falls
/// back to generated art).
struct LumenCollage: View {
    let songs: [Song]
    var size: CGFloat
    var radius: CGFloat = LumenMetrics.artRadius
    var seed: String = "Playlist"
    var symbol: String = "music.note.list"

    var body: some View {
        Group {
            if songs.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkThumbnail(song: songs[0], size: half, showsScrim: false).frame(width: half, height: half).clipped()
                        ArtworkThumbnail(song: songs[1], size: half, showsScrim: false).frame(width: half, height: half).clipped()
                    }
                    HStack(spacing: 0) {
                        ArtworkThumbnail(song: songs[2], size: half, showsScrim: false).frame(width: half, height: half).clipped()
                        ArtworkThumbnail(song: songs[3], size: half, showsScrim: false).frame(width: half, height: half).clipped()
                    }
                }
            } else if let first = songs.first {
                ArtworkThumbnail(song: first, size: size, showsScrim: false)
            } else {
                LumenGeneratedArt(seed: seed, symbol: symbol)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Shelf card: art on top, two lines of caption beneath. The art carries the
/// press feedback; the caption stays put.
struct LumenShelfCard<Art: View>: View {
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = 148
    @ViewBuilder var art: () -> Art

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            art()
                .frame(width: width, height: width)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LumenType.headline(14))
                    .foregroundStyle(LumenPalette.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(LumenType.caption(12))
                        .foregroundStyle(LumenPalette.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

// MARK: - Rows

/// Animated three-bar "now playing" glyph.
struct LumenEqualizerGlyph: View {
    var isAnimating: Bool
    var color: Color = LumenPalette.accent
    var height: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !isAnimating)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = sin(t * (5.0 + Double(i) * 1.7) + Double(i) * 1.3)
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: isAnimating ? height * (0.35 + 0.65 * abs(phase)) : height * 0.4)
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// The one track row every Lumen list uses.
struct LumenTrackRow: View {
    let song: Song
    var index: Int? = nil
    var showsArtwork: Bool = true
    var subtitle: String? = nil
    let onTap: () -> Void

    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager

    private var isCurrent: Bool { player.currentSong?.id == song.id }

    var body: some View {
        songContent.engineConvertingOverlay(songID: song.id)
    }

    /// The row itself; `body` adds the re-encoding lock overlay.
    @ViewBuilder private var songContent: some View {
        HStack(spacing: 14) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    if let index, !showsArtwork {
                        ZStack {
                            if isCurrent {
                                LumenEqualizerGlyph(isAnimating: player.isPlaying)
                            } else {
                                Text("\(index)")
                                    .font(LumenType.mono(14))
                                    .foregroundStyle(LumenPalette.textTertiary)
                            }
                        }
                        .frame(width: 26)
                    }
                    if showsArtwork {
                        ZStack {
                            LumenArtwork(song: song, size: 50, radius: 10)
                            if isCurrent {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.black.opacity(0.45))
                                    .frame(width: 50, height: 50)
                                LumenEqualizerGlyph(isAnimating: player.isPlaying, color: .white)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.displayName)
                            .font(LumenType.headline(15))
                            .foregroundStyle(isCurrent ? LumenPalette.accent : LumenPalette.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if library.isFavorite(songID: song.id) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(LumenPalette.ember)
                            }
                            Text(subtitle ?? "\(song.artistName) · \(song.albumName)")
                                .font(LumenType.caption(12.5))
                                .foregroundStyle(LumenPalette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(song.durationText)
                        .font(LumenType.mono(12))
                        .foregroundStyle(LumenPalette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(LumenPressStyle(scale: 0.98))

            Menu {
                SongContextMenuContent(song: song)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LumenPalette.textSecondary)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More actions for \(song.displayName)")
        }
        .padding(.horizontal, LumenMetrics.gutter)
        .padding(.vertical, 7)
        .songContextMenu(for: song)
    }
}

/// Row used in Lumen's own navigation lists (library index, settings, You).
struct LumenNavRow: View {
    let title: String
    let systemImage: String
    var tint: Color = LumenPalette.accent
    var detail: String? = nil
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            Text(title)
                .font(LumenType.headline(16))
                .foregroundStyle(LumenPalette.textPrimary)
            Spacer(minLength: 8)
            if let badge {
                Text(badge)
                    .font(LumenType.eyebrow(11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(LumenPalette.error, in: Capsule())
            }
            if let detail {
                Text(detail)
                    .font(LumenType.caption(13))
                    .foregroundStyle(LumenPalette.textSecondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LumenPalette.textTertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Inputs

struct LumenSearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(focused ? LumenPalette.accent : LumenPalette.textSecondary)
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(LumenPalette.textTertiary))
                .font(LumenType.body(16))
                .foregroundStyle(LumenPalette.textPrimary)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LumenPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(LumenPalette.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused ? LumenPalette.accent.opacity(0.6) : LumenPalette.hairline, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.18), value: focused)
    }
}

// MARK: - States

struct LumenEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(LumenPalette.glow).opacity(0.18).frame(width: 96, height: 96)
                Circle().strokeBorder(LumenPalette.glow, lineWidth: 1.5).opacity(0.5).frame(width: 96, height: 96)
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(LumenPalette.glow)
            }
            Text(title)
                .font(LumenType.title(20))
                .foregroundStyle(LumenPalette.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(LumenType.body(14))
                .foregroundStyle(LumenPalette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if let actionTitle, let action {
                LumenPrimaryButton(title: actionTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct LumenStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(LumenType.title(20))
                .foregroundStyle(LumenPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(LumenType.eyebrow(10))
                .tracking(1.1)
                .foregroundStyle(LumenPalette.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Formatting

enum LumenFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}
