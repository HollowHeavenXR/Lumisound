import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Transport Controls
    //
    // 2026-07 redesign: control identity/order/visibility/size is now driven
    // by `screenStyle` (resolved from a selected Custom Style's
    // `transportControlOrder`/`hiddenTransportControls`/`transportControlScale`)
    // instead of a fixed shuffle/prev/play/next/repeat layout. Selecting a
    // built-in artwork style (or no custom style) resolves to
    // `NowPlayingScreenStyle.standard`, whose `transportOrder` is the same
    // `TransportControl.allCases` order as before — so the default look is
    // pixel-identical to the pre-redesign layout.

    /// Controls in the user's chosen order, minus any explicitly hidden.
    /// `playPause` can never be hidden (`CustomNowPlayingStyle.sanitized()`
    /// strips it from `hiddenTransportControls` before this ever sees it).
    var visibleTransportControls: [CustomNowPlayingStyle.TransportControl] {
        screenStyle.transportOrder.filter { !screenStyle.hiddenTransportControls.contains($0) }
    }

    /// Controls that render to the left of Play/Pause — Play/Pause always
    /// stays visually centered regardless of where it falls in the saved
    /// order; only the *relative* order of the other controls (and which
    /// side of Play/Pause they land on) is actually driven by that order.
    var transportLeftControls: [CustomNowPlayingStyle.TransportControl] {
        guard let idx = visibleTransportControls.firstIndex(of: .playPause) else { return visibleTransportControls }
        return Array(visibleTransportControls[..<idx])
    }

    var transportRightControls: [CustomNowPlayingStyle.TransportControl] {
        guard let idx = visibleTransportControls.firstIndex(of: .playPause) else { return [] }
        return Array(visibleTransportControls[(idx + 1)...])
    }

    var transportSection: some View {
        HStack(spacing: 0) {
            ForEach(transportLeftControls) { control in
                transportControlView(for: control)
                Spacer()
            }
            playPauseButton
            ForEach(transportRightControls) { control in
                Spacer()
                transportControlView(for: control)
            }
        }
        .padding(.vertical, 4)
    }

    var repeatIcon: String {
        switch player.repeatMode {
        case .off:  return "repeat"
        case .all:  return "repeat"
        case .one:  return "repeat.1"
        }
    }

    /// Play / Pause — centered, a soft gradient circle (accent-driven, so a
    /// custom style's accent color/extracted palette carries through here
    /// too) with press-scale feedback for a tactile, modern feel.
    var playPauseButton: some View {
        let scale = screenStyle.transportScale
        return Button {
            playHaptic.impactOccurred()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                player.togglePlayPause()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [screenStyle.accentColor, AppTheme.accentSoft],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 76 * scale, height: 76 * scale)
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: screenStyle.accentColor.opacity(0.5), radius: 16, x: 0, y: 8)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolReplaceTransition()
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    /// Resolves one `TransportControl` case to its concrete button.
    @ViewBuilder
    func transportControlView(for control: CustomNowPlayingStyle.TransportControl) -> some View {
        switch control {
        case .shuffle:
            transportToggle(
                systemName: "shuffle",
                label: "Shuffle",
                isActive: player.shuffleEnabled
            ) {
                selectHaptic.selectionChanged()
                player.toggleShuffle()
            }
        case .previous:
            transportSkipButton(
                systemName: "backward.fill",
                label: "Previous"
            ) {
                skipHaptic.impactOccurred()
                player.skipToPrevious()
            }
        case .playPause:
            playPauseButton
        case .next:
            transportSkipButton(
                systemName: "forward.fill",
                label: "Next"
            ) {
                skipHaptic.impactOccurred()
                player.userSkipToNext()
            }
        case .repeatControl:
            transportToggle(
                systemName: repeatIcon,
                label: "Repeat",
                isActive: player.repeatMode != .off
            ) {
                selectHaptic.selectionChanged()
                player.cycleRepeatMode()
            }
        }
    }

    // 2026-09 restructure: previous/next are large bare glyphs and
    // shuffle/repeat are smaller glyphs that turn accent-coloured with a dot
    // underneath when on — instead of every control sitting in a filled
    // circle, which made the whole row read as five equal buttons. Size,
    // colour and order still come from `screenStyle`, so custom styles keep
    // working.

    /// Previous / next.
    func transportSkipButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        let scale = screenStyle.transportScale
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 30 * scale, weight: .semibold))
                .foregroundStyle(screenStyle.controlsColor ?? AppTheme.textPrimary)
                .frame(width: 56 * scale, height: 56 * scale)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    /// Shuffle / repeat.
    func transportToggle(
        systemName: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let scale = screenStyle.transportScale
        return Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 19 * scale, weight: .semibold))
                    .foregroundStyle(
                        isActive
                            ? screenStyle.accentColor
                            : (screenStyle.controlsColor ?? AppTheme.textSecondary)
                    )
                    .symbolReplaceTransition()
                Circle()
                    .fill(screenStyle.accentColor)
                    .frame(width: 4, height: 4)
                    .opacity(isActive ? 1 : 0)
            }
            .frame(width: 46 * scale, height: 50 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(isActive ? "On" : "Off")
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}
