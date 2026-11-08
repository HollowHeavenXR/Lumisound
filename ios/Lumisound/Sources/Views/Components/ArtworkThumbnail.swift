import SwiftUI
import UIKit

/// Identifies one `ArtworkThumbnail.task` request. A plain `Equatable` struct
/// instead of an interpolated `"\(song.id)#\(pixelBucket)"` String — SwiftUI
/// re-evaluates `body` (and this id) on every scroll/state invalidation for
/// every visible row, and a formatted-String id would heap-allocate on each
/// of those evaluations just to be diffed against the previous value.
private struct ThumbnailRequestID: Equatable {
    let songID: String
    let pixelBucket: Int
}

struct ArtworkThumbnail: View {
    let song: Song
    let size: CGFloat
    /// The dark fade over the bottom third, for callers that lay text over
    /// the cover. Off for places that show the cover on its own (Now
    /// Playing's styles, album covers), where it only dulled the artwork.
    var showsScrim: Bool = true
    /// Draw the cover with SwiftUI instead of the UIKit `PanningArtwork`.
    /// Required inside a `.drawingGroup()` (Now Playing's styles), which
    /// renders UIKit views blank.
    var drawsInSwiftUI: Bool = false

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage? = nil
    /// False once a load has finished, found or not — stops the shimmer on a
    /// song that simply has no artwork.
    @State private var isLoading = true

    private var cornerRadius: CGFloat { max(4, size * 0.1) }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Placeholder stays underneath so the artwork fades in over it
            // instead of popping in.
            placeholder

            if let image {
                // The whole picture: non-square art slides across the frame
                // instead of being cropped (see `PanningArtwork`).
                Group {
                    if drawsInSwiftUI {
                        SwiftUIPanningArtwork(image: image, size: size)
                    } else {
                        PanningArtwork(image: image)
                            .frame(width: size, height: size)
                    }
                }
                .transition(.opacity)

                if showsScrim {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.black.opacity(0.0),
                            Color.black.opacity(0.45)
                        ]),
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(height: size / 3)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Keyed on size as well as song: grid cells size this view from a
        // GeometryReader, so the width can settle after the first layout pass —
        // without the size in the id, a thumbnail fetched for the initial
        // (smaller) size would never be upgraded.
        .task(id: ThumbnailRequestID(songID: song.id, pixelBucket: Int(size * displayScale))) {
            // Grid cells size this view from a `GeometryReader` (see
            // `SongGridCell`/`LumenSongGridContent`), which can report a
            // transient near-zero width on a cell's very first layout pass
            // inside a `LazyVGrid` — a real, observed SwiftUI quirk, not a
            // hypothetical. Without this guard, that bogus size changed
            // `pixelBucket` above, which cancelled whatever load was already
            // showing and reset `image` to nil below for a size nobody
            // actually wants — reported as "track cards randomly disappear
            // while scrolling, reappear once almost off-screen" (that
            // timing matches: the cell gets a real layout pass, and so a
            // real task, only as it settles near the edge of the lazy
            // container's render window). Skip outright rather than touch
            // any state; the next real layout pass re-triggers this task
            // with a legitimate id.
            guard size >= 1 else { return }
            // Load at (bucketed) display size, not the full 1200px cache size —
            // a 44pt row only needs ~132 physical px, and the thumbnail path
            // keeps disk reads/decodes off the main thread. The synchronous
            // memory-cache check avoids a placeholder flash for art that's
            // already been rendered once.
            let pixelSize = size * displayScale
            if let cached = ArtworkService.shared.thumbnail(for: song, pixelSize: pixelSize) {
                // Already decoded — show it straight away, no fade.
                image = cached
                isLoading = false
                return
            }
            // Clear rather than leave the previous song's art on screen: since
            // SwiftUI can reuse this view's identity for a different row while
            // scrolling, a stale `image` would otherwise display under the
            // new song's row for the duration of the async load below.
            image = nil
            isLoading = true
            let loaded = await ArtworkService.shared.loadThumbnail(for: song, pixelSize: pixelSize)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                image = loaded
            }
            isLoading = false
        }
    }

    /// Accent-tinted gradient with a note glyph — also what shows for a
    /// song that has no artwork at all. Only shimmers while a load is
    /// actually pending.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [AppTheme.dynamicAccent.opacity(0.35), AppTheme.surface],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.32, weight: .medium))
                    .foregroundStyle(AppTheme.dynamicAccent.opacity(0.85))
            }
            .overlay {
                if image == nil, isLoading {
                    ShimmerOverlay()
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .frame(width: size, height: size)
    }
}
