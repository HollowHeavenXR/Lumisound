import MediaPlayer
import SwiftUI

extension SettingsView {

    // MARK: — Sleep Timer Section

    var sleepTimerSection: some View {
        Section {
            if sleepTimer.isActive {
                SleepTimerActiveRow {
                    sleepTimer.cancel()
                    ToastCenter.shared.show("Sleep timer cancelled", category: .info, icon: "moon.zzz")
                }
            } else {
                LumiPicker("Duration", selection: $sleepTimer.selectedDuration) {
                    ForEach(SleepTimerService.presets, id: \.seconds) { preset in
                        Text(preset.label).lumiOptionLabel(String(describing: preset.label)).tag(preset.seconds)
                    }
                }
                .tint(.indigo)
                .foregroundStyle(AppTheme.textPrimary)

                Button {
                    sleepTimer.start()
                    ToastCenter.shared.show("Sleep timer started", category: .success, icon: "moon.zzz.fill")
                } label: {
                    Label("Start Sleep Timer", systemImage: "moon.zzz")
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
        } header: {
            sectionHeader("Sleep Timer", icon: "moon.stars.fill", tint: .indigo)
        }
        .listRowBackground(tintedRowBackground(.indigo))
    }
}

/// Isolates the once-a-second countdown from the rest of `SettingsView` —
/// observing `SleepTimerProgress` here (instead of reading `sleepTimer.
/// formattedRemaining` directly from `SettingsView`'s own body) means only
/// THIS row re-renders every second a sleep timer is active, not the whole
/// Settings screen. See `SleepTimerProgress`'s doc comment: without this,
/// every `Picker(.menu)` dropdown elsewhere in Settings (EQ preset, reverb
/// preset, etc.) rebuilt right along with it, every second.
struct SleepTimerActiveRow: View {
    @EnvironmentObject private var sleepProgress: SleepTimerProgress
    let onCancel: () -> Void

    var body: some View {
        HStack {
            Label("Active — \(SleepTimerService.formatRemaining(sleepProgress.remainingSeconds))", systemImage: "moon.zzz")
                .foregroundStyle(AppTheme.textPrimary)
                .font(.system(.subheadline).monospacedDigit())
            Spacer()
            Button("Cancel", action: onCancel)
                .foregroundStyle(AppTheme.warning)
        }
    }
}
