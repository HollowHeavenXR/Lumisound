import SwiftUI
import UniformTypeIdentifiers

// MARK: - ServerTrackRow

struct ServerTrackRow: View {

    let track: ServerTrack
    let artworkURL: URL?
    let isDownloading: Bool
    let isDownloaded: Bool
    let onPlay: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Artwork
            CachedAsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty:
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(AppTheme.textSecondary)
                        .overlay(ShimmerOverlay())
                case .failure:
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(AppTheme.textSecondary)
                @unknown default:
                    Color.clear
                }
            }
            .frame(width: 48, height: 48)
            .background(AppTheme.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()

            // Title + artist + album/genre
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if !track.genre.isEmpty {
                        Text(track.genre)
                            .font(AppTheme.bodyFont(size: 10).weight(.medium))
                            .foregroundStyle(AppTheme.dynamicAccent)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.dynamicAccent.opacity(0.12), in: Capsule())
                    }
                    if !track.album.isEmpty {
                        Text(track.album)
                            .font(AppTheme.bodyFont(size: 11))
                            .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            // Duration
            Text(track.durationText)
                .font(AppTheme.monoFont(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(minWidth: 36, alignment: .trailing)

            // Play button
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(PressableButtonStyle())

            // Download button — checkmark pops in with a spring rather than
            // just swapping icons, matching StreamTrackRow's treatment.
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
}
