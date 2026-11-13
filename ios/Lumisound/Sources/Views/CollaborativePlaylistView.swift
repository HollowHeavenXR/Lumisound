import SwiftUI

// MARK: - CollaborativePlaylistView
//
// Mode A (playlist != nil): Share a local playlist — generate a link, copy it, revoke it.
// Mode B (playlist == nil): Open a shared playlist by token — fetch metadata and play all.

struct CollaborativePlaylistView: View {
    let playlist: Playlist?

    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var library: LibraryManager

    @StateObject private var collaborativeService = CollaborativeService()

    @Environment(\.dismiss) private var dismiss

    /// Live song list for the playlist, resolved from LibraryManager so mutations are reflected.
    private var songs: [Song] {
        guard let pl = playlist else { return [] }
        return library.songs(for: pl)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let pl = playlist {
                    ShareModeView(
                        playlist: pl,
                        songs: songs,
                        collaborativeService: collaborativeService,
                        account: account,
                        streaming: streaming
                    )
                } else {
                    OpenModeView(
                        collaborativeService: collaborativeService,
                        player: player,
                        streaming: streaming
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .tint(AppTheme.textSecondary)
                }
            }
        }
        .onDisappear {
            collaborativeService.reset()
        }
    }
}

// MARK: - Mode A: Share a Playlist

private struct ShareModeView: View {
    let playlist: Playlist
    let songs: [Song]
    let collaborativeService: CollaborativeService

    let account: AccountService
    let streaming: StreamingService

    @State private var didCopy = false
    @State private var didCopyCode = false

    private var shareLink: String? {
        guard let token = collaborativeService.shareToken else { return nil }
        return "lumisound://shared/\(token)"
    }

