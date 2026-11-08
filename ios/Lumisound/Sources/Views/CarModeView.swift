import SwiftUI
import AVFoundation

// MARK: - CarModeView

/// A full-screen, minimal playback UI optimised for driving.
/// Presents as a `.fullScreenCover` from ContentView and can be dismissed
/// via the "Exit Car Mode" button in the top-right corner.
struct CarModeView: View {

    @EnvironmentObject private var player: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss

    // Volume binding — mirrors player.audioSettings.volume
    @State private var volume: Float = 1.0

    // Haptic generators
    private let playHaptic  = UIImpactFeedbackGenerator(style: .heavy)
    private let skipHaptic  = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        ZStack {
            // MARK: Blurred album-art background
            artworkBackground

            // MARK: Black scrim so text stays legible
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            // MARK: Main layout
            VStack(spacing: 0) {

                // Top bar — only "Exit Car Mode"
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("Exit Car Mode")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.15), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 56)   // below dynamic island / notch

                Spacer()

                // Track info
                trackInfoBlock
                    .padding(.horizontal, 32)

                Spacer()

                // Transport controls
                transportRow
                    .padding(.horizontal, 20)

                Spacer()

                // Volume slider
                volumeRow
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            volume = player.audioSettings.volume
            playHaptic.prepare()
            skipHaptic.prepare()
        }
        .onChange(of: player.audioSettings.volume) { newValue in
            // Volume can change from outside Car Mode (sleep-timer fade, the
            // system volume HUD, another view) — keep the slider's local
            // mirror in sync so it doesn't show a stale position.
            volume = newValue
        }
    }

    // MARK: - Artwork background

    private var artworkBackground: some View {
        GeometryReader { geo in
            if let song = player.currentSong {
                ArtworkThumbnail(song: song, size: max(geo.size.width, geo.size.height))
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 28, opaque: true)
                    .opacity(0.35)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Track info

    private var trackInfoBlock: some View {
        VStack(spacing: 10) {
            Text(player.currentSong?.displayName ?? "Nothing Playing")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            Text(player.currentSong?.artistName ?? "")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Transport row

    private var transportRow: some View {
        HStack(spacing: 0) {
            Spacer()

            // Skip back (previous)
            carButton(systemName: "backward.fill", size: 70) {
                skipHaptic.impactOccurred()
                player.skipToPrevious()
            }

            Spacer()

            // Play / Pause — 100pt
            Button {
                playHaptic.impactOccurred()
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(AppTheme.dynamicAccent)
                        .frame(width: 100, height: 100)
                        .shadow(color: AppTheme.dynamicAccent.opacity(0.5), radius: 20, x: 0, y: 8)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: player.isPlaying)

            Spacer()

            // Skip forward (next)
            carButton(systemName: "forward.fill", size: 70) {
                skipHaptic.impactOccurred()
                player.userSkipToNext()
            }

            Spacer()
        }
    }

    /// Builds a rounded-square skip button for Car Mode.
    private func carButton(
        systemName: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
                Image(systemName: systemName)
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Volume row

    private var volumeRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24)

            Slider(
                value: Binding(
                    get: { volume },
                    set: { newVal in
                        volume = newVal
                        var settings = player.audioSettings
                        settings.volume = newVal
                        player.audioSettings = settings
                    }
                ),
                in: 0...1
            )
            .tint(.white)
            // Increase the touch target so it's easier to adjust while driving
            .frame(height: 36)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28)
        }
    }
}
