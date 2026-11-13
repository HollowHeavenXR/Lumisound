import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - TwoFactorAuthView
//
// Enable/disable UI for the bridge's TOTP two-factor auth (auth.py's
// /auth/2fa/* endpoints — see AccountService+TwoFactorAuth.swift for the
// client wiring). This is the first app UI for a backend feature that
// otherwise has no way to be turned on at all.
struct TwoFactorAuthView: View {
    @EnvironmentObject var account: AccountService

    // Setup flow (not yet enabled)
    @State private var setupResponse: AccountService.TOTPSetupResponse?
    @State private var isStartingSetup = false
    @State private var setupCode = ""
    @State private var isVerifying = false

    // Disable flow (already enabled)
    @State private var disablePassword = ""
    @State private var isDisabling = false
    @State private var showDisableConfirm = false

    var body: some View {
        LKPage(title: "Two-Factor", subtitle: "A code from your authenticator app, on top of your password.",
               icon: "lock.shield.fill", tint: account.isTOTPEnabled ? .green : .red) {
            // Shield status.
            HStack(spacing: 14) {
                Image(systemName: account.isTOTPEnabled ? "checkmark.shield.fill" : "shield.slash")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(account.isTOTPEnabled ? AppTheme.success : AppTheme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.isTOTPEnabled ? "Protected" : "Password only").font(.title3.bold()).foregroundStyle(AppTheme.textPrimary)
                    Text(account.isTOTPEnabled
                         ? "Signing in needs your password and a 6-digit code."
                         : "Anyone with your password can sign in. Add a second step.")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LKCardBackground(tint: account.isTOTPEnabled ? .green : .orange))

            Group {
                if account.isTOTPEnabled {
                    enabledContent
                } else if let setupResponse {
                    setupContent(setupResponse)
                } else {
                    startContent
                }
            }
            .padding(16)
            .background(LKCardBackground())

            if let error = account.errorMessage {
                LKBanner(icon: "exclamationmark.triangle.fill", text: error, tint: AppTheme.error)
            }
            Text("Works with Apple Passwords, Google Authenticator, Authy and other TOTP apps.")
                .font(.caption2).foregroundStyle(AppTheme.textSecondary).padding(.horizontal, 6)
        }
        .task { await account.refreshTOTPStatus() }
        .confirmationDialog(
            "Turn off two-factor authentication?",
            isPresented: $showDisableConfirm, titleVisibility: .visible
        ) {
            Button("Disable 2FA", role: .destructive) {
                Task {
                    isDisabling = true
                    defer { isDisabling = false }
                    if await account.disableTOTP(password: disablePassword) {
                        disablePassword = ""
                    }
                }
            }
        }
    }

    // MARK: - Not yet enabled

    private var startContent: some View {
        Button {
            Task {
                isStartingSetup = true
                defer { isStartingSetup = false }
                setupResponse = await account.startTOTPSetup()
            }
        } label: {
            HStack {
                Label("Enable Two-Factor Authentication", systemImage: "lock.shield")
                    .foregroundStyle(AppTheme.dynamicAccent)
                Spacer()
                if isStartingSetup {
                    ProgressView().tint(AppTheme.dynamicAccent)
                }
            }
        }
        .disabled(isStartingSetup)
    }

    // MARK: - Setup in progress (secret generated, not yet verified)

    @ViewBuilder
    private func setupContent(_ setup: AccountService.TOTPSetupResponse) -> some View {
        VStack(alignment: .center, spacing: 14) {
            Text("Scan this code with your authenticator app, then enter the 6-digit code it shows.")
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let qrImage = Self.qrCodeImage(for: setup.otpauth_url) {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Can't scan? Enter this key manually:")
                    .font(AppTheme.bodyFont(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(setup.secret)
                    .font(AppTheme.monoFont(size: 13))
                    .foregroundStyle(AppTheme.textPrimary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField("6-digit code", text: $setupCode)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
                .padding(10)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: setupCode) { newValue in
                    setupCode = String(newValue.filter(\.isNumber).prefix(6))
                }

            Button {
                Task {
                    isVerifying = true
                    defer { isVerifying = false }
                    if await account.verifyTOTPSetup(code: setupCode) {
                        setupResponse = nil
                        setupCode = ""
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    if isVerifying {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify & Enable").font(.headline).foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(AppTheme.dynamicAccent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isVerifying || setupCode.count != 6)
            .opacity((isVerifying || setupCode.count != 6) ? 0.6 : 1.0)

            Button("Cancel") {
                setupResponse = nil
                setupCode = ""
                account.errorMessage = nil
            }
            .font(AppTheme.bodyFont(size: 13))
            .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Already enabled

    private var enabledContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(AppTheme.success)
                Text("Two-factor authentication is enabled")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            SecureField("Confirm your password to disable", text: $disablePassword)
                .textContentType(.password)
                .foregroundStyle(AppTheme.textPrimary)
                .padding(10)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))

            Button(role: .destructive) {
                showDisableConfirm = true
            } label: {
                HStack {
                    if isDisabling {
                        ProgressView()
                    } else {
                        Text("Disable Two-Factor Authentication")
                    }
                }
            }
            .disabled(isDisabling || disablePassword.isEmpty)
        }
        .padding(.vertical, 4)
    }

    // MARK: - QR generation

    private static func qrCodeImage(for string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        // The raw filter output is tiny (one pixel per module) — scale up so
        // it renders crisp rather than blurry when displayed at 180x180.
        let scale = 8.0
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
