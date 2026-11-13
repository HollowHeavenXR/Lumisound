import SwiftUI

// MARK: - YoutubeApiKeyView
//
// Configures this account's personal YouTube Data API v3 key
// (GET/PUT/DELETE /user/youtube-api-key). When set, the bridge's
// /api/resolve uses playlistItems.list to enumerate full YouTube playlists
// for this account — bypassing yt-dlp's ~205-entry flat-playlist cap. Falls
// back to the server-wide key (if any) when unset.

struct YoutubeApiKeyView: View {
    @EnvironmentObject private var account: AccountService

    @State private var status: YoutubeApiKeyConfig?
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var isValidating = false
    @State private var errorText: String?
    @State private var didSave = false

    /// Once a configured key is rejected for quota, re-show the entry field
    /// so the user can replace it. Shared with SettingsView's YouTube API
    /// Key section via the same UserDefaults key.
    @AppStorage("youtube_api_key_quota_exceeded") private var quotaExceeded = false

    var body: some View {
        LKPage(title: "YouTube API Key", subtitle: "Resolve whole playlists, not just the first ~205 videos.", icon: "key.fill", tint: .red) {
            // The key as a credential card.
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(.white)
                    Spacer()
                    Text(status?.configured == true ? (quotaExceeded ? "QUOTA USED UP" : "ACTIVE") : "NOT SET")
                        .font(.system(size: 10, weight: .heavy)).kerning(1).foregroundStyle(.white.opacity(0.85))
                }
                Text(status?.configured == true ? (status?.apiKey ?? "•••••") : "AIza••••••••••••••••••")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("YouTube Data API v3").font(.caption2).foregroundStyle(.white.opacity(0.8))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: status?.configured == true ? [.red, .orange] : [.gray, .gray.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .shadow(color: .red.opacity(status?.configured == true ? 0.3 : 0), radius: 14, x: 0, y: 6)

            if status?.configured != true || quotaExceeded {
                LKCard(title: quotaExceeded ? "Replace the key" : "Add your key") {
                    LKField(placeholder: "AIza…", text: $apiKey, mono: true).padding(.vertical, 4)
                }
                LKPrimaryButton(title: didSave ? "Saved" : "Save Key", icon: didSave ? "checkmark" : "square.and.arrow.down", tint: .red, busy: isSaving) { save() }
                    .disabled(isSaving || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                LKCard(title: "Get a free key") {
                    steps(["Open the Google Cloud Console and create a project.",
                           "Enable \"YouTube Data API v3\" for it.",
                           "Credentials → Create credentials → API key.",
                           "Paste it above."], tint: .red)
                }
            }
            if status?.configured == true {
                LKCard {
                    LKButtonRow(icon: "checkmark.shield", tint: .green, title: "Validate Key", subtitle: "Checks the key and today's estimated quota", busy: isValidating) { validate() }
                    LKDivider()
                    LKButtonRow(icon: "trash", title: "Remove Key", subtitle: "Falls back to the shared server key", destructive: true) { removeKey() }
                }
            }
            if let errorText {
                LKBanner(icon: "exclamationmark.triangle.fill", text: errorText, tint: AppTheme.error)
            }
        }
        .task { await load() }
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
        status = await account.fetchYoutubeApiKey()
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        errorText = nil
        Task {
            if await account.setYoutubeApiKey(trimmed) {
                didSave = true
                apiKey = ""
                quotaExceeded = false
                status = await account.fetchYoutubeApiKey()
            } else {
                errorText = account.errorMessage ?? "Failed to save API key."
            }
            isSaving = false
        }
    }

    private func validate() {
        isValidating = true
        errorText = nil
        Task {
            let result = await account.validateYouTubeAPIKey()
            // The Data API has no real "remaining quota" endpoint — this is
            // this server's own running count of what IT has spent with this
            // key today, so it's an estimate, not an exact remaining balance.
            // See `AccountService.YouTubeKeyValidation`'s doc comment.
            let quotaSuffix = result.quotaUnitsUsedToday.map { " — ~\($0) quota units used today (est.)" } ?? ""
            switch result.status {
            case "valid":
                quotaExceeded = false
                ToastCenter.shared.show("YouTube API key is valid\(quotaSuffix)", category: .success, icon: "checkmark.seal")
            case "invalid":
                ToastCenter.shared.show("YouTube API key is invalid", category: .error, icon: "xmark.seal")
            case "quota_exceeded":
                quotaExceeded = true
                ToastCenter.shared.show("YouTube API quota exceeded for today\(quotaSuffix)", category: .warning, icon: "exclamationmark.triangle")
            default:
                ToastCenter.shared.show("Couldn't validate key — check connection", category: .error, icon: "wifi.exclamationmark")
            }
            isValidating = false
        }
    }

    private func removeKey() {
        Task {
            if await account.deleteYoutubeApiKey() {
                status = await account.fetchYoutubeApiKey()
                apiKey = ""
                didSave = false
                quotaExceeded = false
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
