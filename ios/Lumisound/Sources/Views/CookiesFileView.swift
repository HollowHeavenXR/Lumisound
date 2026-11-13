import SwiftUI

// MARK: - CookiesFileView
//
// Uploads this account's yt-dlp cookies.txt (Netscape format) so the bridge
// can authenticate yt-dlp extraction (search/stream/resolve/download) as the
// user's own YouTube session — required for age-restricted videos and to
// avoid YouTube's anonymous-request bot-detection blocks. Mirrors
// YoutubeApiKeyView's upload/validate/remove pattern.

struct CookiesFileView: View {
    @EnvironmentObject private var account: AccountService

    @State private var status: YtdlpCookiesStatus?
    @State private var isUploading = false
    @State private var isValidating = false
    @State private var isShowingPicker = false
    @State private var errorText: String?
    @State private var validation: YtdlpCookiesValidation?

    var body: some View {
        LKPage(title: "YouTube Cookies", subtitle: "Download as your own YouTube session.", icon: "doc.text.fill", tint: .orange) {
            // Health checklist.
            VStack(alignment: .leading, spacing: 12) {
                checkRow("Cookies uploaded", ok: status?.configured == true,
                         detail: status?.updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) }.map { "Updated \($0.formatted(date: .abbreviated, time: .shortened))" })
                checkRow("Signed-in session works", ok: validation.map { $0.status == "valid" || $0.status == "valid_no_age_restriction" },
                         detail: validation.map { validationStatusLabel($0.status) })
                checkRow("Age-restricted videos", ok: validation?.ageRestrictionReady, detail: nil)
            }
            .padding(16)
            .background(LKCardBackground(tint: .orange))

            if let validation {
                if !validation.detail.isEmpty {
                    LKBanner(icon: "info.circle", text: validation.detail, tint: validationStatusColor(validation.status))
                }
                ForEach(validation.missing, id: \.self) { item in
                    LKBanner(icon: "exclamationmark.triangle.fill", text: item, tint: AppTheme.warning)
                }
            }

            HStack(spacing: 10) {
                LKPrimaryButton(title: status?.configured == true ? "Replace File" : "Upload cookies.txt", icon: "doc.badge.plus", tint: .orange, busy: isUploading) {
                    isShowingPicker = true
                }
                if status?.configured == true {
                    LKPrimaryButton(title: "Validate", icon: "checkmark.shield", tint: .green, prominent: false, busy: isValidating) { validate() }
                }
            }
            if let errorText {
                LKBanner(icon: "exclamationmark.triangle.fill", text: errorText, tint: AppTheme.error)
            }
            LKCard(title: "How to export") {
                steps(["On a computer, sign in to YouTube normally (not a guest or private window).",
                       "Use a cookies.txt exporter such as \"Get cookies.txt LOCALLY\".",
                       "Save the file to Files or iCloud Drive and upload it here."], tint: .orange)
            }
            Text("Stored on the server for your account only, and never shown back to anyone.")
                .font(.caption2).foregroundStyle(AppTheme.textSecondary).padding(.horizontal, 6)
            if status?.configured == true {
                LKCard {
                    LKButtonRow(icon: "trash", title: "Remove Cookies", destructive: true) { removeCookies() }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $isShowingPicker) {
            DocumentPicker(mode: .textFile) { urls in
                guard let url = urls.first else { return }
                upload(from: url)
            }
        }
    }

    /// ok: true = done, false = failed, nil = not checked yet.
    private func checkRow(_ title: String, ok: Bool?, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "xmark.circle.fill" : "circle.dashed")
                .font(.system(size: 22))
                .foregroundStyle(ok == true ? AppTheme.success : ok == false ? AppTheme.error : AppTheme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(detail ?? (ok == nil ? "Not checked yet" : ok == true ? "Ready" : "Needs attention"))
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private func steps(_ items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, text in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(tint.gradient, in: Circle())
                    Text(text).font(.caption).foregroundStyle(AppTheme.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        status = await account.fetchYtdlpCookiesStatus()
    }

    private func upload(from url: URL) {
        isUploading = true
        errorText = nil
        validation = nil
        Task {
            defer { isUploading = false }
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorText = "Couldn't read that file as text."
                return
            }
            if await account.setYtdlpCookies(text) {
                ToastCenter.shared.show("Cookies uploaded", category: .success, icon: "checkmark.seal")
                status = await account.fetchYtdlpCookiesStatus()
            } else {
                errorText = account.errorMessage ?? "Failed to upload cookies."
            }
        }
    }

    private func validate() {
        isValidating = true
        errorText = nil
        Task {
            defer { isValidating = false }
            validation = await account.validateYtdlpCookies()
            if validation == nil {
                errorText = account.errorMessage ?? "Couldn't validate cookies — check connection."
            }
        }
    }

    private func removeCookies() {
        Task {
            if await account.deleteYtdlpCookies() {
                status = await account.fetchYtdlpCookiesStatus()
                validation = nil
            }
        }
    }

    private func validationStatusLabel(_ status: String) -> String {
        switch status {
        case "valid":                    return "Valid"
        case "valid_no_age_restriction": return "Valid (no age-restriction support)"
        case "expired":                  return "Expired"
        case "incomplete":               return "Incomplete"
        case "missing":                  return "Missing"
        case "invalid":                  return "Invalid"
        default:                         return status.capitalized
        }
    }

    private func validationStatusColor(_ status: String) -> Color {
        switch status {
        case "valid":                    return AppTheme.success
        case "valid_no_age_restriction": return AppTheme.warning
        default:                         return AppTheme.error
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
