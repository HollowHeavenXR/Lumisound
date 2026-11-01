import SwiftUI
import MediaPlayer

// MARK: - Songs multi-select bulk action bar

struct LibrarySelectionActionBar: View {
    let selectedCount: Int
    let onAddToPlaylist: (UUID) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var library: LibraryManager
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 12) {
            Button("Cancel", action: onCancel)
                .foregroundStyle(AppTheme.textSecondary)

            Spacer()

            Text("\(selectedCount) selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            Spacer()

            Menu {
                if library.playlists.isEmpty {
                    Text("No playlists yet")
                } else {
                    ForEach(library.playlists) { playlist in
                        Button {
                            onAddToPlaylist(playlist.id)
                        } label: {
                            Label(playlist.name, systemImage: "music.note.list")
                        }
                    }
                }
            } label: {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.system(size: 18, weight: .medium))
            }
            .disabled(selectedCount == 0)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .medium))
            }
            .disabled(selectedCount == 0)
        }
        .foregroundStyle(AppTheme.dynamicAccent)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .styleAwareMaterial(.ultraThinMaterial, in: Rectangle())
        .overlay(Divider(), alignment: .top)
        .confirmationDialog(
            "Delete \(selectedCount) song\(selectedCount == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedCount) Song\(selectedCount == 1 ? "" : "s")", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Songs from your Apple Music library can't be deleted this way and will be skipped.")
        }
    }
}
