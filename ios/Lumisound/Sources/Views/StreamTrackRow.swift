import SwiftUI
import UniformTypeIdentifiers

// MARK: - StreamTrackRow

struct StreamTrackRow: View {

    let track: StreamTrack
    let isLoading: Bool
    let isDownloading: Bool
    let isDownloaded: Bool
    let onPlay: () -> Void
    let onAddToQueue: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail with a small source-icon badge in the corner — gives each
            // row an at-a-glance platform indicator even outside its grouped section.
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: URL(string: track.thumbnailURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty:
                        Image(systemName: sourceIcon)
                            .font(.system(size: 22))
                            .foregroundStyle(AppTheme.textSecondary)
                            .overlay(ShimmerOverlay())
                    case .failure:
                        Image(systemName: sourceIcon)
                            .font(.system(size: 22))
                            .foregroundStyle(AppTheme.textSecondary)
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: 56, height: 56)
                .background(AppTheme.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipped()

                Image(systemName: sourceIcon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(sourceTint, in: Circle())
                    .overlay(Circle().stroke(AppTheme.surface, lineWidth: 1.5))
                    .offset(x: 4, y: 4)
            }

            // Title + artist
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? sourceLabelForTrack : track.artist)
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Duration
            Text(track.durationText)
                .font(AppTheme.monoFont(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(minWidth: 36, alignment: .trailing)

            // Play / spinner
            if isLoading {
                ProgressView()
                    .tint(AppTheme.dynamicAccent)
                    .frame(width: 32, height: 32)
            } else {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(AppTheme.dynamicAccent)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(PressableButtonStyle())
            }

            // Download button — the checkmark pops in with a little spring
            // when a download completes instead of silently swapping icons,
            // so "it worked" reads as an event rather than a static state.
            Button(action: onDownload) {
                Group {
                    if isDownloading {
                        ProgressView()
                            .tint(AppTheme.dynamicAccent)
                    } else if isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(AppTheme.success)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isDownloading || isDownloaded)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isDownloaded)

            // Queue button
            Button(action: onAddToQueue) {
                Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), fallback: .ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
