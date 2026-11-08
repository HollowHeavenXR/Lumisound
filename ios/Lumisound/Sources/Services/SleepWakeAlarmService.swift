import Foundation
import UserNotifications

/// A wake-up alarm that fades in music, complementing `SleepTimerService`'s
/// fade-out. Entirely on-device: no server involved.
///
/// **Real iOS limitation, stated plainly rather than glossed over:** a
/// third-party app cannot guarantee actual audio playback starts if it has
/// been fully force-quit — there is no API for that. What this reliably
/// does in every case is schedule a local notification (`UNCalendarNotificationTrigger`)
/// that fires at the target time with a sound, even from fully killed.
/// Tapping it opens the app. What it does *additionally*, only if the app
/// process is still alive at that moment (foregrounded, or backgrounded —
/// the app already declares the `audio` background mode, so backgrounded
/// counts) is actually start the chosen playlist and fade the volume in
/// over 60 seconds via an in-process `Timer`, mirroring `SleepTimerService`'s
/// fade-out in reverse. If the app was force-quit, only the notification
/// fires — the user has to tap it and start playback themselves. This is
/// the same constraint every third-party "alarm" feature on iOS lives with.
@MainActor
final class SleepWakeAlarmService: ObservableObject {
    static let shared = SleepWakeAlarmService()

    private enum Keys {
        static let alarmDate = "sleepWakeAlarm.date.v1"
        static let playlistID = "sleepWakeAlarm.playlistID.v1"
    }

    private static let notificationID = "sleepWakeAlarm"
    private static let fadeDurationSeconds: Double = 60
    private static let fadeStepInterval: Double = 0.5

    @Published private(set) var alarmDate: Date?
    @Published var selectedPlaylistID: UUID?

    private var wakeTimer: Timer?
    private var fadeTimer: Timer?

    private init() {
        if let stored = UserDefaults.standard.object(forKey: Keys.alarmDate) as? Date, stored > Date() {
            alarmDate = stored
            selectedPlaylistID = UserDefaults.standard.string(forKey: Keys.playlistID).flatMap(UUID.init)
            scheduleInProcessTimer(for: stored)
        }
    }

    var isScheduled: Bool { alarmDate != nil }

    func scheduleAlarm(at date: Date, playlistID: UUID?) {
        cancelAlarm()
        alarmDate = date
        selectedPlaylistID = playlistID
        UserDefaults.standard.set(date, forKey: Keys.alarmDate)
        if let playlistID {
            UserDefaults.standard.set(playlistID.uuidString, forKey: Keys.playlistID)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.playlistID)
        }

        scheduleNotification(at: date)
        scheduleInProcessTimer(for: date)
    }

    func cancelAlarm() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        alarmDate = nil
        UserDefaults.standard.removeObject(forKey: Keys.alarmDate)
        UserDefaults.standard.removeObject(forKey: Keys.playlistID)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    // MARK: - Notification (fires even if the app is fully killed)

    private func scheduleNotification(at date: Date) {
        guard NotificationService.shared.isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Wake Up"
        content.body = "Open Lumisound to keep listening."
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                appWarn("SleepWakeAlarmService: failed to schedule notification: \(error.localizedDescription)", category: "notifications")
            }
        }
    }

    // MARK: - In-process playback (only fires if the app is still alive)

    private func scheduleInProcessTimer(for date: Date) {
        wakeTimer?.invalidate()
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return }
        wakeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.beginWakePlayback() }
        }
    }

    private func beginWakePlayback() {
        guard let player = AudioPlayerManager.shared, let library = LibraryManager.shared else { return }

        let songs: [Song]
        if let playlistID, let playlist = library.playlists.first(where: { $0.id == playlistID }) {
            songs = library.songs(for: playlist)
        } else {
            songs = library.favoriteSongs
        }
        guard !songs.isEmpty else { return }

        var settings = player.audioSettings
        let targetVolume = settings.volume
        settings.volume = 0
        player.audioSettings = settings
        player.setQueue(songs.smartShuffled(), startIndex: 0, autoplay: true)

        fadeTimer?.invalidate()
        var step = 0
        let stepCount = Int(Self.fadeDurationSeconds / Self.fadeStepInterval)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: Self.fadeStepInterval, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self, let player = AudioPlayerManager.shared else { t.invalidate(); return }
                step += 1
                let progress = min(1, Float(step) / Float(stepCount))
                var s = player.audioSettings
                s.volume = targetVolume * progress
                player.audioSettings = s
                if step >= stepCount {
                    t.invalidate()
                    self.fadeTimer = nil
                }
            }
        }

        // One-shot alarm — clear the schedule now that it's fired.
        alarmDate = nil
        UserDefaults.standard.removeObject(forKey: Keys.alarmDate)
    }

    private var playlistID: UUID? { selectedPlaylistID }
}
