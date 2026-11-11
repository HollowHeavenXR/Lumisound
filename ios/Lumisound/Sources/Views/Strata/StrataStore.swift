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

    /// Bumped whenever the library or play stats changed: screens reload.
    @Published private(set) var revision = 0
    @Published private(set) var theme: StrataTheme = StrataPalette.theme {
        didSet { StrataPalette.theme = theme }
    }
    @Published var path: [StrataRoute] = []
    @Published var layer: StrataLayer = .home
    @Published var showNow = false
    @Published var showCloud = false

    private weak var library: LibraryManager?
    private weak var player: AudioPlayerManager?
    private var bag = Set<AnyCancellable>()
    private var songsByID: [String: Song] = [:]
    private var syncTask: Task<Void, Never>?

    private init() {}

    // MARK: Library hand-over

    func attach(library: LibraryManager, player: AudioPlayerManager) {
        guard self.library == nil else { return }
        self.library = library
        self.player = player
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
            await MainActor.run { self?.revision &+= 1 }
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
        revision &+= 1
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
        let core = core
        return await Task.detached(priority: .userInitiated) {
            core.screen(route: route, now: now, hour: hour, current: current, queue: queue, queueIndex: index)
        }.value
    }

    func page(route: StrataRoute, section: String, offset: Int) async -> [StrataItem] {
        let core = core
        return await Task.detached(priority: .userInitiated) {
            core.page(route: route, sectionId: section, offset: UInt32(offset), limit: 200)
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
        case .none:
            break
        }
    }

    func open(_ route: StrataRoute) {
        switch route {
        case .home: selectLayer(.home)
        case .search: if path.isEmpty, layer != .search { selectLayer(.search) } else { path.append(route) }
        case .you: selectLayer(.you)
        case .cloud: showCloud = true
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
