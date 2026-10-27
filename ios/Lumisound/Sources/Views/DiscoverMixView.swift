import SwiftUI

// MARK: - DiscoverMixView
//
// A personalized mix of tracks (GET /user/discover-mix), seeded server-side
// from the user's most-played artists and excluding anything already in
// their library or favorites.

struct DiscoverMixView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var player: AudioPlayerManager

    @State private var tracks: [StreamTrack] = []
    @State private var isLoading = false
    @State private var loadingTrackID: String?

    var body: some View {
        List {
            if isLoading && tracks.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if tracks.isEmpty {
                EmptyStateView(
                    icon: "sparkles",
                    title: "Nothing to discover yet",
                    message: "Play a few songs and your Discover Mix will fill up with new tracks based on your favorite artists."
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    Button {
                        playAll()
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.dynamicAccent)
                    .listRowBackground(Color.clear)
                }
                .listSectionSeparator(.hidden)

                ForEach(tracks) { track in
                    DiscoverMixRow(
                        track: track,
                        isLoading: loadingTrackID == track.id,
                        onPlay: { play(track: track) },
                        onAddToQueue: { addToQueue(track: track) }
                    )
                    .listRowBackground(AppTheme.surface.opacity(0.5))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Discover Mix")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        tracks = await account.fetchDiscoverMix()
        isLoading = false
    }

    private func play(track: StreamTrack) {
        guard loadingTrackID == nil else { return }
        loadingTrackID = track.id
        Task {
            defer { loadingTrackID = nil }
            do {
                let url = try await streaming.streamURL(for: track)
                let song = streaming.toSong(track: track, streamURL: url)
                player.play(song: song, in: [song])
            } catch {
                streaming.errorMessage = error.localizedDescription
            }
        }
    }

    private func addToQueue(track: StreamTrack) {
        guard loadingTrackID == nil else { return }
        loadingTrackID = track.id
        Task {
            defer { loadingTrackID = nil }
            do {
                let url = try await streaming.streamURL(for: track)
                let song = streaming.toSong(track: track, streamURL: url)
                player.appendToQueue(song: song)
            } catch {
                streaming.errorMessage = error.localizedDescription
            }
        }
    }

    private func playAll() {
        guard let first = tracks.first else { return }
        play(track: first)
        for track in tracks.dropFirst() {
            addToQueue(track: track)
        }
    }
}

// MARK: - DiscoverMixRow

private struct DiscoverMixRow: View {
    let track: StreamTrack
    let isLoading: Bool
    let onPlay: () -> Void
    let onAddToQueue: () -> Void

    @State private var showReason = false

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: track.thumbnailURL)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure, .empty:
                    Image(systemName: track.source == "soundcloud" ? "cloud.fill" : "play.rectangle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(AppTheme.textSecondary)
                @unknown default:
                    Color.clear
                }
            }
            .frame(width: 44, height: 44)
            .background(AppTheme.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(AppTheme.bodyFont(size: 14))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                if showReason, let seedArtist = track.seedArtist {
                    Text("Because you listen to \(seedArtist)")
                        .font(AppTheme.bodyFont(size: 11))
                        .foregroundStyle(AppTheme.dynamicAccent)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 4)

            // "Why this pick" — tap-to-reveal rather than shown for every
            // row at once, so a mix seeded from 3 artists doesn't just
            // repeat the same caption a dozen times.
            if track.seedArtist != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showReason.toggle() }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if isLoading {
                ProgressView()
            } else {
                Button(action: onAddToQueue) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isLoading else { return }
            onPlay()
        }
    }
}