    /// Human-readable message bundled into the system share sheet so the
    /// recipient knows both the code to type into "Open Shared Playlist" and
    /// the deep link that opens it directly.
    private func shareMessage(code: String) -> String {
        "Join my Lumisound playlist \"\(playlist.name)\"! Open the app → Playlists → Open Shared Playlist and enter code \(code), or tap: lumisound://shared/\(code)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // Playlist header
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.elevatedSurface)
                            .frame(width: 80, height: 80)
                        Image(systemName: "music.note.list")
                            .font(.system(size: 34))
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }

                    Text(playlist.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppTheme.textPrimary)

                    let count = playlist.songCount
                    Text("\(count) \(count == 1 ? "song" : "songs")")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.top, 12)

                // Error banner
                if let error = collaborativeService.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.error)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.error)
                        Spacer()
                        Button {
                            collaborativeService.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .padding(12)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal)
                }

                // Share code area
                if let code = collaborativeService.shareToken {
                    VStack(spacing: 12) {
                        Text("Share Code")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // A short code others can type into "Open Shared Playlist"
                        // — easier to read aloud or retype than the full link below.
                        Button {
                            UIPasteboard.general.string = code
                            withAnimation(LumiMotion.glide) { didCopyCode = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                withAnimation(LumiMotion.glide) { didCopyCode = false }
                            }
                        } label: {
                            HStack {
                                Text(code)
                                    .font(.system(.title2, design: .monospaced).weight(.bold))
                                    .kerning(2)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Image(systemName: didCopyCode ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(didCopyCode ? AppTheme.success : AppTheme.dynamicAccent)
                            }
                            .padding(12)
                            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        // Native share sheet — lets the user actually SEND the
                        // code/link to another person (Messages, Mail, etc.)
                        // rather than only copying it to the clipboard.
                        ShareLink(item: shareMessage(code: code)) {
                            Label("Share Code…", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(AppTheme.dynamicAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal)
                }

                // Share link area
                if let link = shareLink {
                    VStack(spacing: 12) {
                        Text("Share Link")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Copyable token
                        HStack(spacing: 8) {
                            Text(link)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        HStack(spacing: 12) {
                            // Copy Link
                            Button {
                                UIPasteboard.general.string = link
                                withAnimation(LumiMotion.glide) { didCopy = true }
                                Task {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    withAnimation(LumiMotion.glide) { didCopy = false }
                                }
                            } label: {
                                Label(
                                    didCopy ? "Copied!" : "Copy Link",
                                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                                )
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(didCopy ? AppTheme.success : AppTheme.dynamicAccent)

                            // Revoke Link
                            Button {
                                guard let token = collaborativeService.shareToken,
                                      let authToken = account.token else { return }
                                Task {
                                    await collaborativeService.revokeShare(
                                        shareToken: token,
                                        bridgeURL: streaming.bridgeURL,
                                        authToken: authToken
                                    )
                                }
                            } label: {
                                Label("Revoke", systemImage: "link.badge.minus")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(AppTheme.error)
                            .disabled(collaborativeService.isLoading)
                        }
                    }
                    .padding(.horizontal)
                } else {
                    // Generate Share Link button
                    Button {
                        guard let authToken = account.token else {
                            collaborativeService.errorMessage = "You must be logged in to share a playlist."
                            return
                        }
                        Task {
                            await collaborativeService.sharePlaylist(
                                playlistName: playlist.name,
                                tracks: songs,
                                bridgeURL: streaming.bridgeURL,
                                authToken: authToken
                            )
                        }
                    } label: {
                        if collaborativeService.isLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(.white)
                                Text("Generating Link…")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Generate Share Link", systemImage: "link.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.dynamicAccent)
                    .disabled(collaborativeService.isLoading || account.token == nil)
                    .padding(.horizontal)

                    if !account.isLoggedIn {
                        Text("Sign in to share playlists with others.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }

                // Collaborators — separate from the link/code above. Adding someone
                // by username gives them edit/view access to this playlist directly
                // in their own account (GET /user/playlists/shared-with-me), rather
                // than via a one-off link.
                if account.isLoggedIn {
                    CollaboratorsSection(playlistId: playlist.id.uuidString, account: account)
                        .padding(.horizontal)
                }

                Spacer(minLength: 40)
            }
            .padding(.vertical, 8)
        }
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Share Playlist")
    }
}

// MARK: - Collaborators Section

private struct CollaboratorsSection: View {
    let playlistId: String
    let account: AccountService

    @State private var collaborators: [PlaylistCollaborator] = []
    @State private var username = ""
    @State private var role = "editor"
    @State private var isLoading = false
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("Collaborators")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(AppTheme.textPrimary)

                LumiPicker("Role", selection: $role) {
                    Text("Editor").lumiOptionLabel("Editor").tag("editor")
                    Text("Viewer").lumiOptionLabel("Viewer").tag("viewer")
                }
                .tint(AppTheme.dynamicAccent)

                Button {
                    addCollaborator()
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                }
                .disabled(isLoading || username.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let localError {
                Text(localError)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !collaborators.isEmpty {
                VStack(spacing: 0) {
                    ForEach(collaborators) { collab in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(collab.username)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text(collab.role.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer()
                            Button {
                                removeCollaborator(userId: collab.userId)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(AppTheme.error)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        Divider().background(AppTheme.background)
                    }
                }
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .task { await loadCollaborators() }
    }

    private func loadCollaborators() async {
        collaborators = await account.fetchCollaborators(playlistId: playlistId)
    }

    private func addCollaborator() {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        localError = nil
        Task {
            let ok = await account.addCollaborator(playlistId: playlistId, username: trimmed, role: role)
            if ok {
                username = ""
                await loadCollaborators()
            } else {
                localError = account.errorMessage ?? "Failed to add collaborator."
            }
            isLoading = false
        }
    }

    private func removeCollaborator(userId: String) {
        Task {
            if await account.removeCollaborator(playlistId: playlistId, userId: userId) {
                await loadCollaborators()
            }
        }
    }
}

// MARK: - Mode B: Open a Shared Playlist

private struct OpenModeView: View {
    let collaborativeService: CollaborativeService
    let player: AudioPlayerManager
    let streaming: StreamingService

    @State private var tokenInput: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // Code entry
                VStack(spacing: 12) {
                    Text("Enter Share Code")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        TextField("e.g. AB3KQ7XZ", text: $tokenInput)
                            .foregroundStyle(AppTheme.textPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .font(.system(.body, design: .monospaced))
                            .padding(12)
                            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Button {
                            let trimmed = tokenInput
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .uppercased()
                            guard !trimmed.isEmpty else { return }
                            Task {
                                await collaborativeService.fetchSharedPlaylist(
                                    shareToken: trimmed,
                                    bridgeURL: streaming.bridgeURL
                                )
                            }
                        } label: {
                            if collaborativeService.isLoading {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 60, height: 44)
                            } else {
                                Text("Open")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(width: 60, height: 44)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.dynamicAccent)
                        .disabled(
                            collaborativeService.isLoading
                            || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)

                // Error banner
                if let error = collaborativeService.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.error)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.error)
                        Spacer()
                        Button {
                            collaborativeService.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .padding(12)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal)
                }

                // Shared playlist result
                if let shared = collaborativeService.importedPlaylist {
                    SharedPlaylistResultView(
                        shared: shared,
                        player: player,
                        streaming: streaming
                    )
                }

                Spacer(minLength: 40)
            }
            .padding(.vertical, 8)
        }
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Open Shared Playlist")
    }
}

// MARK: - Shared Playlist Result

private struct SharedPlaylistResultView: View {
    let shared: SharedPlaylist
    let player: AudioPlayerManager
    let streaming: StreamingService

    // Shared-playlist tracks are metadata-only snapshots (title/artist/album/duration,
    // no stream URL — see SharedTrack). "Play All" has to resolve each one to a
    // playable source via the bridge's search before it can queue anything; otherwise
    // the player would be handed Songs with url == nil, silently "play" silence, and
    // never advance (AudioPlayerManager.scheduleCurrent skips nil-URL songs without
    // setting an error). isResolving drives the button's loading state while that
    // per-track lookup runs.
    @State private var isResolving = false
    @State private var resolveError: String?
    @State private var playAllTask: Task<Void, Never>?

    private var durationText: String {
        let total = Int(shared.tracks.reduce(0) { $0 + $1.duration }.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    var body: some View {
        VStack(spacing: 16) {

            // Header card
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.elevatedSurface)
                        .frame(width: 72, height: 72)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 30))
                        .foregroundStyle(AppTheme.dynamicAccent)
                }

                Text(shared.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("by \(shared.owner)")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)

                let count = shared.tracks.count
                Text("\(count) \(count == 1 ? "song" : "songs") · \(durationText)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            // Resolve error banner
            if let resolveError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.error)
                    Text(resolveError)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.error)
                    Spacer()
                    Button {
                        self.resolveError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .padding(12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal)
            }

            // Play All — shared tracks carry no stream URL, so resolve each one to a
            // playable match via the bridge's search before queuing (see isResolving doc).
            Button {
                guard !isResolving else { return }
                resolveError = nil
                isResolving = true
                playAllTask = Task {
                    defer { isResolving = false }
                    var resolved: [Song] = []
                    for track in shared.tracks {
                        guard !Task.isCancelled else { return }
                        guard let match = await streaming.bestMatch(forTitle: track.title, artist: track.artist),
                              let url = try? await streaming.streamURL(for: match) else { continue }
                        resolved.append(streaming.toSong(track: match, streamURL: url))
                    }
                    guard !Task.isCancelled else { return }
                    guard !resolved.isEmpty else {
                        resolveError = "Couldn't find playable matches for any track in this playlist."
                        return
                    }
                    player.setQueue(resolved, startIndex: 0, autoplay: true)
                }
            } label: {
                if isResolving {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Finding playable tracks…")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Play All", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.dynamicAccent)
            .disabled(isResolving)
            .padding(.horizontal)

            // Track list
            VStack(spacing: 0) {
                ForEach(Array(shared.tracks.enumerated()), id: \.element.id) { index, track in
                    SharedTrackRow(track: track, index: index + 1)

                    if index < shared.tracks.count - 1 {
                        Divider()
                            .background(AppTheme.surface)
                            .padding(.leading, 56)
                    }
                }
            }
            .background(AppTheme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal)
        }
        .onDisappear {
            playAllTask?.cancel()
        }
    }
}

// MARK: - Shared Track Row

private struct SharedTrackRow: View {
    let track: SharedTrack
    let index: Int

    private var durationText: String {
        let s = Int(track.duration.rounded())
        guard s > 0 else { return "--:--" }
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(durationText)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
