import SwiftUI

// MARK: - TrackedPlaylistDetailView
//
// Resolves a tracked playlist to its tracks and lets the user download any of
// them into the local library. Every download is gated by a fresh local
// dir+subdir scan and a combined source-ID / title-artist duplicate check, so a
// track that already exists on the device can't be downloaded twice — the check
// runs BEFORE yt-dlp is ever invoked.

struct TrackedPlaylistDetailView: View {
    let playlist: TrackedPlaylist

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var account: AccountService
    @ObservedObject private var trackedStore = TrackedPlaylistStore.shared

    @State private var tracks: [StreamTrack] = []
    @State private var isResolving = false
    @State private var errorText: String?

    @State private var localCopyIDs: Set<String> = []   // already on device
    @State private var downloadingIDs: Set<String> = []  // in flight
    @State private var playingTrackID: String?

    @State private var isDownloadingAll = false
    @State private var downloadAllDone = 0
    @State private var downloadAllTotal = 0

    @AppStorage("autoCloudBackup") private var autoCloudBackup = false

    private var newCount: Int { tracks.filter { !localCopyIDs.contains($0.id) }.count }
    private var downloadedCount: Int { tracks.count - newCount }
    private var progressFraction: Double { tracks.isEmpty ? 0 : Double(downloadedCount) / Double(tracks.count) }

