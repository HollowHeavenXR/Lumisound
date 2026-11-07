import SwiftUI

// MARK: - SongCardStyle

/// Visual style for the song rows/cards shown throughout the library, queue,
/// favorites, playlists, and artist screens — user-selectable in Appearance
/// settings (`library_cardStyle`) so every `SongRow` call site picks up the
/// chosen look without each screen needing its own rendering logic.
enum SongCardStyle: String, CaseIterable, Identifiable {
    case compact
    case comfortable
    case card
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact:     return "Compact"
        case .comfortable: return "Comfortable"
        case .card:        return "Card"
        case .minimal:     return "Minimal"
        }
    }

    var iconName: String {
        switch self {
        case .compact:     return "list.bullet"
        case .comfortable: return "rectangle.grid.1x2"
        case .card:        return "rectangle.on.rectangle.angled"
        case .minimal:     return "minus"
        }
    }
}

/// Liquid Glass background for the "Card" `SongRow` style — real glass on
/// iOS 26+, falling back to the same flat tint this card used pre-iOS 26
/// (with an accent tint while the song is current) so older OS versions
/// look exactly as before.
private struct SongCardGlassBackground: ViewModifier {
    let isCurrent: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if isCurrent {
            content.adaptiveGlass(
                tint: AppTheme.dynamicAccent,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                fallback: AppTheme.dynamicAccent.opacity(0.14)
            )
        } else {
            content.adaptiveGlass(
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                fallback: AppTheme.elevatedSurface
            )
        }
    }
}

struct SongRow: View {
    let song: Song
    let isCurrent: Bool
    var showArtwork: Bool = true
    var subtitle: String? = nil

    @ObservedObject private var customStyleStore = CustomLibraryStyleStore.shared

    @AppStorage("library_cardStyle") private var cardStyleRaw: String = SongCardStyle.compact.rawValue

    private var style: SongCardStyle? {
        SongCardStyle(rawValue: cardStyleRaw)
    }

    private var customStyle: CustomLibraryRowStyle? {
        customStyleStore.style(withID: cardStyleRaw)
    }

    private var resolvedSubtitle: String {
        subtitle ?? "\(song.artistName) · \(song.albumName)"
    }

    var body: some View {
        songContent.engineConvertingOverlay(songID: song.id)
    }

    /// The row itself; `body` adds the re-encoding lock overlay.
    @ViewBuilder private var songContent: some View {
        if InterfaceEdition.isLumen, customStyle == nil {
            LumenSongRowContent(song: song, isCurrent: isCurrent, showArtwork: showArtwork, subtitle: subtitle)
                .contextMenu {
                    SongContextMenuContent(song: song)
                }
        } else if let customStyle {
            // CustomLibraryRowView applies its own contentShape/animation/contextMenu,
            // so it's returned directly rather than wrapped a second time below.
            CustomLibraryRowView(song: song, isCurrent: isCurrent, config: customStyle, subtitle: subtitle)
        } else {
            builtinBody
                .contentShape(Rectangle())
                // Animate the "now playing" highlight (accent text/background/border)
                // transitioning in or out, instead of snapping instantly.
                .animation(.easeInOut(duration: 0.25), value: isCurrent)
                .contextMenu {
                    SongContextMenuContent(song: song)
                }
        }
    }

    @ViewBuilder
    private var builtinBody: some View {
        switch style ?? .compact {
        case .compact:     compactBody
        case .comfortable: comfortableBody
        case .card:        cardBody
        case .minimal:     minimalBody
        }
    }

    // MARK: - Style variants

