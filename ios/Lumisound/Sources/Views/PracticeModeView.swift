import SwiftUI

/// A dedicated practice tool for musicians learning a track by ear — built
/// entirely from primitives that already exist elsewhere in the app (A-B
/// repeat, the speed slider, per-track BPM) rather than any new playback
/// engine work: loop a specific region, slow it down without losing pitch,
/// and follow a visual metronome pulse synced to the track's own tempo.
/// Opened from Now Playing's overflow menu, operating on whatever's
/// currently loaded — see `NowPlayingView+TopBar.swift`.
struct PracticeModeView: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var bpm: Double?
    @State private var isLoadingBPM = false
    @State private var isExportingClip = false
    @State private var exportedClipURL: URL?
    @State private var showExportShareSheet = false
    @State private var exportError: String?

    private var song: Song? { player.currentSong }

    /// The tempo actually heard right now — the track's own BPM scaled by
    /// current playback speed, since slowing playback down slows the beat
    /// with it.
    private var effectiveBPM: Double? {
        guard let bpm else { return nil }
        return bpm * Double(player.audioSettings.speed)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let song {
                        header(song)
                        metronome
                        speedSection
                        loopSection
                    } else {
                        EmptyStateView(
                            icon: "metronome",
                            title: "Nothing Playing",
                            message: "Start a track, then open Practice Mode to loop and slow down a section."
                        )
                        .padding(.top, 60)
                    }
                }
                .padding()
            }
            .background(GalleryBackgroundView().ignoresSafeArea())
            .navigationTitle("Practice Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadBPM() }
        }
    }

    private func header(_ song: Song) -> some View {
        VStack(spacing: 4) {
            Text(song.title)
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            Text(song.artist)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
    }

    // MARK: - Metronome

    @ViewBuilder
    private var metronome: some View {
        if let effectiveBPM, effectiveBPM > 0 {
            VStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: LumiMotion.frame)) { timeline in
                    let phase = beatPhase(at: timeline.date, bpm: effectiveBPM)
                    Circle()
                        .fill(AppTheme.dynamicAccent)
                        .frame(width: 28, height: 28)
                        .scaleEffect(1.0 + 0.4 * pulseCurve(phase))
                        .opacity(0.5 + 0.5 * pulseCurve(phase))
                }
                .frame(height: 40)

                Text(metronomeCaption)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        } else if isLoadingBPM {
            ProgressView("Analyzing tempo…")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var metronomeCaption: String {
        guard let bpm else { return "" }
        let bpmText = "\(Int(bpm.rounded())) BPM"
        guard player.audioSettings.speed != 1.0, let effectiveBPM else { return bpmText }
        return "\(bpmText) · \(Int(effectiveBPM.rounded())) heard at \(Int(player.audioSettings.speed * 100))%"
    }

    /// 0...1 position within the current beat, from the wall clock — no
    /// dependency on the player's own position/seek state, so the pulse
    /// stays a steady visual metronome even while scrubbing.
    private func beatPhase(at date: Date, bpm: Double) -> Double {
        let secondsPerBeat = 60.0 / bpm
        let elapsed = date.timeIntervalSinceReferenceDate
        return (elapsed / secondsPerBeat).truncatingRemainder(dividingBy: 1.0)
    }

    /// Sharp attack, gentle decay — reads as a beat, not a smooth wobble.
    private func pulseCurve(_ phase: Double) -> Double {
        max(0, 1 - phase * 4)
    }

    // MARK: - Speed

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Playback Speed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(String(format: "%.0f%%", player.audioSettings.speed * 100))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Slider(value: $player.audioSettings.speed, in: 0.5...1.0, step: 0.05)
                .tint(AppTheme.dynamicAccent)
            HStack(spacing: 8) {
                ForEach([0.5, 0.75, 0.9, 1.0], id: \.self) { preset in
                    let isSelected = abs(Double(player.audioSettings.speed) - preset) < 0.001
                    Button {
                        player.audioSettings.speed = Float(preset)
                    } label: {
                        Text("\(Int(preset * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.white : AppTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? AppTheme.dynamicAccent : AppTheme.elevatedSurface,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Loop region

    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loop Region")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            HStack(spacing: 12) {
                loopBoundLabel(title: "Start", value: player.abRepeatStart)
                loopBoundLabel(title: "End", value: player.abRepeatEnd)
            }

            HStack(spacing: 10) {
                Button {
                    player.setABStart()
                } label: {
                    Label("Set Start", systemImage: "a.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    player.setABEnd()
                } label: {
                    Label("Set End", systemImage: "b.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(player.abRepeatStart == nil)
            }
            .tint(AppTheme.dynamicAccent)

            if player.abRepeatEnabled {
                Button(role: .destructive) {
                    player.clearABRepeat()
                } label: {
                    Label("Clear Loop", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if song?.url?.isFileURL == true {
                    Button {
                        exportClip()
                    } label: {
                        if isExportingClip {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Export Clip", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.dynamicAccent)
                    .disabled(isExportingClip)

                    if let exportError {
                        Text(exportError)
                            .font(.caption)
                            .foregroundStyle(AppTheme.error)
                    }
                }
            }
        }
        .padding()
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showExportShareSheet) {
            if let exportedClipURL {
                RewindShareSheet(items: [exportedClipURL])
            }
        }
    }

    private func exportClip() {
        guard let song, let url = song.url,
              let start = player.abRepeatStart, let end = player.abRepeatEnd else { return }
        isExportingClip = true
        exportError = nil
        Task {
            defer { isExportingClip = false }
            do {
                exportedClipURL = try await ClipExportService.exportClip(
                    from: url, start: start, end: end, title: song.title
                )
                showExportShareSheet = true
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func loopBoundLabel(title: String, value: TimeInterval?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
            Text(value.map(formatTime) ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - BPM

    private func loadBPM() async {
        guard let song else { return }
        if let known = song.bpm {
            bpm = known
            return
        }
        isLoadingBPM = true
        bpm = await library.bpm(for: song)
        isLoadingBPM = false
    }
}
