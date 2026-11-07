import SwiftUI

/// Settings screen for the Sleep-to-Wake alarm — schedules a wake-up time
/// that fades in a chosen playlist (or Favorites), entirely on-device.
struct SleepWakeAlarmView: View {
    @EnvironmentObject private var library: LibraryManager
    @ObservedObject private var alarm = SleepWakeAlarmService.shared
    @ObservedObject private var notifications = NotificationService.shared

    @State private var pickerTime = Date().addingTimeInterval(8 * 3600)
    @State private var selectedPlaylistID: UUID?

    var body: some View {
        List {
            statusSection
            if alarm.isScheduled {
                cancelSection
            } else {
                setupSection
            }
            limitationSection
        }
        .scrollContentBackground(.hidden)
        .background(EditionScreenBackground())
        .navigationTitle("Wake-Up Alarm")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await notifications.requestAuthorization()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let date = alarm.alarmDate {
            Section {
                Label("Set for \(date.formatted(date: .omitted, time: .shortened))", systemImage: "alarm.fill")
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .font(.headline)
            }
            .listRowBackground(tintedRowBackground(.pink))
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        Section {
            DatePicker("Wake Time", selection: $pickerTime, displayedComponents: .hourAndMinute)

            LumiPicker("Play", selection: $selectedPlaylistID) {
                Text("Favorites").lumiOptionLabel("Favorites").tag(UUID?.none)
                ForEach(library.playlists) { playlist in
                    Text(playlist.name).lumiOptionLabel(String(describing: playlist.name)).tag(UUID?.some(playlist.id))
                }
            }

            Button {
                scheduleAlarm()
            } label: {
                Label("Set Alarm", systemImage: "alarm")
            }
            .disabled(!notifications.isAuthorized)
        } footer: {
            if !notifications.isAuthorized {
                Text("Notifications are off, so the alarm can't be set — enable them in Settings → Notifications.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.error)
            }
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    @ViewBuilder
    private var cancelSection: some View {
        Section {
            Button(role: .destructive) {
                alarm.cancelAlarm()
            } label: {
                Label("Cancel Alarm", systemImage: "alarm.slash")
            }
        }
        .listRowBackground(tintedRowBackground(.pink))
    }

    @ViewBuilder
    private var limitationSection: some View {
        Section {
            Text("A notification will sound at the set time even if Lumisound is fully closed. Music will only start playing automatically if the app is still open or backgrounded — if it was force-quit, tap the notification to open the app and start playback yourself.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .listRowBackground(Color.clear)
    }

    private func scheduleAlarm() {
        var target = pickerTime
        if target <= Date() {
            target = Calendar.current.date(byAdding: .day, value: 1, to: target) ?? target
        }
        alarm.scheduleAlarm(at: target, playlistID: selectedPlaylistID)
    }
}
