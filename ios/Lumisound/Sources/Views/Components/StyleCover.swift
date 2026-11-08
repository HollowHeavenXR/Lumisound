import SwiftUI

/// Shared album-cover renderer for the Now Playing artwork styles: the real
/// artwork when available, a themed gradient placeholder otherwise. Keeps each
/// style view lean so they can focus on their own animated presentation.
struct StyleCover: View {
    let song: Song?
    let size: CGFloat
    var cornerRadius: CGFloat = 0

    @EnvironmentObject private var library: LibraryManager

    var body: some View {
        Group {
            if let song {
                // No scrim: in Now Playing the cover is the whole point.
                ArtworkThumbnail(song: song, size: size, showsScrim: false, drawsInSwiftUI: true)
                    .environmentObject(library)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.surface, AppTheme.elevatedSurface],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.25, weight: .semibold))
                            .foregroundStyle(AppTheme.dynamicAccent)
                    )
            }
        }
    }
}