    /// The original look — tight single-line row, 44pt artwork.
    private var compactBody: some View {
        HStack(spacing: 12) {
            if showArtwork { artwork(size: 44) }

            VStack(alignment: .leading, spacing: 3) {
                Text(song.displayName)
                    .foregroundStyle(isCurrent ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)

                Text(resolvedSubtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            durationLabel(.caption)
        }
        .padding(.vertical, 4)
    }

    /// More breathing room — bigger artwork and type, generous vertical padding.
    private var comfortableBody: some View {
        HStack(spacing: 14) {
            if showArtwork { artwork(size: 56) }

            VStack(alignment: .leading, spacing: 4) {
                Text(song.displayName)
                    .foregroundStyle(isCurrent ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                    .font(.callout)
                    .fontWeight(isCurrent ? .bold : .semibold)
                    .lineLimit(1)

                Text(resolvedSubtitle)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                formatBadge
                durationLabel(.footnote)
            }
        }
        .padding(.vertical, 9)
    }

    /// Each row rendered as its own elevated, rounded card with an accent
    /// outline when it's the currently-playing track.
    private var cardBody: some View {
        HStack(spacing: 14) {
            if showArtwork { artwork(size: 60, cornerRadius: 12) }

            VStack(alignment: .leading, spacing: 4) {
                Text(song.displayName)
                    .foregroundStyle(isCurrent ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(resolvedSubtitle)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                formatBadge
                durationLabel(.footnote)
            }
        }
        .padding(12)
        .modifier(SongCardGlassBackground(isCurrent: isCurrent, cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isCurrent ? AppTheme.dynamicAccent.opacity(0.5) : .clear, lineWidth: 1.5)
        }
        .padding(.vertical, 4)
    }

    /// Dense, text-forward layout — small artwork, tight line spacing, for
    /// users who'd rather see more tracks per screen.
    private var minimalBody: some View {
        HStack(spacing: 10) {
            if showArtwork { artwork(size: 32, cornerRadius: 5) }

            VStack(alignment: .leading, spacing: 1) {
                Text(song.displayName)
                    .foregroundStyle(isCurrent ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                    .font(.subheadline)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)

                Text(resolvedSubtitle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            durationLabel(.caption2)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Shared pieces

    private func artwork(size: CGFloat, cornerRadius: CGFloat? = nil) -> some View {
        Group {
            if let cornerRadius {
                ArtworkThumbnail(song: song, size: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                ArtworkThumbnail(song: song, size: size)
            }
        }
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: cornerRadius ?? 6, style: .continuous)
                    .fill(AppTheme.dynamicAccent.opacity(0.7))
                WaveformIcon()
            }
        }
    }

    private func durationLabel(_ font: Font) -> some View {
        Text(song.durationText)
            .font(font)
            .foregroundStyle(AppTheme.textSecondary)
            .monospacedDigit()
    }

    private var formatBadge: some View {
        SongFormatBadge(song: song)
    }
}

/// Small outlined tag calling out lossless/Hi-Res files — deliberately
/// silent for the common case (compressed, standard-rate audio) rather than
/// labeling every row/card, so it only draws attention to the notable ones.
/// Shared by `SongRow` (the list presentation) and `SongGridCell` (the card/
/// grid presentation) — the grid cell previously had no format indicator at
/// all, unlike every row-style layout, so a hi-res or lossless file looked
/// identical to any other track whenever the library was viewed as a grid.
struct SongFormatBadge: View {
    let song: Song

    var body: some View {
        if song.isKnownLosslessContainer || song.isHiResSampleRate {
            Text(song.isHiResLossless ? "HI-RES LOSSLESS" : song.isKnownLosslessContainer ? (song.formatTag ?? "LOSSLESS") : "HI-RES")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.dynamicAccent)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(AppTheme.dynamicAccent.opacity(0.5), lineWidth: 1)
                )
        }
    }
}

// MARK: - SongGridCell
//
// Shared grid-cell presentation for songs, used by the main Songs tab's
// 2/3-column grid as well as AlbumDetailView and LocalFolderDetailView's
// grid layouts — keeps artwork sizing, "now playing" badge, and text styling
// consistent everywhere a song grid is shown.

struct SongGridCell: View {
    let song: Song
    let isCurrent: Bool
    /// Optional override for the secondary line (defaults to the artist name).
    var subtitle: String? = nil
    /// Optional track-number badge shown in the top-leading corner of the artwork
    /// (used by AlbumDetailView's grid).
    var trackNumber: Int? = nil

    @ObservedObject private var customStyleStore = CustomLibraryStyleStore.shared

    @AppStorage("library_cardStyle") private var cardStyleRaw: String = SongCardStyle.compact.rawValue

    private var customStyle: CustomLibraryRowStyle? {
        customStyleStore.style(withID: cardStyleRaw)
    }

    private var resolvedSubtitle: String {
        subtitle ?? song.artistName
    }

    var body: some View {
        songContent.engineConvertingOverlay(songID: song.id)
    }

    /// The row itself; `body` adds the re-encoding lock overlay.
    @ViewBuilder private var songContent: some View {
        if InterfaceEdition.isLumen, customStyle == nil {
            LumenSongGridContent(song: song, isCurrent: isCurrent, subtitle: resolvedSubtitle, trackNumber: trackNumber)
                .contextMenu {
                    SongContextMenuContent(song: song)
                }
        } else if let customStyle {
            // CustomLibraryGridCellView applies its own animation/contextMenu,
            // so it's returned directly rather than wrapped a second time below.
            CustomLibraryGridCellView(song: song, isCurrent: isCurrent, config: customStyle, subtitle: subtitle, trackNumber: trackNumber)
        } else {
            builtinBody
        }
    }

    private var builtinBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // GeometryReader ensures the artwork fills the actual column width instead of
            // being locked to a hardcoded size, which caused clipping/spacing issues.
            GeometryReader { geo in
                ArtworkThumbnail(song: song, size: geo.size.width)
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent {
                            Image(systemName: "waveform")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(AppTheme.dynamicAccent, in: Circle())
                                .padding(4)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let trackNumber, trackNumber > 0 {
                            Text("\(trackNumber)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.5), in: Capsule())
                                .padding(4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        SongFormatBadge(song: song)
                            .padding(4)
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCurrent ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                    .lineLimit(2)
                Text(resolvedSubtitle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .adaptiveGlass(
            in: RoundedRectangle(cornerRadius: 10, style: .continuous),
            fallback: AppTheme.surface.opacity(0.5)
        )
        // Animate the "now playing" highlight (accent text/badge) transitioning
        // in or out, instead of snapping instantly.
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
        .contextMenu {
            SongContextMenuContent(song: song)
        }
    }
}

// Animated waveform bars shown when a song is current
private struct WaveformIcon: View {
    @State private var animating = false

    private let heights: [CGFloat] = [0.45, 0.85, 0.60, 0.80, 0.50]
    private let delays: [Double]   = [0.0,  0.15, 0.30, 0.10, 0.25]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppTheme.textPrimary)
                    .frame(width: 3, height: animating ? 14 * heights[i] : 4)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(delays[i]),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}
