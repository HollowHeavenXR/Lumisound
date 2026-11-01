import Foundation
import LocalAuthentication
import SwiftUI

/// App Lock. The state machine (enabled flag, locked/unlocked, one prompt at
/// a time, what a result means) is the Rust core's `AppLock`; this shows the
/// LocalAuthentication prompt and mirrors the state for SwiftUI.
@MainActor
final class AppLockService: ObservableObject {

    static weak var shared: AppLockService?

    private static let legacyEnabledKey = "app_lock_enabled"
    private let core: AppLock

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            apply(core.setEnabled(enabled: isEnabled))
        }
    }

    @Published var isUnlocked: Bool

    @Published private(set) var isAuthenticating = false

    init() {
        let legacy = UserDefaults.standard.object(forKey: Self.legacyEnabledKey) as? Bool
        core = AppLock(legacyEnabled: legacy)
        let s = core.state()
        isEnabled = s.enabled
        isUnlocked = s.unlocked
        Self.shared = self
    }

    private func apply(_ s: AppLockState) {
        if isEnabled != s.enabled { isEnabled = s.enabled }
        isUnlocked = s.unlocked
        isAuthenticating = s.authenticating
    }

    func biometryAvailable() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var biometryTypeName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// Called when the app goes to the background.
    func lock() {
        apply(core.lock())
    }

    func authenticate() async {
        guard core.beginAuthentication() else { return }
        isAuthenticating = true
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        let available = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        var success = false
        if available {
            success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Lumisound") { ok, _ in
                    continuation.resume(returning: ok)
                }
            }
        }
        apply(core.finishAuthentication(success: success, policyAvailable: available))
    }
}
