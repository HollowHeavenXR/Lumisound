import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var streaming: StreamingService

    @State private var isEditing = false
    @State private var showingAddSongs = false
    @State private var showShareSheet = false
    @State private var showOrganizeSheet = false
    @State private var showMixtapeCard = false
    @State private var m3uExportURL: URL?
    @State private var showM3UShareSheet = false

    // Always look up the live playlist so mutations (add/remove/reorder) are reflected immediately.
    private var currentPlaylist: Playlist {
        library.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    private var songs: [Song] {
        library.songs(for: currentPlaylist)
    }

    var body: some View {
        List {
            // Folder / tags summary
            if currentPlaylist.folder != nil || !currentPlaylist.tags.isEmpty {
                Section {
                    Button {
                        showOrganizeSheet = true
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let folder = currentPlaylist.folder {
                                Label(folder, systemImage: "folder")
                                    .font(AppTheme.bodyFont(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            if !currentPlaylist.tags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(currentPlaylist.tags, id: \.self) { tag in
                                            Text(tag)
                                                .font(AppTheme.bodyFont(size: 11))
                                                .foregroundStyle(AppTheme.dynamicAccent)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(AppTheme.dynamicAccent.opacity(0.12), in: Capsule())
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(AppTheme.surface.opacity(0.5))
            }

            if songs.isEmpty {
                EmptyStateView(
                    icon: "music.note.list",
                    title: "No songs",
                    message: "Tap the + button to add songs to this playlist."
                )
                .listRowBackground(Color.clear)
            } else {
                // Play All button
                Section {
                    Button {
                        player.setQueue(songs, startIndex: 0, autoplay: true, playlistID: currentPlaylist.id)
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.dynamicAccent)
                    .listRowBackground(Color.clear)
                }
                .listSectionSeparator(.hidden)

                // Song list
                ForEach(songs) { song in
                    Button {
                        if !isEditing {
                            player.play(song: song, in: songs, playlistID: currentPlaylist.id, uiSource: "playlist")
                        }
                    } label: {
                        SongRow(song: song, isCurrent: player.currentSong?.id == song.id)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AppTheme.surface.opacity(0.5))
                    .contextMenu {
                        Button(role: .destructive) {
                            library.removeSong(id: song.id, fromPlaylistID: playlist.id)
                        } label: {
                            Label("Remove from Playlist", systemImage: "minus.circle")
                        }
                    }
                }
                .onMove { source, destination in
                    // Derive the reordered list from the displayed songs array
                    var reordered = songs.map(\.id)
                    reordered.move(fromOffsets: source, toOffset: destination)
                    reorder(newIDs: reordered)
                }
                .onDelete { indexSet in
                    // Snapshot targets first — `songs` is computed from
                    // `library.playlists`, so each removal would shift later
                    // indices in `indexSet` mid-loop and remove the wrong songs
                    // for multi-row swipes.
                    let targets = indexSet.map { songs[$0] }
                    for song in targets {
                        library.removeSong(id: song.id, fromPlaylistID: playlist.id)
                    }
                }
            }
        }
        // `.plain`, not `.insetGrouped` — see FavoritesView's identical fix;
        // `.insetGrouped` splits each Section into a separate floating card
        // with the gallery background showing fully through the gaps.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Own gallery/theme background (pushed detail views don't inherit the
        // root's), so it matches the rest of the app instead of system black.
        .background(GalleryBackgroundView().ignoresSafeArea())
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
        // While `editMode` is active, SwiftUI/UIKit's List editing chrome
        // suppresses the system back button and the edge-swipe-to-pop
        // gesture (a List-in-edit-mode convention: leaving mid-reorder is
        // blocked so you can't "swipe away" a half-finished drag). Without
        // an explicit way out in the same top-left spot users look for, that
        // reads as "I can't go back" — a leading "Done" here guarantees an
        // always-visible, always-tappable exit for as long as editing is on,
        // matching Apple's own Photos/Notes edit-mode convention.
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation(LumiMotion.glide) { isEditing = false }
                    } label: {
                        Text("Done").fontWeight(.semibold)
                    }
                    .tint(AppTheme.dynamicAccent)
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !isEditing {
                    LumiMenu {
                        Button {
                            showOrganizeSheet = true
                        } label: {
                            Label("Organize", systemImage: "folder.badge.gearshape")
                        }
                        Button {
                            exportM3U()
                        } label: {
                            Label("Export as M3U", systemImage: "doc.text")
                        }
                        Button {
                            showMixtapeCard = true
                        } label: {
                            Label("Mixtape Card", systemImage: "photo.artframe")
                        }
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .tint(AppTheme.dynamicAccent)

                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(AppTheme.dynamicAccent)

                    Button {
                        showingAddSongs = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(AppTheme.dynamicAccent)
                }

                Button {
                    withAnimation(LumiMotion.glide) { isEditing.toggle() }
                } label: {
                    Text(isEditing ? "Done" : "Edit")
                        .fontWeight(isEditing ? .semibold : .regular)
                }
                .tint(AppTheme.dynamicAccent)
            }
        }
        .sheet(isPresented: $showingAddSongs) {
            AddSongsSheet(playlist: playlist)
                .environmentObject(library)
                .environmentObject(player) // SongRow context menu (SongContextMenuContent) needs it
        }
        .sheet(isPresented: $showOrganizeSheet) {
            PlaylistOrganizeSheet(playlist: currentPlaylist)
                .environmentObject(library)
        }
        .sheet(isPresented: $showMixtapeCard) {
            NavigationStack {
                MixtapeCardView(playlist: currentPlaylist)
                    .environmentObject(library)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            CollaborativePlaylistView(playlist: playlist)
                .environmentObject(player)
                .environmentObject(account)
                .environmentObject(streaming)
                .environmentObject(library)
        }
        .sheet(isPresented: $showM3UShareSheet) {
            if let m3uExportURL {
                RewindShareSheet(items: [m3uExportURL])
            }
        }
    }

    /// Generates a UTF-8 M3U playlist file and opens the share sheet for it.
    /// Songs backed by an actual local file (imported/downloaded) get their
    /// real path; Apple Music library items have no exportable file, so they
    /// get a metadata-only comment line instead — still a readable record of
    /// what was in the playlist, just not something another app can resolve.
    private func exportM3U() {
        var lines = ["#EXTM3U"]
        for song in songs {
            lines.append("#EXTINF:\(Int(song.duration.rounded())),\(song.artistName) - \(song.title)")
            if let url = song.url {
                lines.append(url.path)
            } else {
                lines.append("# (Apple Music library item — no exportable file)")
            }
        }
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else { return }
        let safeName = currentPlaylist.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).m3u8")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        m3uExportURL = url
        showM3UShareSheet = true
    }

    private func reorder(newIDs: [Song.ID]) {
        library.reorderSongs(in: playlist.id, to: newIDs)
    }
}

// MARK: - Playlist Organize Sheet
//
// Lets the user file a playlist into a folder (existing or new) and attach
// free-form tags. Folders are just a string field on the playlist — the
// "Folders" grouping in PlaylistsView groups by this value.

private struct PlaylistOrganizeSheet: View {
    let playlist: Playlist

    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var folderText: String = ""
    @State private var tagText: String = ""
    @State private var tags: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name (optional)", text: $folderText)
                        .autocorrectionDisabled()
                        .foregroundStyle(AppTheme.textPrimary)
                        .listRowBackground(AppTheme.surface)

                    if !library.playlistFolders.isEmpty {
                        ForEach(library.playlistFolders, id: \.self) { folder in
                            Button(folder) {
                                folderText = folder
                            }
                            .foregroundStyle(AppTheme.textSecondary)
                            .listRowBackground(AppTheme.surface)
                        }
                    }
                } header: {
                    Text("Folder")
                } footer: {
                    Text("Leave empty for no folder. Tap an existing folder to reuse it.")
                }

                Section {
                    HStack {
                        TextField("Add a tag", text: $tagText)
                            .autocorrectionDisabled()
                            .foregroundStyle(AppTheme.textPrimary)
                            .onSubmit(addTag)
                        Button("Add", action: addTag)
                            .disabled(tagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .tint(AppTheme.dynamicAccent)
                    }
                    .listRowBackground(AppTheme.surface)

                    if !tags.isEmpty {
                        ForEach(tags, id: \.self) { tag in
                            HStack {
                                Text(tag)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Button {
                                    tags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(AppTheme.error)
                                }
                            }
                            .listRowBackground(AppTheme.surface)
                        }
                    }
                } header: {
                    Text("Tags")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear.ignoresSafeArea())
            .navigationTitle("Organize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.setFolder(folderText, forPlaylistID: playlist.id)
                        library.setTags(tags, forPlaylistID: playlist.id)
                        dismiss()
                    }
                    .tint(AppTheme.dynamicAccent)
                }
            }
            .onAppear {
                folderText = playlist.folder ?? ""
                tags = playlist.tags
            }
        }
    }

    private func addTag() {
        let trimmed = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        tagText = ""
    }
}

// MARK: - Add Songs Sheet

private struct AddSongsSheet: View {
    let playlist: Playlist

    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    private var filteredSongs: [Song] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.allSongs }
        return library.allSongs.filter { song in
            song.displayName.localizedCaseInsensitiveContains(query)
                || song.artistName.localizedCaseInsensitiveContains(query)
        }
    }

    /// The playlist's current song IDs as a Set, built once per render —
    /// `isInPlaylist` used to look the playlist up and linearly scan its
    /// song IDs four times for every visible row.
    private var memberIDs: Set<String> {
        Set((library.playlists.first(where: { $0.id == playlist.id }) ?? playlist).songIDs)
    }

    var body: some View {
        let memberIDs = self.memberIDs
        func isInPlaylist(_ song: Song) -> Bool { memberIDs.contains(song.id) }
        return NavigationStack {
            List {
                ForEach(filteredSongs) { song in
                    Button {
                        if isInPlaylist(song) {
                            library.removeSong(id: song.id, fromPlaylistID: playlist.id)
                        } else {
                            library.addSong(id: song.id, toPlaylistID: playlist.id)
                        }
                    } label: {
                        HStack {
                            SongRow(
                                song: song,
                                isCurrent: false,
                                showArtwork: true,
                                subtitle: song.artistName
                            )
                            Spacer(minLength: 8)
                            Image(systemName: isInPlaylist(song) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isInPlaylist(song) ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                                .font(.system(size: 22))
                                .animation(LumiMotion.fade(0.15), value: isInPlaylist(song))
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AppTheme.surface.opacity(0.5))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear.ignoresSafeArea())
            .searchable(text: $searchText, prompt: "Search songs")
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(AppTheme.dynamicAccent)
                }
            }
        }
    }
}
