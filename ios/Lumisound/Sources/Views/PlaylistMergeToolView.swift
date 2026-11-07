import SwiftUI

/// Compares two playlists — what's in both, and what's unique to each —
/// and lets you save any of the three resulting sets as a new playlist.
/// Pure client-side library-management tool, no server involvement beyond
/// whatever `LibraryManager.createPlaylist` already does for any new
/// playlist.
struct PlaylistMergeToolView: View {
    @EnvironmentObject private var library: LibraryManager

    @State private var playlistAID: UUID?
    @State private var playlistBID: UUID?

    private var playlistA: Playlist? {
        playlistAID.flatMap { id in library.playlists.first { $0.id == id } }
    }

    private var playlistB: Playlist? {
        playlistBID.flatMap { id in library.playlists.first { $0.id == id } }
    }

    private var inBoth: [Song.ID] {
        guard let a = playlistA, let b = playlistB else { return [] }
        let bSet = Set(b.songIDs)
        return a.songIDs.filter { bSet.contains($0) }
    }

    private var onlyInA: [Song.ID] {
        guard let a = playlistA, let b = playlistB else { return [] }
        let bSet = Set(b.songIDs)
        return a.songIDs.filter { !bSet.contains($0) }
    }

    private var onlyInB: [Song.ID] {
        guard let a = playlistA, let b = playlistB else { return [] }
        let aSet = Set(a.songIDs)
        return b.songIDs.filter { !aSet.contains($0) }
    }

    var body: some View {
        List {
            Section("Compare") {
                LumiPicker("Playlist A", selection: $playlistAID) {
                    Text("Choose one").lumiOptionLabel("Choose one").tag(UUID?.none)
                    ForEach(library.playlists) { playlist in
                        Text(playlist.name).lumiOptionLabel(String(describing: playlist.name)).tag(Optional(playlist.id))
                    }
                }
                LumiPicker("Playlist B", selection: $playlistBID) {
                    Text("Choose one").lumiOptionLabel("Choose one").tag(UUID?.none)
                    ForEach(library.playlists) { playlist in
                        Text(playlist.name).lumiOptionLabel(String(describing: playlist.name)).tag(Optional(playlist.id))
                    }
                }
            }
            .listRowBackground(tintedRowBackground(.pink))

            if let playlistA, let playlistB, playlistA.id == playlistB.id {
                Section {
                    Text("Choose two different playlists to compare.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(Color.clear)
            } else if playlistA != nil, playlistB != nil {
                resultSection(
                    title: "In Both",
                    subtitle: "\(inBoth.count) track\(inBoth.count == 1 ? "" : "s")",
                    songIDs: inBoth,
                    defaultName: "\(playlistA?.name ?? "") ∩ \(playlistB?.name ?? "")"
                )
                resultSection(
                    title: "Only in \(playlistA?.name ?? "A")",
                    subtitle: "\(onlyInA.count) track\(onlyInA.count == 1 ? "" : "s")",
                    songIDs: onlyInA,
                    defaultName: "\(playlistA?.name ?? "") only"
                )
                resultSection(
                    title: "Only in \(playlistB?.name ?? "B")",
                    subtitle: "\(onlyInB.count) track\(onlyInB.count == 1 ? "" : "s")",
                    songIDs: onlyInB,
                    defaultName: "\(playlistB?.name ?? "") only"
                )
            } else {
                Section {
                    EmptyStateView(
                        icon: "rectangle.2.swap",
                        title: "Pick Two Playlists",
                        message: "Choose Playlist A and Playlist B above to see what overlaps and what's unique to each."
                    )
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Compare Playlists")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func resultSection(title: String, subtitle: String, songIDs: [Song.ID], defaultName: String) -> some View {
        Section {
            if songIDs.isEmpty {
                Text("Nothing here.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                SaveAsPlaylistRow(songIDs: songIDs, defaultName: defaultName)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text(subtitle)
            }
            .textCase(nil)
        }
        .listRowBackground(tintedRowBackground(.pink))
    }
}

/// A "Save as New Playlist" row with an inline name field — shared by all
/// three result sections above.
private struct SaveAsPlaylistRow: View {
    let songIDs: [Song.ID]
    let defaultName: String

    @EnvironmentObject private var library: LibraryManager
    @State private var name: String = ""
    @State private var saved = false

    var body: some View {
        HStack(spacing: 10) {
            TextField("Playlist name", text: Binding(
                get: { name.isEmpty ? defaultName : name },
                set: { name = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            Button {
                let resolvedName = name.isEmpty ? defaultName : name
                _ = library.createPlaylist(name: resolvedName, songIDs: songIDs)
                saved = true
                ToastCenter.shared.show("Saved \"\(resolvedName)\"", category: .success, icon: "checkmark.circle.fill")
            } label: {
                Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(saved ? .green : AppTheme.dynamicAccent)
            }
            .buttonStyle(.plain)
        }
    }
}
