import Combine
import SwiftUI
import UIKit

// MARK: - StrataStore
//
// Strata is composed in Rust (rust/core/src/strata.rs): which sections a
// screen has, what every row says, what a tap does, and the palette. This
// store is the thin Swift side: it hands the library to the Rust core once
// (re-sent only when the library changes), asks it for screens, carries out
// the actions it returns with the existing player/library services, and
// keeps the Rust-computed theme in step with the playing artwork.

@MainActor
final class StrataStore: ObservableObject {
    static let shared = StrataStore()

    let core = StrataCore()

    /// Bumped when the library changed (every screen reloads)…
    @Published private(set) var dataRevision = 0
    /// …and when the playing song changed (only Home and Queue reload).
    @Published private(set) var nowRevision = 0
    /// The playing song's id (rows highlight it without observing the player).
    @Published private(set) var currentID: String?
    @Published private(set) var theme: StrataTheme = StrataPalette.theme {
        didSet { StrataPalette.theme = theme }
    }
    @Published var path: [StrataRoute] = []
    @Published var layer: StrataLayer = .home
    @Published var showNow = false
    /// Bumped when a setting changed (settings/account screens reload).
    @Published private(set) var settingsRevision = 0

    // Presentation the Rust actions ask for.
    @Published var sheetRoute: StrataRoute?
    @Published var classicPage: StrataClassicPage?
    @Published var prompt: StrataPrompt?
    @Published var confirmDelete: StrataPlaylistRef?

    private weak var library: LibraryManager?
    private weak var player: AudioPlayerManager?
    private weak var streaming: StreamingService?
    private weak var account: AccountService?
    private weak var sleep: SleepTimerService?
    /// Online results by id (StreamPlay / StreamDownload look them up).
    private var results: [String: StreamTrack] = [:]
    private var cloudCount = 0
    private var searchTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var songsByID: [String: Song] = [:]
    private var syncTask: Task<Void, Never>?

    private init() {}

    // MARK: Library hand-over

