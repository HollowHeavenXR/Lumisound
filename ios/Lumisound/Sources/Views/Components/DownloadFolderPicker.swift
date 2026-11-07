import SwiftUI

// MARK: - DownloadFolderPicker

/// Reusable "existing folder, or create a new one" picker for choosing a
/// download destination subfolder under "Imported Music". Backs both the
/// global yt-dlp download-folder setting (Settings → yt-dlp) and each tracked
/// playlist's own destination folder, so a playlist's auto-downloads can land
/// somewhere dedicated instead of only ever using the one global setting.
///
/// `folderName` is empty for the "Imported Music" root itself, or a sanitized
/// subfolder name otherwise — same convention `StreamingService.downloadDirectory`
/// and `downloadDirectory(forFolderName:)` already use.
struct DownloadFolderPicker: View {
    @Binding var folderName: String

    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var existingFolders: [String] = []

    var body: some View {
        LumiMenu {
            Button {
                folderName = ""
            } label: {
                if folderName.isEmpty {
                    Label("Imported Music (default)", systemImage: "checkmark")
                } else {
                    Text("Imported Music (default)")
                }
            }
            if !existingFolders.isEmpty {
                Divider()
                ForEach(existingFolders, id: \.self) { name in
                    Button {
                        folderName = name
                    } label: {
                        if folderName == name {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
            Divider()
            Button {
                newFolderName = ""
                showingNewFolderAlert = true
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(folderName.isEmpty ? "Imported Music" : folderName)
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .onAppear { existingFolders = StreamingService.existingDownloadFolderNames() }
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
                .autocorrectionDisabled()
            Button("Create") {
                let sanitized = StreamingService.sanitizedFolderName(newFolderName)
                guard !sanitized.isEmpty else { return }
                StreamingService.createDownloadFolder(named: sanitized)
                folderName = sanitized
                existingFolders = StreamingService.existingDownloadFolderNames()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tracks will be saved to Imported Music/<name>.")
        }
    }
}
