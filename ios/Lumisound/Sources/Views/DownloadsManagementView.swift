import SwiftUI

/// Dedicated per-track view of locally-imported/downloaded music, since
/// `CacheManagerView`'s "Downloaded Music" section only ever showed one
/// aggregate total — there was no way to see which tracks were actually
/// taking up space, or remove several at once, without going through the
/// general Library list (which has no per-track size column at all).
struct DownloadsManagementView: View {

    @EnvironmentObject private var library: LibraryManager

    private enum SortOption: String, CaseIterable, Identifiable {
        case sizeDescending = "Largest First"
        case sizeAscending = "Smallest First"
        case dateNewest = "Newest First"
        case dateOldest = "Oldest First"
        case name = "Name (A–Z)"
        var id: String { rawValue }
    }

    @State private var sortOption: SortOption = .sizeDescending
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBulkDeleteConfirm = false
    @State private var showSingleDeleteConfirm: Song?
    /// Computed off-actor once on appear (and whenever the imported-song set
    /// changes) — reading `FileManager` attributes for every track is cheap
    /// per-file but adds up across a large library, so it's not recomputed
    /// on every sort/selection change.
    @State private var sizesByID: [String: Int64] = [:]

    private var downloadedSongs: [Song] {
        library.importedSongs.filter { $0.url != nil }
    }

    /// Sorted once per change of the downloads, their sizes or the sort
    /// option rather than on every read (it's read several times a render,
    /// and selection taps re-render the whole list).
    @State private var sortedSongs: [Song] = []

    private func sorted() -> [Song] {
        let downloadedSongs = self.downloadedSongs
        switch sortOption {
        case .sizeDescending:
            return downloadedSongs.sorted { (sizesByID[$0.id] ?? 0) > (sizesByID[$1.id] ?? 0) }
        case .sizeAscending:
            return downloadedSongs.sorted { (sizesByID[$0.id] ?? 0) < (sizesByID[$1.id] ?? 0) }
        case .dateNewest:
            return downloadedSongs.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .dateOldest:
            return downloadedSongs.sorted { ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast) }
        case .name:
            return downloadedSongs.sortedByDisplayName()
        }
    }

    private var totalSize: Int64 { sizesByID.values.reduce(0, +) }
    private var selectedSize: Int64 { selectedIDs.reduce(0) { $0 + (sizesByID[$1] ?? 0) } }

    var body: some View {
        List {
            if sortedSongs.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 36))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text("No downloaded tracks")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(sortedSongs) { song in
                        row(for: song)
                    }
                } header: {
                    Text("\(sortedSongs.count) TRACK\(sortedSongs.count == 1 ? "" : "S") · \(CacheManagerService.formattedSize(totalSize))")
                        .font(AppTheme.bodyFont(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                        .kerning(0.8)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(EditionScreenBackground())
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                LumiPicker(selection: $sortOption) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.rawValue).lumiOptionLabel(option.rawValue).tag(option)
                    }
                } trigger: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .disabled(sortedSongs.isEmpty)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    RecentlyDeletedView()
                } label: {
                    Image(systemName: "trash.slash")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !sortedSongs.isEmpty {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                        selectedIDs.removeAll()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selectedIDs.isEmpty {
                Button(role: .destructive) {
                    showBulkDeleteConfirm = true
                } label: {
                    Label(
                        "Delete \(selectedIDs.count) (\(CacheManagerService.formattedSize(selectedSize)))",
                        systemImage: "trash"
                    )
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.error)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .styleAwareMaterial(.ultraThinMaterial, in: Rectangle())
            }
        }
        .confirmationDialog(
            "Delete \(selectedIDs.count) Track\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                library.removeImportedSongs(ids: selectedIDs)
                selectedIDs.removeAll()
                isSelecting = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the files from your device. This can't be undone.")
        }
        .confirmationDialog(
            "Delete \"\(showSingleDeleteConfirm?.displayName ?? "")\"?",
            isPresented: Binding(
                get: { showSingleDeleteConfirm != nil },
                set: { if !$0 { showSingleDeleteConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let song = showSingleDeleteConfirm {
                    library.removeImportedSong(id: song.id)
                }
                showSingleDeleteConfirm = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the file from your device. This can't be undone.")
        }
        // Watches `importedSongs` directly rather than
        // `downloadedSongs.map(\.id)`, which filtered and mapped the whole
        // imported library on every render just to diff it.
        .onAppear {
            sortedSongs = sorted()
            computeSizes()
        }
        .onChange(of: library.importedSongs) {
            sortedSongs = sorted()
            computeSizes()
        }
        .onChange(of: sortOption) { sortedSongs = sorted() }
        .onChange(of: sizesByID) { sortedSongs = sorted() }
    }

    @ViewBuilder
    private func row(for song: Song) -> some View {
        Button {
            if isSelecting {
                if selectedIDs.contains(song.id) {
                    selectedIDs.remove(song.id)
                } else {
                    selectedIDs.insert(song.id)
                }
            }
        } label: {
            HStack(spacing: 12) {
                if isSelecting {
                    Image(systemName: selectedIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selectedIDs.contains(song.id) ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(CacheManagerService.formattedSize(sizesByID[song.id] ?? 0))
                    .font(AppTheme.monoFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(AppTheme.surface)
        .swipeActions(edge: .trailing) {
            if !isSelecting {
                Button(role: .destructive) {
                    showSingleDeleteConfirm = song
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func computeSizes() {
        let songs = downloadedSongs
        Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for song in songs {
                guard let url = song.url else { continue }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let number = attrs[.size] as? NSNumber {
                    sizes[song.id] = number.int64Value
                }
            }
            await MainActor.run {
                self.sizesByID = sizes
            }
        }
    }
}
