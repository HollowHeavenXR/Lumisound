import SwiftUI
import MediaPlayer
import UIKit

// MARK: - Folders Tab
//
// Groups imported songs by the first subdirectory of "Imported Music" that
// contains them. Unlike the Albums tab, grouping is done by filesystem path —
// every song inside a folder shows up here regardless of its album metadata tag.
// The actual grouping logic lives in `MusicFolderService.localFolderGroups(from:)`
// so `LibraryHubView`'s speed-dial folder tiles use the exact same folder set.

private typealias FolderEntry = MusicFolderService.LocalFolderGroup

struct FoldersTab: View {
    @EnvironmentObject private var library: LibraryManager
    @AppStorage("library_folders_columns") private var columns: Int = 2

    @State private var folders: [FolderEntry] = []
    /// Which folders' inline "peek" is expanded — owned here, not by each
    /// `FolderGridCell`, since the toggle button has to live OUTSIDE the
    /// `NavigationLink`'s label as a sibling overlay (see the ForEach below):
    /// a `Button` nested inside a `NavigationLink`'s label is an unreliable
    /// pattern on iOS — the outer link's tap recognizer can swallow the
    /// inner button's taps — so the actual toggle control can't live inside
    /// `FolderGridCell` itself the way a first draft of this had it.
    @State private var expandedFolderIDs: Set<String> = []

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
    }

    var body: some View {
        ScrollView {
            if folders.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "No folders",
                    message: "Create subfolders inside \"Imported Music\" in the Files app to organise your tracks."
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(folders) { folder in
                        ZStack(alignment: .topTrailing) {
                            NavigationLink {
                                LocalFolderDetailView(folderName: folder.id, folderURL: folder.dirURL)
                            } label: {
                                FolderGridCell(folder: folder, isExpanded: expandedFolderIDs.contains(folder.id))
                            }
                            .buttonStyle(.plain)

                            // Drawn on top as a sibling (not inside the
                            // NavigationLink's label) so it reliably gets its
                            // own taps instead of the link swallowing them —
                            // see `expandedFolderIDs`'s doc comment.
                            Button {
                                withAnimation(LumiMotion.snap) {
                                    if expandedFolderIDs.contains(folder.id) {
                                        expandedFolderIDs.remove(folder.id)
                                    } else {
                                        expandedFolderIDs.insert(folder.id)
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .rotationEffect(.degrees(expandedFolderIDs.contains(folder.id) ? 180 : 0))
                                    .padding(6)
                                    // Flat color, not `adaptiveGlass` — this
                                    // is a real backdrop blur on iOS 26+, and
                                    // paying for one on every single grid
                                    // cell's decorative chevron (20-50+
                                    // visible/near-visible at once) is a real,
                                    // measured contributor to scroll stutter
                                    // and sustained GPU/thermal load. A flat
                                    // backing reads the same for a glyph this
                                    // small.
                                    .background(Color.black.opacity(0.4), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                // Extra clearance below the last row — see SongsTab's
                // identical fix.
                .padding(.bottom, 190)
            }
        }
        .background(Color.clear.ignoresSafeArea())
        .task(id: library.allSongs.count) {
            // Grouping is O(n) over the whole library and, for the big
            // libraries this tab exists for, easily large enough to be a
            // visible main-thread stall — see `rebuildAllSongs()`'s identical
            // off-actor pattern. `allSongs.count` changes once per rebuild
            // *during* a scan (song-by-song, every ~0.1s — see
            // `rebuildAllSongs`'s debounce), so without this, a long import
            // repeatedly re-blocked the main thread doing a full re-group,
            // which is what made scrolling here freeze and snap back to the
            // top while a scan was still running.
            let songs = library.allSongs
            let grouped = await Task.detached(priority: .userInitiated) {
                MusicFolderService.localFolderGroups(from: songs)
            }.value
            guard !Task.isCancelled else { return }
            folders = grouped
        }
        .toolbar {
            // Mirrors SongsTab's column-toggle buttons (rather than a Menu) so
            // switching the Folders layout works the same, directly-tappable way.
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    columns = 1
                } label: {
                    Image(systemName: "rectangle.grid.1x2")
                        .foregroundStyle(columns == 1 ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                }
                .buttonStyle(.plain)

                Button {
                    columns = 2
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(columns == 2 ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                }
                .buttonStyle(.plain)

                Button {
                    columns = 3
                } label: {
                    Image(systemName: "square.grid.3x3")
                        .foregroundStyle(columns == 3 ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FolderGridCell: View {
    let folder: FolderEntry
    /// Owned by `FoldersTab` (see `expandedFolderIDs`'s doc comment there) —
    /// this view only reads it to decide whether to show the inline peek;
    /// the actual toggle button lives outside this view entirely.
    let isExpanded: Bool

    private var trackCount: Int { folder.songs.count }
    /// Up to four representative tracks for the collage — a real folder full
    /// of mismatched album art reads as a proper "shelf" of what's inside,
    /// not just one arbitrarily-first track's cover standing in for the
    /// whole folder the way the old single-image tile did.
    private var collageSongs: [Song] { Array(folder.songs.prefix(4)) }

    // Custom, device-local folder cover art (see FolderCoverArtService) —
    // read once on appear/whenever this folder's identity changes rather
    // than as a plain computed property: `cover(for:)` does a dictionary
    // lookup (cheap) but also decodes+caches from disk on a cold cache
    // miss, which isn't free to repeat on every SwiftUI body pass for a
    // grid full of these cells. LocalFolderDetailView already shows
    // whatever custom cover is set for a folder; this grid never checked
    // for one at all, so a folder with a custom cover reverted to its
    // default (first song's artwork / folder glyph) the moment you backed
    // out to the grid.
    @State private var customCover: UIImage? = nil
    // Observed so a cover change made elsewhere (LocalFolderDetailView,
    // while this cell was already mounted and off the `.onAppear` path)
    // still reaches this cell — see `FolderCoverArtService.changeCount`'s
    // doc comment.
    @ObservedObject private var coverService = FolderCoverArtService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // GeometryReader sizes the artwork to the actual column width — like
            // SongGridCell, a hardcoded size here clips (3-column) or under-fills
            // (1-column) the cell depending on how many columns are selected.
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.surface)

                    if let customCover {
                        Image(uiImage: customCover)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.width)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else if collageSongs.count > 1 {
                        collage(songs: collageSongs, side: geo.size.width)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else if let song = collageSongs.first {
                        ArtworkThumbnail(song: song, size: geo.size.width)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        Image(systemName: "folder.fill")
                            .font(.system(size: geo.size.width * 0.25))
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }

                    // Folder badge overlay — the real expand/collapse toggle
                    // is a separate button drawn by `FoldersTab` on top of
                    // this whole cell (top-trailing corner), not here; see
                    // `isExpanded`'s doc comment for why.
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "folder.fill")
                                .font(.caption2)
                            Spacer()
                        }
                        .padding(6)
                        // Flat color — see the chevron button's identical
                        // change above for why `adaptiveGlass`'s real
                        // backdrop blur isn't worth it at grid scale here.
                        .background(Color.black.opacity(0.35), in: Rectangle())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            // `.compositingGroup()` flattens this whole layered, frequently-
            // changing subtree (async artwork fade-in, collage, badge) into
            // one rendered layer BEFORE the shadow is computed. Without it,
            // `.shadow` on dynamic non-opaque content forces its own
            // offscreen render pass to derive the shadow's alpha mask —
            // paid independently by every visible/near-visible grid cell on
            // every redraw during a scroll.
            .compositingGroup()
            .shadow(color: .black.opacity(0.3), radius: 8, y: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.id)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)

                Text("\(trackCount) \(trackCount == 1 ? "track" : "tracks")")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 2)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(folder.songs.prefix(4)) { song in
                        Text(song.displayName)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                    if trackCount > 4 {
                        Text("+ \(trackCount - 4) more")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            Task { customCover = await FolderCoverArtService.shared.cover(for: folder.dirURL) }
        }
        .onChange(of: coverService.changeCount) { _ in
            Task { customCover = await FolderCoverArtService.shared.cover(for: folder.dirURL) }
        }
    }

    /// A 2×2 grid of up to 4 tracks' artwork, quarter-sized — the "shelf of
    /// what's actually inside" collage used when a folder has more than one
    /// track and no custom cover set.
    private func collage(songs: [Song], side: CGFloat) -> some View {
        let half = side / 2
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                collageCell(songs, 0, half)
                collageCell(songs, 1, half)
            }
            HStack(spacing: 0) {
                collageCell(songs, 2, half)
                collageCell(songs, 3, half)
            }
        }
        .frame(width: side, height: side)
    }

    @ViewBuilder
    private func collageCell(_ songs: [Song], _ index: Int, _ side: CGFloat) -> some View {
        if index < songs.count {
            ArtworkThumbnail(song: songs[index], size: side)
        } else {
            Rectangle().fill(AppTheme.surface).frame(width: side, height: side)
        }
    }
}
