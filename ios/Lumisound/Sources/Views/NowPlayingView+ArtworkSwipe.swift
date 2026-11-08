import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Artwork swipe-to-skip

    /// Swipe left/right on the artwork to skip to the next/previous track,
    /// mirroring the forward/backward transport buttons. Requires the drag to
    /// be clearly horizontal so it doesn't fight a sheet's swipe-to-dismiss.
    /// Horizontal-only (see `HorizontalSwipeGesture`), so a vertical drag
    /// that starts on the artwork still scrolls the screen.
    var artworkSwipeGesture: HorizontalSwipeGesture {
        HorizontalSwipeGesture(
            onChanged: { horizontal in
                // Rubber-band: follow the finger but taper past ~120pt so a
                // long drag doesn't fling the artwork off-screen.
                artworkDragOffset = horizontal * (abs(horizontal) > 120 ? 0.15 : 0.4)
                artworkDragScale = 1.0 - min(abs(horizontal) / 800, 0.06)
            },
            onEnded: { horizontal, vertical in
                let isHorizontalSwipe = abs(horizontal) > abs(vertical) * 1.5 && abs(horizontal) > 60

                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    artworkDragOffset = 0
                    artworkDragScale = 1.0
                }

                guard isHorizontalSwipe else { return }
                skipHaptic.impactOccurred()
                if horizontal < 0 {
                    player.userSkipToNext()
                } else {
                    player.skipToPrevious()
                }
            }
        )
    }
}
