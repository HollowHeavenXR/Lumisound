import SwiftUI
import UniformTypeIdentifiers

/// Settings screen for the local playlist/favorites backup feature —
/// entirely on-device, no server/account involved. Exports a JSON snapshot
/// of playlist structure + favorites for sharing (AirDrop, Files, Messages,
/// etc.) and can re-import one later, e.g. after a reinstall or on a new
/// device that already has the same songs imported/synced via iCloud Music
/// Library.
struct LibraryBackupView: View {
    @EnvironmentObject private var library: LibraryManager

    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var showImporter = false
    @State private var importErrorMessage: String?

    /// Plain, pre-computed string (rather than a multi-ternary interpolation
    /// inline in a `Text(...)` call) — kept simple deliberately after a
    /// sibling screen (`CacheManagerView`) hit a Swift type-checker timeout
    /// from too much inline ViewBuilder complexity in one `body`.
    private var exportFooterText: String {
        let playlistWord = library.playlists.count == 1 ? "playlist" : "playlists"
        let favoriteWord = library.favoriteSongIDs.count == 1 ? "favorite" : "favorites"
        return "Saves your \(library.playlists.count) \(playlistWord) and \(library.favoriteSongIDs.count) \(favoriteWord) to a single file you can AirDrop, save to Files, or send to yourself."
    }

    var body: some View {
        LKPage(title: "Backup & Restore", subtitle: "Your playlists and favorites in one file — no account needed.",
               icon: "arrow.triangle.2.circlepath", tint: .green) {
            HStack(spacing: 10) {
                LKStat(value: "\(library.playlists.count)", label: "Playlists", icon: "music.note.list", tint: .green)
                LKStat(value: "\(library.favoriteSongIDs.count)", label: "Favorites", icon: "heart.fill", tint: .pink)
            }
            HStack(spacing: 12) {
                actionTile(icon: "square.and.arrow.up.fill", title: "Export", detail: "Save or AirDrop a backup file", tint: .green) {
                    exportBackup()
                }
                .disabled(library.playlists.isEmpty && library.favoriteSongIDs.isEmpty)
                actionTile(icon: "square.and.arrow.down.fill", title: "Import", detail: "Add from a backup file", tint: .blue) {
                    showImporter = true
                }
            }
            LKCard(title: "Good to know") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Importing adds — nothing you have now is replaced or removed.", systemImage: "plus.square.on.square")
                    Label("Songs a backup mentions that aren't on this device are skipped.", systemImage: "forward")
                    Label("Audio files aren't included: move downloads separately; Apple Music songs need iCloud Music Library on both devices.", systemImage: "music.note")
                }
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.vertical, 4)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportURL {
                RewindShareSheet(items: [exportURL])
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImportResult(result)
        }
        .alert("Import Failed", isPresented: .constant(importErrorMessage != nil), presenting: importErrorMessage) { _ in
            Button("OK") { importErrorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func actionTile(icon: String, title: String, detail: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold))
                Spacer(minLength: 0)
                Text(title).font(.headline)
                Text(detail).font(.caption2).opacity(0.85).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .padding(14)
            .foregroundStyle(.white)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func exportBackup() {
        appLog("LibraryBackupView: user tapped Export Backup", category: "library")
        let backup = LibraryBackup(playlists: library.playlists, favoriteSongIDs: library.favoriteSongIDs)
        do {
            exportURL = try LibraryBackupService.exportBackup(backup)
            showShareSheet = true
        } catch {
            appError("LibraryBackupView: export failed: \(error.localizedDescription)", category: "library")
            importErrorMessage = "Couldn't create the backup file. Please try again."
        }
    }

    private func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            appWarn("LibraryBackupView: file importer failed: \(error.localizedDescription)", category: "library")
            importErrorMessage = "Couldn't read that file."
        case .success(let url):
            appLog("LibraryBackupView: user picked \(url.lastPathComponent) to import", category: "library")
            do {
                let backup = try LibraryBackupService.decodeBackup(from: url)
                let (imported, skipped) = library.importBackup(backup)
                let skippedText = skipped > 0 ? ", \(skipped) song\(skipped == 1 ? "" : "s") skipped (not in your library)" : ""
                ToastCenter.shared.show(
                    "Imported \(imported) playlist\(imported == 1 ? "" : "s")\(skippedText)",
                    category: .success,
                    icon: "square.and.arrow.down"
                )
            } catch {
                appError("LibraryBackupView: import failed for \(url.lastPathComponent): \(error.localizedDescription)", category: "library")
                importErrorMessage = "That file doesn't look like a Lumisound backup."
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
