import SwiftUI
import UniformTypeIdentifiers

extension StreamSearchView {

    // MARK: — My Library body

    var userLibraryBody: some View {
        Group {
            if !account.isLoggedIn {
                VStack(spacing: 0) {
                    Spacer()
                    CloudEmptyStateView(
                        icon: "person.crop.circle.badge.questionmark",
                        title: "Log In Required",
                        message: "Log in to access your personal cloud library — upload tracks and stream them on any device."
                    )
                    Spacer()
                }
            } else if streaming.isLoadingUserMusic {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(AppTheme.dynamicAccent)
                            .scaleEffect(0.8)
                        Text("Loading your library…")
                            .font(AppTheme.bodyFont(size: 13).weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    SkeletonList()
                }
            } else {
                List {
                    if !searchText.isEmpty && !matchingLocalSongs.isEmpty {
                        Section {
                            ForEach(matchingLocalSongs) { song in
                                SongRow(song: song, isCurrent: player.currentSong?.id == song.id)
                                    .listRowBackground(AppTheme.surface)
                                    .listRowSeparatorTint(AppTheme.background)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        player.play(song: song, in: matchingLocalSongs)
                                    }
                            }
                        } header: {
                            CloudSectionHeader(icon: "iphone", text: "On This Device")
                        }
                    }

                    if !searchText.isEmpty && !matchingDownloadHistory.isEmpty {
                        Section {
                            ForEach(matchingDownloadHistory) { item in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(AppTheme.bodyFont(size: 15))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(item.artist)
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if downloadingTrackIDs.contains(item.id) {
                                        ProgressView().tint(AppTheme.dynamicAccent)
                                    } else if downloadedTrackIDs.contains(item.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AppTheme.success)
                                            .transition(.scale.combined(with: .opacity))
                                    } else {
                                        Button {
                                            handleDownload(track: item.asStreamTrack)
                                        } label: {
                                            Image(systemName: "arrow.down.circle")
                                                .font(.system(size: 20))
                                                .foregroundStyle(AppTheme.dynamicAccent)
                                        }
                                        .buttonStyle(PressableButtonStyle())
                                    }
                                }
                                .animation(LumiMotion.snap, value: downloadedTrackIDs.contains(item.id))
                                .padding(.vertical, 4)
                                .listRowBackground(AppTheme.surface)
                                .listRowSeparatorTint(AppTheme.background)
                            }
                        } header: {
                            CloudSectionHeader(icon: "clock.arrow.circlepath", text: "Previously Downloaded")
                        }
                    }

                    // Storage usage — the one piece of the Personal Cloud
                    // Library the server has always tracked (GET
                    // /user/storage/usage) but the app never showed, so this
                    // screen read as "a file list with no sense of what your
                    // account actually holds or how much room is left."
                    if let usage = streaming.storageUsage {
                        Section {
                            StorageUsageRow(usage: usage)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .adaptiveGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: .ultraThinMaterial)
                        }
                    }

                    // Upload button header
                    Section {
                        Button {
                            showUploadPicker = true
                        } label: {
                            HStack {
                                Label("Upload Music to Server", systemImage: "icloud.and.arrow.up")
                                    .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                                    .foregroundStyle(AppTheme.dynamicAccent)
                                Spacer()
                                if streaming.isUploadingUserMusic {
                                    ProgressView()
                                        .tint(AppTheme.dynamicAccent)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(streaming.isUploadingUserMusic)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: .ultraThinMaterial)
                    }

                    if streaming.userMusicTracks.isEmpty {
                        Section {
                            CloudEmptyStateView(
                                icon: "folder.badge.plus",
                                title: "Your Library Is Empty",
                                message: "Upload music files to your personal server folder to play them anywhere.",
                                actionTitle: "Upload Music",
                                action: { showUploadPicker = true }
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    } else {
                        Section {
                            ForEach(streaming.userMusicTracks) { track in
                                UserMusicTrackRow(
                                    track: track,
                                    artworkURL: streaming.userMusicArtworkURL(for: track),
                                    isDeleting: deletingUserTrackPath == track.serverPath,
                                    onPlay: { handleUserLibraryPlay(track: track) },
                                    onInfo: { selectedInfoTrack = track },
                                    onDelete: { handleUserLibraryDelete(track: track) }
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            }
                        } header: {
                            CloudSectionHeader(icon: "icloud.fill", text: "My Cloud Library")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task(id: libraryMatchKey) { await refreshLibraryMatches() }
    }
}

// MARK: - StorageUsageRow

/// Compact "used of quota" summary + progress bar for the Personal Cloud
/// Library, shown at the top of the "My Library" tab.
private struct StorageUsageRow: View {
    let usage: StorageUsage

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private var usedText: String { Self.byteFormatter.string(fromByteCount: Int64(usage.usedBytes)) }
    private var quotaText: String { Self.byteFormatter.string(fromByteCount: Int64(usage.quotaBytes)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Storage", systemImage: "internaldrive")
                    .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(usage.isUnlimited ? usedText : "\(usedText) of \(quotaText)")
                    .font(.footnote)
                    .foregroundStyle(usage.quotaExceeded ? AppTheme.error : AppTheme.textSecondary)
            }

            if let fraction = usage.usedFraction {
                ProgressView(value: fraction)
                    .tint(usage.quotaExceeded ? AppTheme.error : AppTheme.dynamicAccent)
            }

            Text("\(usage.musicCount) \(usage.musicCount == 1 ? "track" : "tracks")\(usage.galleryBytes > 0 ? " · gallery backups included" : "")")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)

            if usage.quotaExceeded {
                Text("You're over your storage quota — delete a few tracks or ask the server admin to raise it.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.error)
            }
        }
        .padding(14)
    }
}
