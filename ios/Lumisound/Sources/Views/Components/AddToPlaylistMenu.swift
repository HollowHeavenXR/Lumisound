import SwiftUI

// MARK: - Reusable song context menu content

/// Drop-in context menu content for any song row.
/// Usage: attach `.contextMenu { SongContextMenuContent(song: song) }` to any view,
/// or use the `.songContextMenu(for:)` convenience modifier.
struct SongContextMenuContent: View {
    let song: Song

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @ObservedObject private var ariaLog = AriaActivityLog.shared

    var body: some View {
        // MARK: Revert Aria's Change — only shown when she's actually done
        // something to this specific track (currently: auto-removed a
        // duplicate and kept this copy) that hasn't already been reverted.
        if let action = ariaLog.activeAction(forSurvivingSongID: song.id) {
            Button {
                ariaLog.revertDuplicateRemoved(action, library: library)
            } label: {
                Label("Revert Aria's Change", systemImage: "arrow.uturn.backward")
            }
            Divider()
        }

        // MARK: Favorite / Unfavorite
        Button {
            library.toggleFavorite(songID: song.id)
        } label: {
            let isFav = library.isFavorite(songID: song.id)
            Label(
                isFav ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFav ? "heart.slash" : "heart"
            )
        }

        Divider()

        // MARK: Play Next
        Button {
            player.insertNext(song: song)
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        // MARK: Add to End of Queue
        Button {
            player.appendToQueue(song: song)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        // MARK: Identify Track (AcoustID) — only for imported/downloaded songs
        // with a local file. `persistentID == nil` is the same "is this an
        // imported song, not an Apple Music library track" test
        // `removeImportedSong` documents — Apple Music tracks have a real
        // persistentID and applyMetadataCorrection can't touch them anyway.
        if song.persistentID == nil, song.url?.isFileURL == true {
            Button {
                AcoustIDConfirmCenter.shared.identify(song: song)
            } label: {
                Label("Identify Track", systemImage: "waveform.badge.magnifyingglass")
            }
        }

        // MARK: Convert for Compatibility — only for imported files stuck on a
        // format (opus/webm/ogg) that only plays through the reduced AVPlayer
        // fallback (no EQ/pitch/crossfade/effects). Re-encodes to AAC in place.
        if song.usesCompatibilityFallbackFormat, song.url?.isFileURL == true {
            Button {
                Task { await library.convertImportedSongFormat(songID: song.id) }
            } label: {
                Label("Convert for Compatibility", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        // MARK: Make a Clip — same "local file, not DRM Apple Music" gate as Identify Track
        if song.url?.isFileURL == true {
            Button {
                ClipMakerCenter.shared.present(song: song)
            } label: {
                Label("Make a Clip", systemImage: "scissors")
            }
        }

        Divider()

        // MARK: Add to Playlist submenu
        if !library.playlists.isEmpty {
            LumiMenu {
                ForEach(library.playlists) { playlist in
                    Button {
                        library.addSong(id: song.id, toPlaylistID: playlist.id)
                        ToastCenter.shared.show("Added to \"\(playlist.name)\"", category: .success, icon: "plus.rectangle.on.folder")
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Add to Playlist", systemImage: "plus.rectangle.on.folder")
            }
        }

        // MARK: New Playlist with Song
        Button {
            let playlistName = song.displayName
            library.createPlaylist(name: playlistName)
            // Find by name rather than using .last, which is fragile if the array is sorted
            // or another concurrent mutation has appended to it.
            if let newPlaylist = library.playlists.last(where: { $0.name == playlistName }) {
                library.addSong(id: song.id, toPlaylistID: newPlaylist.id)
            }
            ToastCenter.shared.show("Created playlist \"\(playlistName)\"", category: .success, icon: "folder.badge.plus")
        } label: {
            Label("New Playlist with Song", systemImage: "folder.badge.plus")
        }

    }

}

// MARK: - ViewModifier

private struct SongContextMenuModifier: ViewModifier {
    let song: Song

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    func body(content: Content) -> some View {
        content.contextMenu {
            SongContextMenuContent(song: song)
                .environmentObject(library)
                .environmentObject(player)
        }
    }
}

// MARK: - View extension

extension View {
    /// Attaches the standard song context menu to any view.
    func songContextMenu(for song: Song) -> some View {
        modifier(SongContextMenuModifier(song: song))
    }
}
