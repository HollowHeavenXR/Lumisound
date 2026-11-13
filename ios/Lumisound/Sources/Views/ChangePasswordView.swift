import SwiftUI

// MARK: - ChangePasswordView
//
// Lets the user change their account password (POST /auth/change-password).
// On success, the server signs out every other device's session.

struct ChangePasswordView: View {
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSubmitting = false
    @State private var localError: String?
    @State private var didSucceed = false

    private var canSubmit: Bool {
        !currentPassword.isEmpty
            && newPassword.count >= 8
            && newPassword == confirmPassword
            && !isSubmitting
    }

    /// Simple strength estimate for the meter (length + character variety).
    private var strength: Int {
        var score = 0
        if newPassword.count >= 8 { score += 1 }
        if newPassword.count >= 12 { score += 1 }
        if newPassword.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
        if newPassword.rangeOfCharacter(from: .punctuationCharacters.union(.symbols)) != nil { score += 1 }
        if newPassword.rangeOfCharacter(from: .uppercaseLetters) != nil && newPassword.rangeOfCharacter(from: .lowercaseLetters) != nil { score += 1 }
        return min(score, 4)
    }

    private func check(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundStyle(ok ? AppTheme.success : AppTheme.textSecondary)
    }

    var body: some View {
        LKPage(title: "Change Password", subtitle: "Other devices are signed out when you change it.", icon: "key.fill", tint: .orange) {
            LKCard(title: "Current") {
                LKField(placeholder: "Current password", text: $currentPassword, secure: true)
                    .textContentType(.password)
            }
            LKCard(title: "New") {
                VStack(alignment: .leading, spacing: 10) {
                    LKField(placeholder: "New password", text: $newPassword, secure: true)
                        .textContentType(.newPassword)
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { i in
                            Capsule()
                                .fill(i < strength ? [AppTheme.error, Color.orange, Color.yellow, AppTheme.success][max(strength - 1, 0)] : AppTheme.textSecondary.opacity(0.15))
                                .frame(height: 5)
                        }
                    }
                    .animation(LumiMotion.fade(0.2), value: strength)
                    LKField(placeholder: "Confirm new password", text: $confirmPassword, secure: true)
                        .textContentType(.newPassword)
                    VStack(alignment: .leading, spacing: 4) {
                        check(newPassword.count >= 8, "At least 8 characters")
                        check(!confirmPassword.isEmpty && newPassword == confirmPassword, "Both new passwords match")
                    }
                }
            }
            if let localError {
                LKBanner(icon: "exclamationmark.triangle.fill", text: localError, tint: AppTheme.error)
            }
            LKPrimaryButton(title: "Change Password", icon: "lock.rotation", tint: .orange, busy: isSubmitting) { submit() }
                .disabled(!canSubmit)
                .opacity(canSubmit || isSubmitting ? 1 : 0.5)
        }
        .alert("Password Updated", isPresented: $didSucceed) {
            Button("OK") { dismiss() }
        } message: {
            Text("Your password has been changed. Other signed-in devices have been signed out.")
        }
    }

    private func submit() {
        guard canSubmit else { return }
        localError = nil
        isSubmitting = true
        Task {
            let success = await account.changePassword(currentPassword: currentPassword, newPassword: newPassword)
            isSubmitting = false
            if success {
                currentPassword = ""
                newPassword = ""
                confirmPassword = ""
                didSucceed = true
            } else {
                localError = account.errorMessage ?? "Could not change password. Please try again."
            }
        }
    }
}
