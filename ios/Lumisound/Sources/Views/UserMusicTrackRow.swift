import SwiftUI
import UniformTypeIdentifiers

// MARK: - UserMusicTrackRow

struct UserMusicTrackRow: View {
    let track: UserMusicTrack
    let artworkURL: URL?
    var isDeleting: Bool = false
    let onPlay: () -> Void
    let onInfo: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty:
                    Image(systemName: "music.note")
                        .font(.system(size: 18))
                        .foregroundStyle(AppTheme.textSecondary)
                        .overlay(ShimmerOverlay())
                case .failure:
                    Image(systemName: "music.note")
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

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                if !track.artist.isEmpty && track.artist != "Unknown Artist" {
                    Text(track.artist)
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(AppTheme.bodyFont(size: 11))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Text(track.durationText)
                .font(AppTheme.monoFont(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(minWidth: 36, alignment: .trailing)

            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isDeleting)

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isDeleting)

            Button(role: .destructive, action: onDelete) {
                if isDeleting {
                    ProgressView()
                        .tint(AppTheme.error)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 28, height: 28)
                }
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isDeleting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), fallback: .ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.05), lineWidth: 1)
        )
        .opacity(isDeleting ? 0.55 : 1)
        .animation(.easeOut(duration: 0.2), value: isDeleting)
        .contentShape(Rectangle())
        .onTapGesture { if !isDeleting { onPlay() } }
    }
}
