import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Sleep Timer Pill

    @ViewBuilder
    var sleepTimerPill: some View {
        if sleepTimer.isActive {
            SleepTimerPillContent { showSleepTimerSheet = true }
                .transition(.scale.combined(with: .opacity))
                .animation(LumiMotion.settle, value: sleepTimer.isActive)
        }
    }
}

/// Split out so the once-a-second countdown tick re-renders only this pill,
/// not all of `NowPlayingView` — see `SleepTimerProgress`'s doc comment.
/// `NowPlayingView` itself still reads `sleepTimer.isActive` directly above
/// (fine: that only changes on start/cancel/expire, not every second), but
/// must NOT also hold `SleepTimerProgress` itself, or the Menu in
/// `NowPlayingView+TopBar.swift` — part of the same view via extensions —
/// would rebuild every second right along with it.
private struct SleepTimerPillContent: View {
    @EnvironmentObject private var sleepProgress: SleepTimerProgress
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text("💤")
                    .font(.caption)
                Text(SleepTimerService.formatRemaining(sleepProgress.remainingSeconds))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.5), value: sleepProgress.remainingSeconds)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .adaptiveGlass(tint: AppTheme.dynamicAccent, in: Capsule(), fallback: .regularMaterial)
            .overlay(
                Capsule()
                    .strokeBorder(AppTheme.dynamicAccent.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
