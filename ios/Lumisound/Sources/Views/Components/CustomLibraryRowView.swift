import SwiftUI

// MARK: - Shape type erasure (artwork clip shape needs to return one of 3 shapes)

private struct AnyLibraryShape: Shape {
    private let pathBuilder: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { pathBuilder = shape.path(in:) }
    func path(in rect: CGRect) -> Path { pathBuilder(rect) }
}

// MARK: - CustomLibraryRowView
//
// Generic renderer for user-created custom library row styles. Unlike the
// 4 built-in `SongCardStyle` cases (each a hand-written body in `SongRow`),
// this one interprets a `CustomLibraryRowStyle` value at runtime.
struct CustomLibraryRowView: View {
    let song: Song
    let isCurrent: Bool
    let config: CustomLibraryRowStyle
    var subtitle: String? = nil


    private var resolvedSubtitle: String {
        subtitle ?? "\(song.artistName) · \(song.albumName)"
    }

    private var titleColor: Color {
        isCurrent ? config.accentColor : config.titleColor
    }

    private var artworkShape: AnyLibraryShape {
        switch config.artworkShape {
        case .square:
            return AnyLibraryShape(Rectangle())
        case .rounded:
            return AnyLibraryShape(RoundedRectangle(cornerRadius: config.artworkCornerRadius, style: .continuous))
        case .circle:
            return AnyLibraryShape(Circle())
        }
    }

    var body: some View {
        songContent.engineConvertingOverlay(songID: song.id)
    }

    /// The row itself; `body` adds the re-encoding lock overlay.
    @ViewBuilder private var songContent: some View {
        layoutBody
            .contentShape(Rectangle())
            .animation(LumiMotion.fade(0.25), value: isCurrent)
            .contextMenu {
                SongContextMenuContent(song: song)
            }
    }

    @ViewBuilder
    private var layoutBody: some View {
        switch config.layout {
        case .row:
            flatRowBody
        case .card:
            cardRowBody
        }
    }

    private var flatRowBody: some View {
        VStack(spacing: 0) {
            mainRow
                .padding(.vertical, config.density.verticalPadding)
                .padding(.horizontal, config.horizontalInset)
            if config.showDivider {
                Divider().opacity(0.3)
            }
        }
        .background { backgroundTint }
        .overlay(alignment: .leading) { borderAccent }
    }

    private var cardRowBody: some View {
        mainRow
            .padding(12)
            .background {
                cardShape.fill(cardBackgroundFill)
                    .overlay {
                        if config.backgroundTreatment == .frostedGlass {
                            cardShape.fill(.ultraThinMaterial)
                        }
                    }
            }
            .overlay {
                if isCurrent && config.accentUsage == .border {
                    cardShape.strokeBorder(config.accentColor.opacity(0.5), lineWidth: 1.5)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, config.horizontalInset)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: config.cardCornerRadius, style: .continuous)
    }

    private var mainRow: some View {
        HStack(spacing: config.density.spacing) {
            artworkView
            textStack
            Spacer(minLength: 0)
            if config.showDuration { durationLabel }
        }
    }

