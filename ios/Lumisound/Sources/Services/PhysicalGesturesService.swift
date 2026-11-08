import CoreMotion
import UIKit

/// Shake the phone to skip; cover the proximity sensor (top of the phone,
/// same sensor a phone call uses to blank the screen against your cheek)
/// to pause. Both opt-in, OFF by default — accelerometer polling has a
/// real (if small) battery cost, and an unwanted skip/pause from an
/// accidental bump or pocket-cover would be an actively bad default, not
/// just an unused feature.
///
/// Shake detection uses `CMMotionManager` accelerometer polling (reuses the
/// existing `NSMotionUsageDescription` already granted for Spatial Audio's
/// head tracking — no new permission string needed) rather than the
/// system `UIResponder.motionEnded(_:with:)` shake event, which needs a
/// window/responder-chain override this SwiftUI-lifecycle app doesn't
/// otherwise have a clean place to add.
@MainActor
final class PhysicalGesturesService: ObservableObject {
    static weak var shared: PhysicalGesturesService?

    /// Pre-split toggle, kept only as a one-time migration source for users
    /// who already had it on — never read after `init()`.
    private static let legacyEnabledKey = "physicalGestures.enabled"
    private static let shakeEnabledKey = "physicalGestures.shakeToSkip.enabled"
    private static let coverEnabledKey = "physicalGestures.coverToPause.enabled"

    @Published var shakeToSkipEnabled: Bool = PhysicalGesturesService.migratedValue(for: PhysicalGesturesService.shakeEnabledKey) {
        didSet {
            UserDefaults.standard.set(shakeToSkipEnabled, forKey: Self.shakeEnabledKey)
            shakeToSkipEnabled ? startShake() : stopShake()
        }
    }

    @Published var coverToPauseEnabled: Bool = PhysicalGesturesService.migratedValue(for: PhysicalGesturesService.coverEnabledKey) {
        didSet {
            UserDefaults.standard.set(coverToPauseEnabled, forKey: Self.coverEnabledKey)
            coverToPauseEnabled ? startCover() : stopCover()
        }
    }

    weak var player: AudioPlayerManager?

    private let motionManager = CMMotionManager()
    private var lastAcceleration: CMAcceleration?
    private var lastShakeAt: Date = .distantPast
    private var isShakeRunning = false
    private var isCoverRunning = false
    private var pendingCoverPause: DispatchWorkItem?

    /// Sum-of-axis-deltas magnitude past this, between consecutive ~0.1s
    /// samples, reads as a real shake rather than normal handling/walking
    /// — picked generously above ordinary pocket/hand jostle on purpose:
    /// false positives (skipping a track because the phone got bumped)
    /// are worse than occasionally missing a deliberate shake.
    private static let shakeThreshold = 2.2
    private static let shakeCooldown: TimeInterval = 1.5

    /// Proximity state has to hold steady this long before we actually
    /// pause — raised from an instant trigger (0s) after reports that a
    /// casual grip or brushing a hand near the top of the phone (sensor
    /// sits right next to the earpiece/camera, so this happens a lot more
    /// often than for a phone call, where the phone is already against
    /// your face) was pausing playback unintentionally. A deliberate
    /// cover-to-pause is normally held well past this.
    private static let coverDebounce: TimeInterval = 0.45

    private static func migratedValue(for key: String) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        if defaults.object(forKey: legacyEnabledKey) != nil {
            let legacy = defaults.bool(forKey: legacyEnabledKey)
            defaults.set(legacy, forKey: key)
            return legacy
        }
        return false
    }

    init() {
        Self.shared = self
    }

    func start() {
        if shakeToSkipEnabled { startShake() }
        if coverToPauseEnabled { startCover() }
    }

    func stop() {
        stopShake()
        stopCover()
    }

    private func startShake() {
        guard shakeToSkipEnabled, !isShakeRunning else { return }
        isShakeRunning = true

        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 0.1
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.handleAccelerometer(data.acceleration)
            }
        }
    }

    private func stopShake() {
        guard isShakeRunning else { return }
        isShakeRunning = false
        motionManager.stopAccelerometerUpdates()
        lastAcceleration = nil
    }

    private func startCover() {
        guard coverToPauseEnabled, !isCoverRunning else { return }
        isCoverRunning = true
        UIDevice.current.isProximityMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(proximityChanged),
            name: UIDevice.proximityStateDidChangeNotification, object: nil
        )
    }

    private func stopCover() {
        guard isCoverRunning else { return }
        isCoverRunning = false
        pendingCoverPause?.cancel()
        pendingCoverPause = nil
        UIDevice.current.isProximityMonitoringEnabled = false
        NotificationCenter.default.removeObserver(self, name: UIDevice.proximityStateDidChangeNotification, object: nil)
    }

    private func handleAccelerometer(_ acceleration: CMAcceleration) {
        defer { lastAcceleration = acceleration }
        guard let last = lastAcceleration else { return }
        let delta = abs(acceleration.x - last.x) + abs(acceleration.y - last.y) + abs(acceleration.z - last.z)
        guard delta > Self.shakeThreshold else { return }
        guard Date().timeIntervalSince(lastShakeAt) > Self.shakeCooldown else { return }
        lastShakeAt = Date()
        player?.userSkipToNext()
    }

    @objc private func proximityChanged() {
        pendingCoverPause?.cancel()
        pendingCoverPause = nil

        guard UIDevice.current.proximityState else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, UIDevice.current.proximityState, self.player?.isPlaying == true else { return }
            self.player?.pause()
        }
        pendingCoverPause = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coverDebounce, execute: work)
    }
}
