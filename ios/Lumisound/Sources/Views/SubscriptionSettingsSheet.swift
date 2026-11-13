import SwiftUI

// MARK: - SubscriptionSettingsSheet
//
// Per-subscription settings — auto-download (+ destination folder),
// notification mute, and category — presented from a gear button on each
// row in `SubscriptionsView`. Mirrors `TrackedPlaylistDetailView`'s own
// auto-download/destination-folder controls (same `DownloadFolderPicker`
// component) for consistency between the two "follow something and get new
// tracks automatically" features.

struct SubscriptionSettingsSheet: View {
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss

    let subscription: ArtistSubscription
    /// Called after a successful save so the presenting view can refresh its list.
    var onSaved: () -> Void

    @State private var autoDownload: Bool
    @State private var destinationFolder: String
    @State private var notificationsMuted: Bool
    @State private var category: String
    @State private var isSaving = false
    @State private var errorText: String?

    init(subscription: ArtistSubscription, onSaved: @escaping () -> Void) {
        self.subscription = subscription
        self.onSaved = onSaved
        _autoDownload = State(initialValue: subscription.autoDownload)
        _destinationFolder = State(initialValue: subscription.destinationFolder ?? "")
        _notificationsMuted = State(initialValue: subscription.notificationsMuted)
        _category = State(initialValue: subscription.category ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LK.spacing) {
                    HStack(spacing: 12) {
                        LKIcon(symbol: "person.crop.circle.badge.checkmark", tint: .cyan, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(subscription.channelName ?? "Channel").font(.headline).foregroundStyle(AppTheme.textPrimary)
                            Text(subscription.channelUrl).font(.caption2).foregroundStyle(AppTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    LKCard(title: "New uploads", footer: "Auto-downloaded uploads go straight into your library. \"Save to\" overrides the global download folder for this channel.") {
                        LKToggle(icon: "arrow.down.circle.fill", tint: .green, title: "Download automatically", isOn: $autoDownload)
                        if autoDownload {
                            HStack(spacing: 12) {
                                LKIcon(symbol: "folder.fill", tint: .brown)
                                Text("Save to").font(AppTheme.bodyFont(size: 15)).foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                DownloadFolderPicker(folderName: $destinationFolder)
                            }
                            .padding(.vertical, 6)
                        }
                        LKDivider()
                        LKToggle(icon: notificationsMuted ? "bell.slash.fill" : "bell.fill", tint: .orange, title: "Mute alerts",
                                 subtitle: "Still listed in New Releases", isOn: $notificationsMuted)
                    }
                    LKCard(title: "Category", footer: "Group channels, e.g. \"Podcasts\" or \"DJs\". Leave blank for none.") {
                        LKField(placeholder: "Category (optional)", text: $category).padding(.vertical, 4)
                    }
                    if let errorText {
                        LKBanner(icon: "exclamationmark.triangle.fill", text: errorText, tint: AppTheme.error)
                    }
                }
                .padding(LK.gutter)
                .animation(.easeInOut(duration: 0.2), value: autoDownload)
            }
            .background(GalleryBackgroundView().ignoresSafeArea())
            .navigationTitle("Channel Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        if isSaving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(isSaving)
                    .foregroundStyle(.cyan)
                }
            }
        }
    }

    private func save() {
        isSaving = true
        errorText = nil
        let trimmedCategory = category.trimmingCharacters(in: .whitespaces)
        let trimmedFolder = destinationFolder.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = await account.updateSubscriptionSettings(
                id: subscription.id,
                autoDownload: autoDownload,
                destinationFolder: trimmedFolder,
                notificationsMuted: notificationsMuted,
                category: trimmedCategory
            )
            isSaving = false
            if ok {
                onSaved()
                dismiss()
            } else {
                errorText = account.errorMessage ?? "Failed to save settings."
            }
        }
    }
}
