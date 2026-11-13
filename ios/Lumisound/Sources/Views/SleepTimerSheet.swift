import SwiftUI

// MARK: - SleepTimerSheet

struct SleepTimerSheet: View {
    @EnvironmentObject private var sleepTimer: SleepTimerService
    // See `SleepTimerProgress`'s doc comment — observed separately so the
    // once-a-second countdown tick doesn't force this whole sheet's body
    // (including the duration/fade `Picker`s in `inactiveContent`) to
    // re-evaluate every second.
    @EnvironmentObject private var sleepProgress: SleepTimerProgress
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var adaptiveSleep = AdaptiveSleepTimerService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                EditionScreenBackground()

                ScrollView {
                    VStack(spacing: 28) {
                        if sleepTimer.isActive {
                            activeContent
                        } else {
                            inactiveContent
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
        }
        .task {
            if adaptiveSleep.isAuthorized { await adaptiveSleep.learn() }
        }
    }

    // MARK: - Active State

    private var activeContent: some View {
        VStack(spacing: 28) {
            // Large countdown display
            VStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .padding(.bottom, 4)

                Text(SleepTimerService.formatRemaining(sleepProgress.remainingSeconds))
                    .font(.system(size: 64, weight: .thin, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.5), value: sleepProgress.remainingSeconds)

                Text("Music will pause when the timer ends")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .background(
                AppTheme.dynamicAccent.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )

            // Cancel button
            Button {
                sleepTimer.cancel()
                ToastCenter.shared.show("Sleep timer cancelled", category: .info, icon: "moon.zzz")
                dismiss()
            } label: {
                Label("Cancel Timer", systemImage: "xmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.warning, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Inactive State

    private var inactiveContent: some View {
        VStack(spacing: 24) {
            // Icon header
            VStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppTheme.textSecondary)
                Text("Set a sleep timer to automatically pause music.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 4)

            adaptiveSleepRow

            // Preset grid
            let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(SleepTimerService.presets, id: \.seconds) { preset in
                    presetButton(preset: preset)
                }
            }

            // Custom stepper
            customDurationRow

            // Fade-out duration
            fadeDurationRow

            // Start button
            Button {
                sleepTimer.start()
                ToastCenter.shared.show("Sleep timer started", category: .success, icon: "moon.zzz.fill")
                dismiss()
            } label: {
                Label("Start Timer", systemImage: "moon.zzz.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.dynamicAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: AppTheme.dynamicAccent.opacity(0.35), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(.plain)
        }
    }

    /// Suggests a duration learned from real sleep data (see
    /// AdaptiveSleepTimerService) instead of a fixed preset guess.
    @ViewBuilder
    private var adaptiveSleepRow: some View {
        if !adaptiveSleep.isHealthDataAvailable {
            EmptyView()
        } else if !adaptiveSleep.isAuthorized {
            Button {
                Task { await adaptiveSleep.requestAuthorization() }
            } label: {
                Label("Learn from your sleep data", systemImage: "bed.double")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppTheme.dynamicAccent)
            }
        } else if let minutes = adaptiveSleep.suggestedMinutes {
            Button {
                sleepTimer.selectedDuration = minutes * 60
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bed.double.fill")
                    Text("Use suggested: ~\(Int(minutes.rounded()))m (based on your sleep data)")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppTheme.dynamicAccent)
            }
        }
    }

    private func presetButton(preset: (label: String, seconds: TimeInterval)) -> some View {
        let isSelected = sleepTimer.selectedDuration == preset.seconds
        return Button {
            sleepTimer.selectedDuration = preset.seconds
        } label: {
            Text(preset.label)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : AppTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    isSelected ? AppTheme.dynamicAccent : AppTheme.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .shadow(
                    color: isSelected ? AppTheme.dynamicAccent.opacity(0.3) : .clear,
                    radius: 8, x: 0, y: 4
                )
        }
        .buttonStyle(.plain)
        .animation(LumiMotion.snap, value: isSelected)
    }

    private var customDurationRow: some View {
        HStack {
            Label("Custom", systemImage: "slider.horizontal.3")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Stepper(
                value: $sleepTimer.selectedDuration,
                in: 60...10800,
                step: 60
            ) {
                let minutes = Int(sleepTimer.selectedDuration) / 60
                Text("\(minutes) min")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .monospacedDigit()
            }
            .tint(AppTheme.dynamicAccent)
        }
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var fadeDurationRow: some View {
        HStack {
            Label("Fade Out Over", systemImage: "waveform.path.ecg.rectangle")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            LumiPicker("", selection: $sleepTimer.fadeDurationSeconds) {
                ForEach(SleepTimerService.fadeDurationPresets, id: \.seconds) { preset in
                    Text(preset.label).lumiOptionLabel(String(describing: preset.label)).tag(preset.seconds)
                }
            }
            .tint(AppTheme.dynamicAccent)
        }
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
