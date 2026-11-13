import SwiftUI
import UIKit
import PhotosUI

// MARK: - LocalFolderDetailView
//
// Shows every song whose file lives anywhere inside `folderURL`, matched by
// filesystem path prefix rather than album metadata.  This means all tracks
// the user placed in a folder are visible here — regardless of whether their
// embedded album tag matches the folder name or not.

// MARK: - Sort Order

private enum FolderSortOrder: String, CaseIterable {
    case trackOrder = "Track Order"
    case title      = "Title"
    case artist     = "Artist"
    case duration   = "Duration"
    case dateAdded  = "Date Added"
}

struct LocalFolderDetailView: View {
    let folderName: String
    let folderURL: URL

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    @AppStorage("folderDetail_columns") private var columns: Int = 1
    @AppStorage("folderDetail_sortOrder") private var sortOrderRaw: String = FolderSortOrder.trackOrder.rawValue

    private var sortOrder: FolderSortOrder {
        FolderSortOrder(rawValue: sortOrderRaw) ?? .trackOrder
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
    }

    @State private var songs: [Song] = []

    // Multi-select (list layout only — mirrors LibraryView/SongsTab, which
    // also drop out of selection when switching to a grid layout).
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

    // Total on-disk size across every song in the folder — computed off the
    // main actor (same pattern as DownloadsManagementView.computeSizes())
    // since it means an attributesOfItem(atPath:) call per file.
    @State private var totalSizeBytes: Int64 = 0
    @State private var sizeComputeTask: Task<Void, Never>?

    // Custom, device-local folder cover art (see FolderCoverArtService).
    @State private var customCover: UIImage? = nil

    // Sheets
    @State private var showDuplicatesSheet = false
    @State private var showCreatePlaylistSheet = false

    /// Off the render path AND off the main actor (see `.task(id:)` below) so
    /// large libraries don't re-filter the entire song list, synchronously
    /// on the main thread, on every folder open — this ran an
    /// `url.standardizedFileURL.path` resolution + string-prefix compare per
    /// song in the WHOLE library, every single navigation push into any
    /// folder, which is exactly the shape of stall `FoldersTab`'s own grid
    /// load was fixed for (see that file). Filtering only — sorting is
    /// applied separately by `sortedResult(songs:sortOrder:)` so changing the
    /// sort order doesn't require re-scanning `library.allSongs`.
    private static func computeSongs(allSongs: [Song], folderURL: URL) -> [Song] {
        let prefix = folderURL.standardizedFileURL.path + "/"
        return allSongs.filter { song in
            guard let url = song.url else { return false }
            return url.standardizedFileURL.path.hasPrefix(prefix)
        }
    }

    /// `songs`, ordered per the user's chosen `sortOrder` — recomputed only
    /// when `songs` or `sortOrder` actually changes (see `refreshSortedSongs()`),
    /// not a plain computed property. This view's body references it up to
    /// half a dozen times (Play/Shuffle buttons, the row ForEach, the
    /// duplicates/export sheets); a computed property would have re-sorted
    /// the whole list from scratch on every single one of those reads, on
    /// every body re-evaluation — a real, easily-avoidable CPU cost that
    /// scales with folder size (noticeable once a folder holds hundreds of
    /// tracks).
    @State private var sortedSongs: [Song] = []

    /// Track Order split per album, when the folder holds more than one real
    /// album — see `albumSections(for:)`. Empty for every other sort order,
    /// and for single-album folders, which list flat.
    @State private var albumSections: [FolderAlbumSection] = []

    /// Up to four songs with distinct artwork for the header mosaic.
    @State private var collageSongs: [Song] = []

