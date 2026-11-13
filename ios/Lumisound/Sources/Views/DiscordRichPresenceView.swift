import AuthenticationServices
import SwiftUI

// MARK: - DiscordRichPresenceView
//
// Sets up the local Discord Rich Presence daemon (discord-rpc/) for this
// account:
//   1. Generate an RPC setup token (POST /user/rpc-token) — the only
//      credential the daemon needs.
//   2. Register that Rich Presence is enabled (PUT /user/discord-rpc-config).
//      By default this uses Lumisound's OWN shared Discord Application
//      (discord_client_id left unset — resolved server-side, see
//      DISCORD_RPC_DEFAULT_CLIENT_ID in main.py), so a verified user needs
//      nothing but this one toggle. Anyone who wants their own branding can
//      still register a personal Discord Developer Application under
//      Advanced below.
//
// Rich Presence itself is still set locally by the daemon over Discord's
// IPC (a Unix socket on Linux/macOS, a named pipe on Windows) — there is no
// server-side API to set it remotely, so the daemon still has to be
// installed once on whichever computer runs Discord (`./install.sh <token>`
// from the discord-rpc folder). That one-time desktop step can't be
// automated away from the app side; everything else now is.

struct DiscordRichPresenceView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var discordVerification: DiscordVerificationService

    private let discordPresentationContext = DiscordAuthPresentationContext()

    @State private var config: DiscordRpcConfig?
    @State private var isTogglingEnabled = false
    @State private var enabled = false

    @State private var generatedToken: String?
    @State private var didCopyToken = false

    // Advanced: custom Discord Application override
    @State private var showAdvanced = false
    @State private var clientIdText = ""
    @State private var largeImageText = ""
    @State private var smallImageText = ""
    @State private var showButtons = true
    @State private var isSavingAdvanced = false
    @State private var isGeneratingToken = false
    @State private var errorText: String?
    @State private var didSaveAdvanced = false

    var body: some View {
        LKPage(title: "Rich Presence", subtitle: "Show what you're playing on your Discord profile.", icon: "key.viewfinder", tint: Color(red: 0.345, green: 0.396, blue: 0.949)) {
            discordAccountSection
            richPresenceSection
            if let errorText {
                LKSection {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.error)
                }
            }
            advancedSection
        }
        .background(Color.clear.ignoresSafeArea())
        .navigationTitle("Discord Rich Presence")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Discord Account

    private var discordAccountSection: some View {
        LKSection {
            if discordVerification.isVerified {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.345, green: 0.396, blue: 0.949))
                    Text(discordVerification.discordUsername ?? "Discord Verified")
                        .foregroundStyle(AppTheme.textPrimary)
                }
            } else {
                Button {
                    Task {
                        await discordVerification.startVerification(presentationContext: discordPresentationContext)
                    }
                } label: {
                    HStack {
                        Label("Verify with Discord", systemImage: "checkmark.seal")
                            .foregroundStyle(AppTheme.textPrimary)
                        if discordVerification.isLinking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(discordVerification.isLinking)
                if let error = discordVerification.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.error)
                }
            }
        } header: {
            sectionHeader("Discord Account")
        } footer: {
            Text("Confirms which Discord account this is you — separate from Rich Presence itself, which is driven by whatever Discord desktop client is signed in locally and works whether or not you verify here.")
                .font(AppTheme.bodyFont(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Rich Presence (the simplified, main flow)

    private var richPresenceSection: some View {
        LKSection {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { newValue in Task { await toggleEnabled(newValue) } }
            )) {
                HStack {
                    Label("Enable Rich Presence", systemImage: "gamecontroller.fill")
                        .foregroundStyle(AppTheme.textPrimary)
                    if isTogglingEnabled {
                        ProgressView()
                    }
                }
            }
            .tint(AppTheme.dynamicAccent)
            .disabled(!discordVerification.isVerified || isTogglingEnabled)

            if let generatedToken {
                VStack(alignment: .leading, spacing: 8) {
                    Text("One-time setup: run this on the computer where Discord is open.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(generatedToken)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = generatedToken
                        didCopyToken = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            didCopyToken = false
                        }
                    } label: {
                        Label(didCopyToken ? "Copied" : "Copy Token", systemImage: didCopyToken ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            sectionHeader("Rich Presence")
        } footer: {
            if !discordVerification.isVerified {
                Text("Verify your Discord account above first.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                Text("Uses Lumisound's own Discord app — nothing to register. The token above only allows reading your own playback state, not your password, and can be revoked any time from Active Sessions (\"Discord RPC Bridge\"). Run \"./install.sh <token>\" (or install-macos.sh / install-windows.ps1) from the discord-rpc folder on GitHub once, on the computer where Discord is open — Rich Presence is set over Discord's local connection, so it can't be driven remotely.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    /// First-ever enable (no registration exists yet): generates a fresh RPC
    /// token and registers `enabled = true` using Lumisound's shared Discord
    /// app (no client ID sent). A returning user re-enabling just flips the
    /// existing registration's `enabled` flag — their daemon already has a
    /// token from before, so generating a new one isn't necessary and would
    /// just be one more thing to re-copy for no reason.
    private func toggleEnabled(_ newValue: Bool) async {
        guard !isTogglingEnabled else { return }
        isTogglingEnabled = true
        errorText = nil
        defer { isTogglingEnabled = false }

        let isFirstTimeEnable = newValue && config?.configured != true
        if isFirstTimeEnable {
            generatedToken = await account.generateRpcToken()
        }

        let ok = await account.setDiscordRpcConfig(
            clientId: (config?.isCustom == true) ? clientIdText.trimmingCharacters(in: .whitespaces) : nil,
            largeImage: (config?.isCustom == true) ? (largeImageText.isEmpty ? nil : largeImageText) : nil,
            smallImage: (config?.isCustom == true) ? (smallImageText.isEmpty ? nil : smallImageText) : nil,
            showButtons: showButtons,
            enabled: newValue
        )
        if ok {
            enabled = newValue
            config = await account.fetchDiscordRpcConfig()
        } else {
            errorText = account.errorMessage ?? "Failed to update Rich Presence."
        }
    }

    // MARK: - Advanced: custom Discord Application override

    private var advancedSection: some View {
        LKSection {
            DisclosureGroup(isExpanded: $showAdvanced) {
                TextField("Discord Application Client ID", text: $clientIdText)
                    .keyboardType(.numberPad)
                    .foregroundStyle(AppTheme.textPrimary)

                TextField("Large image art asset name (optional)", text: $largeImageText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(AppTheme.textPrimary)

                TextField("Small status icon asset name (optional)", text: $smallImageText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(AppTheme.textPrimary)

                Toggle("Show \"Listen on...\" Button", isOn: $showButtons)
                    .tint(AppTheme.dynamicAccent)
                    .foregroundStyle(AppTheme.textPrimary)

                Button {
                    saveAdvanced()
                } label: {
                    if isSavingAdvanced {
                        ProgressView()
                    } else {
                        Text(didSaveAdvanced ? "Saved" : "Use Custom Discord App")
                    }
                }
                .disabled(isSavingAdvanced || clientIdText.trimmingCharacters(in: .whitespaces).isEmpty)
                .foregroundStyle(AppTheme.dynamicAccent)

                if config?.isCustom == true {
                    Button(role: .destructive) {
                        useSharedApp()
                    } label: {
                        Text("Switch Back to Lumisound's Shared App")
                    }
                }

                Button {
                    Task {
                        isGeneratingToken = true
                        generatedToken = await account.generateRpcToken()
                        isGeneratingToken = false
                    }
                } label: {
                    HStack {
                        Label("Generate New Token", systemImage: "key.viewfinder")
                            .foregroundStyle(AppTheme.textPrimary)
                        if isGeneratingToken {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isGeneratingToken)

                if config?.configured == true {
                    Button(role: .destructive) {
                        removeConfig()
                    } label: {
                        Text("Remove Registration")
                    }
                }
            } label: {
                Label("Advanced: Custom Discord App", systemImage: "slider.horizontal.3")
                    .foregroundStyle(AppTheme.textPrimary)
            }
        } footer: {
            Text("Only needed if you want your own branding (a different Discord Application, your own Rich Presence art) instead of Lumisound's shared one. Find your Application ID at discord.com/developers/applications; asset names must be uploaded there as \"Rich Presence Art Assets\".")
                .font(AppTheme.bodyFont(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func saveAdvanced() {
        let trimmedId = clientIdText.trimmingCharacters(in: .whitespaces)
        guard !trimmedId.isEmpty else { return }
        let trimmedLargeImage = largeImageText.trimmingCharacters(in: .whitespaces)
        let trimmedSmallImage = smallImageText.trimmingCharacters(in: .whitespaces)
        isSavingAdvanced = true
        errorText = nil
        Task {
            if await account.setDiscordRpcConfig(
                clientId: trimmedId,
                largeImage: trimmedLargeImage.isEmpty ? nil : trimmedLargeImage,
                smallImage: trimmedSmallImage.isEmpty ? nil : trimmedSmallImage,
                showButtons: showButtons,
                enabled: enabled
            ) {
                didSaveAdvanced = true
                config = await account.fetchDiscordRpcConfig()
            } else {
                errorText = account.errorMessage ?? "Failed to save configuration."
            }
            isSavingAdvanced = false
        }
    }

    /// Clears a custom override back to Lumisound's shared Discord app —
    /// sends an explicit empty client ID (distinct from omitting the field
    /// entirely on first-ever enable) so the server drops the stored
    /// override rather than leaving it in place.
    private func useSharedApp() {
        Task {
            if await account.setDiscordRpcConfig(clientId: "", largeImage: nil, smallImage: nil, showButtons: showButtons, enabled: enabled) {
                clientIdText = ""
                largeImageText = ""
                smallImageText = ""
                config = await account.fetchDiscordRpcConfig()
            } else {
                errorText = account.errorMessage ?? "Failed to switch back to the shared app."
            }
        }
    }

    private func removeConfig() {
        Task {
            if await account.deleteDiscordRpcConfig() {
                config = await account.fetchDiscordRpcConfig()
                clientIdText = ""
                largeImageText = ""
                smallImageText = ""
                showButtons = true
                enabled = false
                didSaveAdvanced = false
                generatedToken = nil
            }
        }
    }

    private func load() async {
        config = await account.fetchDiscordRpcConfig()
        if let config {
            enabled = config.enabled
            showButtons = config.showButtons
            if config.isCustom {
                clientIdText = config.discordClientId ?? ""
                largeImageText = config.largeImage ?? ""
                smallImageText = config.smallImage ?? ""
                showAdvanced = true
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
