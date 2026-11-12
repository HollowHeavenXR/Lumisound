import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Volume

    var volumeSection: some View {
        VStack(spacing: 4) {
            // Purely decorative ambient bars (a fake sine wave, not driven by
            // real audio analysis) — deliberately NOT reusing
            // AudioVisualizerService's live FFT tap here, since that tap is
            // shared/idempotent-guarded and already has other consumers (e.g.
            // the "Live Spectrum" artwork style); a second independent
            // start()/stop() caller could cut the tap out from under them.
            AmbientEqualizerBars(isPlaying: player.isPlaying)

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                Slider(value: audioBinding(\.volume), in: 0...AudioSettings.maxVolume)
                    .tint(AppTheme.dynamicAccent)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                // AirPlay / output-route picker (AirPlay speakers, Bluetooth, etc.).
                AirPlayRoutePicker(
                    tint: UIColor(AppTheme.textSecondary),
                    activeTint: UIColor(AppTheme.dynamicAccent)
                )
                .frame(width: 30, height: 30)
            }
            // Above 100 % the slider drives LumiBoost (the engine's multiband,
            // route-aware loudness booster) instead of a plain gain stage.
            if player.audioSettings.volume > 1.0 {
                LumiBoostReadout(volume: player.audioSettings.volume, usesEngine: player.isUsingRustEngine)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - LumiBoostReadout

/// "LumiBoost +6.0 dB · Headphone profile" plus a live hold-back meter: how
/// far the booster is keeping loud passages under the ceiling right now
/// (quiet passages get the full boost; that's the point).
private struct LumiBoostReadout: View {
    let volume: Float
    let usesEngine: Bool

    var body: some View {
        let boost = min(20 * log10(volume), AudioSettings.maxBoostDB)
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                Text("LumiBoost +\(String(format: "%.1f", boost)) dB")
                    .font(.caption2.weight(.semibold))
                if usesEngine {
                    Text("· \(AudioPlayerManager.boostRouteName)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .foregroundStyle(AppTheme.dynamicAccent)
            if usesEngine {
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let hold = max(0, min(12, -AudioPlayerManager.rust.boostReduction()))
                    HStack(spacing: 6) {
                        Text("Hold-back")
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.textSecondary)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(AppTheme.textSecondary.opacity(0.15))
                                Capsule()
                                    .fill(hold > 6 ? Color.orange : AppTheme.dynamicAccent)
                                    .frame(width: geo.size.width * CGFloat(hold / 12))
                            }
                        }
                        .frame(height: 4)
                        Text(String(format: "%.1f dB", hold))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .animation(.linear(duration: 0.18), value: hold)
                }
                .frame(height: 12)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - AmbientEqualizerBars

/// A small row of animated bars behind the volume slider — purely decorative
/// (a fake sine wave keyed off wall-clock time), not real audio analysis.
/// See `volumeSection`'s comment for why this deliberately avoids
/// `AudioVisualizerService`'s shared FFT tap.
private struct AmbientEqualizerBars: View {
    let isPlaying: Bool
    private let barCount = 16

    var body: some View {
        // Capped at 30fps: decorative bars gain nothing from 120Hz ProMotion
        // redraws, which were costing CPU for the whole time Now Playing is open.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = Double(i) * 0.45
                    let h = isPlaying ? (0.2 + 0.8 * (0.5 + 0.5 * sin(t * 3.2 + phase))) : 0.15
                    Capsule()
                        .fill(AppTheme.dynamicAccent.opacity(0.35))
                        .frame(height: 18 * CGFloat(h))
                }
            }
            .frame(height: 18, alignment: .center)
            .animation(.easeInOut(duration: 0.2), value: isPlaying)
        }
    }
}
