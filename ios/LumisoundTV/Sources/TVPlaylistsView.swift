import SwiftUI

// MARK: - TVPlaylistsView (synced playlists — GET /user/playlists)
//
// A playlist's tracks come from whichever device(s) added them and may point
// at an on-device library item (`local_song_id`) instead of a stream URL —
// tvOS has no local file/media library access at all, so those entries are shown but not playable
// here. Entries backed by a Personal Cloud Library upload carry the bridge's
// own `/user/music/stream` URL as `track_url` and play like any other track.
//
// Create/rename/delete/add/remove all go through the bridge's dedicated
// playlist-mutation endpoints (not the wholesale `/user/sync` snapshot push,
// which would also overwrite the user's other settings) — see
// `TVBridgeClient`'s "Playlist mutations" section.

struct TVPlaylistsView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String

    @State private var showNewPlaylist = false
    @State private var renamingPlaylist: TVPlaylist?

    /// The first playlist with something in it gets the hero; the grid holds
    /// the rest so nothing is shown twice.
    private var featured: TVPlaylist? {
        guard let first = client.playlists.first, !first.tracks.isEmpty else { return nil }
        return first
    }

    private var gridPlaylists: [TVPlaylist] {
        featured == nil ? client.playlists : Array(client.playlists.dropFirst())
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                if client.isLoadingPlaylists {
                    TVLoadingState(text: "Loading your playlists…")
                } else if let err = client.playlistsError {
                    TVEmptyState(systemImage: "exclamationmark.icloud",
                                 title: "Couldn't load playlists",
                                 message: err) {
                        Button {
                            Task { await client.fetchPlaylists(token: token) }
                        } label: {
                            TVPillLabel(title: "Try Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                } else if client.playlists.isEmpty {
                    TVEmptyState(systemImage: "music.note.list",
                                 title: "No playlists yet",
                                 message: "Make one here, or on your iPhone — playlists sync across your devices.") {
                        Button {
                            showNewPlaylist = true
                        } label: {
                            TVPillLabel(title: "New Playlist", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                } else {
                    content(width: geo.size.width)
                }
            }
        }
        .task {
            if client.playlists.isEmpty { await client.fetchPlaylists(token: token) }
        }
        .sheet(isPresented: $showNewPlaylist) {
            TVPlaylistNameSheet(title: "New Playlist", initialName: "") { name in
                _ = await client.createPlaylist(name: name, token: token)
            }
        }
        .sheet(item: $renamingPlaylist) { playlist in
            TVPlaylistNameSheet(title: "Rename Playlist", initialName: playlist.name) { name in
                _ = await client.renamePlaylist(id: playlist.id, name: name, token: token)
            }
        }
    }

    private func content(width: CGFloat) -> some View {
        // Definite cell widths, for the same reason as TVCardGrid — that view
        // owns its own ScrollView, so it can't sit under the hero here.
        let count = max(2, min(4, TVAudioSettings.shared.gridColumns + 1))
        let spacing: CGFloat = 40
        let usable = width - TVMetrics.margin * 2 - spacing * CGFloat(count - 1)
        let cell = max(140, usable / CGFloat(count))

        return VStack(alignment: .leading, spacing: TVMetrics.section) {
            VStack(alignment: .leading, spacing: 0) {
                TVScreenTitle(title: "Playlists",
                              detail: "\(client.playlists.count) \(client.playlists.count == 1 ? "playlist" : "playlists")")
                if let featured {
                    featuredHero(featured)
                }
            }

            VStack(alignment: .leading, spacing: 24) {
                TVSectionHeader(title: featured == nil ? "Your Playlists" : "More Playlists")
                    .padding(.horizontal, TVMetrics.margin)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: count),
                    alignment: .leading,
                    spacing: spacing + 16
                ) {
                    newPlaylistCard(width: cell)
                    ForEach(gridPlaylists) { playlist in
                        NavigationLink {
                            TVPlaylistDetailView(client: client, token: token, playlist: playlist)
                        } label: {
                            playlistCard(playlist, width: cell)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .contextMenu { playlistMenu(playlist) }
                    }
                }
                .padding(.horizontal, TVMetrics.margin)
            }
        }
        .padding(.bottom, 80)
    }

    @ViewBuilder
    private func playlistMenu(_ playlist: TVPlaylist) -> some View {
        Button {
            renamingPlaylist = playlist
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) {
            Task { await client.deletePlaylist(id: playlist.id, token: token) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func newPlaylistCard(width: CGFloat) -> some View {
        Button {
            showNewPlaylist = true
        } label: {
            TVArtworkCardLabel(title: "New Playlist", subtitle: "Start from scratch", width: width) {
                ZStack {
                    Color.white.opacity(0.04)
                    RoundedRectangle(cornerRadius: TVMetrics.cardCorner, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25),
                                      style: StrokeStyle(lineWidth: 2, dash: [12, 10]))
                    Image(systemName: "plus")
                        .font(.system(size: width * 0.2, weight: .semibold))
                        .foregroundStyle(TVPalette.brandVertical)
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    /// The first playlist as the hero — same component Home uses.
    @ViewBuilder
    private func featuredHero(_ playlist: TVPlaylist) -> some View {
        let queue = playlist.tracks.compactMap { client.playable(from: $0, token: token) }
        if let first = queue.first {
            TVHeroBanner(
                eyebrow: "Featured Playlist",
                title: playlist.name,
                subtitle: playlist.description.flatMap { $0.isEmpty ? nil : $0 }
                    ?? tvSongCount(playlist.tracks.count),
                art: {
                    TVPlaylistArtwork(name: playlist.name,
                                      artworkURLs: client.artworkURLs(for: playlist, token: token),
                                      token: token)
                },
                playButton: {
                    HStack(spacing: 22) {
                        NavigationLink(value: TVPlayContext(queue: queue, startID: first.id)) {
                            TVPillLabel(title: "Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        NavigationLink {
                            TVPlaylistDetailView(client: client, token: token, playlist: playlist)
                        } label: {
                            TVPillLabel(title: "Open", systemImage: "list.bullet", style: .secondary)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }
            )
        }
    }

    private func playlistCard(_ playlist: TVPlaylist, width: CGFloat) -> some View {
        TVArtworkCardLabel(title: playlist.name, subtitle: tvSongCount(playlist.tracks.count), width: width) {
            TVPlaylistArtwork(name: playlist.name,
                              artworkURLs: client.artworkURLs(for: playlist, token: token),
                              token: token)
        }
    }
}

// MARK: - Playlist detail

struct TVPlaylistDetailView: View {
    @ObservedObject var client: TVBridgeClient
    let token: String
    let playlist: TVPlaylist

    /// Re-reads the live copy out of `client.playlists` so a track removal
    /// (which mutates that array) is reflected here without a separate fetch.
    private var current: TVPlaylist {
        client.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    private func meta(playableCount: Int, totalCount: Int) -> String {
        if playableCount == totalCount { return tvSongCount(totalCount) }
        return "\(tvSongCount(totalCount)) · \(playableCount) playable on Apple TV"
    }

    var body: some View {
        // Computed ONCE per render and threaded through explicitly below —
        // `current`/`queue` were both computed `var`s read fresh by `meta`,
        // the Play button, AND once per row inside `row(for:)`'s `ForEach`,
        // so a K-track playlist's render recomputed the full `compactMap`
        // (itself O(K), and O(K · client.library.count) on a cache miss via
        // `client.playable(from:)`'s `libraryMatch` fallback) K+2 times —
        // O(K²) total for one screen draw. Same shape as the old
        // `smartTempoOrder` bug fixed on the main iOS app.
        let current = current
        let queue: [TVPlayable] = current.tracks.compactMap { client.playable(from: $0, token: token) }
        let urls = client.artworkURLs(for: current, token: token)
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                TVDetailHeader(
                    eyebrow: "Playlist",
                    title: current.name,
                    subtitle: current.description,
                    meta: meta(playableCount: queue.count, totalCount: current.tracks.count)
                ) {
                    TVPlaylistArtwork(name: current.name, artworkURLs: urls, token: token, showsTitle: false)
                } actions: {
                    if let first = queue.first {
                        NavigationLink(value: TVPlayContext(queue: queue, startID: first.id)) {
                            TVPillLabel(title: "Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }

                if current.tracks.isEmpty {
                    TVEmptyState(systemImage: "music.note.list",
                                 title: "This playlist is empty",
                                 message: "Press and hold Select on any song and choose Add to Playlist.")
                } else {
                    TVTrackList {
                        ForEach(current.tracks) { track in
                            row(for: track, queue: queue)
                        }
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .background(TVCollectionBackdrop(url: urls.first, token: token))
    }

    @ViewBuilder
    private func row(for track: TVPlaylistTrack, queue: [TVPlayable]) -> some View {
        let playable = client.playable(from: track, token: token)
        let label = TVTrackRow(
            artworkURL: playable?.artworkURL,
            token: token,
            title: track.title,
            artist: track.artist ?? "",
            detail: track.durationSeconds.flatMap { Double($0).tvDurationText },
            unavailableReason: playable == nil ? "Only on iPhone" : nil
        )

        Group {
            if let playable {
                NavigationLink(value: TVPlayContext(queue: queue, startID: playable.id)) {
                    label
                }
            } else {
                // Still focusable, so the context menu (Remove) can reach it —
                // a dead row you can see but not act on is worse than one that
                // explains itself.
                Button {} label: { label }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .contextMenu {
            Button(role: .destructive) {
                Task { await client.removeTrack(track.id, fromPlaylist: playlist.id, token: token) }
            } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }
        }
    }
}

// MARK: - TVPlaylistNameSheet
//
// Shared name-entry sheet for both create and rename. A plain `TextField` in
// a `List` (not a `TextField` embedded in `.alert`, which tvOS's on-screen
// keyboard flow doesn't drive reliably) — same pattern as the "New Playlist"
// row in `TVAddToPlaylistSheet`.

struct TVPlaylistNameSheet: View {
    let title: String
    let initialName: String
    let onSave: (String) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            List {
                TextField("Playlist name", text: $name)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            await onSave(name.trimmingCharacters(in: .whitespaces))
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { name = initialName }
    }
}