    func attach(library: LibraryManager, player: AudioPlayerManager, streaming: StreamingService, account: AccountService, sleep: SleepTimerService) {
        guard self.library == nil else { return }
        self.library = library
        self.player = player
        self.streaming = streaming
        self.account = account
        self.sleep = sleep
        // Library sort orders chosen earlier.
        for tab in ["songs", "albums", "artists"] {
            if let s = UserDefaults.standard.string(forKey: "strata_sort_\(tab)") { core.setSort(tab: tab, sort: s) }
        }
        account.$isLoggedIn.sink { [weak self] _ in self?.settingsRevision &+= 1 }.store(in: &bag)
        library.$allSongs.combineLatest(library.$playlists, library.$favoriteSongIDs)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] songs, playlists, favs in self?.sync(songs: songs, playlists: playlists, favorites: favs) }
            .store(in: &bag)
        player.$currentSong
            .removeDuplicates(by: { $0?.id == $1?.id })
            .sink { [weak self] song in self?.songChanged(song) }
            .store(in: &bag)
    }

    private func sync(songs: [Song], playlists: [Playlist], favorites: Set<String>) {
        songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let history = PlayHistoryStore.shared
        let input: [StrataSong] = songs.map { s in
            StrataSong(id: s.id, title: s.title, artist: s.artist, album: s.album, genre: s.genre, year: s.year,
                       duration: s.duration, added: s.dateAdded?.timeIntervalSince1970 ?? 0,
                       plays: UInt32(max(0, history.playCount(for: s.id))),
                       lastPlayed: history.lastPlayedAt(for: s.id)?.timeIntervalSince1970 ?? 0,
                       favorite: favorites.contains(s.id), bpm: s.bpm ?? 0, remote: !(s.url?.isFileURL ?? false))
        }
        let lists = playlists.map { p in
            StrataPlaylist(id: p.id.uuidString, name: p.name, songIds: p.songIDs, created: p.createdAt.timeIntervalSince1970, folder: p.folder)
        }
        let core = core
        syncTask?.cancel()
        syncTask = Task.detached(priority: .userInitiated) { [weak self] in
            core.setLibrary(songs: input, playlists: lists)
            await MainActor.run { self?.dataRevision &+= 1 }
        }
    }

    private func songChanged(_ song: Song?) {
        // Play stats moved: the Rust index learns it without a full re-send.
        if let s = song {
            let h = PlayHistoryStore.shared
            core.updateSongStats(id: s.id, plays: UInt32(max(0, h.playCount(for: s.id))),
                                 lastPlayed: h.lastPlayedAt(for: s.id)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                                 favorite: library?.favoriteSongIDs.contains(s.id) ?? false)
        }
        currentID = song?.id
        nowRevision &+= 1
        retheme(for: song)
    }

    // MARK: Theme

    /// The accent the Rust theme is seeded with: Strata's own saved accent
    /// (Settings > Appearance while in Strata), else Strata's default.
    static func accentHex() -> String {
        if let data = UserDefaults.standard.data(forKey: "strata_accent_color_data"),
           let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) {
            return c.strataHex
        }
        return "#FF5A3C"
    }

    func refreshTheme() { retheme(for: player?.currentSong) }

    private func retheme(for song: Song?) {
        let accent = Self.accentHex()
        guard let song else {
            withAnimation(.easeInOut(duration: 0.6)) { theme = strataTheme(accentHex: accent, artworkRgb: nil) }
            return
        }
        Task { [weak self] in
            let image = await ArtworkService.shared.loadThumbnail(for: song, pixelSize: 96)
            let rgb = image.flatMap { ArtworkColorExtractor.palette(from: $0) }.map { UIColor($0.primary).strataRGB }
            let t = strataTheme(accentHex: accent, artworkRgb: rgb)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.8)) { self?.theme = t }
            }
        }
    }

    // MARK: Screens

    func screen(for route: StrataRoute) async -> StrataScreen {
        let now = Date().timeIntervalSince1970
        let hour = UInt32(Calendar.current.component(.hour, from: Date()))
        let current = player?.currentSong?.id
        let queue = player?.queue.map(\.id) ?? []
        let index = UInt32(max(0, player?.currentIndex ?? 0))
        let values = StrataSettings.values(player: player, account: account, sleep: sleep, cloudCount: cloudCount)
        let core = core
        return await Task.detached(priority: .userInitiated) {
            core.screen(route: route, now: now, hour: hour, current: current, queue: queue, queueIndex: index, values: values)
        }.value
    }

    func page(route: StrataRoute, section: String, offset: Int, limit: Int = 120) async -> [StrataItem] {
        let core = core
        return await Task.detached(priority: .userInitiated) {
            core.page(route: route, sectionId: section, offset: UInt32(offset), limit: UInt32(min(max(limit, 1), 500)))
        }.value
    }

    func song(_ id: String) -> Song? {
        songsByID[id] ?? player?.queue.first(where: { $0.id == id })
    }

    // MARK: Actions

    func perform(_ action: StrataAction) {
        guard let player, let library else { return }
        switch action {
        case let .play(ids, index, shuffle):
            let songs = ids.compactMap { song($0) }
            guard !songs.isEmpty else { return }
            let start = min(Int(index), songs.count - 1)
            if shuffle {
                player.setQueue(songs.smartShuffled(), startIndex: 0, autoplay: true)
            } else {
                player.play(song: songs[start], in: songs, uiSource: "strata")
            }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case let .playFrom(route, section, index, shuffle):
            // Long lists play by reference: their ids are fetched once, now.
            let core = core
            Task {
                let ids = await Task.detached(priority: .userInitiated) { core.sectionIds(route: route, sectionId: section) }.value
                self.perform(.play(ids: ids, index: index, shuffle: shuffle))
            }
        case let .playNext(ids):
            for s in ids.compactMap({ song($0) }).reversed() { player.insertNext(song: s) }
            ToastCenter.shared.show(ids.count == 1 ? "Plays next" : "\(ids.count) songs play next")
        case let .addToQueue(ids):
            for s in ids.compactMap({ song($0) }) { player.appendToQueue(song: s) }
            ToastCenter.shared.show("Added to queue")
        case let .open(route):
            open(route)
        case let .toggleFavorite(id):
            library.toggleFavorite(songID: id)
        case let .queueJump(index):
            let i = Int(index)
            guard player.queue.indices.contains(i) else { return }
            player.setQueue(player.queue, startIndex: i, autoplay: true, playlistID: player.currentPlaylistID)
        case let .createPlaylist(name, ids):
            if let name, !name.isEmpty {
                let p = library.createPlaylist(name: name, songIDs: ids)
                ToastCenter.shared.show("Created \"\(p.name)\"", icon: "music.note.list")
                sheetRoute = nil
                bumpData()
            } else {
                prompt = StrataPrompt(title: "New playlist", placeholder: "Playlist name", value: "") { [weak self] text in
                    self?.perform(.createPlaylist(name: text, ids: ids))
                }
            }
        case let .renamePlaylist(id):
            guard let p = library.playlists.first(where: { $0.id.uuidString == id }) else { return }
            prompt = StrataPrompt(title: "Rename playlist", placeholder: "Name", value: p.name) { text in
                guard !text.isEmpty else { return }
                library.renamePlaylist(p, to: text)
            }
        case let .deletePlaylist(id):
            if let p = library.playlists.first(where: { $0.id.uuidString == id }) { confirmDelete = StrataPlaylistRef(id: id, name: p.name) }
        case let .addToPlaylist(playlist, ids):
            guard let uuid = UUID(uuidString: playlist), let p = library.playlists.first(where: { $0.id == uuid }) else { return }
            library.addSongs(ids: Set(ids), toPlaylistID: uuid)
            ToastCenter.shared.show("Added to \"\(p.name)\"", icon: "checkmark.circle")
            sheetRoute = nil
        case let .removeFromPlaylist(playlist, id):
            if let uuid = UUID(uuidString: playlist) { library.removeSong(id: id, fromPlaylistID: uuid) }
        case let .setSort(tab, sort):
            core.setSort(tab: tab, sort: sort)
            UserDefaults.standard.set(sort, forKey: "strata_sort_\(tab)")
            UISelectionFeedbackGenerator().selectionChanged()
            bumpData()
        case let .setSetting(key, value):
            StrataSettings.apply(key: key, value: value, player: player, library: library, account: account, sleep: sleep)
            settingsRevision &+= 1
        case let .promptSetting(key, title, value):
            prompt = StrataPrompt(title: title, placeholder: title, value: value) { [weak self] text in
                self?.perform(.setSetting(key: key, value: .text(value: text)))
            }
        case let .streamPlay(id):
            guard let t = results[id], let streaming else { return }
            Task {
                do {
                    let url = try await streaming.streamURL(for: t)
                    let song = streaming.toSong(track: t, streamURL: url)
                    player.play(song: song, in: [song], uiSource: "strata-cloud")
                } catch {
                    ToastCenter.shared.show("Couldn't stream \"\(t.title)\"", category: .error)
                }
            }
        case let .streamDownload(id):
            guard let t = results[id] else { return }
            download(t)
        case let .cloudPlay(id):
            guard let streaming, let token = account?.token, let t = streaming.userMusicTracks.first(where: { $0.id == id }) else { return }
            let song = streaming.toSong(userMusicTrack: t, token: token)
            player.play(song: song, in: [song], uiSource: "strata-cloud")
        case let .openClassic(page):
            classicPage = StrataClassicPage(page: page)
        case .signIn:
            classicPage = StrataClassicPage(page: "signin")
        case .signOut:
            Task { await account?.logout() }
        case .none:
            break
        }
    }

    private func bumpData() { dataRevision &+= 1 }

    func deletePlaylist(_ ref: StrataPlaylistRef) {
        guard let library, let p = library.playlists.first(where: { $0.id.uuidString == ref.id }) else { return }
        library.deletePlaylist(p)
        if case .playlist(let id) = path.last, id == ref.id { path.removeLast() }
    }

    // MARK: Cloud

    /// Your cloud uploads, for the Cloud screen.
    func loadCloud() async {
        guard let streaming, let token = account?.token else { return }
        await streaming.fetchUserMusic(token: token)
        let local = Set(songsByID.values.map { "\($0.title.lowercased())|\($0.artist.lowercased())" })
        let tracks = streaming.userMusicTracks.map {
            StrataRemote(id: $0.id, title: $0.title, artist: $0.artist, duration: $0.duration, thumbnail: "", source: "cloud",
                         downloaded: local.contains("\($0.title.lowercased())|\($0.artist.lowercased())"))
        }
        cloudCount = tracks.count
        core.setCloud(tracks: tracks)
        bumpData()
    }

    /// Online search for the Cloud screen (results go to Rust, which composes them).
    func searchOnline(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let streaming else { return }
        core.setResults(query: query, results: [], searching: true)
        bumpData()
        searchTask = Task {
            let found = await streaming.searchSilently(query: q)
            guard !Task.isCancelled else { return }
            let have = Set(songsByID.values.compactMap(\.sourceTrackID))
            for t in found { results[t.id] = t }
            core.setResults(query: query, results: found.map {
                StrataRemote(id: $0.id, title: $0.title, artist: $0.artist, duration: $0.duration, thumbnail: $0.thumbnailURL,
                             source: $0.source, downloaded: have.contains($0.sourceTrackID))
            }, searching: false)
            bumpData()
        }
    }

    private func download(_ t: StreamTrack) {
        guard let streaming, let library else { return }
        ToastCenter.shared.show("Downloading \"\(t.title)\"", category: .download, icon: "arrow.down.circle")
        Task {
            do {
                await library.scanLocalDocumentsAsync()
                if library.isAlreadyImported(title: t.title, artist: t.artist, duration: t.duration) {
                    ToastCenter.shared.show("\"\(t.title)\" is already in your library", icon: "checkmark.circle")
                    return
                }
                _ = try await streaming.downloadToLibrary(track: t, existingSongs: library.allSongs)
                library.scanLocalDocuments()
                ToastCenter.shared.show("Downloaded \"\(t.title)\"", category: .download, icon: "checkmark.circle.fill")
            } catch {
                ToastCenter.shared.show("Download failed: \(error.localizedDescription)", category: .error)
            }
        }
    }

    func open(_ route: StrataRoute) {
        switch route {
        case .home: selectLayer(.home)
        case .search: if path.isEmpty, layer != .search { selectLayer(.search) } else { path.append(route) }
        case .you: selectLayer(.you)
        case .addToPlaylist: sheetRoute = route
        case .library(let tab) where path.isEmpty && layer == .library:
            libraryTab = tab
        default:
            path.append(route)
        }
    }

    /// The tab of the Library layer (chips swap it in place).
    @Published var libraryTab = "songs"

    func selectLayer(_ l: StrataLayer) {
        if l == layer {
            withAnimation(.easeInOut(duration: 0.3)) { path.removeAll() }
        } else {
            UISelectionFeedbackGenerator().selectionChanged()
            path.removeAll()
            layer = l
        }
    }
}

