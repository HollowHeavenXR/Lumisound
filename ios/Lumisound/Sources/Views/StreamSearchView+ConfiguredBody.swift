import SwiftUI
import UniformTypeIdentifiers

extension StreamSearchView {

    // MARK: — Configured body

    var configuredBody: some View {
        VStack(spacing: 0) {
            // Source picker — a custom icon+label pill row (matching the
            // sliding-pill language DiscoverView's tab selector already
            // established) instead of the stock `.segmented` Picker, which
            // rendered with default iOS colors and no accent tint or icons.
            sourcePillSelector
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .onChange(of: selectedSource) { _ in
                    if !searchText.isEmpty {
                        triggerSearch()
                    }
                }

            // Error banner — glass card with an icon-scale pop-in and a
            // dismiss control, sliding down from the top instead of just
            // appearing, so a failure reads as a distinct event rather than
            // a static line of red text.
            if let error = streaming.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.warning)
                    Text(error)
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.warning)
                        .lineLimit(2)
                    Spacer()
                    if !searchText.isEmpty {
                        Button {
                            triggerSearch()
                        } label: {
                            Text("Retry")
                                .font(AppTheme.bodyFont(size: 13).weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(AppTheme.warning, in: Capsule())
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                    Button {
                        withAnimation(LumiMotion.glide(0.2)) {
                            streaming.errorMessage = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .adaptiveGlass(tint: AppTheme.warning, in: Rectangle(), fallback: AppTheme.warning.opacity(0.14))
                .overlay(Divider().background(AppTheme.warning.opacity(0.3)), alignment: .bottom)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Results
            if selectedSource == "server" {
                serverResultsBody
            } else if selectedSource == "my" {
                userLibraryBody
            } else {
                streamResultsBody
            }
        }
        .animation(LumiMotion.settle, value: streaming.errorMessage != nil)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: selectedSource == "server" ? "Search server library…"
                : selectedSource == "my"    ? "Search your library…"
                : "Search or paste a YouTube playlist URL…"
        )
        .onSubmit(of: .search) {
            triggerSearch()
        }
        .onChange(of: searchText) { newValue in
            if newValue.isEmpty {
                streaming.searchResults = []
                streaming.serverTracks = []
                streaming.errorMessage = nil
                streaming.isPlaylistResult = false
                suggestions = []
                return
            }
            if selectedSource == "youtube" || selectedSource == "soundcloud" {
                Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if searchText == newValue {
                        suggestions = await streaming.searchSuggestions(query: newValue)
                    }
                }
            }
            // Debounced auto-search — mirrors LibraryView's 300ms pattern (the only
            // existing trigger here was `.onSubmit(of: .search)`, which fires solely
            // on the keyboard's Search/Return key). Most users type a query and expect
            // results to appear, never realizing they need to explicitly submit —
            // which is exactly what made this "search" look broken/unresponsive.
            // 400ms (vs Library's 300ms) gives the network round-trip to the bridge
            // a beat of slack so fast typists don't fire a search per keystroke.
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if searchText == newValue {
                    triggerSearch()
                }
            }
        }
        .onChange(of: streaming.searchResults.count) { _ in
            resultsAnimationToken = UUID()
            refreshDownloadedStatus()
        }
        .onChange(of: streaming.serverTracks.count) { _ in
            refreshDownloadedStatus()
        }
        // `library.allSongs` only settles after the initial scan (and after any
        // subfolder/Force Metadata rescan) completes — re-check downloaded status
        // whenever it changes so subfolder-imported tracks correctly flip their
        // download icon to "already downloaded" instead of staying stuck on
        // "not downloaded" forever.
        .onChange(of: library.allSongs.count) { _ in
            refreshDownloadedStatus()
        }
        // When a playlist resolves, freshly scan the local library FIRST so
        // already-owned tracks (including ones in subfolders or restored from a
        // backup, which a stale `allSongs` would miss) are flagged as downloaded
        // immediately as the playlist appears — instead of showing as downloadable
        // until some later scan happens to settle.
        .onChange(of: streaming.isPlaylistResult) { isPlaylist in
            guard isPlaylist else { return }
            Task {
                await library.scanLocalDocumentsAsync()
                refreshDownloadedStatus()
            }
        }
        // Playback failures (expired CDN URL, YouTube bot-detection, network errors, etc.)
        // surface only on `player.errorMessage`, which previously had no visible home
        // outside Settings → Audio. Mirroring it into the banner here means tapping ▶
        // and having the stream fail to load shows *something* instead of looking like
        // the tap did nothing.
        .onChange(of: player.errorMessage) { newValue in
            if let message = newValue {
                streaming.errorMessage = message
            }
        }
        .onChange(of: selectedSource) { src in
            if src == "my" {
                guard let token = account.token else { return }
                Task { await streaming.fetchUserMusic(token: token) }
                Task { await streaming.fetchStorageUsage(token: token) }
            } else if src == "server" {
                // Browse the whole server library on open (empty query) so the
                // Server tab actually shows content instead of an empty prompt.
                Task { await streaming.searchServerLibrary(query: searchText) }
            }
        }
        .onAppear {
            if selectedSource == "my", let token = account.token {
                Task { await streaming.fetchUserMusic(token: token) }
                Task { await streaming.fetchStorageUsage(token: token) }
            }
            if selectedSource == "server" {
                Task { await streaming.searchServerLibrary(query: searchText) }
            }
            if trendingQueries.isEmpty {
                loadTrending(days: trendingWindowDays)
            }
            refreshDownloadedStatus()
        }
        // fileImporter must be at this level (NavigationStack content root), NOT inside
        // a nested List or conditional branch — SwiftUI can't present the picker from deep hierarchy.
        .sheet(item: $selectedInfoTrack) { track in
            UserMusicInfoSheet(track: track)
        }
        .fileImporter(
            isPresented: $showUploadPicker,
            allowedContentTypes: AudioImportTypes.all,
            allowsMultipleSelection: true
        ) { result in
            guard let token = account.token else { return }
            switch result {
            case .success(let urls):
                Task {
                    for url in urls {
                        let didAccess = url.startAccessingSecurityScopedResource()
                        do {
                            try await streaming.uploadToUserLibrary(fileURL: url, token: token)
                        } catch {
                            streaming.errorMessage = "Upload failed: \(error.localizedDescription)"
                        }
                        if didAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    await streaming.fetchUserMusic(token: token)
                    await streaming.fetchStorageUsage(token: token)
                }
            case .failure(let error):
                streaming.errorMessage = "File picker error: \(error.localizedDescription)"
            }
        }
    }

    /// Custom icon+label pill row replacing the stock `.segmented` Picker —
    /// each source gets an icon, the active pill slides via
    /// `matchedGeometryEffect` (namespace lives on `StreamSearchView` itself
    /// since extensions can't hold `@Namespace` storage), and taps get the
    /// same tactile press feedback as every other control in this redesign.
    var sourcePillSelector: some View {
        HStack(spacing: 6) {
            ForEach(sources, id: \.self) { src in
                Button {
                    withAnimation(LumiMotion.settle) {
                        selectedSource = src
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: sourceIcon(src))
                            .font(.system(size: 11, weight: .semibold))
                        Text(sourceLabel(src))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(selectedSource == src ? .white : AppTheme.textSecondary)
                    .background {
                        if selectedSource == src {
                            Capsule(style: .continuous)
                                .fill(AppTheme.dynamicAccentGradient)
                                .shadow(color: AppTheme.dynamicAccent.opacity(0.4), radius: 6, x: 0, y: 3)
                                .matchedGeometryEffect(id: "sourcePill", in: sourcePillNamespace)
                        } else {
                            Capsule(style: .continuous)
                                .fill(AppTheme.surface.opacity(0.6))
                                .overlay(Capsule().stroke(.white.opacity(0.06), lineWidth: 1))
                        }
                    }
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }
}
