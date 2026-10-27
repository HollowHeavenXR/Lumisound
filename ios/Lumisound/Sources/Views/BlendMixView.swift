import SwiftUI

/// A playable mix blending the caller's and a chosen friend's top artists
/// (GET /api/social/blend/{user_id}) — the "press play" companion to the
/// Music Match score/shared-artists card on a friend's profile
/// (`MusicCompatibilityRow`). Distinct from Listening Twin's Twin Mix:
/// that auto-matches an anonymous best-fit stranger; this is intentional —
/// you already picked this specific friend. Same row/play/queue shape as
/// `DiscoverMixView`, just fetched from a different endpoint.
struct BlendMixView: View {
    let friendUserID: String
    let friendName: String

    @EnvironmentObject private var social: SocialService
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var player: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss

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
                    icon: "person.2.wave.2",
                    title: "Nothing to Blend Yet",
                    message: "Once you and \(friendName) both have some listening history, a mix will show up here."
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
                    BlendMixRow(
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
        .navigationTitle("Blend with \(friendName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        tracks = await social.fetchBlendMix(userId: friendUserID)
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

private struct BlendMixRow: View {
    let track: StreamTrack
    let isLoading: Bool
    let onPlay: () -> Void
    let onAddToQueue: () -> Void

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
            }

            Spacer(minLength: 4)

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
