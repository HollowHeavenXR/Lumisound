import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Artwork
    //
    // 2026-09 restructure: the row of 26+ style chips that sat under the
    // artwork is gone — it was the first thing under the cover and pushed
    // the title and controls well down the screen. Styles are now picked in
    // the Customize sheet (`NowPlayingCustomizeSheet`), opened from the small
    // pill under the artwork that names the current style. Swiping the
    // artwork still skips tracks.

    // The artwork stage (2026-09): every style — built-in or custom — is
    // drawn at 300pt and now sits on one shared stage instead of each one
    // floating in its own box:
    //
    // - a fixed 320pt-tall stage, so switching styles or tracks never moves
    //   the title and controls below;
    // - the ambient palette glow as a *background* that bleeds past the
    //   stage without taking layout space, faded out radially (it used to be
    //   clipped to a square, the hard-edged box behind every style);
    // - a soft floor shadow tinted by the accent, which grounds the artwork.
    static let artworkStageHeight: CGFloat = 320

    var artworkSection: some View {
        VStack(spacing: 12) {
            artworkDisplay
                .scaleEffect(artworkScale * artworkDragScale)
                .opacity(artworkOpacity)
                .offset(x: artworkDragOffset)
                .animation(LumiMotion.settle, value: artworkScale)
                .animation(LumiMotion.fade(0.2), value: artworkOpacity)
                .id(artworkAnimationID)
                .modifier(PulseModifier(isPlaying: player.isPlaying))
                .frame(maxWidth: .infinity)
                .frame(height: Self.artworkStageHeight)
                .background {
                    ZStack {
                        AmbientArtworkBackground(song: player.currentSong, isPlaying: artworkIsPlaying)
                            .environmentObject(library)
                        artworkFloorShadow
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(artworkSwipeGesture)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(player.currentSong.map { "Artwork for \($0.displayName)" } ?? "No artwork")
                .accessibilityHint("Swipe left or right to change track")

            currentStylePill
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// A blurred ellipse under the stage, in the accent colour, so the
    /// artwork reads as sitting on something rather than hanging in space.
    var artworkFloorShadow: some View {
        Ellipse()
            .fill(screenStyle.accentColor.opacity(0.35))
            .frame(width: 220, height: 34)
            .blur(radius: 22)
            .offset(y: Self.artworkStageHeight / 2 - 6)
    }

    /// Name + icon of the selected artwork style (built-in or custom).
    var currentStyleLabel: (name: String, icon: String) {
        if let builtin = selectedBuiltinStyle {
            return (builtin.displayName, builtin.iconName)
        }
        if let custom = selectedCustomStyle {
            return (custom.name, custom.iconName)
        }
        return (NowPlayingArtworkStyle.kaleidoscopeBloom.displayName, NowPlayingArtworkStyle.kaleidoscopeBloom.iconName)
    }

    /// "✦ Kaleidoscope Bloom ⌄" — opens the Customize sheet. No long-press
    /// menu: a `.contextMenu` here swallowed vertical drags that started on
    /// the pill, so the screen wouldn't scroll from the middle of it.
    var currentStylePill: some View {
        let label = currentStyleLabel
        return Button {
            selectHaptic.selectionChanged()
            showCustomizeSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: label.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(screenStyle.accentColor)
                Text(label.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(0.6))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Artwork style: \(label.name)")
        .accessibilityHint("Opens Now Playing customization")
    }
}
