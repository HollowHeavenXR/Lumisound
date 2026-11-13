import SwiftUI

// MARK: - DiscordWebhookView
//
// Configures a Discord webhook the server posts "Now Playing" updates to
// (GET/PUT/DELETE /user/discord-webhook). Distinct from the local Discord
// Rich Presence daemon (RPC setup token, in Settings) — this posts messages
// to a Discord channel via an incoming webhook.

struct DiscordWebhookView: View {
    @EnvironmentObject private var account: AccountService

    @State private var status: DiscordWebhookStatus?
    @State private var webhookURL = ""
    @State private var enabled = true
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var didSave = false

    private static let blurple = Color(red: 0.345, green: 0.396, blue: 0.949)

    var body: some View {
        LKPage(title: "Now Playing Webhook", subtitle: "Post what you play to a Discord channel.", icon: "message.fill", tint: Self.blurple) {
            // A mock of the message Discord will show.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(Self.blurple.gradient).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "music.note").font(.caption.weight(.bold)).foregroundStyle(.white))
                    Text("Lumisound").font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
                    Text("BOT").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Self.blurple, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
                }
                HStack(spacing: 0) {
                    Rectangle().fill(Self.blurple).frame(width: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Now Playing").font(.caption2.weight(.bold)).foregroundStyle(AppTheme.textSecondary)
                        Text("Your current song").font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
                        Text("by the artist").font(.caption).foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(10)
                    Spacer()
                }
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(14)
            .background(LKCardBackground(tint: Self.blurple))

            if status?.configured == true {
                LKCard(title: "Connected") {
                    HStack(spacing: 12) {
                        LKIcon(symbol: "link", tint: Self.blurple)
                        Text(status?.webhookUrl ?? "")
                            .font(AppTheme.monoFont(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.vertical, 6)
                    LKDivider()
                    LKToggle(icon: "power", tint: Self.blurple, title: "Posting", subtitle: enabled ? "Every new track is posted" : "Paused", isOn: $enabled)
                        .onChange(of: enabled) { newValue in
                            Task { _ = await account.setDiscordWebhook(url: nil, enabled: newValue) }
                        }
                    LKDivider()
                    LKButtonRow(icon: "trash", title: "Remove Webhook", destructive: true) { removeWebhook() }
                }
            } else {
                LKCard(title: "Paste a webhook URL", footer: "In Discord: Channel Settings → Integrations → Webhooks → New Webhook → Copy URL.") {
                    LKField(placeholder: "https://discord.com/api/webhooks/…", text: $webhookURL, mono: true)
                        .keyboardType(.URL)
                        .padding(.vertical, 4)
                }
                LKPrimaryButton(title: didSave ? "Saved" : "Connect", icon: didSave ? "checkmark" : "link", tint: Self.blurple, busy: isSaving) { save() }
                    .disabled(isSaving || webhookURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let errorText {
                LKBanner(icon: "exclamationmark.triangle.fill", text: errorText, tint: AppTheme.error)
            }
        }
        .task { await load() }
    }

    private func load() async {
        status = await account.fetchDiscordWebhook()
        enabled = status?.enabled ?? true
    }

    private func save() {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        errorText = nil
        Task {
            if await account.setDiscordWebhook(url: trimmed, enabled: enabled) {
                didSave = true
                status = await account.fetchDiscordWebhook()
            } else {
                errorText = account.errorMessage ?? "Failed to save webhook."
            }
            isSaving = false
        }
    }

    private func removeWebhook() {
        Task {
            if await account.deleteDiscordWebhook() {
                status = await account.fetchDiscordWebhook()
                webhookURL = ""
                didSave = false
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
