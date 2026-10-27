import SwiftUI

struct ArtistDetailView: View {
    let artist: String

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var account: AccountService

    @State private var bio: ArtistBio?
    @State private var isBioExpanded = false

    /// Songs sorted by album name then track number, grouped by album in
    /// the order they first appear. Built once per library change (see
    /// `.onChange` below) — these were computed properties, so every render
    /// re-sorted the artist's songs several times over and re-filtered them
    /// once per album section, and this view re-renders on player updates.
    private struct AlbumGroup {
        let name: String
        var songs: [Song]
    }
    private struct Contents {
        var songs: [Song] = []
        var albums: [AlbumGroup] = []
    }
    @State private var contents: Contents?

    private var songs: [Song] { contents?.songs ?? [] }

    private func buildContents() -> Contents {
        let sorted = library.songs(byArtist: artist)
            .sorted {
                if $0.albumName != $1.albumName {
                    return $0.albumName.localizedCaseInsensitiveCompare($1.albumName) == .orderedAscending
                }
                return $0.trackNumber < $1.trackNumber
            }
        var albums: [AlbumGroup] = []
        var indexByName: [String: Int] = [:]
        for song in sorted {
            if let index = indexByName[song.albumName] {
                albums[index].songs.append(song)
            } else {
                indexByName[song.albumName] = albums.count
                albums.append(AlbumGroup(name: song.albumName, songs: [song]))
            }
        }
        return Contents(songs: sorted, albums: albums)
    }

    var body: some View {
        List {
            // Artist header — real profile picture, matching the look of
            // AlbumDetailView's/LocalFolderDetailView's headers.
            Section {
                ArtistHeaderView(artist: artist, songCount: songs.count, albumCount: contents?.albums.count ?? 0)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listSectionSeparator(.hidden)

            bioSection

            if contents == nil {
                // Still building — show nothing rather than a flash of the
                // empty state.
                EmptyView()
            } else if songs.isEmpty {
                EmptyStateView(
                    icon: "person.crop.circle",
                    title: "No songs",
                    message: "No songs found for this artist."
                )
                .listRowBackground(Color.clear)
            } else {
                // Play / Shuffle section
                Section {
                    playbackButtons
                }
                .listRowBackground(Color.clear)
                .listSectionSeparator(.hidden)

                // Albums and their songs — uses the same SongRow component as
                // the main Songs tab so rows look/behave identically (context
                // menus, favorite/play targets, styling) everywhere.
                ForEach(contents?.albums ?? [], id: \.name) { album in
                    Section {
                        ForEach(album.songs) { song in
                            Button {
                                player.play(song: song, in: songs, uiSource: "artist")
                            } label: {
                                SongRow(
                                    song: song,
                                    isCurrent: player.currentSong?.id == song.id
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(AppTheme.surface.opacity(0.5))
                        }
                    } header: {
                        AlbumSectionHeader(album: album.name, songs: album.songs)
                    }
                }
            }
        }
        // .plain to match the main Library / Album / Folder views (was
        // .insetGrouped, an inconsistent boxed look).
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Own gallery/theme background so the pushed detail view matches the
        // rest of the app instead of falling back to the system black.
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle(artist)
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
        // Watches the list itself, not its count, so an edited tag moves a
        // song between albums (or off this artist) straight away.
        .onAppear { contents = buildContents() }
        .onChange(of: library.allSongs) { contents = buildContents() }
        .task(id: artist) {
            bio = await account.fetchArtistBio(name: artist)
        }
    }

    @ViewBuilder
    private var bioSection: some View {
        if let bio, bio.found, let text = bio.bio, !text.isEmpty {
            Section {
                ArtistBioCard(bio: bio, text: text, isExpanded: $isBioExpanded)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listSectionSeparator(.hidden)
        }
    }

    private var playbackButtons: some View {
        HStack(spacing: 12) {
            Button {
                player.setQueue(songs, startIndex: 0, autoplay: true)
            } label: {
                Label("Play All", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.dynamicAccent)

            Button {
                let shuffled = songs.shuffled()
                player.setQueue(shuffled, startIndex: 0, autoplay: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.dynamicAccent)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Artist Header

private struct ArtistHeaderView: View {
    let artist: String
    let songCount: Int
    let albumCount: Int

    var body: some View {
        VStack(spacing: 16) {
            ArtistAvatar(artist: artist, size: 144, cornerRadius: 72)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)

            VStack(spacing: 6) {
                Text(artist)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .multilineTextAlignment(.center)

                Text("\(albumCount) \(albumCount == 1 ? "album" : "albums") · \(songCount) \(songCount == 1 ? "song" : "songs")")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Artist Bio Card

/// "About this artist" — MusicBrainz facts (type/country/active years/tags)
/// plus a Wikipedia bio excerpt with a "more" toggle, since full Wikipedia
/// extracts can run several paragraphs. See `AccountService.fetchArtistBio`.
private struct ArtistBioCard: View {
    let bio: ArtistBio
    let text: String
    @Binding var isExpanded: Bool

    private var factsLine: String? {
        var parts: [String] = []
        if let type = bio.artistType, !type.isEmpty { parts.append(type) }
        if let country = bio.country, !country.isEmpty { parts.append(country) }
        if let begin = bio.beginDate, !begin.isEmpty {
            let end = bio.endDate?.isEmpty == false ? bio.endDate! : "present"
            parts.append("\(begin.prefix(4))\u{2013}\(end.prefix(4))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let urlString = bio.imageURL, !urlString.isEmpty, let url = URL(string: urlString) {
                    CachedAsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            AppTheme.elevatedSurface
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("About")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    if let factsLine {
                        Text(factsLine)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(isExpanded ? nil : 4)

            HStack(spacing: 16) {
                Button(isExpanded ? "Show Less" : "Read More") {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.dynamicAccent)

                if let urlString = bio.wikipediaURL, !urlString.isEmpty, let url = URL(string: urlString) {
                    Link("Wikipedia", destination: url)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
            }

            if let tags = bio.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppTheme.elevatedSurface, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Album Section Header

private struct AlbumSectionHeader: View {
    let album: String
    let songs: [Song]
    @EnvironmentObject private var library: LibraryManager

    private var representativeSong: Song? { songs.first }

    var body: some View {
        HStack(spacing: 10) {
            if let song = representativeSong {
                ArtworkThumbnail(song: song, size: 40)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "square.stack")
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(album)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("\(songs.count) \(songs.count == 1 ? "track" : "tracks")")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }
}
