import SwiftUI

// MARK: - StreamTrackGridCell
//
// The 2/3-column grid counterpart to `StreamTrackRow` (the original
// single-column list row) — same track data and actions, laid out as an
// artwork-forward tile instead of a wide row, for when the user picks a
// denser layout via the column-count control in `streamResultsBody`.
// Mirrors `AlbumGridCell`'s square-artwork-over-caption shape so the
// streaming search grid reads consistently with the rest of the app's grid
// views (Albums/Songs/Folders tabs).

struct StreamTrackGridCell: View {

    let track: StreamTrack
    let isLoading: Bool
    let isDownloading: Bool
    let isDownloaded: Bool
    let onPlay: () -> Void
    let onAddToQueue: () -> Void
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                GeometryReader { geo in
                    CachedAsyncImage(url: URL(string: track.thumbnailURL)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .empty:
                            Image(systemName: sourceIcon)
                                .font(.system(size: geo.size.width * 0.22))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(ShimmerOverlay())
                        case .failure:
                            Image(systemName: sourceIcon)
                                .font(.system(size: geo.size.width * 0.22))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        @unknown default:
                            Color.clear
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.width)
                }
                .aspectRatio(1, contentMode: .fit)
                .background(AppTheme.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Image(systemName: sourceIcon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(sourceTint, in: Circle())
                    .overlay(Circle().stroke(AppTheme.surface, lineWidth: 1.5))
                    .padding(5)

                // Play / spinner — overlaid centered on the artwork rather
                // than beside it (no room for a separate row of controls at
                // 2-3 columns wide).
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Button(action: onPlay) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(AppTheme.bodyFont(size: 13).weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(track.artist.isEmpty ? sourceLabelForTrack : track.artist)
                        .font(AppTheme.bodyFont(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(track.durationText)
                        .font(AppTheme.monoFont(size: 10))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Button(action: onDownload) {
                    Group {
                        if isDownloading {
                            ProgressView().tint(AppTheme.dynamicAccent)
                        } else if isDownloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AppTheme.success)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .font(.system(size: 16))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isDownloading || isDownloaded)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isDownloaded)

                Button(action: onAddToQueue) {
                    Image(systemName: "text.line.last.and.arrowtriangle.forward")
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isLoading)

                Spacer()
            }
        }
        .padding(8)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: .ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.05), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
    }

    private var sourceIcon: String {
        switch track.source {
        case "soundcloud": return "cloud.fill"
        case "bandcamp":   return "music.note.list"
        default:           return "play.rectangle.fill"
        }
    }

    private var sourceTint: Color {
        switch track.source {
        case "soundcloud": return Color.orange
        case "bandcamp":   return Color.cyan
        default:           return Color.red
        }
    }

    private var sourceLabelForTrack: String {
        switch track.source {
        case "soundcloud": return "SoundCloud"
        case "bandcamp":   return "Bandcamp"
        default:           return "YouTube"
        }
    }
}
