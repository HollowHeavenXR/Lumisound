import SwiftUI
import UniformTypeIdentifiers

struct PlaylistsView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var account: AccountService

    @State private var showingCreateSheet = false
    @State private var newPlaylistName = ""

    // Rename alert state
    @State private var renameTarget: Playlist? = nil
    @State private var renameText: String = ""
    @State private var showingRenameAlert = false

    // M3U import state
    @State private var showingM3UImporter = false
    @State private var isImportingM3U = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SmartPlaylistsView()
                } label: {
                    Label("Smart Playlists", systemImage: "sparkles")
                        .foregroundStyle(AppTheme.textPrimary)
                }
            }
            .listRowBackground(AppTheme.surface.opacity(0.5))

            if account.isLoggedIn {
                Section {
                    NavigationLink {
                        SharedPlaylistsView()
                    } label: {
                        Label("Shared with Me", systemImage: "person.2.fill")
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                }
                .listRowBackground(AppTheme.surface.opacity(0.5))
            }

            if library.playlists.isEmpty {
                EmptyStateView(
                    icon: "music.note.list",
                    title: "No playlists",
                    message: "Tap the + button to create your first playlist."
                )
                .listRowBackground(Color.clear)
            } else {
                let unfiled = library.playlists.filter { $0.folder == nil }
                ForEach(unfiled) { playlist in
                    playlistRow(playlist)
                }
                .onDelete { indexSet in
                    let targets = indexSet.map { unfiled[$0] }
                    for playlist in targets {
                        library.deletePlaylist(playlist)
                    }
                    if let name = targets.first?.name {
                        let suffix = targets.count > 1 ? " and \(targets.count - 1) more" : ""
                        ToastCenter.shared.show("Deleted \"\(name)\"\(suffix)", category: .info, icon: "trash")
                    }
                }

                ForEach(library.playlistFolders, id: \.self) { folder in
                    let folderPlaylists = library.playlists.filter { $0.folder == folder }
                    Section {
                        ForEach(folderPlaylists) { playlist in
                            playlistRow(playlist)
                        }
                        .onDelete { indexSet in
                            let targets = indexSet.map { folderPlaylists[$0] }
                            for playlist in targets {
                                library.deletePlaylist(playlist)
                            }
                            if let name = targets.first?.name {
                                let suffix = targets.count > 1 ? " and \(targets.count - 1) more" : ""
                                ToastCenter.shared.show("Deleted \"\(name)\"\(suffix)", category: .info, icon: "trash")
                            }
                        }
                    } header: {
                        Label(folder, systemImage: "folder")
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isImportingM3U {
                    ProgressView().tint(AppTheme.dynamicAccent)
                } else {
                    LumiMenu {
                        Button {
                            newPlaylistName = ""
                            showingCreateSheet = true
                        } label: {
                            Label("New Playlist", systemImage: "plus")
                        }
                        Button {
                            showingM3UImporter = true
                        } label: {
                            Label("Import M3U File", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(AppTheme.dynamicAccent)
                }
            }
        }
        .fileImporter(
            isPresented: $showingM3UImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "m3u") ?? .plainText,
                UTType(filenameExtension: "m3u8") ?? .plainText,
                .plainText,
            ]
        ) { result in
            guard case .success(let fileURL) = result else { return }
            isImportingM3U = true
            Task {
                let name = fileURL.deletingPathExtension().lastPathComponent
                let importResult = M3UImportService.import(fileURL: fileURL, library: library)
                isImportingM3U = false
                guard importResult.totalEntries > 0 else {
                    ToastCenter.shared.show("No tracks found in that file", category: .error, icon: "exclamationmark.triangle")
                    return
                }
                library.createPlaylist(name: name, songIDs: importResult.matchedSongIDs)
                let matched = importResult.matchedSongIDs.count
                ToastCenter.shared.show(
                    "Imported \"\(name)\" — \(matched) of \(importResult.totalEntries) track\(importResult.totalEntries == 1 ? "" : "s") matched",
                    category: matched > 0 ? .success : .error,
                    icon: "music.note.list"
                )
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreatePlaylistSheet(
                name: $newPlaylistName,
                onCreate: { name in
                    library.createPlaylist(name: name)
                    showingCreateSheet = false
                    ToastCenter.shared.show("Playlist \"\(name)\" created", category: .success, icon: "music.note.list")
                },
                onCancel: {
                    showingCreateSheet = false
                }
            )
        }
        // Rename alert
        .alert("Rename Playlist", isPresented: $showingRenameAlert, presenting: renameTarget) { playlist in
            TextField("Playlist name", text: $renameText)
                .autocorrectionDisabled()
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    library.renamePlaylist(playlist, to: trimmed)
                    ToastCenter.shared.show("Renamed to \"\(trimmed)\"", category: .success, icon: "pencil")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { playlist in
            Text("Enter a new name for \"\(playlist.name)\".")
        }
    }

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist) -> some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
        } label: {
            PlaylistRow(playlist: playlist)
        }
        .listRowBackground(AppTheme.surface.opacity(0.5))
        .contextMenu {
            Button {
                renameTarget = playlist
                renameText = playlist.name
                showingRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button(role: .destructive) {
                library.deletePlaylist(playlist)
                ToastCenter.shared.show("Deleted \"\(playlist.name)\"", category: .info, icon: "trash")
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Playlist Row

private struct PlaylistRow: View {
    let playlist: Playlist
    @EnvironmentObject private var library: LibraryManager

    // Total duration of all songs in the playlist
    private var totalDuration: TimeInterval {
        library.songs(for: playlist).reduce(0) { $0 + $1.duration }
    }

    /// Formats seconds as "Xh Ym" or "Xm" etc.
    private var durationText: String {
        let total = Int(totalDuration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private var subtitle: String {
        let count = playlist.songCount
        let countText = "\(count) \(count == 1 ? "song" : "songs")"
        guard playlist.songCount > 0 else { return countText }
        return "\(countText) · \(durationText)"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
                Image(systemName: "music.note.list")
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .font(.system(size: 18))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                if !playlist.tags.isEmpty {
                    Text(playlist.tags.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.dynamicAccent)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Create Playlist Sheet

private struct CreatePlaylistSheet: View {
    @Binding var name: String
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist Name") {
                    TextField("My Playlist", text: $name)
                        .focused($isFocused)
                        .autocorrectionDisabled()
                        .foregroundStyle(AppTheme.textPrimary)
                        .listRowBackground(AppTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear.ignoresSafeArea())
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .tint(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreate(trimmed)
                    }
                    .disabled(!isValid)
                    .tint(AppTheme.dynamicAccent)
                }
            }
            .onAppear { isFocused = true }
        }
    }
}