// MARK: - Layers

enum StrataLayer: String, CaseIterable, Identifiable {
    case home, library, search, you
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .search: return "Search"
        case .you: return "You"
        }
    }
    var glyph: String {
        switch self {
        case .home: return "circle.hexagongrid"
        case .library: return "square.stack.3d.up"
        case .search: return "magnifyingglass"
        case .you: return "person"
        }
    }
}

// MARK: - Colour helpers

extension Color {
    /// "#RRGGBB" from the Rust theme.
    init(strataHex hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(s, radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: 1)
    }
}

extension UIColor {
    var strataRGB: [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b)].map { min(1, max(0, $0)) }
    }

    var strataHex: String {
        let c = strataRGB.map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c[0], c[1], c[2])
    }
}

/// Strata's palette for every screen that reads `AppTheme` (Settings,
/// Account, Cloud...). Values come from the Rust theme.
enum StrataPalette {
    /// Mirror of the store's theme, readable from anywhere (AppTheme's
    /// static getters aren't main-actor isolated).
    nonisolated(unsafe) static var theme: StrataTheme = strataTheme(accentHex: "#FF5A3C", artworkRgb: nil)
    static var ground: Color { Color(strataHex: theme.ground) }
    static var layer: Color { Color(strataHex: theme.layer) }
    static var raised: Color { Color(strataHex: theme.raised) }
    static var rule: Color { Color(strataHex: theme.rule) }
    static var ink: Color { Color(strataHex: theme.ink) }
    static var inkDim: Color { Color(strataHex: theme.inkDim) }
    static var inkFaint: Color { Color(strataHex: theme.inkFaint) }
    static var accent: Color { Color(strataHex: theme.accent) }
    static var onAccent: Color { Color(strataHex: theme.onAccent) }
    static var glow: Color { Color(strataHex: theme.glow) }
    static var danger: Color { Color(strataHex: theme.danger) }
}

// MARK: - Presentation models

struct StrataPrompt: Identifiable {
    let id = UUID()
    let title: String
    let placeholder: String
    var value: String
    let submit: (String) -> Void
}

struct StrataClassicPage: Identifiable {
    var id: String { page }
    let page: String
}

struct StrataPlaylistRef: Identifiable {
    let id: String
    let name: String
}

extension StrataRoute: Identifiable {
    public var id: String { "\(self)" }
}