    /// Off the main actor, same reasoning as `computeSongs` above — this is a
    /// full sort (plus, for track order, a `Dictionary(grouping:)` and two
    /// nested sorts) of the folder's songs, previously run synchronously on
    /// every folder open and every sort-order change.
    private static func sortedResult(songs: [Song], sortOrder: FolderSortOrder) -> (sorted: [Song], albumSections: [FolderAlbumSection]) {
        switch sortOrder {
        case .trackOrder:
            // Album by album, each in its own track order. Sorting by track
            // number across the whole folder interleaved albums (every
            // album's track 1, then every track 2, …) as soon as a folder
            // held more than one.
            let sections = Self.albumSections(for: songs)
            return (sections.flatMap(\.songs), sections.count > 1 ? sections : [])
        case .title:
            return (songs.sortedByDisplayName(), [])
        case .artist:
            let sorted = songs.sorted {
                let cmp = $0.artistName.localizedCaseInsensitiveCompare($1.artistName)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return (sorted, [])
        case .duration:
            return (songs.sorted { $0.duration > $1.duration }, [])
        case .dateAdded:
            let sorted = songs.sorted {
                switch ($0.dateAdded, $1.dateAdded) {
                case let (a?, b?):
                    return a > b
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
            }
            return (sorted, [])
        }
    }

    /// Groups by album (folder-inferred "albums" collapse into one "Unknown
    /// Album" group, via `groupableAlbumName`), albums alphabetically with
    /// Unknown Album last, tracks by number then title.
    private static func albumSections(for songs: [Song]) -> [FolderAlbumSection] {
        let grouped = Dictionary(grouping: songs, by: \.groupableAlbumName)
        return grouped
            .map { name, albumSongs in
                let tracks = albumSongs.sorted {
                    if $0.trackNumber != $1.trackNumber {
                        // Untagged (0) tracks after numbered ones.
                        if $0.trackNumber == 0 { return false }
                        if $1.trackNumber == 0 { return true }
                        return $0.trackNumber < $1.trackNumber
                    }
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                return FolderAlbumSection(title: name, songs: tracks)
            }
            .sorted { lhs, rhs in
                if lhs.isUnknown != rhs.isUnknown { return !lhs.isUnknown }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    /// "A, B & C" / "A, B & 3 more", most-represented artists first.
    private var artistSummary: String? {
        var counts: [String: Int] = [:]
        for song in songs where !song.artist.trimmingCharacters(in: .whitespaces).isEmpty {
            counts[song.artistName, default: 0] += 1
        }
        let names = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        case 3: return "\(names[0]), \(names[1]) & \(names[2])"
        default: return "\(names[0]), \(names[1]) & \(names.count - 2) more"
        }
    }

    private var albumCount: Int {
        Set(songs.map(\.groupableAlbumName)).count
    }

    private var totalDurationText: String {
        let total = Int(songs.reduce(0) { $0 + $1.duration }.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private var totalSizeText: String {
        CacheManagerService.formattedSize(totalSizeBytes)
    }

    private func toggleSelection(_ song: Song) {
        if selectedIDs.contains(song.id) {
            selectedIDs.remove(song.id)
        } else {
            selectedIDs.insert(song.id)
        }
    }

    /// Off-actor total-size scan across every song currently in the folder —
    /// mirrors DownloadsManagementView.computeSizes()'s pattern exactly
    /// (Task.detached + attributesOfItem(atPath:) per file, hopping back to
    /// the main actor only for the final assignment).
    private func recomputeTotalSize() {
        sizeComputeTask?.cancel()
        let currentSongs = songs
        sizeComputeTask = Task.detached(priority: .utility) {
            var total: Int64 = 0
            for song in currentSongs {
                if Task.isCancelled { return }
                guard let url = song.url else { continue }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let number = attrs[.size] as? NSNumber {
                    total += number.int64Value
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.totalSizeBytes = total
            }
        }
    }

    var body: some View {
        Group {
            if columns == 1 {
                List {
                    Section {
                        headerAndControls
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listSectionSeparator(.hidden)

                    if sortedSongs.isEmpty {
                        Section {
                            EmptyStateView(icon: "folder", title: "Empty folder", message: "No audio files found inside \"\(folderName)\".")
                                .listRowBackground(Color.clear)
                        }
                    } else if !albumSections.isEmpty {
                        // One section per album, each under a small album
                        // header — see `albumSections(for:)`.
                        ForEach(albumSections) { section in
                            Section {
                                ForEach(section.songs) { song in
                                    songListRow(song, subtitle: trackSubtitle(for: song))
                                }
                            } header: {
                                FolderAlbumHeader(section: section) {
                                    player.setQueue(section.songs, startIndex: 0, autoplay: true)
                                }
                            }
                            .listSectionSeparator(.hidden)
                        }
                    } else {
                        // Track list — the same SongRow the Songs tab uses, so
                        // rows honour the user's chosen row style everywhere.
                        Section {
                            ForEach(sortedSongs) { song in
                                songListRow(song, subtitle: nil)
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }

                    if !sortedSongs.isEmpty {
                        Section {
                            summaryFooter
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listSectionSeparator(.hidden)
                    }
                }
                // .plain to match the main Library's edge-to-edge list.
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        headerAndControls

                        if sortedSongs.isEmpty {
                            EmptyStateView(icon: "folder", title: "Empty folder", message: "No audio files found inside \"\(folderName)\".")
                                .padding(.top, 40)
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(sortedSongs) { song in
                                    Button {
                                        player.play(song: song, in: sortedSongs)
                                    } label: {
                                        SongGridCell(song: song, isCurrent: player.currentSong?.id == song.id)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)

                            summaryFooter
                        }
                    }
                    // Extra clearance below the last row — see SongsTab's
                    // identical fix (MiniPlayerBar + tab bar clearance).
                    .padding(.bottom, 190)
                }
            }
        }
        // Own gallery/theme background — a pushed detail view doesn't inherit
        // the Library root's background, so a clear background fell back to the
        // system black (the "folders use a different dark UI" bug).
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle(folderName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                FolderSelectionActionBar(
                    selectedCount: selectedIDs.count,
                    onAddToPlaylist: { playlistID in
                        library.addSongs(ids: selectedIDs, toPlaylistID: playlistID)
                        isSelecting = false
                        selectedIDs.removeAll()
                    },
                    onAddToQueue: {
                        let toQueue = sortedSongs.filter { selectedIDs.contains($0.id) }
                        for song in toQueue { player.appendToQueue(song: song) }
                        ToastCenter.shared.show(
                            "Added \(toQueue.count) song\(toQueue.count == 1 ? "" : "s") to queue",
                            category: .success, icon: "text.badge.plus"
                        )
                        isSelecting = false
                        selectedIDs.removeAll()
                    },
                    onFavorite: {
                        library.addFavorites(ids: selectedIDs)
                        isSelecting = false
                        selectedIDs.removeAll()
                    },
                    onDelete: {
                        library.removeImportedSongs(ids: selectedIDs)
                        isSelecting = false
                        selectedIDs.removeAll()
                    },
                    onCancel: {
                        isSelecting = false
                        selectedIDs.removeAll()
                    }
                )
                .environmentObject(library)
            } else {
                MiniPlayerBar()
            }
        }
        .task(id: library.allSongs.count) {
            let allSongs = library.allSongs
            let url = folderURL
            let order = sortOrder
            let (filtered, result) = await Task.detached(priority: .userInitiated) {
                let filtered = Self.computeSongs(allSongs: allSongs, folderURL: url)
                return (filtered, Self.sortedResult(songs: filtered, sortOrder: order))
            }.value
            guard !Task.isCancelled else { return }
            songs = filtered
            sortedSongs = result.sorted
            albumSections = result.albumSections
            collageSongs = library.collageSongs(from: songs)
            recomputeTotalSize()
        }
        .onAppear {
            Task { customCover = await FolderCoverArtService.shared.cover(for: folderURL) }
        }
        .onChange(of: sortOrderRaw) { _ in
            let currentSongs = songs
            let order = sortOrder
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Self.sortedResult(songs: currentSongs, sortOrder: order)
                }.value
                guard !Task.isCancelled else { return }
                sortedSongs = result.sorted
                albumSections = result.albumSections
            }
        }
        .onChange(of: columns) { newValue in
            // Multi-select only applies to the single-column List layout —
            // drop out of it if the user switches to grid mid-selection
            // (mirrors LibraryView's identical songColumns guard).
            if isSelecting && newValue != 1 {
                isSelecting = false
                selectedIDs.removeAll()
            }
        }
        .sheet(isPresented: $showDuplicatesSheet) {
            FolderDuplicatesSheet(songs: sortedSongs)
                .environmentObject(library)
                .environmentObject(player)
        }
        .sheet(isPresented: $showCreatePlaylistSheet) {
            FolderExportPlaylistSheet(
                defaultName: folderName,
                onCreate: { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let ids = sortedSongs.map(\.id)
                    library.createPlaylist(name: trimmed, songIDs: ids)
                    ToastCenter.shared.show(
                        "Created playlist \"\(trimmed)\" with \(ids.count) song\(ids.count == 1 ? "" : "s")",
                        category: .success, icon: "music.note.list"
                    )
                    showCreatePlaylistSheet = false
                },
                onCancel: { showCreatePlaylistSheet = false }
            )
        }
        // Sort and layout moved out of the toolbar into the inline controls
        // row under the header; the toolbar keeps Select and the ⋯ menu.
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(isSelecting ? "Done" : "Select") {
                    if isSelecting {
                        isSelecting = false
                        selectedIDs.removeAll()
                    } else {
                        isSelecting = true
                        columns = 1
                    }
                }
                .tint(AppTheme.dynamicAccent)
                .disabled(songs.isEmpty)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                LumiMenu {
                    Button {
                        showCreatePlaylistSheet = true
                    } label: {
                        Label("New Playlist from Folder", systemImage: "music.note.list")
                    }
                    .disabled(songs.isEmpty)

                    Button {
                        showDuplicatesSheet = true
                    } label: {
                        Label("Find Duplicates in Folder", systemImage: "doc.on.doc")
                    }
                    .disabled(songs.count < 2)

                    if customCover != nil {
                        Divider()
                        Button(role: .destructive) {
                            FolderCoverArtService.shared.removeCover(for: folderURL)
                            customCover = nil
                        } label: {
                            Label("Remove Folder Cover", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(AppTheme.dynamicAccent)
            }
        }
    }

    // MARK: Header, actions and controls

    private var headerAndControls: some View {
        VStack(spacing: 18) {
            FolderDetailHeaderView(
                folderName: folderName,
                folderURL: folderURL,
                representativeSong: songs.first,
                collageSongs: collageSongs,
                artistSummary: artistSummary,
                songCount: songs.count,
                albumCount: albumCount,
                totalDurationText: totalDurationText,
                totalSizeText: totalSizeText,
                customCover: $customCover
            )

            actionButtons
                .padding(.horizontal, 16)

            controlsRow
                .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                player.setQueue(sortedSongs, startIndex: 0, autoplay: true)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(AppTheme.dynamicAccentGradient, in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                player.setQueue(songs.smartShuffled(), startIndex: 0, autoplay: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .adaptiveGlass(tint: AppTheme.dynamicAccent.opacity(0.12), in: Capsule(), fallback: AppTheme.surface)
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                for song in sortedSongs { player.appendToQueue(song: song) }
                ToastCenter.shared.show(
                    "Added \(sortedSongs.count) song\(sortedSongs.count == 1 ? "" : "s") to queue",
                    category: .success, icon: "text.badge.plus"
                )
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.headline)
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .frame(width: 48, height: 48)
                    .adaptiveGlass(tint: AppTheme.dynamicAccent.opacity(0.12), in: Circle(), fallback: AppTheme.surface)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Add folder to queue")
        }
        .disabled(songs.isEmpty)
        .opacity(songs.isEmpty ? 0.5 : 1)
    }

    /// Sort on the left, list/grid on the right — both used to be toolbar
    /// items (five in all, three of them bare layout icons).
    private var controlsRow: some View {
        HStack {
            LumiMenu {
                ForEach(FolderSortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrderRaw = order.rawValue
                    } label: {
                        if sortOrder == order {
                            Label(order.rawValue, systemImage: "checkmark")
                        } else {
                            Text(order.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(sortOrder.rawValue)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(0.7))
            }

            Spacer()

            HStack(spacing: 2) {
                layoutButton(columns: 1, icon: "list.bullet", label: "List")
                layoutButton(columns: 2, icon: "square.grid.2x2", label: "Two-column grid")
                layoutButton(columns: 3, icon: "square.grid.3x3", label: "Three-column grid")
            }
            .padding(3)
            .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(0.7))
        }
    }

    private func layoutButton(columns target: Int, icon: String, label: String) -> some View {
        Button {
            withAnimation(LumiMotion.fade(0.2)) { columns = target }
        } label: {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(columns == target ? Color.white : AppTheme.textSecondary)
                .frame(width: 32, height: 26)
                .background {
                    if columns == target {
                        Capsule().fill(AppTheme.dynamicAccent)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(columns == target ? .isSelected : [])
    }

    private var summaryFooter: some View {
        Text("\(songs.count) \(songs.count == 1 ? "song" : "songs") · \(totalDurationText) · \(totalSizeText)")
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    /// Inside an album section the album name is already the header, so rows
    /// show the track number and artist instead of repeating it.
    private func trackSubtitle(for song: Song) -> String {
        song.trackNumber > 0 ? "\(song.trackNumber) · \(song.artistName)" : song.artistName
    }

    @ViewBuilder
    private func songListRow(_ song: Song, subtitle: String?) -> some View {
        Button {
            if isSelecting {
                toggleSelection(song)
            } else {
                player.play(song: song, in: sortedSongs)
            }
        } label: {
            HStack(spacing: 12) {
                if isSelecting {
                    Image(systemName: selectedIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            selectedIDs.contains(song.id)
                                ? AppTheme.dynamicAccent
                                : AppTheme.textSecondary
                        )
                        .transition(.scale.combined(with: .opacity))
                        .animation(LumiMotion.snap, value: selectedIDs)
                }
                SongRow(song: song, isCurrent: player.currentSong?.id == song.id, subtitle: subtitle)
            }
            .animation(LumiMotion.fade(0.15), value: isSelecting)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.elevatedSurface.opacity(0.6))
        )
        .listRowSeparator(.hidden)
    }
}

// MARK: - Album sections

struct FolderAlbumSection: Identifiable {
    let title: String
    let songs: [Song]
    var id: String { title }
    var isUnknown: Bool { title == "Unknown Album" }

    var artist: String? {
        let artists = Set(songs.map(\.artistName))
        return artists.count == 1 ? artists.first : "Various Artists"
    }

    var year: String? {
        songs.lazy.map { $0.year.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

/// A compact album header inside a folder's track list — cover, name,
/// artist · year · count, and a play button for just that album.
private struct FolderAlbumHeader: View {
    let section: FolderAlbumSection
    let onPlay: () -> Void

    private var detail: String {
        var parts: [String] = []
        if let artist = section.artist { parts.append(artist) }
        if let year = section.year { parts.append(year) }
        parts.append("\(section.songs.count) \(section.songs.count == 1 ? "song" : "songs")")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let first = section.songs.first {
                    ArtworkThumbnail(song: first, size: 44)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(AppTheme.surface)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(AppTheme.dynamicAccent)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Play \(section.title)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Plain-list section headers stay pinned while their section
        // scrolls; without a background the rows show through the header.
        .styleAwareMaterial(.ultraThinMaterial, in: Rectangle())
        .listRowInsets(EdgeInsets())
        .textCase(nil)
    }
}

// MARK: - Header

private struct FolderDetailHeaderView: View {
    let folderName: String
    let folderURL: URL
    let representativeSong: Song?
    /// Up to four songs with distinct artwork, for the mosaic shown when the
    /// folder has no custom cover.
    let collageSongs: [Song]
    let artistSummary: String?
    let songCount: Int
    let albumCount: Int
    let totalDurationText: String
    let totalSizeText: String
    @Binding var customCover: UIImage?

    @State private var pickerItem: PhotosPickerItem?

    private let coverSize: CGFloat = 200

    var body: some View {
        ZStack(alignment: .bottom) {
            // Big blurred-artwork backdrop, same component the Queue and
            // Songs redesigns use.
            HeroArtworkBackdrop(song: representativeSong, height: 380)

            VStack(spacing: 14) {
                BreadcrumbTrail(parent: "Imported Music", current: folderName)

                ZStack(alignment: .bottomTrailing) {
                    cover
                        .frame(width: coverSize, height: coverSize)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(.white.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)

                    // Custom folder cover art — device-local, see
                    // FolderCoverArtService. Overlaid on the artwork itself so
                    // it's discoverable the same way changing a playlist's or
                    // profile's photo is elsewhere in the app.
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, AppTheme.dynamicAccent)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    .padding(8)
                    .accessibilityLabel("Change folder cover")
                }
                .onChange(of: pickerItem) { item in
                    guard let item else { return }
                    Task {
                        // Downsample straight from the encoded bytes (ImageIO,
                        // never decodes the full-resolution photo-library asset)
                        // — see ImageDownsampler's header comment.
                        guard let data = try? await item.loadTransferable(type: Data.self),
                              let image = ImageDownsampler.downsampled(from: data, maxPixelSize: 512)
                        else { return }
                        // loadTransferable can resume off the main actor, and
                        // FolderCoverArtService is @MainActor.
                        await FolderCoverArtService.shared.setCover(image, for: folderURL)
                        let newCover = await FolderCoverArtService.shared.cover(for: folderURL)
                        await MainActor.run {
                            customCover = newCover
                            pickerItem = nil
                        }
                    }
                }

                VStack(spacing: 6) {
                    Text("FOLDER")
                        .font(.caption2.weight(.heavy))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.dynamicAccent)
                    Text(folderName)
                        .font(.title.weight(.bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let artistSummary {
                        Text(artistSummary)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        ScreenStatChip(icon: "music.note", text: "\(songCount) \(songCount == 1 ? "song" : "songs")")
                        if albumCount > 1 {
                            ScreenStatChip(icon: "square.stack", text: "\(albumCount) albums")
                        }
                        ScreenStatChip(icon: "clock", text: totalDurationText)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var cover: some View {
        if let customCover {
            Image(uiImage: customCover)
                .resizable()
                .scaledToFill()
        } else if collageSongs.count >= 4 {
            let half = coverSize / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ArtworkThumbnail(song: collageSongs[0], size: half)
                    ArtworkThumbnail(song: collageSongs[1], size: half)
                }
                HStack(spacing: 0) {
                    ArtworkThumbnail(song: collageSongs[2], size: half)
                    ArtworkThumbnail(song: collageSongs[3], size: half)
                }
            }
        } else if let song = collageSongs.first ?? representativeSong {
            ArtworkThumbnail(song: song, size: coverSize)
        } else {
            ZStack {
                AppTheme.surface
                Image(systemName: "folder.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(AppTheme.dynamicAccent)
            }
        }
    }
}

// MARK: - Selection Action Bar
//
// Bulk actions for the folder's multi-select mode — add to an existing
// playlist, add to queue, favorite, or delete. Modeled directly on
// LibrarySelectionActionBar (same layout/confirmation-dialog conventions)
// but with two extra actions (queue, favorite) that screen doesn't need,
// so it's its own small type rather than a shared one.

private struct FolderSelectionActionBar: View {
    let selectedCount: Int
    let onAddToPlaylist: (UUID) -> Void
    let onAddToQueue: () -> Void
    let onFavorite: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var library: LibraryManager
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 14) {
            Button("Cancel", action: onCancel)
                .foregroundStyle(AppTheme.textSecondary)

            Spacer()

            Text("\(selectedCount) selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer()

            Button(action: onFavorite) {
                Image(systemName: "heart")
                    .font(.system(size: 17, weight: .medium))
            }
            .disabled(selectedCount == 0)

            Button(action: onAddToQueue) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 17, weight: .medium))
            }
            .disabled(selectedCount == 0)

            LumiMenu {
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
                    .font(.system(size: 17, weight: .medium))
            }
            .disabled(selectedCount == 0)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .medium))
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

// MARK: - Export-as-Playlist Sheet

private struct FolderExportPlaylistSheet: View {
    let defaultName: String
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @FocusState private var isFocused: Bool

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist Name") {
                    TextField("Playlist name", text: $name)
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
                        onCreate(name)
                    }
                    .disabled(!isValid)
                    .tint(AppTheme.dynamicAccent)
                }
            }
            .onAppear {
                name = defaultName
                isFocused = true
            }
        }
    }
}