    private var artworkView: some View {
        let size = CGFloat(config.artworkSize)
        return ArtworkThumbnail(song: song, size: size)
            .clipShape(artworkShape)
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(song.displayName)
                    .foregroundStyle(titleColor)
                    .font(.system(size: CGFloat(config.titleFontSize)))
                    .fontWeight(config.titleWeight.fontWeight)
                    .kerning(CGFloat(config.titleLetterSpacing))
                    .lineLimit(1)
                SongFormatBadge(song: song)
            }
            if config.showSubtitle {
                Text(resolvedSubtitle)
                    .font(.system(size: CGFloat(config.subtitleFontSize)))
                    .foregroundStyle(config.subtitleColor)
                    .lineLimit(1)
            }
        }
    }

    private var durationLabel: some View {
        Text(song.durationText)
            .font(.system(size: CGFloat(config.subtitleFontSize)))
            .foregroundStyle(config.subtitleColor)
            .monospacedDigit()
    }

    @ViewBuilder
    private var backgroundTint: some View {
        if isCurrent && config.accentUsage == .backgroundTint {
            config.accentColor.opacity(0.12)
        }
    }

    @ViewBuilder
    private var borderAccent: some View {
        if isCurrent && config.accentUsage == .border {
            Rectangle().fill(config.accentColor).frame(width: 3)
        }
    }

    /// Base card fill: the now-playing accent tint when active, otherwise
    /// the style's configured background color — both scaled by
    /// `backgroundOpacity` so a style can blend into the gallery background
    /// behind it instead of always reading as a fully opaque card. A
    /// `.gradient` treatment layers a second, softer stop of the same color
    /// on top for a subtle depth effect rather than a flat fill.
    private var cardBackgroundFill: AnyShapeStyle {
        let base = isCurrent && config.accentUsage == .backgroundTint
            ? config.accentColor.opacity(0.16)
            : config.backgroundColor.opacity(0.6)
        let opacity = config.backgroundOpacity
        if config.backgroundTreatment == .gradient {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [base.opacity(opacity), base.opacity(opacity * 0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(base.opacity(opacity))
    }
}

// MARK: - CustomLibraryGridCellView
//
// Grid-cell counterpart, mirroring `SongGridCell`'s layout but driven by the
// same `CustomLibraryRowStyle` config used for the row form.
struct CustomLibraryGridCellView: View {
    let song: Song
    let isCurrent: Bool
    let config: CustomLibraryRowStyle
    var subtitle: String? = nil
    var trackNumber: Int? = nil


    private var resolvedSubtitle: String {
        subtitle ?? song.artistName
    }

    private var cellCornerRadius: CGFloat {
        switch config.artworkShape {
        case .square:  return 0
        case .rounded: return CGFloat(config.artworkCornerRadius)
        case .circle:  return 999
        }
    }

    private var cellBackgroundFill: AnyShapeStyle {
        let base = isCurrent && config.accentUsage == .backgroundTint
            ? config.accentColor.opacity(0.16)
            : config.backgroundColor.opacity(0.5)
        let opacity = config.backgroundOpacity
        if config.backgroundTreatment == .gradient {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [base.opacity(opacity), base.opacity(opacity * 0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(base.opacity(opacity))
    }

    private var cellCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: config.cardCornerRadius, style: .continuous)
    }

    var body: some View {
        songContent.engineConvertingOverlay(songID: song.id)
    }

    /// The row itself; `body` adds the re-encoding lock overlay.
    @ViewBuilder private var songContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ArtworkThumbnail(song: song, size: geo.size.width)
                    .overlay(alignment: .bottomTrailing) { nowPlayingBadge }
                    .overlay(alignment: .topLeading) { trackNumberBadge }
                    .overlay(alignment: .topTrailing) {
                        SongFormatBadge(song: song).padding(4)
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: cellCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayName)
                    .font(.system(size: CGFloat(max(11, config.titleFontSize - 4))))
                    .fontWeight(config.titleWeight.fontWeight)
                    .kerning(CGFloat(config.titleLetterSpacing))
                    .foregroundStyle(isCurrent ? config.accentColor : config.titleColor)
                    .lineLimit(2)
                if config.showSubtitle {
                    Text(resolvedSubtitle)
                        .font(.system(size: CGFloat(max(9, config.subtitleFontSize - 2))))
                        .foregroundStyle(config.subtitleColor)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background {
            cellCardShape.fill(cellBackgroundFill)
                .overlay {
                    if config.backgroundTreatment == .frostedGlass {
                        cellCardShape.fill(.ultraThinMaterial)
                    }
                }
        }
        .overlay {
            if isCurrent && config.accentUsage == .border {
                cellCardShape.strokeBorder(config.accentColor.opacity(0.5), lineWidth: 1.5)
            }
        }
        .padding(.horizontal, config.horizontalInset)
        .animation(LumiMotion.fade(0.25), value: isCurrent)
        .contextMenu {
            SongContextMenuContent(song: song)
        }
    }

    @ViewBuilder
    private var nowPlayingBadge: some View {
        if isCurrent {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(config.accentColor, in: Circle())
                .padding(4)
        }
    }

    @ViewBuilder
    private var trackNumberBadge: some View {
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
}
