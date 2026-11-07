import MediaPlayer
import SwiftUI

extension SettingsView {

    // MARK: — Streaming & Downloads Section

    var streamingDownloadsSection: some View {
        Section {
            #if DEBUG
            // Status row — only meaningful in DEBUG since `isConfigured` is
            // hardcoded `true` for release builds (a default bridge URL is
            // always baked in), so it'd always read "Configured" otherwise.
            HStack {
                Label("Bridge Server", systemImage: "server.rack")
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(streaming.isConfigured ? "Configured" : "Not configured")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(streaming.isConfigured ? AppTheme.success : AppTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        (streaming.isConfigured ? AppTheme.success : AppTheme.textSecondary).opacity(0.15),
                        in: Capsule()
                    )
            }

            // Server URL and API key point at the developer's personal backend
            // (a default URL is baked in via `StreamingService.defaultBridgeURL`,
            // so the app works without any user input). These overrides are only
            // useful for local development/testing against a different bridge,
            // so they're hidden from end users entirely.
            // Server URL field
            HStack {
                Label("Server URL", systemImage: "link")
                    .foregroundStyle(AppTheme.textPrimary)
                TextField("http://192.168.1.x:7333", text: Binding(
                    get: { streaming.bridgeURL },
                    set: { streaming.bridgeURL = $0 }
                ))
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(AppTheme.textSecondary)
            }

            // API Key (optional)
            HStack {
                Label("API Key (optional)", systemImage: "key")
                    .foregroundStyle(AppTheme.textPrimary)
                SecureField("Leave blank if not set", text: Binding(
                    get: { streaming.apiKey },
                    set: { streaming.apiKey = $0 }
                ))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(AppTheme.textSecondary)
            }
            #endif

            // Audio Format picker
            AudioFormatPickerRow(streaming: streaming, tint: .cyan, hidesLabel: false)

            // Wi-Fi Only Downloads — blocks the single downloadToLibrary
            // chokepoint (see that function's guard) whenever the device is
            // on cellular with no Wi-Fi available, so it covers every
            // download path (foreground, background job reconciliation,
            // tracked-playlist auto-download) without a check at each site.
            Toggle(isOn: $wifiOnlyDownloadsEnabled) {
                Label("Wi-Fi Only Downloads", systemImage: "wifi")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.cyan)

            // Test connection
            Button {
                Task {
                    let ok = await streaming.checkHealth()
                    healthOK = ok
                    showHealthResult = true
                }
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(AppTheme.dynamicAccent)
                    Spacer()
                    if showHealthResult {
                        Image(systemName: healthOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(healthOK ? AppTheme.success : AppTheme.error)
                    }
                }
            }

            // YouTube Data API key — only relevant when signed in, since the
            // key is stored server-side on the user's account.
            if account.isLoggedIn {
                youtubeAPIKeySection
                acoustIDAPIKeySection
            }

        } header: {
            sectionHeader("Streaming & Downloads", icon: "arrow.down.circle.fill", tint: .cyan)
        }
        .listRowBackground(tintedRowBackground(.cyan))
    }
}

/// Isolates the Audio Format picker from `SettingsView`'s body — same
/// "dropdown resets while open" root cause as `FadeCurvePickerRow`/
/// `EQPresetPickerRow`/`ReverbPresetPickerRow` in
/// `SettingsView+PlaybackAudioSection.swift` (see that file's doc comment),
/// just via `streaming` instead of `player`. `preferredFormat` is a plain
/// `UserDefaults`-backed computed property on `StreamingService`, not
/// `@Published` — forcing the `Binding(get:set:)` shape both prior
/// "Save to" dropdown fixes identified as the strongest fingerprint of this
/// bug. Shared by both Settings screens that surface this picker
/// (Streaming & Downloads, yt-dlp) since it's the exact same control with
/// only cosmetic differences between them.
struct AudioFormatPickerRow: View {
    @ObservedObject var streaming: StreamingService
    var tint: Color
    var hidesLabel: Bool

    var body: some View {
        HStack {
            Label("Audio Format", systemImage: "waveform")
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Group {
                if hidesLabel {
                    picker.labelsHidden()
                } else {
                    picker
                }
            }
            .pickerStyle(.menu)
            .tint(tint)
        }
    }

    private var picker: some View {
        LumiPicker("Audio Format", selection: Binding(
            get: { streaming.preferredFormat },
            set: { streaming.preferredFormat = $0 }
        )) {
            ForEach(StreamingService.availableFormats, id: \.value) { fmt in
                Text(fmt.label).lumiOptionLabel(String(describing: fmt.label)).tag(fmt.value)
            }
        }
    }
}
