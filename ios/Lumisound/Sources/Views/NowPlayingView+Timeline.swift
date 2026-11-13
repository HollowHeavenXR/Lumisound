import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Timeline

    // 2026-09 restructure: the seeker and playtime-counter style pickers
    // (two horizontally scrolling chip rows, plus the custom-seeker panel)
    // moved into the Customize sheet. What's left is the scrubber and, when
    // one is chosen, the counter — tap it to step to the next format.
    var timelineSection: some View {
        VStack(spacing: 6) {
            NowPlayingScrubber(seekerStyle: seekerStyle, seekHaptic: seekHaptic)
            if playtimeCounterStyle != .hidden {
                Button {
                    selectHaptic.selectionChanged()
                    cyclePlaytimeCounterStyle()
                } label: {
                    NowPlayingPlaytimeCounter(style: playtimeCounterStyle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Changes the time format")
            }
        }
    }

    /// Next visible counter format — skips `.hidden`, which is only chosen
    /// from the Customize sheet so a tap can't make the counter vanish.
    func cyclePlaytimeCounterStyle() {
        let formats = PlaytimeCounterStyle.allCases.filter { $0 != .hidden }
        guard let idx = formats.firstIndex(of: playtimeCounterStyle) else { return }
        withAnimation(LumiMotion.snap) {
            playtimeCounterStyle = formats[(idx + 1) % formats.count]
        }
    }
}

// MARK: - Progress-isolated subviews
//
// These declare their own `@EnvironmentObject var progress: PlaybackProgress`
// instead of `NowPlayingView` doing so. `@EnvironmentObject`/`@ObservedObject`
// subscribes to `objectWillChange` for as long as it's *declared* on a type —
// regardless of whether that render's `body` actually reads it (see
// `PlaybackProgress`'s doc comment in AudioPlayerManager.swift) — so having
// it on `NowPlayingView` itself, one of the biggest view trees in the app
// (artwork, queue preview, lyrics, EQ, effects), forced all of that to
// re-evaluate on every ~0.25-0.5s position tick. Isolating the two pieces
// that actually need live position into their own small views keeps only
// these re-rendering that often.

private struct NowPlayingScrubber: View {
    @EnvironmentObject private var progress: PlaybackProgress
    @EnvironmentObject private var player: AudioPlayerManager
    let seekerStyle: SeekerStyle
    let seekHaptic: UIImpactFeedbackGenerator

    var body: some View {
        let onSeek: (TimeInterval) -> Void = { seekHaptic.impactOccurred(); player.seek(to: $0) }
        switch seekerStyle {
        case .waveform:
            if let url = player.currentSong?.url, url.isFileURL, progress.duration > 0 {
                WaveformScrubberView(
                    url: url,
                    position: progress.position,
                    duration: progress.duration,
                    isPlaying: player.isPlaying,
                    onSeek: onSeek
                )
            } else {
                ClassicScrubberView(
                    position: progress.position,
                    duration: progress.duration,
                    isPlaying: player.isPlaying,
                    onSeek: onSeek
                )
            }
        case .classic:
            ClassicScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        case .ring:
            RingScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        case .bars:
            BarsScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        case .digital:
            DigitalScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        case .pill:
            PillScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        case .neonLine:
            NeonLineScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        case .dotTrack:
            DotTrackScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        case .segmented:
            SegmentedScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        case .minimal:
            MinimalScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        case .ruler:
            RulerScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        case .custom:
            CustomScrubberView(
                position: progress.position,
                duration: progress.duration,
                isPlaying: player.isPlaying,
                onSeek: onSeek
            )
        }
    }
}

private struct NowPlayingPlaytimeCounter: View {
    @EnvironmentObject private var progress: PlaybackProgress
    let style: PlaytimeCounterStyle

    var body: some View {
        Text(style.text(position: progress.position, duration: progress.duration))
            .font(AppTheme.monoFont(size: 13))
            .foregroundStyle(AppTheme.textSecondary)
            .contentTransition(.numericText())
            .animation(LumiMotion.snap, value: progress.position)
    }
}
