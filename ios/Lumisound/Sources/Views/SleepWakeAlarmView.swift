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
        LKPage(title: "Wake-Up Alarm", subtitle: "Wake up to music that fades in.", icon: "alarm.fill", tint: .orange, showsHero: false) {
            clockFace
            if alarm.isScheduled {
                LKPrimaryButton(title: "Cancel Alarm", icon: "alarm.waves.left.and.right", tint: AppTheme.error, prominent: false) {
                    alarm.cancelAlarm()
                }
            } else {
                LKCard(title: "Wake me") {
                    DatePicker("Wake time", selection: $pickerTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .frame(height: 140)
                        .clipped()
                    LKDivider(inset: 0)
                    HStack(spacing: 12) {
                        LKIcon(symbol: "music.note.list", tint: .orange)
                        Text("Play").font(AppTheme.bodyFont(size: 15)).foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        LumiPicker("Play", selection: $selectedPlaylistID) {
                            Text("Favorites").lumiOptionLabel("Favorites").tag(UUID?.none)
                            ForEach(library.playlists) { playlist in
                                Text(playlist.name).lumiOptionLabel(String(describing: playlist.name)).tag(UUID?.some(playlist.id))
                            }
                        }
                        .tint(.orange)
                    }
                    .padding(.vertical, 8)
                }
                if !notifications.isAuthorized {
                    LKBanner(icon: "bell.slash.fill", text: "Notifications are off, so the alarm can't ring. Turn them on in Settings → Notifications.", tint: AppTheme.error)
                }
                LKPrimaryButton(title: "Set Alarm for \(nextRing.formatted(date: .omitted, time: .shortened))", icon: "alarm", tint: .orange) {
                    scheduleAlarm()
                }
                .disabled(!notifications.isAuthorized)
                .opacity(notifications.isAuthorized ? 1 : 0.5)
            }
            LKBanner(icon: "info.circle", text: "The alarm notification rings even if Lumisound is closed. Music starts by itself only if the app is still open or in the background; after a force-quit, tap the notification to start it.", tint: .gray)
        }
        .animation(.easeInOut(duration: 0.25), value: alarm.isScheduled)
        .task { await notifications.requestAuthorization() }
    }

    /// When the alarm would ring if set now.
    private var nextRing: Date {
        pickerTime <= Date() ? (Calendar.current.date(byAdding: .day, value: 1, to: pickerTime) ?? pickerTime) : pickerTime
    }

    private var clockFace: some View {
        let date = alarm.alarmDate
        return VStack(spacing: 6) {
            Image(systemName: date == nil ? "alarm" : "alarm.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(date == nil ? AppTheme.textSecondary : .orange)
                .symbolEffect(.bounce, value: date)
            Text(date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "--:--")
                .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
                .contentTransition(.numericText())
            if let date {
                Text("Rings \(date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(AppTheme.textSecondary)
            } else {
                Text("No alarm set").font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(LKCardBackground(tint: date == nil ? nil : .orange))
    }

    private func scheduleAlarm() {
        var target = pickerTime
        if target <= Date() {
            target = Calendar.current.date(byAdding: .day, value: 1, to: target) ?? target
        }
        alarm.scheduleAlarm(at: target, playlistID: selectedPlaylistID)
    }
}
