import SwiftUI
import UniformTypeIdentifiers

extension StreamSearchView {

    // MARK: — Streaming results (YouTube / SoundCloud)

    var streamResultsBody: some View {
        Group {
            if streaming.isSearching || streaming.isResolvingPlaylist {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(AppTheme.dynamicAccent)
                            .scaleEffect(0.8)
                        Text(streaming.isResolvingPlaylist ? "Loading playlist…" : "Searching…")
                            .font(AppTheme.bodyFont(size: 13).weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    SkeletonList()
                }
            } else if searchText.isEmpty {
                trendingSearchesBody
            } else if streaming.searchResults.isEmpty {
                VStack(spacing: 0) {
                    if !suggestions.isEmpty {
                        suggestionsBody
                    }
                    Spacer()
                    CloudEmptyStateView(
                        icon: "magnifyingglass",
                        title: "No Results",
                        message: "Nothing matched \"\(searchText)\" on \(sourceLabel(selectedSource)). Try a different search term or source."
                    )
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    // Playlist banner — only shown after a successful playlist resolve
                    if streaming.isPlaylistResult && !streaming.searchResults.isEmpty {
                        VStack(spacing: 8) {
                            HStack(spacing: 10) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(AppTheme.dynamicAccent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Playlist")
                                        .font(AppTheme.bodyFont(size: 11).weight(.semibold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .kerning(0.6)
                                    Text("\(streaming.searchResults.count) tracks")
                                        .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                }
                                Spacer()
                                if isDownloadingAll {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .tint(AppTheme.dynamicAccent)
                                            .scaleEffect(0.8)
                                        Text("\(downloadAllDone)/\(downloadAllTotal)")
                                            .font(AppTheme.monoFont(size: 13))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                } else if !failedTrackIDs.isEmpty {
                                    // Only the tracks that failed last time are retried — no
                                    // full search/resolve refresh, unlike the generic error
                                    // banner's "Retry" which re-resolves the whole playlist.
                                    Button {
                                        handleRetryFailedDownloads()
                                    } label: {
                                        Label("Retry \(failedTrackIDs.count)", systemImage: "arrow.clockwise")
                                            .font(AppTheme.bodyFont(size: 13).weight(.semibold))
                                            .foregroundStyle(AppTheme.warning)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .adaptiveGlass(in: Capsule(), fallback: AppTheme.warning.opacity(0.15))
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button {
                                        handleDownloadAll()
                                    } label: {
                                        Label("Download All", systemImage: "arrow.down.circle.fill")
                                            .font(AppTheme.bodyFont(size: 13).weight(.semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .adaptiveGlass(tint: AppTheme.dynamicAccent, in: Capsule(), fallback: AppTheme.dynamicAccent)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // Determinate progress bar while a "Download All" run is active.
                            if isDownloadingAll && downloadAllTotal > 0 {
                                ProgressView(value: Double(downloadAllDone), total: Double(downloadAllTotal))
                                    .tint(AppTheme.dynamicAccent)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .adaptiveGlass(in: Rectangle(), fallback: .ultraThinMaterial)
                        .overlay(Divider().opacity(0.3), alignment: .bottom)
                    }

                    // Result count + layout picker — always shown (not just for
                    // playlist resolves) so the column control is reachable from
                    // any search.
                    HStack {
                        Text("\(streaming.searchResults.count) result\(streaming.searchResults.count == 1 ? "" : "s")")
                            .font(AppTheme.bodyFont(size: 12).weight(.medium))
                            .foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        streamResultsColumnPicker
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                    if searchResultColumns == 1 {
                        List {
                            // Group results into per-source sections (YouTube / SoundCloud)
                            // so the user can clearly tell which platform each result came
                            // from. Most single-source searches will only populate one
                            // section, but playlist resolves can mix sources.
                            ForEach(groupedResults, id: \.source) { group in
                                Section {
                                    ForEach(Array(group.tracks.enumerated()), id: \.element.id) { localIndex, track in
                                        // Cap the stagger index: it only drives the fade-in delay, and
                                        // the old `searchResults.firstIndex` lookup here was O(n) per
                                        // row → O(n²) over a big playlist (a main-thread hang).
                                        let globalIndex = min(localIndex, 12)
                                        StreamTrackRow(
                                            track: track,
                                            isLoading: loadingTrackID == track.id,
                                            isDownloading: downloadingTrackIDs.contains(track.id),
                                            isDownloaded: downloadedTrackIDs.contains(track.id),
                                            onPlay: { handlePlay(track: track) },
                                            onAddToQueue: { handleAddToQueue(track: track) },
                                            onDownload: { handleDownload(track: track) }
                                        )
                                        // The row now supplies its own floating glass-card
                                        // background, so the list row itself stays transparent
                                        // with no separator line between cards.
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                        // Staggered fade-in when results first appear
                                        .modifier(StaggeredFadeInModifier(index: globalIndex, token: resultsAnimationToken))
                                        .contextMenu { streamResultContextMenu(for: track) }
                                    }
                                } header: {
                                    CloudSectionHeader(icon: sourceIcon(group.source), text: sourceLabel(group.source))
                                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                                ForEach(groupedResults, id: \.source) { group in
                                    Section {
                                        LazyVGrid(columns: gridColumns, spacing: 12) {
                                            ForEach(Array(group.tracks.enumerated()), id: \.element.id) { localIndex, track in
                                                let globalIndex = min(localIndex, 12)
                                                StreamTrackGridCell(
                                                    track: track,
                                                    isLoading: loadingTrackID == track.id,
                                                    isDownloading: downloadingTrackIDs.contains(track.id),
                                                    isDownloaded: downloadedTrackIDs.contains(track.id),
                                                    onPlay: { handlePlay(track: track) },
                                                    onAddToQueue: { handleAddToQueue(track: track) },
                                                    onDownload: { handleDownload(track: track) }
                                                )
                                                .modifier(StaggeredFadeInModifier(index: globalIndex, token: resultsAnimationToken))
                                                .contextMenu { streamResultContextMenu(for: track) }
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    } header: {
                                        CloudSectionHeader(icon: sourceIcon(group.source), text: sourceLabel(group.source))
                                            .padding(.horizontal, 16)
                                            .padding(.top, 8)
                                            .padding(.bottom, 4)
                                            .background(Color.clear)
                                    }
                                }
                            }
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
        }
    }

    /// Column-count control for the streaming search results grid (1/2/3),
    /// same pattern as AlbumsTab's toolbar menu — surfaced inline above the
    /// results (rather than in StreamSearchView's shared navigation toolbar,
    /// which spans every sub-tab, not just streaming search).
    var streamResultsColumnPicker: some View {
        LumiMenu {
            Button { searchResultColumns = 1 } label: {
                Label("List", systemImage: "rectangle.grid.1x2")
            }
            Button { searchResultColumns = 2 } label: {
                Label("2 Columns", systemImage: "square.grid.2x2")
            }
            Button { searchResultColumns = 3 } label: {
                Label("3 Columns", systemImage: "square.grid.3x3")
            }
        } label: {
            Image(systemName: searchResultColumns == 1 ? "rectangle.grid.1x2" : searchResultColumns == 2 ? "square.grid.2x2" : "square.grid.3x3")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 32, height: 32)
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: searchResultColumns)
    }

    @ViewBuilder
    private func streamResultContextMenu(for track: StreamTrack) -> some View {
        Button {
            handlePlayNext(track: track)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            handleAddToQueue(track: track)
        } label: {
            Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Button {
            handleDownload(track: track)
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        if !track.youtubeURL.isEmpty, let linkURL = URL(string: track.youtubeURL) {
            Divider()
            Button {
                UIPasteboard.general.string = track.youtubeURL
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            ShareLink(item: linkURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}
