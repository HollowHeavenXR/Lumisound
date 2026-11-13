import SwiftUI
import UniformTypeIdentifiers

// MARK: - UploadMusicView

/// Cloud upload & backup management for the user's personal music library.
/// Shows upload progress, a list of previously uploaded files with delete,
/// and a "Restore to Device" section for re-downloading uploaded tracks.
///
/// Requires the user to be logged in; shows a login prompt if not authenticated.
struct UploadMusicView: View {

    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var account: AccountService

    @AppStorage("autoCloudBackup") private var autoCloudBackup: Bool = false

    // MARK: State

    @State private var showFilePicker        = false
    @State private var uploadQueue: [URL]    = []
    @State private var uploadIndex: Int      = 0
    @State private var isUploading           = false
    @State private var uploadMessage: String = ""
    @State private var errorMessage: String? = nil

    @State private var deletingID: String?   = nil
    @State private var showDeleteConfirm     = false
    @State private var pendingDeleteTrack: UserMusicMetadataTrack? = nil
    @State private var showDeleteAllConfirm  = false
    @State private var isDeletingAll         = false

    @State private var restoringFilename: String? = nil
    @State private var showLoginSheet       = false
    @State private var recommendationsFor: UserMusicMetadataTrack? = nil

    // MARK: Computed

