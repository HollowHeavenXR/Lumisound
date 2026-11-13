import MediaPlayer
import SwiftUI

extension SettingsView {

    // MARK: — yt-dlp Section

    var ytdlpSection: some View {
        Group {
            Section {
                Toggle(isOn: $ytdlpUseAria2) {
                    Label("Use aria2 downloader", systemImage: "bolt.horizontal.circle")
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .tint(.yellow)

                Text(ytdlpUseAria2
                     ? "Downloads use aria2 with multiple parallel connections. This can help on networks where YouTube throttles single connections — but on a fast, un-throttled connection the built-in downloader is usually faster."
                     : "Downloads use yt-dlp's built-in downloader (recommended — benchmarked faster on most connections). Turn this on only if your network throttles single downloads.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            } header: {
                sectionHeader("Download Engine", icon: "bolt.fill", tint: .yellow)
            } footer: {
                Text("aria2 opens many connections per download. It bypasses per-connection throttling on some networks, but adds overhead that makes it slower when a single connection is already fast.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .listRowBackground(tintedRowBackground(.yellow))

            // Download tuning — speed vs. ban-risk knobs that were hardcoded.
            Section {
                Stepper(value: $ytdlpThrottleSeconds, in: 0...30, step: 1) {
                    HStack {
                        Label("Request Throttle", systemImage: "tortoise")
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        Text(ytdlpThrottleSeconds == 0 ? "Off" : "\(ytdlpThrottleSeconds)s")
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Stepper(value: $ytdlpConcurrentFragments, in: 1...16, step: 1) {
                    HStack {
                        Label("Parallel Fragments", systemImage: "hare")
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        Text("\(ytdlpConcurrentFragments)×")
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            } header: {
                sectionHeader("Download Speed", icon: "speedometer", tint: .orange)
            } footer: {
                Text("Throttle adds a pause between requests to avoid YouTube bot checks — set it to Off for maximum speed (slightly higher risk of temporary blocks). Parallel Fragments downloads pieces of each track at once; higher is faster on big files.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .listRowBackground(tintedRowBackground(.orange))

            // Audio format also governs yt-dlp's output, so surface it here too.
            // `hidesLabel: true` because this row already draws its own
            // `Label` above — a `.menu` picker in a List renders its title
            // too, so this row read "Audio Format  Audio Format" with the
            // real value pushed to the far edge. See `AudioFormatPickerRow`
            // (SettingsView+StreamingDownloadsSection.swift) for the shared
            // implementation and why it's its own isolated row.
            Section {
                AudioFormatPickerRow(streaming: streaming, tint: .gray, hidesLabel: true)
            } header: {
                sectionHeader("Format", icon: "doc.fill", tint: .gray)
            } footer: {
                Text("Preferred audio format for downloads (yt-dlp -x --audio-format). Highest quality is used for every download.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .listRowBackground(tintedRowBackground(.gray))

            // Custom download folder — downloads land in Imported Music/<folder>.
            Section {
                HStack {
                    Label("Download Folder", systemImage: "folder")
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    DownloadFolderPicker(folderName: $ytdlpDownloadFolder)
                }
            } header: {
                sectionHeader("Download Folder", icon: "folder.fill", tint: .brown)
            } footer: {
                Text("Every download goes into this folder (created automatically), so a big playlist lands together instead of in the Imported Music root. Choose an existing folder or create a new one. Downloads in any subfolder are still found and de-duplicated. Each tracked playlist can also override this with its own folder.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .listRowBackground(tintedRowBackground(.brown))

            // YouTube auth — cookies + Data API key — both feed yt-dlp lookups.
            if account.isLoggedIn {
                Section {
                    NavigationLink(destination: CookiesFileView()) {
                        Label("YouTube Cookies", systemImage: "doc.text")
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    NavigationLink(destination: YoutubeApiKeyView()) {
                        Label("YouTube API Key", systemImage: "key")
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                } header: {
                    sectionHeader("YouTube Authentication", icon: "key.fill", tint: .red)
                } footer: {
                    Text("Upload a cookies.txt to download age-restricted content and avoid bot checks. Add a YouTube Data API key for full playlist resolution.")
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(tintedRowBackground(.red))
            }
        }
        .animation(LumiMotion.fade(0.22), value: ytdlpUseAria2)
    }
}
