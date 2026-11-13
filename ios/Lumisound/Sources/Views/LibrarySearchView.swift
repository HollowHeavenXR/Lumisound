import SwiftUI

// MARK: - LibrarySearchView
//
// Library search results from the Lumisound search engine
// (rust/core/src/search.rs via LibrarySearchService): a top result, then
// songs, artists, albums, playlists and lines from lyrics, with the matched
// letters lit up. A lyric line that has a time starts the song right there.

struct LibrarySearchView: View {
    let query: String

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @ObservedObject private var service = LibrarySearchService.shared

    @State private var results = SearchResults(query: "", topKind: "", songs: [], artists: [], albums: [], playlists: [], lyrics: [], totalSongs: 0, elapsedMs: 0)
    @State private var scope: Scope = .all
    @State private var loading = true

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", artists = "Artists", albums = "Albums", playlists = "Playlists", lyrics = "Lyrics"
        var id: String { rawValue }
    }

    private var accent: Color { AppTheme.dynamicAccent }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                scopeBar
                if loading && results.query.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if isEmpty {
                    LKEmpty(icon: "magnifyingglass", title: "Nothing matches “\(query)”",
                            message: "Check the spelling or try fewer words. Lumisound also looks through song lyrics\(service.lyricsIndexed > 0 ? " (\(service.lyricsIndexed) songs)" : "").")
                } else {
                    content
                    footer
                }
            }
            .padding(.horizontal, LK.gutter)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .task(id: query) { await run() }
        .onAppear { service.reloadLyricsIfChanged() }
        .onChange(of: service.isIndexed) { _ in Task { await run() } }
        .animation(LumiMotion.fade(0.18), value: scope)
    }

    private var isEmpty: Bool {
        results.songs.isEmpty && results.artists.isEmpty && results.albums.isEmpty && results.playlists.isEmpty && results.lyrics.isEmpty
    }

    private func run() async {
        loading = true
        let r = await service.search(query)
        guard !Task.isCancelled else { return }
        results = r
        loading = false
        if count(scope) == 0 { scope = .all }
    }

    // MARK: Scope

    private func count(_ s: Scope) -> Int {
        switch s {
        case .all: return 1
        case .songs: return Int(results.totalSongs)
        case .artists: return results.artists.count
        case .albums: return results.albums.count
        case .playlists: return results.playlists.count
        case .lyrics: return results.lyrics.count
        }
    }

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Scope.allCases) { s in
                    let n = count(s)
                    if s == .all || n > 0 {
                        Button { scope = s } label: {
                            LKChip(title: s == .all ? s.rawValue : "\(s.rawValue) · \(n)", selected: scope == s)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch scope {
        case .all:
            topResult
            if !results.songs.isEmpty {
                sectionHeader("Songs", more: results.songs.count > 6 ? .songs : nil)
                songList(Array(results.songs.prefix(6)))
            }
            if !results.artists.isEmpty {
                sectionHeader("Artists", more: results.artists.count > 8 ? .artists : nil)
                artistRibbon(Array(results.artists.prefix(12)))
            }
            if !results.albums.isEmpty {
                sectionHeader("Albums", more: results.albums.count > 8 ? .albums : nil)
                albumRibbon(Array(results.albums.prefix(12)))
            }
            if !results.playlists.isEmpty {
                sectionHeader("Playlists", more: results.playlists.count > 4 ? .playlists : nil)
                playlistList(Array(results.playlists.prefix(4)))
            }
            if !results.lyrics.isEmpty {
                sectionHeader("In the lyrics", more: results.lyrics.count > 3 ? .lyrics : nil)
                lyricCards(Array(results.lyrics.prefix(3)))
            }
        case .songs:
            songList(results.songs)
        case .artists:
            LKGrid { ForEach(results.artists, id: \.key) { artistTile($0, size: 96) } }
        case .albums:
            LKGrid { ForEach(results.albums, id: \.key) { albumTile($0, size: 150) } }
        case .playlists:
            playlistList(results.playlists)
        case .lyrics:
            lyricCards(results.lyrics)
        }
    }

    private var footer: some View {
        Text("\(results.totalSongs) song\(results.totalSongs == 1 ? "" : "s") · searched in \(String(format: "%.0f", max(1, results.elapsedMs))) ms")
            .font(.caption2)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    private func sectionHeader(_ title: String, more: Scope?) -> some View {
        HStack {
            LKSectionTitle(title)
            Spacer()
            if let more {
                Button("See all") { scope = more }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
            }
        }
        .padding(.bottom, -8)
    }

    // MARK: Top result

    @ViewBuilder
    private var topResult: some View {
        switch results.topKind {
        case "song":
            if let hit = results.songs.first, let song = library.songsByID[hit.id] {
                Button { play(hit.id) } label: {
                    topCard(art: AnyView(ArtworkThumbnail(song: song, size: 84, showsScrim: false)),
                            kind: "Song", title: highlight(song.displayName, hit.title),
                            subtitle: highlight(song.artistName, hit.artist), icon: "play.fill")
                }
                .buttonStyle(.plain)
            }
        case "artist":
            if let g = results.artists.first {
                NavigationLink { artistDestination(g) } label: {
                    topCard(art: AnyView(groupArt(g, size: 84, circle: true)), kind: "Artist",
                            title: highlight(g.name, g.nameRanges), subtitle: AttributedString(g.subtitle), icon: "chevron.right")
                }
                .buttonStyle(.plain)
            }
        case "album":
            if let g = results.albums.first {
                NavigationLink { albumDestination(g) } label: {
                    topCard(art: AnyView(groupArt(g, size: 84, circle: false)), kind: "Album",
                            title: highlight(g.name, g.nameRanges), subtitle: AttributedString(g.subtitle), icon: "chevron.right")
                }
                .buttonStyle(.plain)
            }
        case "playlist":
            if let g = results.playlists.first {
                NavigationLink { playlistDestination(g) } label: {
                    topCard(art: AnyView(groupArt(g, size: 84, circle: false)), kind: "Playlist",
                            title: highlight(g.name, g.nameRanges), subtitle: AttributedString(g.subtitle), icon: "chevron.right")
                }
                .buttonStyle(.plain)
            }
        default:
            EmptyView()
        }
    }

    private func topCard(art: AnyView, kind: String, title: AttributedString, subtitle: AttributedString, icon: String) -> some View {
        HStack(spacing: 14) {
            art.frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 4) {
                Text("TOP RESULT · \(kind.uppercased())")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(accent)
                Text(title)
                    .font(AppTheme.headlineFont(size: 20))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(accent.gradient, in: Circle())
        }
        .padding(14)
        .background(LKCardBackground(tint: accent))
    }

    // MARK: Songs

    private func songList(_ hits: [SongHit]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                if let song = library.songsByID[hit.id] {
                    if index > 0 { LKDivider(inset: 66) }
                    Button { play(hit.id) } label: {
                        HStack(spacing: 12) {
                            ArtworkThumbnail(song: song, size: 44, showsScrim: false)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(highlight(song.displayName, hit.title))
                                    .font(.subheadline)
                                    .foregroundStyle(player.currentSong?.id == song.id ? accent : AppTheme.textPrimary)
                                    .lineLimit(1)
                                Text(highlight(song.artistName, hit.artist) + AttributedString(" · ") + highlight(song.albumName, hit.album))
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if hit.matchedIn == "genre" {
                                LKPill(text: song.genre)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { songMenu(song) }
                }
            }
        }
        .padding(.vertical, 4)
        .background(LKCardBackground())
    }

    @ViewBuilder
    private func songMenu(_ song: Song) -> some View {
        Button { player.insertNext(song: song) } label: { Label("Play Next", systemImage: "text.insert") }
        Button { player.appendToQueue(song: song) } label: { Label("Add to Queue", systemImage: "text.append") }
    }

    // MARK: Groups

    private func artistRibbon(_ groups: [GroupHit]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(groups, id: \.key) { artistTile($0, size: 84) }
            }
            .padding(.vertical, 2)
        }
    }

    private func artistTile(_ g: GroupHit, size: CGFloat) -> some View {
        NavigationLink { artistDestination(g) } label: {
            VStack(spacing: 6) {
                groupArt(g, size: size, circle: true)
                    .frame(width: size, height: size)
                Text(highlight(g.name, g.nameRanges))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(g.subtitle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .frame(width: size + 12)
        }
        .buttonStyle(.plain)
    }

    private func albumRibbon(_ groups: [GroupHit]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(groups, id: \.key) { albumTile($0, size: 124) }
            }
            .padding(.vertical, 2)
        }
    }

    private func albumTile(_ g: GroupHit, size: CGFloat) -> some View {
        NavigationLink { albumDestination(g) } label: {
            VStack(alignment: .leading, spacing: 4) {
                groupArt(g, size: size, circle: false)
                    .frame(width: size, height: size)
                Text(highlight(g.name, g.nameRanges))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(g.subtitle.isEmpty ? "\(g.count) songs" : g.subtitle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
    }

    private func playlistList(_ groups: [GroupHit]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.key) { index, g in
                if index > 0 { LKDivider(inset: 66) }
                NavigationLink { playlistDestination(g) } label: {
                    HStack(spacing: 12) {
                        groupArt(g, size: 44, circle: false).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(highlight(g.name, g.nameRanges)).font(.subheadline).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                            Text(g.subtitle).font(.caption).foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(LKCardBackground())
    }

    @ViewBuilder
    private func groupArt(_ g: GroupHit, size: CGFloat, circle: Bool) -> some View {
        Group {
            if let id = g.artSongId, let song = library.songsByID[id] {
                ArtworkThumbnail(song: song, size: size, showsScrim: false)
            } else {
                ZStack {
                    AppTheme.elevatedSurface
                    Image(systemName: circle ? "person.fill" : "music.note.list").foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: max(6, size * 0.12), style: .continuous)))
    }

    // MARK: Lyrics

    private func lyricCards(_ hits: [LyricHit]) -> some View {
        VStack(spacing: 10) {
            ForEach(hits, id: \.songId) { hit in
                if let song = library.songsByID[hit.songId] {
                    Button { play(hit.songId, at: hit.time) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "quote.opening")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(accent)
                                Text(highlight(hit.line, hit.ranges))
                                    .font(AppTheme.headlineFont(size: 16))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 8) {
                                ArtworkThumbnail(song: song, size: 26, showsScrim: false).frame(width: 26, height: 26)
                                Text("\(song.displayName) · \(song.artistName)")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if let t = hit.time {
                                    Label(Self.clock(t), systemImage: "play.fill")
                                        .font(.caption2.weight(.bold).monospacedDigit())
                                        .foregroundStyle(accent)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(accent.opacity(0.14), in: Capsule())
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LKCardBackground())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(hit.time == nil ? "Plays the song" : "Plays the song from this line")
                }
            }
        }
    }

    private static func clock(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Destinations

    @ViewBuilder
    private func artistDestination(_ g: GroupHit) -> some View {
        if !library.songs(byArtist: g.name).isEmpty {
            ArtistDetailView(artist: g.name)
        } else {
            SearchSongsListView(title: g.name, subtitle: g.subtitle, songs: g.songIds.compactMap { library.songsByID[$0] })
        }
    }

    @ViewBuilder
    private func albumDestination(_ g: GroupHit) -> some View {
        if !library.songs(inAlbum: g.name).isEmpty {
            AlbumDetailView(album: g.name)
        } else {
            SearchSongsListView(title: g.name, subtitle: g.subtitle, songs: g.songIds.compactMap { library.songsByID[$0] })
        }
    }

    @ViewBuilder
    private func playlistDestination(_ g: GroupHit) -> some View {
        if let p = library.playlists.first(where: { $0.id.uuidString == g.key }) {
            PlaylistDetailView(playlist: p)
        } else {
            SearchSongsListView(title: g.name, subtitle: g.subtitle, songs: g.songIds.compactMap { library.songsByID[$0] })
        }
    }

    // MARK: Actions

    /// Plays the hit with the visible song results as the queue.
    private func play(_ id: String, at time: Double? = nil) {
        guard let song = library.songsByID[id] else { return }
        let queue = results.songs.compactMap { library.songsByID[$0.id] }
        player.play(song: song, in: queue.contains(where: { $0.id == id }) ? queue : [song], uiSource: "library_search")
        if let time, time > 0.5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if player.currentSong?.id == id { player.seek(to: time) }
            }
        }
    }

    /// `text` with the engine's UTF-16 ranges in bold accent.
    private func highlight(_ text: String, _ ranges: [SearchRange]) -> AttributedString {
        guard !ranges.isEmpty else { return AttributedString(text) }
        var out = AttributedString()
        let utf16 = text.utf16
        var cursor = 0
        for r in ranges {
            let start = min(Int(r.start), utf16.count), end = min(Int(r.end), utf16.count)
            guard start >= cursor, end > start else { continue }
            out += AttributedString(Self.slice(text, cursor, start))
            var hit = AttributedString(Self.slice(text, start, end))
            hit.foregroundColor = accent
            hit.inlinePresentationIntent = .stronglyEmphasized
            out += hit
            cursor = end
        }
        out += AttributedString(Self.slice(text, cursor, utf16.count))
        return out
    }

    private static func slice(_ s: String, _ a: Int, _ b: Int) -> String {
        let i = String.Index(utf16Offset: a, in: s), j = String.Index(utf16Offset: b, in: s)
        return i < j ? String(s[i..<j]) : ""
    }
}

/// Songs for an artist / album / playlist hit that has no page of its own
/// (e.g. one name out of "A feat. B").
struct SearchSongsListView: View {
    let title: String
    let subtitle: String
    let songs: [Song]

    @EnvironmentObject private var player: AudioPlayerManager

    var body: some View {
        LKPage(title: title, subtitle: subtitle, icon: "music.note.list", showsHero: false) {
            LKPrimaryButton(title: "Play", icon: "play.fill") {
                if let first = songs.first { player.play(song: first, in: songs, uiSource: "library_search") }
            }
            VStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    if index > 0 { LKDivider(inset: 66) }
                    Button { player.play(song: song, in: songs, uiSource: "library_search") } label: {
                        SongRow(song: song, isCurrent: player.currentSong?.id == song.id)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .background(LKCardBackground())
        }
    }
}
