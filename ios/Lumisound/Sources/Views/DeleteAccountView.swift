import SwiftUI

// MARK: - DeleteAccountView
//
// Permanently deletes the user's account (POST /auth/delete-account),
// including their server-side library data, backups, and any uploaded
// music/gallery files. Requires password confirmation.

struct DeleteAccountView: View {
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var isSubmitting = false
    @State private var localError: String?
    @State private var showConfirm = false

    var body: some View {
        LKPage(title: "Delete Account", subtitle: "This can't be undone.", icon: "trash.fill", tint: AppTheme.error) {
            LKCard(title: "What gets erased") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach([("heart.fill", "Favorites and playlists"), ("clock.fill", "Listening history and stats"),
                             ("externaldrive.fill", "Sync backups"), ("icloud.fill", "Music and images you uploaded"),
                             ("person.crop.circle.fill", "Your profile, friends and guestbook")], id: \.1) { item in
                        Label(item.1, systemImage: item.0)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                }
                .padding(.vertical, 4)
            }
            LKBanner(icon: "iphone", text: "Songs downloaded to this phone stay on this phone.", tint: .gray)
            LKCard(title: "Confirm with your password") {
                LKField(placeholder: "Password", text: $password, secure: true)
                    .textContentType(.password)
            }
            if let localError {
                LKBanner(icon: "exclamationmark.triangle.fill", text: localError, tint: AppTheme.error)
            }
            LKPrimaryButton(title: "Delete My Account", icon: "trash", tint: AppTheme.error, busy: isSubmitting) { showConfirm = true }
                .disabled(password.isEmpty || isSubmitting)
                .opacity(password.isEmpty ? 0.5 : 1)
        }
        .confirmationDialog(
            "Delete your account permanently?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                submit()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All of your data on the server will be erased. This cannot be undone.")
        }
    }

    private func submit() {
        localError = nil
        isSubmitting = true
        Task {
            let success = await account.deleteAccount(password: password)
            isSubmitting = false
            if success {
                dismiss()
            } else {
                localError = account.errorMessage ?? "Could not delete account. Please try again."
            }
        }
    }
}
