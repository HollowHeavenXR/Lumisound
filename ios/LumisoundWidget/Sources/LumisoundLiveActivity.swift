import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen banner, Dynamic Island, and the small presentation used by the
/// Apple Watch Smart Stack and CarPlay. Content is the same
/// `NowPlayingSnapshot` the Home Screen widgets read; artwork is that
/// snapshot's own per-track thumbnail, so art always matches the title.
struct LumisoundLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LumisoundActivityAttributes.self) { context in
            LiveActivityLockScreen(snapshot: Self.snapshot(context))
                .activityBackgroundTint(Self.snapshot(context).backdropColor.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = Self.snapshot(context)
            let art = NowPlayingSnapshot.loadImage(s.thumbFile, maxPixel: 180)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    NowPlayingArtwork(image: art, snapshot: s, height: s.isWide ? 44 : 56, cornerRadius: 12)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: ToggleFavoriteIntent()) {
                        Image(systemName: s.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(s.isFavorite ? Color.pink : .white.opacity(0.85))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                }
                DynamicIslandExpandedRegion(.center) {
                    NowPlayingLabels(snapshot: s, titleSize: 15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        NowPlayingProgressBar(snapshot: s)
                        ZStack {
                            NowPlayingTimeRow(snapshot: s)
                            NowPlayingControls(snapshot: s, size: 18, spacing: 26)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                NowPlayingArtwork(image: art, snapshot: s, height: 24, cornerRadius: 6, square: true)
            } compactTrailing: {
                CompactRing(snapshot: s)
            } minimal: {
                CompactRing(snapshot: s)
            }
            .keylineTint(s.tintColor)
        }
        .supplementalActivityFamilies([.small, .medium])
    }

    /// Past its stale date (the track ran out with no update from the app),
    /// the activity shows the track stopped at its end, not still playing.
    static func snapshot(_ context: ActivityViewContext<LumisoundActivityAttributes>) -> NowPlayingSnapshot {
        context.isStale ? context.state.now.finished : context.state.now
    }
}

private struct CompactRing: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        ZStack {
            NowPlayingRing(snapshot: snapshot)
            Image(systemName: snapshot.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(snapshot.tintColor)
        }
        .frame(width: 22, height: 22)
    }
}

private struct LiveActivityLockScreen: View {
    @Environment(\.activityFamily) private var family
    let snapshot: NowPlayingSnapshot

    var body: some View {
        let art = NowPlayingSnapshot.loadImage(snapshot.thumbFile, maxPixel: 180)
        switch family {
        case .small:
            // Watch Smart Stack / CarPlay: art, title, live bar.
            HStack(spacing: 8) {
                NowPlayingArtwork(image: art, snapshot: snapshot, height: 36, cornerRadius: 8, square: true)
                VStack(alignment: .leading, spacing: 3) {
                    NowPlayingLabels(snapshot: snapshot, titleSize: 13, showsDetail: false)
                    NowPlayingProgressBar(snapshot: snapshot, height: 3)
                }
            }
            .padding(10)
        default:
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    NowPlayingArtwork(image: art, snapshot: snapshot, height: snapshot.isWide ? 54 : 62, cornerRadius: 12)
                    NowPlayingLabels(snapshot: snapshot, titleSize: 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 28) // room for the heart
                }
                VStack(spacing: 4) {
                    NowPlayingProgressBar(snapshot: snapshot)
                    ZStack {
                        NowPlayingTimeRow(snapshot: snapshot)
                        NowPlayingControls(snapshot: snapshot, size: 19, spacing: 24, showsFavorite: false)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .overlay(alignment: .topTrailing) {
                Button(intent: ToggleFavoriteIntent()) {
                    Image(systemName: snapshot.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(snapshot.isFavorite ? Color.pink : .white.opacity(0.8))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
    }
}