    private var token: String? { account.token }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if account.isLoggedIn {
                    mainContent
                } else {
                    notLoggedInView
                }
            }
            .navigationTitle("Cloud Backup")
            .navigationBarTitleDisplayMode(.large)
            .background(GalleryBackgroundView().ignoresSafeArea())
            .toolbar {
                if account.isLoggedIn {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Upload", systemImage: "icloud.and.arrow.up")
                                .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                                .foregroundStyle(AppTheme.dynamicAccent)
                        }
                        .disabled(isUploading)
                    }
                }
            }
            // fileImporter must be at the NavigationStack root level
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: AudioImportTypes.all,
                allowsMultipleSelection: true
            ) { result in
                handleFilePick(result: result)
            }
            .sheet(isPresented: $showLoginSheet) {
                LoginView()
            }
            .sheet(item: $recommendationsFor) { track in
                RecommendationsSheet(seed: track, token: token)
                    .environmentObject(streaming)
            }
            .task {
                if account.isLoggedIn, let tok = token {
                    try? await streaming.fetchUserMusicMetadata(token: tok)
                }
            }
            .alert("Delete Track?", isPresented: $showDeleteConfirm, presenting: pendingDeleteTrack) { track in
                Button("Delete", role: .destructive) {
                    Task { await deleteTrack(track) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { track in
                Text("Remove \"\(track.title ?? track.filename)\" from cloud storage? This cannot be undone.")
            }
            .confirmationDialog(
                "Delete all uploaded tracks?",
                isPresented: $showDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All (\(streaming.userMusicMetadata.count))", role: .destructive) {
                    Task { await deleteAllTracks() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes all \(streaming.userMusicMetadata.count) uploaded track\(streaming.userMusicMetadata.count == 1 ? "" : "s") from cloud storage. Your local files are not affected. This cannot be undone.")
            }
        }
    }

    // MARK: — Not logged in

    private var notLoggedInView: some View {
        VStack(spacing: 24) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 56))
                .foregroundStyle(AppTheme.textSecondary)

            Text("Sign in to Use Cloud Backup")
                .font(AppTheme.headlineFont(size: 18))
                .foregroundStyle(AppTheme.textPrimary)

            Text("Upload your local tracks to secure cloud storage and restore them on any device.")
                .font(AppTheme.bodyFont(size: 14))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showLoginSheet = true
            } label: {
                Label("Sign In / Register", systemImage: "person.crop.circle")
                    .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                    .foregroundStyle(AppTheme.background)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 13)
                    .background(AppTheme.dynamicAccent, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: — Main content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 20) {

                // MARK: Upload progress banner
                if isUploading {
                    uploadProgressBanner
                }

                // MARK: Error banner
                if let err = errorMessage {
                    errorBanner(err)
                }

                // MARK: Auto-backup toggle
                autoBackupToggle

                // MARK: Upload button (prominent shortcut)
                uploadButton

                // MARK: Uploaded tracks list
                uploadedTracksSection

                // MARK: Restore section
                restoreSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    // MARK: — Auto-backup toggle

    private var autoBackupToggle: some View {
        HStack(spacing: 14) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.title3)
                .foregroundStyle(AppTheme.dynamicAccent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-Backup Library")
                    .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Automatically upload downloaded, imported, and scanned songs to your cloud library in the background")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            Toggle("", isOn: $autoCloudBackup)
                .labelsHidden()
                .tint(AppTheme.dynamicAccent)
        }
        .padding(14)
        .background(AppTheme.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: — Upload progress banner

    private var uploadProgressBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.dynamicAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(uploadMessage.isEmpty ? "Uploading…" : uploadMessage)
                    .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)

                if !uploadQueue.isEmpty {
                    Text("\(uploadIndex) of \(uploadQueue.count) files")
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            Spacer()

            if uploadQueue.count > 1 {
                // Show a simple progress indicator
                Text("\(Int(Double(uploadIndex) / Double(max(uploadQueue.count, 1)) * 100))%")
                    .font(AppTheme.monoFont(size: 13))
                    .foregroundStyle(AppTheme.dynamicAccent)
            }
        }
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: — Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.error)
            Text(message)
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(3)
            Spacer()
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(12)
        .background(AppTheme.error.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: — Upload button

    private var uploadButton: some View {
        Button {
            showFilePicker = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.up.fill")
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upload to Cloud")
                        .font(AppTheme.headlineFont(size: 16))
                    Text("Pick one or more audio files")
                        .font(AppTheme.bodyFont(size: 12))
                        .opacity(0.8)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppTheme.background)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(AppTheme.dynamicAccent, in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isUploading)
        .opacity(isUploading ? 0.5 : 1)
    }

    // MARK: — Uploaded tracks section

    @ViewBuilder
    private var uploadedTracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Uploaded Tracks")
                    .font(AppTheme.headlineFont(size: 16))
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                if isDeletingAll {
                    ProgressView()
                        .tint(AppTheme.error)
                        .scaleEffect(0.8)
                } else if streaming.isLoadingUserMusicMetadata {
                    ProgressView()
                        .tint(AppTheme.dynamicAccent)
                        .scaleEffect(0.8)
                } else {
                    if !streaming.userMusicMetadata.isEmpty {
                        Button {
                            showDeleteAllConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(AppTheme.error)
                        }
                    }
                    Button {
                        guard let tok = token else { return }
                        Task { try? await streaming.fetchUserMusicMetadata(token: tok) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                }

                Text("\(streaming.userMusicMetadata.count)")
                    .font(AppTheme.monoFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.surface, in: Capsule())
            }

            if streaming.userMusicMetadata.isEmpty && !streaming.isLoadingUserMusicMetadata {
                emptyState(
                    icon: "cloud",
                    title: "No Uploaded Tracks",
                    message: "Tap Upload to Cloud to back up your audio files."
                )
            } else {
                // LazyVStack, not VStack: this screen renders every uploaded
                // track (thousands for a heavy user), and a plain VStack inside
                // a ScrollView builds/lays out ALL of them synchronously on
                // appear instead of only what's on-screen — a main-thread hang
                // long enough to trip the iOS watchdog and get the app killed.
                LazyVStack(spacing: 0) {
                    ForEach(streaming.userMusicMetadata) { track in
                        uploadedTrackRow(track)
                        if track.id != streaming.userMusicMetadata.last?.id {
                            Divider()
                                .background(AppTheme.background)
                                .padding(.leading, 56)
                        }
                    }
                }
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func uploadedTrackRow(_ track: UserMusicMetadataTrack) -> some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(AppTheme.elevatedSurface)
                    .frame(width: 40, height: 40)
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                    .foregroundStyle(AppTheme.dynamicAccent)
            }

            // Metadata
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title ?? track.filename)
                    .font(AppTheme.bodyFont(size: 14).weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let artist = track.artist, !artist.isEmpty {
                        Text(artist)
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                    if let size = track.fileSizeBytes {
                        Text("·")
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(track.fileSizeText)
                            .font(AppTheme.monoFont(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Text(track.durationText)
                        .font(AppTheme.monoFont(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                if let tempoKeyText = track.tempoKeyText {
                    Text(tempoKeyText)
                        .font(AppTheme.monoFont(size: 10))
                        .foregroundStyle(AppTheme.dynamicAccent.opacity(0.85))
                }
            }

            Spacer()

            // Similar Tracks (harmonic mixing recommendations) — only offered
            // once this track has been analyzed (needs both bpm and musicalKey).
            if track.bpm != nil, track.musicalKey != nil {
                Button {
                    recommendationsFor = track
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
                .buttonStyle(.plain)
            }

            // Delete button
            if deletingID == track.id {
                ProgressView()
                    .tint(AppTheme.error)
                    .scaleEffect(0.8)
            } else {
                Button {
                    pendingDeleteTrack = track
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.error)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: — Restore section

    @ViewBuilder
    private var restoreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Restore to Device")
                .font(AppTheme.headlineFont(size: 16))
                .foregroundStyle(AppTheme.textPrimary)

            if streaming.userMusicMetadata.isEmpty {
                emptyState(
                    icon: "icloud.and.arrow.down",
                    title: "Nothing to Restore",
                    message: "Upload tracks first and they will appear here for re-download."
                )
            } else {
                // Same LazyVStack fix as uploadedTracksSection above — this is
                // a second full render of the same (potentially thousands-long)
                // track list, so it needs the fix independently.
                LazyVStack(spacing: 0) {
                    ForEach(streaming.userMusicMetadata) { track in
                        restoreTrackRow(track)
                        if track.id != streaming.userMusicMetadata.last?.id {
                            Divider()
                                .background(AppTheme.background)
                                .padding(.leading, 56)
                        }
                    }
                }
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func restoreTrackRow(_ track: UserMusicMetadataTrack) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.elevatedSurface)
                    .frame(width: 40, height: 40)
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 15))
                    .foregroundStyle(AppTheme.accentSoft)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title ?? track.filename)
                    .font(AppTheme.bodyFont(size: 14).weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)

                if let artist = track.artist, !artist.isEmpty {
                    Text(artist)
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if restoringFilename == track.filename {
                ProgressView()
                    .tint(AppTheme.dynamicAccent)
                    .scaleEffect(0.8)
            } else {
                Button {
                    Task { await restoreTrack(track) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: — Empty state helper

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(AppTheme.textSecondary)
            Text(title)
                .font(AppTheme.headlineFont(size: 15))
                .foregroundStyle(AppTheme.textPrimary)
            Text(message)
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: — Actions

    private func handleFilePick(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            uploadQueue = urls
            uploadIndex = 0
            errorMessage = nil
            Task { await runUploadQueue() }
        case .failure(let error):
            errorMessage = "File picker error: \(error.localizedDescription)"
        }
    }

    private func runUploadQueue() async {
        guard let tok = token else {
            errorMessage = "Not logged in."
            return
        }
        isUploading = true
        defer { isUploading = false; uploadMessage = "" }

        for (idx, url) in uploadQueue.enumerated() {
            uploadIndex = idx + 1
            uploadMessage = "Uploading \(url.lastPathComponent)…"

            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            // Build metadata from file attributes where possible
            var meta = TrackMetadata()
            meta.hasArtwork = await LumisoundExclusiveExtensionService.hasEmbeddedThumbnailTag(fileURL: url)
            // Duration and bitrate are not easily available without AVFoundation;
            // pass what we can and let the server handle the rest.

            do {
                _ = try await streaming.uploadTrack(fileURL: url, token: tok, metadata: meta)
            } catch {
                errorMessage = "Upload failed for \(url.lastPathComponent): \(error.localizedDescription)"
                // Continue with remaining files
            }
        }

        uploadQueue = []
        // Refresh the metadata list
        try? await streaming.fetchUserMusicMetadata(token: tok)
    }

    private func deleteTrack(_ track: UserMusicMetadataTrack) async {
        guard let tok = token else { return }
        deletingID = track.id
        defer { deletingID = nil }

        do {
            // Delete from server via the existing /user/music/{filepath} endpoint
            try await streaming.deleteUserMusic(path: track.filename, token: tok)
            // Also remove the metadata row by refreshing
            try? await streaming.fetchUserMusicMetadata(token: tok)
            // Also refresh the basic music list
            await streaming.fetchUserMusic(token: tok)
        } catch StreamingError.httpError(404) {
            // The file (and its metadata row) is already gone on the server —
            // that's the state we wanted, so just refresh the list silently
            // instead of surfacing a "Delete failed" error.
            try? await streaming.fetchUserMusicMetadata(token: tok)
            await streaming.fetchUserMusic(token: tok)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func deleteAllTracks() async {
        guard let tok = token else { return }
        isDeletingAll = true
        defer { isDeletingAll = false }

        for track in streaming.userMusicMetadata {
            do {
                try await streaming.deleteUserMusic(path: track.filename, token: tok)
            } catch StreamingError.httpError(404) {
                // Already gone — nothing to do.
            } catch {
                errorMessage = "Delete failed for \(track.title ?? track.filename): \(error.localizedDescription)"
                // Continue with remaining tracks
            }
        }

        try? await streaming.fetchUserMusicMetadata(token: tok)
        await streaming.fetchUserMusic(token: tok)
    }

    private func restoreTrack(_ track: UserMusicMetadataTrack) async {
        guard let tok = token else { return }
        restoringFilename = track.filename
        defer { restoringFilename = nil }

        // Build a minimal UserMusicTrack so we can use the existing stream endpoint.
        // `track.filename` may itself be a Lumisound-locked "<realext>.lms" backup
        // (see LumisoundLockFormat) — restoring one is actually a no-op download:
        // it lands back in the local import dir under its exact ".lms" filename
        // below, which the local library scan already recognizes and unlocks at
        // play time, same as any freshly-converted local file.
        let isLockedBackup = (track.filename as NSString).pathExtension.lowercased() == LumisoundExclusiveExtensionService.marker
        let realExt = isLockedBackup
            ? (track.filename as NSString).deletingPathExtension.split(separator: ".").last.map(String.init) ?? ""
            : String(track.filename.split(separator: ".").last ?? "")
        let userTrack = UserMusicTrack(
            id: track.id,
            title: track.title ?? track.filename,
            artist: track.artist ?? "",
            album: track.album ?? "",
            duration: track.durationSeconds ?? 0,
            genre: track.genre ?? "",
            trackNumber: "",
            hasArtwork: track.hasArtwork,
            serverPath: track.filename,
            filename: track.filename,
            ext: realExt,
            isLocked: isLockedBackup
        )

        guard let streamURL = streaming.userMusicStreamURL(for: userTrack, token: tok) else {
            errorMessage = "Could not build stream URL for restore."
            return
        }

        // Download the file to the local Documents directory
        let importDir = streaming.downloadDirectory
        do {
            try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        } catch {
            // withIntermediateDirectories: true doesn't throw for "already
            // exists" — a failure here is a real filesystem problem
            // (permissions, disk full), which the download below would also
            // hit but with a far less specific error. Surface it now instead
            // of masking the root cause behind a generic download failure.
            appWarn("restore: createDirectory failed for \(importDir.path): \(error.localizedDescription)", category: "storage")
            errorMessage = "Restore failed: could not create download folder (\(error.localizedDescription))"
            return
        }

        let destURL = importDir.appendingPathComponent(track.filename)
        if FileManager.default.fileExists(atPath: destURL.path) {
            // Already present — say so, otherwise the tap appears to do nothing.
            errorMessage = "\(track.title ?? track.filename) is already on this device."
            return
        }

        var request = URLRequest(url: streamURL)
        request.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300

        do {
            let (tempURL, response) = try await Core.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                errorMessage = "Restore failed: HTTP \(http.statusCode)"
                return
            }
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct UploadMusicView_Previews: PreviewProvider {
    static var previews: some View {
        UploadMusicView()
            .environmentObject(StreamingService())
            .environmentObject(AccountService())
    }
}
#endif
