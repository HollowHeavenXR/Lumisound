import SwiftUI

// MARK: - ListeningTwinView
//
// A personal "who's my music twin" reveal (GET /user/social/twin) — the
// single opted-in user whose top artists overlap most with the caller's
// own, plus a mix seeded from that person's other top artists (GET
// /user/social/twin/mix). Distinct from the anonymous cohort behind
// `SimilarListenersCard`/`fetchSimilarListeners`: this names a specific
// person and offers a one-tap friend request, rather than only surfacing
// recommended tracks.

struct ListeningTwinView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var social: SocialService
    @EnvironmentObject private var streaming: StreamingService
    @EnvironmentObject private var player: AudioPlayerManager

    @State private var twin: ListeningTwin?
    @State private var mixTracks: [StreamTrack] = []
    @State private var isLoading = true
    @State private var friendRequestSent = false
    @State private var loadingTrackID: String?

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if let twin {
                twinCard(twin)
                if !mixTracks.isEmpty {
                    mixSection
                }
            } else {
                EmptyStateView(
                    icon: "person.2.wave.2",
                    title: "No Twin Found Yet",
                    message: emptyMessage
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Listening Twin")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var emptyMessage: String {
        if account.currentUser?.shareListeningActivity != true {
            return "Turn on Share Listening Activity in Account settings, then play a few tracks — your twin is found among other users who've also opted in."
        }
        return "Play a few more tracks, or check back later — a twin is found among other users who've opted in to sharing listening activity."
    }

    private func load() async {
        isLoading = true
        twin = await account.fetchListeningTwin()
        if twin != nil {
            mixTracks = await account.fetchTwinMix()
        }
        isLoading = false
    }

    // MARK: - Twin card

    private func twinCard(_ twin: ListeningTwin) -> some View {
        Section {
            VStack(spacing: 14) {
                CachedAsyncImage(url: twin.avatarURL.flatMap(URL.init)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(Circle())

                Text(twin.displayName ?? twin.username)
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)

                Text("\(twin.similarity)% Match")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)

                if !twin.sharedArtists.isEmpty {
                    Text("You both listen to \(twin.sharedArtists.prefix(4).joined(separator: ", "))\(twin.sharedArtists.count > 4 ? ", and more" : "")")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }

                Button {
                    Task {
                        friendRequestSent = await social.sendFriendRequest(toUsername: twin.username)
                    }
                } label: {
                    Label(friendRequestSent ? "Request Sent" : "Add as Friend", systemImage: friendRequestSent ? "checkmark" : "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.dynamicAccent)
                .disabled(friendRequestSent)
                .padding(.horizontal, 24)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .listRowBackground(Color.clear)
        .listSectionSeparator(.hidden)
    }

    // MARK: - Twin mix

    private var mixSection: some View {
        Section {
            Button {
                playAllMix()
            } label: {
                Label("Play Twin Mix", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.dynamicAccent)
            .listRowBackground(Color.clear)

            ForEach(mixTracks) { track in
                twinMixRow(track)
                    .listRowBackground(AppTheme.surface.opacity(0.5))
            }
        } header: {
            Text("Twin Mix")
        }
        .listSectionSeparator(.hidden)
    }

    private func twinMixRow(_ track: StreamTrack) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: track.thumbnailURL)) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Image(systemName: track.source == "soundcloud" ? "cloud.fill" : "play.rectangle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(AppTheme.textSecondary)
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

            if loadingTrackID == track.id {
                ProgressView()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard loadingTrackID == nil else { return }
            play(track: track)
        }
    }

    private func play(track: StreamTrack) {
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

    private func playAllMix() {
        guard let first = mixTracks.first else { return }
        play(track: first)
        for track in mixTracks.dropFirst() {
            Task {
                if let url = try? await streaming.streamURL(for: track) {
                    let song = streaming.toSong(track: track, streamURL: url)
                    player.appendToQueue(song: song)
                }
            }
        }
    }
}