    var body: some View {
        List {
            heroSection

            if isResolving && tracks.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let errorText, tracks.isEmpty {
                EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't load playlist", message: errorText)
                    .listRowBackground(Color.clear)
            } else if tracks.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "No tracks", message: "This playlist returned no tracks.")
                    .listRowBackground(Color.clear)
            } else {
                let newTracks = tracks.filter { !localCopyIDs.contains($0.id) }
                let downloaded = tracks.filter { localCopyIDs.contains($0.id) }

                if !newTracks.isEmpty {
                    Section {
                        ForEach(newTracks) { track in
                            trackRow(track)
                        }
                    } header: {
                        groupHeader("NOT DOWNLOADED", count: newTracks.count)
                    }
                    .listRowBackground(AppTheme.surface.opacity(0.5))
                }

                if !downloaded.isEmpty {
                    Section {
                        ForEach(downloaded) { track in
                            trackRow(track)
                        }
                    } header: {
                        groupHeader("IN YOUR LIBRARY", count: downloaded.count)
                    }
                    .listRowBackground(AppTheme.surface.opacity(0.5))
                }
            }
        }
        // `.plain`, not `.insetGrouped` — see FavoritesView's identical fix;
        // `.insetGrouped` splits each Section into a separate floating card
        // with the gallery background showing fully through the gaps.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            MiniPlayerBar()
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await resolve() }
        .refreshable { await resolve() }
    }

    // MARK: Group header

    private func groupHeader(_ title: String, count: Int) -> some View {
        Text("\(title) · \(count)")
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }

    // MARK: Hero

    /// Structural/visual redesign: a single hero card replaces the old flat
    /// list of controls — playlist art, a ring showing download completion at
    /// a glance, and the primary/secondary actions grouped underneath it,
    /// rather than everything reading as one undifferentiated settings list.
    private var heroSection: some View {
        Section {
            VStack(spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    heroArtwork

                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.name)
                            .font(AppTheme.headlineFont(size: 18))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(2)
                        Text(tracks.isEmpty ? "Resolving…" : "\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    Spacer()

                    downloadProgressRing
                }

                Button {
                    Task { await downloadAllNew() }
                } label: {
                    HStack {
                        Spacer()
                        if isDownloadingAll {
                            ProgressView().tint(.white)
                            Text("Downloading \(downloadAllDone)/\(downloadAllTotal)…")
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(newCount > 0 ? "Download \(newCount) New Track\(newCount == 1 ? "" : "s")" : "All Tracks Downloaded")
                        }
                        Spacer()
                    }
                    .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(newCount > 0 && !isDownloadingAll ? AppTheme.dynamicAccent : AppTheme.textSecondary.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDownloadingAll || newCount == 0)

                if isDownloadingAll && downloadAllTotal > 0 {
                    ProgressView(value: Double(downloadAllDone), total: Double(downloadAllTotal))
                        .tint(AppTheme.dynamicAccent)
                }

                Divider().overlay(AppTheme.textSecondary.opacity(0.15))

                TrackedPlaylistSettingsRow(playlistID: playlist.id)
            }
            .padding(.vertical, 6)
        } footer: {
            Text("Tracks already in your library are skipped automatically — Lumisound rescans the local Imported Music folder (and its subfolders) before each download so nothing is fetched twice. With auto-download on, new tracks added to this playlist are fetched automatically when you open the app. \"Save to\" overrides the global Download Folder setting just for this playlist.")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var heroArtwork: some View {
        Group {
            if let first = tracks.first, let url = URL(string: first.thumbnailURL), !first.thumbnailURL.isEmpty {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                    default: placeholderThumb
                    }
                }
            } else {
                placeholderThumb
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }

    private var downloadProgressRing: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.textSecondary.opacity(0.2), lineWidth: 5)
            Circle()
                .trim(from: 0, to: progressFraction)
                .stroke(AppTheme.dynamicAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progressFraction)
            Text(tracks.isEmpty ? "–" : "\(Int(progressFraction * 100))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel("\(downloadedCount) of \(tracks.count) tracks downloaded")
    }

    /// This playlist's own destination-folder override, if set (nil falls
    /// back to the global Settings → yt-dlp → Download Folder default) —
    /// also sent to `/api/download` as `destination_folder` so a track that
    /// finishes after the app closes/crashes mid-download still recovers
    /// into this same folder (see `reconcilePendingDownloads`).
    private var destinationFolderName: String? {
        trackedStore.playlists.first { $0.id == playlist.id }?.destinationFolder
    }

    /// This playlist's resolved destination directory (its own override, or
    /// the global Settings → yt-dlp → Download Folder default).
    private var destinationDir: URL? {
        StreamingService.downloadDirectory(forFolderName: destinationFolderName)
    }

    // MARK: Track Row

    @ViewBuilder
    private func trackRow(_ track: StreamTrack) -> some View {
        let isLocal = localCopyIDs.contains(track.id)
        HStack(spacing: 12) {
            thumbnail(for: track)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !track.artist.isEmpty {
                        Text(track.artist)
                            .lineLimit(1)
                    }
                    if track.durationSeconds > 0 {
                        Text(track.durationText)
                    }
                }
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            if downloadingIDs.contains(track.id) {
                ProgressView()
            } else if isLocal {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.success)
                    .accessibilityLabel("In library")
            } else {
                Button {
                    Task { await downloadOne(track) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await play(track) } }
        .overlay(alignment: .trailing) {
            if playingTrackID == track.id { ProgressView().offset(x: 28) }
        }
    }

    @ViewBuilder
    private func thumbnail(for track: StreamTrack) -> some View {
        if let url = URL(string: track.thumbnailURL), !track.thumbnailURL.isEmpty {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default: placeholderThumb
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            placeholderThumb.frame(width: 44, height: 44)
        }
    }

    private var placeholderThumb: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(AppTheme.elevatedSurface)
            .overlay {
                Image(systemName: "music.note")
                    .foregroundStyle(AppTheme.textSecondary)
            }
    }

    // MARK: Actions

    private func resolve() async {
        isResolving = true
        errorText = nil
        defer { isResolving = false }

        // Make sure the local library reflects every file on disk (root +
        // Imported Music + any subfolders) BEFORE we compute duplicate status.
        await library.scanLocalDocumentsAsync()

        let resolved = await streaming.fetchPlaylistTracks(url: playlist.url, existingSongs: [])
        guard !resolved.isEmpty else {
            errorText = streaming.errorMessage ?? "The playlist couldn't be resolved. Check the URL and try again."
            return
        }
        tracks = resolved
        await recomputeLocalCopies()
        TrackedPlaylistStore.shared.updateMetadata(
            id: playlist.id,
            trackCount: resolved.count,
            thumbnailURL: resolved.first?.thumbnailURL
        )
    }

    /// Re-derives which tracks already exist locally. Assumes the caller has
    /// just scanned, so `library.allSongs` is current.
    ///
    /// Builds the fast-path lookups ONCE before checking every track — the
    /// naive `tracks.filter { library.hasLocalCopy(of: $0) }` called
    /// `hasLocalCopy` (O(library) per call) once per track, which for a big
    /// playlist (hundreds of tracks) against a sizeable library was an
    /// O(tracks × library) main-thread hang long enough to trip the iOS
    /// watchdog — the "opening a big playlist crashes" bug. Same fix as
    /// `StreamSearchView.refreshDownloadedStatus`.
    private func recomputeLocalCopies() async {
        let ids = await library.localSourceIDs()
        let index = library.importedIdentityIndex()
        localCopyIDs = Set(
            tracks
                .filter { library.hasLocalCopy(of: $0, localSourceIDs: ids, identityIndex: index) }
                .map { $0.id }
        )
    }

    private func downloadOne(_ track: StreamTrack) async {
        guard !downloadingIDs.contains(track.id) else { return }
        downloadingIDs.insert(track.id)
        defer { downloadingIDs.remove(track.id) }

        // Re-scan + re-check immediately before invoking yt-dlp so a copy that
        // appeared since the initial resolve (or lives in a subfolder) is caught.
        await library.scanLocalDocumentsAsync()
        if library.hasLocalCopy(of: track) {
            localCopyIDs.insert(track.id)
            ToastCenter.shared.show("\"\(track.title)\" is already in your library", category: .info, icon: "checkmark.circle")
            return
        }

        do {
            let localURL = try await streaming.downloadToLibrary(
                track: track,
                destinationDir: destinationDir,
                existingSongs: library.allSongs,
                destinationFolderName: destinationFolderName
            )
            library.scanLocalDocuments()
            localCopyIDs.insert(track.id)
            await maybeCloudBackup(track: track, localURL: localURL)
            ToastCenter.shared.show("Downloaded \"\(track.title)\"", category: .download)
        } catch StreamingError.serverDetail(let detail) {
            // A specific, actionable reason from the bridge (e.g. an
            // auto-generated Topic-channel track blocked from extraction) —
            // show it directly instead of a generic "failed to download".
            ToastCenter.shared.show(detail, category: .error)
        } catch {
            ToastCenter.shared.show("Failed to download \"\(track.title)\"", category: .error)
        }
    }

    private func downloadAllNew() async {
        guard !isDownloadingAll else { return }
        isDownloadingAll = true
        defer { isDownloadingAll = false }

        await library.scanLocalDocumentsAsync()
        await recomputeLocalCopies()

        let toDownload = tracks.filter { !localCopyIDs.contains($0.id) }
        guard !toDownload.isEmpty else { return }

        downloadAllDone = 0
        downloadAllTotal = toDownload.count

        // Snapshot the library once on the main actor so the @Sendable task-group
        // children don't reach back into the @MainActor LibraryManager.
        let existing = library.allSongs
        let dir = destinationDir
        let folderName = destinationFolderName

        // Bounded concurrency matching the bridge's yt-dlp semaphore.
        // Dropped 4 -> 2 (2026-08) — see TrackedPlaylistStore.autoDownloadConcurrency.
        let maxConcurrent = 2
        var nextIndex = 0
        var failed = 0
        var blockedCount = 0

        await withTaskGroup(of: (track: StreamTrack, localURL: URL?, blocked: Bool).self) { group in
            func launchNext() {
                guard nextIndex < toDownload.count else { return }
                let track = toDownload[nextIndex]
                nextIndex += 1
                downloadingIDs.insert(track.id)
                group.addTask {
                    do {
                        let url = try await streaming.downloadToLibrary(
                            track: track,
                            destinationDir: dir,
                            existingSongs: existing,
                            destinationFolderName: folderName
                        )
                        return (track, url, false)
                    } catch StreamingError.serverDetail {
                        // e.g. an auto-generated Topic-channel track blocked from
                        // extraction — tallied separately so the summary toast can
                        // explain why, rather than reading like a generic failure.
                        return (track, nil, true)
                    } catch {
                        return (track, nil, false)
                    }
                }
            }

            for _ in 0..<min(maxConcurrent, toDownload.count) { launchNext() }

            for await result in group {
                downloadingIDs.remove(result.track.id)
                if let localURL = result.localURL {
                    localCopyIDs.insert(result.track.id)
                    await maybeCloudBackup(track: result.track, localURL: localURL)
                } else if result.blocked {
                    blockedCount += 1
                    failed += 1
                } else {
                    failed += 1
                }
                downloadAllDone += 1
                launchNext()
            }
        }

        library.scanLocalDocuments()
        await recomputeLocalCopies()

        if failed == 0 {
            ToastCenter.shared.show("Downloaded \(toDownload.count) track\(toDownload.count == 1 ? "" : "s")", category: .download)
        } else if blockedCount == failed {
            ToastCenter.shared.show(
                "Downloaded \(toDownload.count - failed), \(failed) blocked by YouTube (auto-generated \"Topic\" channel tracks)",
                category: .error
            )
        } else if blockedCount > 0 {
            ToastCenter.shared.show(
                "Downloaded \(toDownload.count - failed), \(failed) failed (\(blockedCount) blocked by YouTube)",
                category: .error
            )
        } else {
            ToastCenter.shared.show("Downloaded \(toDownload.count - failed), \(failed) failed", category: .error)
        }
    }

    private func play(_ track: StreamTrack) async {
        guard playingTrackID == nil else { return }
        playingTrackID = track.id
        defer { playingTrackID = nil }
        do {
            let url = try await streaming.streamURL(for: track)
            let song = streaming.toSong(track: track, streamURL: url)
            player.play(song: song, in: [song])
        } catch {
            streaming.errorMessage = error.localizedDescription
        }
    }

    private func maybeCloudBackup(track: StreamTrack, localURL: URL) async {
        guard autoCloudBackup, account.isLoggedIn, let token = account.token else { return }
        let hasArtwork = await LumisoundExclusiveExtensionService.hasEmbeddedThumbnailTag(fileURL: localURL)
        try? await streaming.uploadTrack(
            fileURL: localURL,
            token: token,
            metadata: TrackMetadata(title: track.title, artist: track.artist, durationSeconds: track.duration, hasArtwork: hasArtwork)
        )
    }
}

