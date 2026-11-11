import AppIntents
import SwiftUI
import WidgetKit

// Building blocks shared by the Home Screen / Lock Screen widgets and the
// Live Activity. Everything takes a `NowPlayingSnapshot`, and every moving
// part (bar, elapsed, remaining) is driven by the system from the snapshot's
// wall-clock range, so it advances smoothly between updates and lands exactly
// where the app's own scrubber is.

/// Artwork in its own shape: square art as a square, a 16:9 video frame as a
/// 16:9 tile. `height` fixes the tile height; width follows the shape.
struct NowPlayingArtwork: View {
    let image: UIImage?
    let snapshot: NowPlayingSnapshot
    var height: CGFloat
    var cornerRadius: CGFloat = 10
    /// Force a square tile (tight spots like the compact Dynamic Island).
    var square = false

    private var width: CGFloat {
        square || !snapshot.isWide ? height : (height * 16 / 9).rounded()
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [snapshot.tintColor.opacity(0.55), snapshot.backdropColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: height * 0.38, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// Track progress. While playing it is a system timer bar (no updates needed
/// to move); paused, it sits at the exact paused position.
struct NowPlayingProgressBar: View {
    let snapshot: NowPlayingSnapshot
    var tint: Color? = nil
    var height: CGFloat = 4

    var body: some View {
        let color = tint ?? snapshot.tintColor
        Group {
            if snapshot.isLive {
                ProgressView(timerInterval: snapshot.wallRange, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(color)
            } else {
                ProgressView(value: snapshot.fraction)
                    .progressViewStyle(.linear)
                    .tint(color)
            }
        }
        .frame(height: height)
    }
}

/// Small circular progress ring (compact Dynamic Island, Lock Screen circle).
struct NowPlayingRing: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        Group {
            if snapshot.isLive {
                ProgressView(timerInterval: snapshot.wallRange, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: snapshot.fraction)
            }
        }
        .progressViewStyle(.circular)
        .tint(snapshot.tintColor)
    }
}

/// "1:12 ........ -2:31". Elapsed ticks by itself at normal speed; at other
/// speeds it shows the speed instead (a ticking label would count real
/// seconds). Remaining is real time left either way.
struct NowPlayingTimeRow: View {
    let snapshot: NowPlayingSnapshot
    var font: Font = .system(size: 11, weight: .medium)
    var opacity: Double = 0.7

    var body: some View {
        HStack(spacing: 0) {
            elapsed
                .frame(maxWidth: .infinity, alignment: .leading)
            remaining
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(font)
        .monospacedDigit()
        .foregroundStyle(.white.opacity(opacity))
        .lineLimit(1)
    }

    @ViewBuilder private var elapsed: some View {
        if snapshot.isLive, snapshot.isNormalSpeed {
            Text(timerInterval: snapshot.wallRange, countsDown: false, showsHours: snapshot.duration >= 3600)
                .multilineTextAlignment(.leading)
        } else if snapshot.isLive {
            Text(NowPlayingFormat.rate(snapshot.rate))
        } else {
            Text(NowPlayingFormat.time(snapshot.elapsed()))
        }
    }

    @ViewBuilder private var remaining: some View {
        if snapshot.duration <= 0 {
            Text("--:--")
        } else if snapshot.isLive {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text("-")
                Text(timerInterval: snapshot.wallRange, countsDown: true, showsHours: snapshot.duration >= 3600)
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
            }
        } else {
            Text("-" + NowPlayingFormat.time(max(0, snapshot.duration - snapshot.elapsed())))
        }
    }
}

/// Previous / play-pause / next (+ favourite). Buttons run their intents in
/// the app's process (see LumisoundPlaybackIntents.swift).
struct NowPlayingControls: View {
    let snapshot: NowPlayingSnapshot
    var size: CGFloat = 20
    var spacing: CGFloat = 26
    var showsFavorite = false
    var showsSkips = true

    var body: some View {
        HStack(spacing: spacing) {
            if showsFavorite {
                Button(intent: ToggleFavoriteIntent()) {
                    Image(systemName: snapshot.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: size * 0.8, weight: .semibold))
                        .foregroundStyle(snapshot.isFavorite ? Color.pink : .white.opacity(0.85))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
            }
            if showsSkips {
                Button(intent: SkipPreviousIntent()) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: size * 0.82, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 1.15, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: size * 1.6, height: size * 1.6)
            }
            .buttonStyle(.plain)
            if showsSkips {
                Button(intent: SkipNextIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: size * 0.82, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Title, artist and the engine/format line.
struct NowPlayingLabels: View {
    let snapshot: NowPlayingSnapshot
    var titleSize: CGFloat = 15
    var titleLines = 1
    var showsDetail = true
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(snapshot.hasTrack ? snapshot.title : "Nothing Playing")
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(titleLines)
            if !snapshot.artist.isEmpty {
                Text(snapshot.artist)
                    .font(.system(size: titleSize * 0.82))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            if showsDetail, let line = detailLine {
                Text(line)
                    .font(.system(size: max(9, titleSize * 0.66), weight: .medium))
                    .foregroundStyle(snapshot.tintColor)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    private var detailLine: String? {
        var parts: [String] = []
        if let d = snapshot.detail, !d.isEmpty { parts.append(d) }
        if let bpm = snapshot.bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Background: the artwork's colour, darkened, so text stays readable on any art.
struct NowPlayingBackdrop: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        LinearGradient(
            colors: [snapshot.backdropColor, Color(white: 0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
