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

    /// Which tracks the list shows.
    enum TrackFilter: Hashable { case missing, downloaded, all }
    @State private var filter: TrackFilter = .missing
    @State private var didPickInitialFilter = false
    @State private var query = ""

    private var newCount: Int { tracks.count - downloadedCount }
    private var downloadedCount: Int { tracks.reduce(0) { $0 + (localCopyIDs.contains($1.id) ? 1 : 0) } }
    private var progressFraction: Double { tracks.isEmpty ? 0 : Double(downloadedCount) / Double(tracks.count) }

    private var visibleTracks: [StreamTrack] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return tracks.filter { track in
            let local = localCopyIDs.contains(track.id)
            switch filter {
            case .missing where local: return false
            case .downloaded where !local: return false
            default: break
            }
            guard !q.isEmpty else { return true }
            return track.title.lowercased().contains(q) || track.artist.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LK.spacing) {
                hero
                if isResolving && tracks.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if let errorText, tracks.isEmpty {
                    LKEmpty(icon: "exclamationmark.triangle", title: "Couldn't load playlist", message: errorText, tint: AppTheme.warning)
                } else if tracks.isEmpty {
                    LKEmpty(icon: "music.note.list", title: "No tracks", message: "This playlist returned no tracks.")
                } else {
                    filterBar
                    trackList
                }
                LKCard(title: "Tracking",
                       footer: "Anything already in your library is skipped: Lumisound rescans your music folders before each download. With auto-download on, new songs in this playlist arrive on the background schedule. \"Save to\" overrides the global download folder for this playlist only.") {
                    TrackedPlaylistSettingsRow(playlistID: playlist.id)
                }
            }
            .padding(.horizontal, LK.gutter)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await resolve() }
        .refreshable { await resolve() }
        .animation(LumiMotion.fade(0.2), value: filter)
    }

    // MARK: Hero

    /// Artwork over its own blurred glow, the downloaded / missing split as
    /// one bar, and the main action.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                heroArtwork
                VStack(alignment: .leading, spacing: 5) {
                    Text(playlist.name)
                        .font(AppTheme.headlineFont(size: 20))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                    Text(tracks.isEmpty ? (isResolving ? "Reading playlist…" : "No tracks yet")
                                        : "\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                    if trackedStore.playlists.first(where: { $0.id == playlist.id })?.isAutoDownload == true {
                        LKPill(text: "Auto-download", tint: .green)
                    }
                }
                Spacer(minLength: 0)
            }

            if !tracks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { geo in
                        HStack(spacing: 3) {
                            Capsule().fill(AppTheme.success)
                                .frame(width: max(downloadedCount > 0 ? 6 : 0, (geo.size.width - 3) * progressFraction))
                            if newCount > 0 { Capsule().fill(AppTheme.warning.opacity(0.85)) }
                        }
                    }
                    .frame(height: 8)
                    .animation(LumiMotion.fade(0.4), value: progressFraction)
                    HStack(spacing: 14) {
                        legend(color: AppTheme.success, text: "\(downloadedCount) in library")
                        legend(color: AppTheme.warning, text: "\(newCount) missing")
                        Spacer()
                        Text("\(Int((progressFraction * 100).rounded()))%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(downloadedCount) of \(tracks.count) tracks downloaded, \(newCount) missing")
            }

            LKPrimaryButton(
                title: isDownloadingAll ? "Downloading \(downloadAllDone) of \(downloadAllTotal)…"
                     : (newCount > 0 ? "Download \(newCount) Missing" : "Everything's Downloaded"),
                icon: newCount > 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill",
                tint: newCount > 0 ? AppTheme.dynamicAccent : AppTheme.success,
                prominent: newCount > 0,
                busy: isDownloadingAll
            ) {
                Task { await downloadAllNew() }
            }
            .disabled(newCount == 0 || tracks.isEmpty)

            if isDownloadingAll && downloadAllTotal > 0 {
                ProgressView(value: Double(downloadAllDone), total: Double(downloadAllTotal))
                    .tint(AppTheme.dynamicAccent)
            }
        }
        .padding(16)
        .background {
            ZStack {
                LKCardBackground(tint: AppTheme.dynamicAccent)
                artworkImage
                    .blur(radius: 40)
                    .opacity(0.35)
                    .clipShape(RoundedRectangle(cornerRadius: LK.corner, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var artworkImage: some View {
        let stored = trackedStore.playlists.first(where: { $0.id == playlist.id })?.thumbnailURL ?? ""
        let thumb = stored.isEmpty ? (tracks.first?.thumbnailURL ?? "") : stored
        if let url = URL(string: thumb), !thumb.isEmpty {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default: Color.clear
                }
            }
        } else {
            Color.clear
        }
    }

    private var heroArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.elevatedSurface)
            Image(systemName: "music.note.list").font(.system(size: 28)).foregroundStyle(AppTheme.textSecondary)
            artworkImage
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
    }

    // MARK: Filter + list

    private var filterBar: some View {
        VStack(spacing: 10) {
            LKSegmented(options: [(TrackFilter.missing, "Missing · \(newCount)"),
                                  (TrackFilter.downloaded, "In Library · \(downloadedCount)"),
                                  (TrackFilter.all, "All")],
                        selection: $filter)
            if tracks.count > 12 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.textSecondary)
                    TextField("Search this playlist", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AppTheme.textSecondary) }
                            .buttonStyle(.plain)
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var trackList: some View {
        let shown = visibleTracks
        if shown.isEmpty {
            LKEmpty(icon: filter == .missing ? "checkmark.seal.fill" : "music.note",
                    title: !query.isEmpty ? "No matches" : (filter == .missing ? "Nothing missing" : "Nothing downloaded yet"),
                    message: !query.isEmpty ? nil : (filter == .missing ? "Every song in this playlist is in your library." : "Download songs to see them here."),
                    tint: filter == .missing ? AppTheme.success : AppTheme.dynamicAccent)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, track in
                    if index > 0 { LKDivider(inset: 68) }
                    trackRow(track, number: index + 1)
                }
            }
            .padding(.vertical, 4)
            .background(LKCardBackground())
        }
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
    private func trackRow(_ track: StreamTrack, number: Int) -> some View {
        let isLocal = localCopyIDs.contains(track.id)
        HStack(spacing: 12) {
            thumbnail(for: track)
                .overlay {
                    if playingTrackID == track.id {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.45))
                        ProgressView().tint(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text([track.artist, track.durationSeconds > 0 ? track.durationText : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if downloadingIDs.contains(track.id) {
                ProgressView().controlSize(.small)
                    .frame(width: 32, height: 32)
            } else if isLocal {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AppTheme.success)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("In library")
            } else {
                Button {
                    Task { await downloadOne(track) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.dynamicAccent)
                        .frame(width: 32, height: 32)
                        .background(AppTheme.dynamicAccent.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download \(track.title)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { Task { await play(track) } }
        .accessibilityHint("Plays the song")
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
        if !didPickInitialFilter {
            didPickInitialFilter = true
            filter = newCount > 0 ? .missing : .all
        }
        TrackedPlaylistStore.shared.updateMetadata(
            id: playlist.id,
            trackCount: resolved.count,
            thumbnailURL: resolved.first?.thumbnailURL
        )
    }

    /// Re-derives which tracks already exist locally. Assumes the caller has
    /// just scanned, so `library.allSongs` is current.
    ///
    /// One index for the whole playlist (O(1) per track); per-track library
    /// scans on a big playlist tripped the iOS watchdog.
    private func recomputeLocalCopies() async {
        let index = await library.localCopyIndex()
        localCopyIDs = Set(tracks.filter { index.contains(candidate: $0.remoteCandidate) }.map(\.id))
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
