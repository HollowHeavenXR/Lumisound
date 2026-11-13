import SwiftUI

struct CacheManagerView: View {

    @EnvironmentObject private var cacheManager: CacheManagerService
    @EnvironmentObject private var library: LibraryManager
    @State private var showClearArtworkConfirm = false
    @State private var showClearTempConfirm = false
    @State private var showClearAllConfirm = false
    @State private var showClearArtistImagesConfirm = false
    @State private var showClearTranscodeConfirm = false
    @State private var showDeleteOrphansConfirm = false
    @State private var savedBytes: Int64 = 0
    @State private var showSavedBanner = false

    /// Each cache category's `Section` is its own computed property (rather
    /// than all inline in one `List { ... }`) — with 8 sections' worth of
    /// nested HStack/VStack/Button/Label content, the Swift type-checker
    /// timed out trying to infer the whole `body` as a single expression
    /// ("unable to type-check this expression in reasonable time"). Breaking
    /// it up gives the checker a much smaller expression to solve per piece.
    /// One slice of the storage bar.
    private struct Slice: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let color: Color
    }

    private var slices: [Slice] {
        [
            Slice(id: "music", title: "Music", bytes: cacheManager.downloadedMusicSize, color: .pink),
            Slice(id: "art", title: "Artwork", bytes: cacheManager.artworkCacheSize, color: .purple),
            Slice(id: "artist", title: "Artist photos", bytes: cacheManager.artistImageCacheSize, color: .blue),
            Slice(id: "temp", title: "Temp", bytes: cacheManager.tempFilesSize, color: .orange),
            Slice(id: "transcode", title: "Transcode", bytes: cacheManager.transcodeCacheSize, color: .teal),
            Slice(id: "orphan", title: "Orphans", bytes: cacheManager.orphanedFilesSize, color: .gray),
        ]
    }

    var body: some View {
        LKPage(title: "Storage", subtitle: nil, icon: "internaldrive.fill", tint: .gray, showsHero: false) {
            storageMap
            if showSavedBanner {
                LKBanner(icon: "checkmark.circle.fill", text: "\(CacheManagerService.formattedSize(savedBytes)) freed", tint: AppTheme.success)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            LKCard(title: "Your music") {
                NavigationLink { DownloadsManagementView() } label: {
                    LKRow(icon: "music.note", tint: .pink, title: "Imported Music", subtitle: "Sort by size, remove tracks",
                          value: CacheManagerService.formattedSize(cacheManager.downloadedMusicSize))
                }
                .buttonStyle(.plain)
            }
            LKCard(title: "Safe to clear", footer: "Everything here is re-created when needed. Don't clear temp or transcode files while a download or export is running.") {
                cacheRow(icon: "photo.on.rectangle.angled", tint: .purple, title: "Artwork", detail: "\(cacheManager.artworkCacheCount) files",
                         bytes: cacheManager.artworkCacheSize) { showClearArtworkConfirm = true }
                LKDivider()
                cacheRow(icon: "person.crop.square", tint: .blue, title: "Artist photos", detail: "\(cacheManager.artistImageCacheCount) files",
                         bytes: cacheManager.artistImageCacheSize) { showClearArtistImagesConfirm = true }
                LKDivider()
                cacheRow(icon: "arrow.down.circle.dotted", tint: .orange, title: "Temp downloads", detail: "Interrupted downloads",
                         bytes: cacheManager.tempFilesSize) { showClearTempConfirm = true }
                LKDivider()
                cacheRow(icon: "waveform", tint: .teal, title: "Transcode work files", detail: "Fingerprinting and exports",
                         bytes: cacheManager.transcodeCacheSize) { showClearTranscodeConfirm = true }
            }
            orphansCard
            if totalClearableSize > 0 {
                LKPrimaryButton(title: "Clear All Caches · \(CacheManagerService.formattedSize(totalClearableSize))", icon: "sparkles", tint: .purple) {
                    showClearAllConfirm = true
                }
            }
            LKBanner(icon: "server.rack", text: "The bridge server's streaming cache is managed on the server automatically.", tint: .gray)
        }
        .animation(LumiMotion.fade(0.25), value: showSavedBanner)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if cacheManager.isScanning {
                    ProgressView().tint(AppTheme.dynamicAccent)
                } else {
                    Button {
                        Task { await cacheManager.scan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .tint(AppTheme.dynamicAccent)
                }
            }
        }
        .onAppear {
            cacheManager.scanOnAppear()
            Task {
                // `library.allSongs` is main-actor-isolated, so building
                // `known` here runs on the main actor, not off it like the
                // rest of this file's work — on a several-thousand-song
                // library that's a full-library `compactMap` plus a `Set`
                // build every time this screen (reachable from Settings →
                // Storage & Cache) appears. Unconfirmed as an actual
                // contributor (no prior instrumentation existed to say
                // either way); measured rather than moved off-main for now
                // since `cacheManager.scanOrphans` needs `known` either way
                // and this screen's main concern was the cache scan, not
                // this lookup.
                let known = MainThreadActivity.measure("cacheManager.knownFilenames") {
                    Set(library.allSongs.compactMap { $0.url?.lastPathComponent })
                }
                await cacheManager.scanOrphans(knownFilenames: known)
            }
        }
        .confirmationDialog(
            "Clear Artwork Cache?",
            isPresented: $showClearArtworkConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                let freed = cacheManager.artworkCacheSize
                cacheManager.clearArtworkCache()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Album art will be re-downloaded as you browse your library.")
        }
        .confirmationDialog(
            "Clear Temp Files?",
            isPresented: $showClearTempConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                let freed = cacheManager.tempFilesSize
                cacheManager.clearTempFiles()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Partial download folders will be deleted. Do not clear while a download is in progress.")
        }
        .confirmationDialog(
            "Clear Artist Photo Cache?",
            isPresented: $showClearArtistImagesConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                let freed = cacheManager.artistImageCacheSize
                cacheManager.clearArtistImageCache()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Artist photos will be re-fetched from Deezer as you browse.")
        }
        .confirmationDialog(
            "Clear Transcode Cache?",
            isPresented: $showClearTranscodeConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                let freed = cacheManager.transcodeCacheSize
                cacheManager.clearTranscodeCache()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Temporary audio-conversion files will be deleted. Do not clear while fingerprinting or exporting a track.")
        }
        .confirmationDialog(
            "Delete Orphaned Files?",
            isPresented: $showDeleteOrphansConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let freed = cacheManager.orphanedFilesSize
                cacheManager.deleteOrphanedFiles()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These files aren't referenced by anything in your library and will be permanently deleted.")
        }
        .confirmationDialog(
            "Clear All Cache?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                let freed = totalClearableSize
                cacheManager.clearAll()
                flashSavedBanner(bytes: freed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Album art, artist photos, temp downloads, and transcode work files will all be cleared/re-fetched as needed. Your downloaded music and orphaned files are not affected — orphaned files must be deleted separately above.")
        }
    }

    // MARK: - Pieces

    private var storageMap: some View {
        let total = max(slices.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(CacheManagerService.formattedSize(slices.reduce(Int64(0)) { $0 + $1.bytes }))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("used by Lumisound").font(.subheadline).foregroundStyle(AppTheme.textSecondary)
                Spacer()
                if cacheManager.isScanning || cacheManager.isScanningOrphans { ProgressView() }
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(slices.filter { $0.bytes > 0 }) { slice in
                        Rectangle().fill(slice.color.gradient)
                            .frame(width: max(3, geo.size.width * CGFloat(Double(slice.bytes) / Double(total))))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            LKGrid(columns: 3) {
                ForEach(slices) { slice in
                    HStack(spacing: 6) {
                        Circle().fill(slice.color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(slice.title).font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                            Text(CacheManagerService.formattedSize(slice.bytes)).font(.caption2.monospacedDigit()).foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .background(LKCardBackground())
    }

    private func cacheRow(icon: String, tint: Color, title: String, detail: String, bytes: Int64, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            LKIcon(symbol: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppTheme.bodyFont(size: 15)).foregroundStyle(AppTheme.textPrimary)
                Text("\(CacheManagerService.formattedSize(bytes)) · \(detail)").font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button(action: clear) {
                Image(systemName: "trash").font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(bytes == 0 ? AppTheme.textSecondary : AppTheme.error)
                    .background((bytes == 0 ? AppTheme.textSecondary : AppTheme.error).opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(bytes == 0)
            .accessibilityLabel("Clear \(title)")
        }
        .padding(.vertical, 6)
    }

    private var orphansCard: some View {
        LKCard(title: "Orphaned files", footer: "Files in Imported Music that nothing in your library uses — leftovers or files added outside the app. Deleting them is permanent.") {
            HStack(spacing: 12) {
                LKIcon(symbol: "questionmark.folder", tint: .gray)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cacheManager.isScanningOrphans ? "Checking against your library…" : "\(cacheManager.orphanedFiles.count) file\(cacheManager.orphanedFiles.count == 1 ? "" : "s")")
                        .font(AppTheme.bodyFont(size: 15)).foregroundStyle(AppTheme.textPrimary)
                    Text(CacheManagerService.formattedSize(cacheManager.orphanedFilesSize)).font(.caption).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                if !cacheManager.orphanedFiles.isEmpty {
                    Button("Delete") { showDeleteOrphansConfirm = true }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(AppTheme.error)
                        .background(AppTheme.error.opacity(0.12), in: Capsule())
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var totalClearableSize: Int64 {
        cacheManager.artworkCacheSize + cacheManager.tempFilesSize
            + cacheManager.artistImageCacheSize + cacheManager.transcodeCacheSize
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }

    private func flashSavedBanner(bytes: Int64) {
        guard bytes > 0 else { return }
        savedBytes = bytes
        withAnimation(LumiMotion.glide) { showSavedBanner = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(LumiMotion.glide) { showSavedBanner = false }
        }
    }
}