/// Isolates the auto-download toggle and "Save to" folder-picker dropdown
/// from the rest of `TrackedPlaylistDetailView` — which, being one `Section`/
/// one computed property, re-rendered this row every time ANY of the
/// parent's own state changed, including `downloadAllDone`/`isDownloadingAll`
/// ticking on every track completed during an active "Download N New Tracks"
/// run. A native `Menu` (the folder picker) is far more sensitive to its
/// parent being torn down and rebuilt mid-presentation than plain SwiftUI
/// content — reported (with a screen recording) as the dropdown visibly
/// resetting/flickering open while several downloads completed in quick
/// succession. Taking only `playlistID` (a plain value, not observed) and
/// reading `TrackedPlaylistStore` itself here means this row now only
/// re-renders when the store's own `playlists` actually changes — e.g. the
/// user flips the toggle — not on every download-progress tick.
private struct TrackedPlaylistSettingsRow: View {
    let playlistID: String
    @ObservedObject private var trackedStore = TrackedPlaylistStore.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { trackedStore.playlists.first { $0.id == playlistID }?.isAutoDownload ?? false },
            set: { trackedStore.setAutoDownload(id: playlistID, $0) }
        )) {
            Label("Auto-download new tracks", systemImage: "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(AppTheme.textPrimary)
        }
        .tint(AppTheme.dynamicAccent)

        HStack {
            Label("Save to", systemImage: "folder")
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            DownloadFolderPicker(folderName: Binding(
                get: { trackedStore.playlists.first { $0.id == playlistID }?.destinationFolder ?? "" },
                set: { trackedStore.setDestinationFolder(id: playlistID, $0) }
            ))
        }
    }
}
