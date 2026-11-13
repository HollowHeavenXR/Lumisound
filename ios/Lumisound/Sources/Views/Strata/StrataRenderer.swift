import SwiftUI

// MARK: - Screen host
//
// Draws a `StrataScreen` the Rust core composed. Nothing here decides what
// a screen contains: sections arrive in order with a style, rows arrive
// with their text, artwork id and the action a tap performs.

struct StrataScreenHost: View {
    let route: StrataRoute
    @EnvironmentObject private var store: StrataStore
    @StateObject private var model = StrataScreenModel()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let screen = model.screen {
                    StrataScreenView(screen: screen, model: model)
                } else {
                    StrataLoading()
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .trailing) {
                if let s = model.screen?.sections.first(where: { $0.index.count > 3 }) {
                    StrataIndexRail(letters: s.index) { i in
                        Task {
                            let target = Int(s.indexPositions[i])
                            await model.ensureLoaded(section: s, through: target, route: route, store: store)
                            if let row = model.items(of: s)[safe: target] {
                                withAnimation(LumiMotion.glide(0.2)) { proxy.scrollTo(row.id, anchor: .top) }
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
        .background(StrataPalette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: key) {
            let s = await store.screen(for: route)
            model.set(s)
            await model.restorePaging(route: route, store: store)
        }
    }

    /// Only Home and Queue change with the playing song; the rest reload
    /// only when the library does (Library used to reload on every track).
    private var key: TaskKey {
        let followsPlayback: Bool
        switch route {
        case .home, .queue: followsPlayback = true
        default: followsPlayback = false
        }
        let followsSettings: Bool
        switch route {
        case .settings, .account: followsSettings = true
        default: followsSettings = false
        }
        return TaskKey(route: route, data: store.dataRevision, now: (followsPlayback ? store.nowRevision : 0) &+ (followsSettings ? store.settingsRevision &* 7919 : 0))
    }

    private struct TaskKey: Equatable {
        let route: StrataRoute
        let data: Int
        let now: Int
    }
}

/// One screen's description plus the rows paged in after it.
@MainActor
final class StrataScreenModel: ObservableObject {
    @Published private(set) var screen: StrataScreen?
    @Published private(set) var extra: [String: [StrataItem]] = [:]
    private var loading: Set<String> = []

    /// Rows that were loaded per section before a reload.
    private var reloadCounts: [String: Int] = [:]

    func set(_ s: StrataScreen) {
        guard screen != s else { return }
        if let old = screen, old.route == s.route {
            reloadCounts = Dictionary(uniqueKeysWithValues: old.sections.map { ($0.id, items(of: $0).count) })
        } else {
            reloadCounts = [:]
        }
        screen = s
        extra = [:]
    }

    /// After a reload (library changed), page back in as many rows as were
    /// loaded, so a long list keeps its scroll depth.
    func restorePaging(route: StrataRoute, store: StrataStore) async {
        guard let screen else { return }
        for section in screen.sections {
            if let n = reloadCounts[section.id], n > section.items.count {
                await ensureLoaded(section: section, through: n - 1, route: route, store: store)
            }
        }
        reloadCounts = [:]
    }

    func items(of section: StrataSection) -> [StrataItem] {
        section.items + (extra[section.id] ?? [])
    }

    /// Next page when the last row appears.
    func loadMore(_ section: StrataSection, route: StrataRoute, store: StrataStore) {
        let have = items(of: section).count
        guard have < Int(section.total), !loading.contains(section.id) else { return }
        loading.insert(section.id)
        Task {
            let more = await store.page(route: route, section: section.id, offset: have)
            extra[section.id, default: []].append(contentsOf: more)
            loading.remove(section.id)
        }
    }

    /// Rows up to `index` loaded (the A–Z rail jumping past what's on screen).
    func ensureLoaded(section: StrataSection, through index: Int, route: StrataRoute, store: StrataStore) async {
        let have = items(of: section).count
        guard index >= have, have < Int(section.total) else { return }
        let more = await store.page(route: route, section: section.id, offset: have, limit: index - have + 60)
        extra[section.id, default: []].append(contentsOf: more)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct StrataScreenView: View {
    let screen: StrataScreen
    @ObservedObject var model: StrataScreenModel
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        // Rows of long sections go straight into this lazy stack (no nested
        // container), so only rows on screen exist.
        LazyVStack(alignment: .leading, spacing: 0) {
            StrataHead(screen: screen).padding(.bottom, 30)
            ForEach(screen.sections, id: \.id) { section in
                StrataSectionHeader(section: section).padding(.bottom, 14)
                switch section.style {
                case .ledger:
                    let rows = model.items(of: section)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                        StrataLedgerRow(item: item, route: screen.route)
                            .padding(.trailing, section.index.count > 3 ? 18 : 0)
                            .onAppear { if i == rows.count - 1 { model.loadMore(section, route: screen.route, store: store) } }
                    }
                    Color.clear.frame(height: 34)
                case .grid:
                    let rows = model.items(of: section)
                    let pairs = stride(from: 0, to: rows.count, by: 2).map { Array(rows[$0..<min($0 + 2, rows.count)]) }
                    ForEach(Array(pairs.enumerated()), id: \.element.first!.id) { i, pair in
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(pair, id: \.id) { StrataGridCell(item: $0) }
                            if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                        }
                        .padding(.trailing, section.index.count > 3 ? 18 : 0)
                        .padding(.bottom, 20)
                        .onAppear { if i == pairs.count - 1 { model.loadMore(section, route: screen.route, store: store) } }
                    }
                    Color.clear.frame(height: 14)
                default:
                    StrataSectionBody(section: section, route: screen.route).padding(.bottom, 34)
                }
            }
            Color.clear.frame(height: 150)
        }
        .padding(.horizontal, t.gutter)
        .padding(.top, 12)
    }
}

// MARK: - Head

struct StrataHead: View {
    let screen: StrataScreen
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        VStack(alignment: .leading, spacing: 10) {
            if !store.path.isEmpty {
                Button {
                    _ = withAnimation(LumiMotion.fade(0.28)) { store.path.removeLast() }
                } label: {
                    Label("Back", systemImage: "arrow.left")
                        .font(.system(size: t.typeScale[4], weight: .semibold))
                        .foregroundStyle(StrataPalette.inkDim)
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    if let k = screen.kicker {
                        Text(k.uppercased())
                            .font(.system(size: t.typeScale[5], weight: .heavy, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(StrataPalette.accent)
                    }
                    Text(screen.title)
                        .font(.system(size: t.typeScale[0], weight: .black))
                        .tracking(-1.2)
                        .foregroundStyle(StrataPalette.ink)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                    if let sub = screen.subtitle {
                        Text(sub)
                            .font(.system(size: t.typeScale[4], weight: .medium).monospacedDigit())
                            .foregroundStyle(StrataPalette.inkFaint)
                    }
                }
                Spacer(minLength: 0)
                if let art = screen.art, let song = store.song(art), screen.route != .home {
                    StrataArt(song: song, size: 84, radius: t.radius)
                        .rotationEffect(.degrees(3))
                        .shadow(color: StrataPalette.glow.opacity(0.4), radius: 18, y: 8)
                }
            }
            if !screen.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(screen.actions, id: \.id) { a in
                        StrataButton(item: a)
                    }
                }
                .padding(.top, 6)
            }
            Rectangle().fill(StrataPalette.rule).frame(height: 1).padding(.top, 8)
        }
    }
}

struct StrataButton: View {
    let item: StrataItem
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        Button { store.perform(item.action) } label: {
            HStack(spacing: 6) {
                if let g = item.glyph { Image(systemName: g).font(.system(size: 13, weight: .bold)) }
                Text(item.title).font(.system(size: t.typeScale[4], weight: .bold))
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .foregroundStyle(item.emphasis ? StrataPalette.onAccent : StrataPalette.ink)
            .background(item.emphasis ? StrataPalette.accent : StrataPalette.raised, in: RoundedRectangle(cornerRadius: t.radius, style: .continuous))
        }
        .buttonStyle(StrataPress())
    }
}

// MARK: - Sections

struct StrataSectionHeader: View {
    let section: StrataSection
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        if section.title != nil || section.caption != nil {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    if let title = section.title {
                        Text(title)
                            .font(.system(size: t.typeScale[2], weight: .heavy))
                            .tracking(-0.4)
                            .foregroundStyle(StrataPalette.ink)
                    }
                    if let c = section.caption {
                        Text(c).font(.system(size: t.typeScale[4])).foregroundStyle(StrataPalette.inkFaint)
                    }
                }
                Spacer()
                if let more = section.more {
                    Button { store.perform(more) } label: {
                        Text("All").font(.system(size: t.typeScale[4], weight: .bold)).foregroundStyle(StrataPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct StrataSectionBody: View {
    let section: StrataSection
    let route: StrataRoute

    var body: some View {
        switch section.style {
        case .hero: StrataHeroSection(items: section.items)
        case .stack: StrataStackSection(items: section.items)
        case .ribbon: StrataRibbonSection(items: section.items)
        case .chips: StrataChipsSection(items: section.items)
        case .stats: StrataStatsSection(items: section.items)
        case .note: StrataNoteSection(items: section.items)
        case .controls: StrataControlsSection(items: section.items, caption: section.caption)
        case .ledger, .grid: EmptyView()
        }
    }
}

/// One big statement: what's playing / the top result.
struct StrataHeroSection: View {
    let items: [StrataItem]
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        ForEach(items, id: \.id) { item in
            Button { store.perform(item.action) } label: {
                HStack(alignment: .bottom, spacing: 16) {
                    StrataArt(song: item.art.flatMap { store.song($0) }, size: 128, radius: t.radiusLarge, glyph: item.glyph)
                    VStack(alignment: .leading, spacing: 6) {
                        if let m = item.meta {
                            Text(m.uppercased())
                                .font(.system(size: t.typeScale[5], weight: .heavy, design: .monospaced))
                                .tracking(1.6)
                                .foregroundStyle(StrataPalette.accent)
                        }
                        Text(item.title)
                            .font(.system(size: t.typeScale[1], weight: .black))
                            .tracking(-0.8)
                            .foregroundStyle(StrataPalette.ink)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        if let s = item.subtitle {
                            Text(s).font(.system(size: t.typeScale[4], weight: .medium)).foregroundStyle(StrataPalette.inkDim).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(
                    LinearGradient(colors: [StrataPalette.glow.opacity(0.35), StrataPalette.layer], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: t.radiusLarge, style: .continuous)
                )
            }
            .buttonStyle(StrataPress())
            .contextMenu { StrataItemMenu(item: item) }
        }
    }
}

/// Layered offset cards: the first on top, the rest peeking out behind,
/// pager-swiped one layer at a time.
struct StrataStackSection: View {
    let items: [StrataItem]
    @EnvironmentObject private var store: StrataStore
    @State private var top = 0

    var body: some View {
        let t = store.theme
        let count = items.count
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()).reversed(), id: \.element.id) { i, item in
                let depth = (i - top + count) % count
                if depth < 4 {
                    StrataStackCard(item: item, number: i + 1)
                        .offset(x: CGFloat(depth) * 14, y: CGFloat(depth) * 10)
                        .scaleEffect(1 - CGFloat(depth) * 0.035, anchor: .topLeading)
                        .opacity(depth == 0 ? 1 : 0.85 - Double(depth) * 0.18)
                        .zIndex(Double(10 - depth))
                        .allowsHitTesting(depth == 0)
                }
            }
        }
        .frame(height: 150, alignment: .topLeading)
        .padding(.bottom, 30)
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { v in
                guard count > 1 else { return }
                withAnimation(.spring(response: t.motion[1], dampingFraction: t.motion[3])) {
                    top = v.translation.width < 0 ? (top + 1) % count : (top - 1 + count) % count
                }
                UISelectionFeedbackGenerator().selectionChanged()
            }
        )
        .overlay(alignment: .bottomTrailing) {
            Text("\(top + 1)/\(count)")
                .font(.system(size: t.typeScale[5], weight: .bold, design: .monospaced))
                .foregroundStyle(StrataPalette.inkFaint)
        }
    }
}

struct StrataStackCard: View {
    let item: StrataItem
    let number: Int
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        Button { store.perform(item.action) } label: {
            HStack(spacing: 14) {
                StrataArt(song: item.art.flatMap { store.song($0) }, size: 118, radius: t.radius)
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(format: "%02d", number))
                        .font(.system(size: t.typeScale[2], weight: .black, design: .monospaced))
                        .foregroundStyle(StrataPalette.accent)
                    Text(item.title).font(.system(size: t.typeScale[3], weight: .heavy)).foregroundStyle(StrataPalette.ink).lineLimit(2)
                    if let s = item.subtitle {
                        Text(s).font(.system(size: t.typeScale[4])).foregroundStyle(StrataPalette.inkDim).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 300, height: 142, alignment: .leading)
            .background(StrataPalette.raised, in: RoundedRectangle(cornerRadius: t.radiusLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: t.radiusLarge, style: .continuous).strokeBorder(StrataPalette.rule, lineWidth: 1))
        }
        .buttonStyle(StrataPress())
        .contextMenu { StrataItemMenu(item: item) }
    }
}

/// Wide cards in a horizontal run.
struct StrataRibbonSection: View {
    let items: [StrataItem]
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(items, id: \.id) { item in
                    Button { store.perform(item.action) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            StrataArt(song: item.art.flatMap { store.song($0) }, size: 150, radius: t.radius, glyph: item.glyph)
                            Text(item.title).font(.system(size: t.typeScale[4], weight: .bold)).foregroundStyle(StrataPalette.ink).lineLimit(2)
                            if let s = item.subtitle {
                                Text(s).font(.system(size: t.typeScale[5], weight: .medium)).foregroundStyle(StrataPalette.inkFaint).lineLimit(1)
                            }
                        }
                        .frame(width: 150, alignment: .leading)
                    }
                    .buttonStyle(StrataPress())
                    .contextMenu { StrataItemMenu(item: item) }
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -t.gutter)
        .contentMargins(.horizontal, t.gutter, for: .scrollContent)
    }
}

struct StrataLedgerRow: View {
    let item: StrataItem
    var route: StrataRoute = .home
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        let playing = store.currentID == item.id
        Button { store.perform(item.action) } label: {
            HStack(spacing: 12) {
                if let n = item.number {
                    Text(String(format: "%02d", n))
                        .font(.system(size: t.typeScale[4], weight: .heavy, design: .monospaced))
                        .foregroundStyle(playing ? StrataPalette.accent : StrataPalette.inkFaint)
                        .frame(width: 26, alignment: .leading)
                }
                if item.art != nil || item.glyph != nil {
                    let remote = item.art.flatMap { $0.hasPrefix("remote:") ? URL(string: String($0.dropFirst(7))) : nil }
                    StrataArt(song: remote == nil ? item.art.flatMap { store.song($0) } : nil, size: 44, radius: 4, glyph: item.glyph, remote: remote)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: t.typeScale[3], weight: playing ? .heavy : .semibold))
                        .foregroundStyle(playing ? StrataPalette.accent : StrataPalette.ink)
                        .lineLimit(1)
                    if let s = item.subtitle {
                        Text(s).font(.system(size: t.typeScale[4])).foregroundStyle(StrataPalette.inkFaint).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if item.emphasis {
                    Image(systemName: "heart.fill").font(.system(size: 10)).foregroundStyle(StrataPalette.accent)
                }
                if let m = item.meta {
                    Text(m).font(.system(size: t.typeScale[4], weight: .medium).monospacedDigit()).foregroundStyle(StrataPalette.inkFaint)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .overlay(Rectangle().fill(StrataPalette.rule.opacity(0.6)).frame(height: 1), alignment: .bottom)
        }
        .buttonStyle(StrataPress())
        .contextMenu { StrataItemMenu(item: item, route: route) }
    }
}

/// A–Z rail: letters jump to where Rust says each one starts.
struct StrataIndexRail: View {
    let letters: [String]
    let jump: (Int) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(letters.enumerated()), id: \.offset) { i, l in
                Button { jump(i); UISelectionFeedbackGenerator().selectionChanged() } label: {
                    Text(l).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(StrataPalette.accent)
                        .frame(width: 18, height: 13)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .background(StrataPalette.layer.opacity(0.85), in: Capsule())
    }
}

struct StrataGridCell: View {
    let item: StrataItem
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        Button { store.perform(item.action) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        GeometryReader { g in
                            StrataArt(song: item.art.flatMap { store.song($0) }, size: g.size.width, radius: t.radius, glyph: item.glyph)
                        }
                    }
                Text(item.title).font(.system(size: t.typeScale[4], weight: .bold)).foregroundStyle(StrataPalette.ink).lineLimit(2)
                if let s = item.subtitle {
                    Text(s).font(.system(size: t.typeScale[5])).foregroundStyle(StrataPalette.inkFaint).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(StrataPress())
    }
}

struct StrataChipsSection: View {
    let items: [StrataItem]
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        StrataFlow(spacing: 8) {
            ForEach(items, id: \.id) { item in
                Button { store.perform(item.action) } label: {
                    HStack(spacing: 6) {
                        if let g = item.glyph { Image(systemName: g).font(.system(size: 11, weight: .bold)) }
                        Text(item.title).font(.system(size: t.typeScale[4], weight: .bold))
                        if let m = item.meta {
                            Text(m).font(.system(size: t.typeScale[5], weight: .bold, design: .monospaced)).opacity(0.6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .foregroundStyle(item.emphasis ? StrataPalette.onAccent : StrataPalette.ink)
                    .background(item.emphasis ? StrataPalette.accent : Color.clear, in: RoundedRectangle(cornerRadius: t.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: t.radius, style: .continuous).strokeBorder(item.emphasis ? Color.clear : StrataPalette.rule, lineWidth: 1))
                }
                .buttonStyle(StrataPress())
            }
        }
    }
}

struct StrataStatsSection: View {
    let items: [StrataItem]
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
            ForEach(items, id: \.id) { item in
                Button { store.perform(item.action) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: t.typeScale[1], weight: .black).monospacedDigit())
                            .foregroundStyle(StrataPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if let s = item.subtitle {
                            Text(s.uppercased()).font(.system(size: t.typeScale[5], weight: .heavy, design: .monospaced)).tracking(1.4).foregroundStyle(StrataPalette.inkFaint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(StrataPalette.layer)
                }
                .buttonStyle(StrataPress())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: t.radiusLarge, style: .continuous))
        .background(StrataPalette.rule, in: RoundedRectangle(cornerRadius: t.radiusLarge, style: .continuous))
    }
}

struct StrataNoteSection: View {
    let items: [StrataItem]
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        ForEach(items, id: \.id) { item in
            VStack(alignment: .leading, spacing: 8) {
                if let g = item.glyph { Image(systemName: g).font(.system(size: 26, weight: .bold)).foregroundStyle(StrataPalette.accent) }
                Text(item.title).font(.system(size: t.typeScale[2], weight: .heavy)).foregroundStyle(StrataPalette.ink)
                if let s = item.subtitle { Text(s).font(.system(size: t.typeScale[3])).foregroundStyle(StrataPalette.inkDim) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .overlay(RoundedRectangle(cornerRadius: t.radiusLarge).strokeBorder(StrataPalette.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        }
    }
}

// MARK: - Bits

struct StrataItemMenu: View {
    let item: StrataItem
    var route: StrataRoute = .home
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        // Song rows carry the song id; long-press acts on that song.
        if let song = store.song(item.id) {
            Button { store.perform(.playNext(ids: [song.id])) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { store.perform(.addToQueue(ids: [song.id])) } label: { Label("Add to queue", systemImage: "text.badge.plus") }
            Button { store.perform(.open(route: .addToPlaylist(ids: [song.id]))) } label: { Label("Add to playlist", systemImage: "music.note.list") }
            Button { store.perform(.toggleFavorite(id: song.id)) } label: { Label("Favorite", systemImage: "heart") }
            if case .playlist(let pid) = route {
                Button(role: .destructive) { store.perform(.removeFromPlaylist(playlist: pid, id: song.id)) } label: { Label("Remove from playlist", systemImage: "minus.circle") }
            }
            Button { store.perform(.open(route: .artist(name: song.artist))) } label: { Label("Go to artist", systemImage: "person") }
        } else if let s = item.secondary {
            Button { store.perform(s) } label: {
                if case .streamDownload = s { Label("Download", systemImage: "arrow.down.circle") } else { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            }
        }
    }
}

struct StrataArt: View {
    let song: Song?
    var size: CGFloat
    var radius: CGFloat = 6
    var glyph: String? = nil

    var remote: URL? = nil

    var body: some View {
        Group {
            if let song {
                ArtworkThumbnail(song: song, size: size, showsScrim: false)
            } else if let remote {
                AsyncImage(url: remote) { img in img.resizable().scaledToFill() } placeholder: { StrataPalette.layer }
            } else {
                ZStack {
                    LinearGradient(colors: [StrataPalette.raised, StrataPalette.layer], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: glyph ?? "music.note").font(.system(size: max(12, size * 0.32), weight: .bold)).foregroundStyle(StrataPalette.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct StrataPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(LumiMotion.glide(0.12), value: configuration.isPressed)
    }
}

struct StrataLoading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4).fill(StrataPalette.layer).frame(width: i == 0 ? 220 : 300, height: i == 0 ? 40 : 18)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wrapping row layout for chips.
struct StrataFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - Settings controls

struct StrataControlsSection: View {
    let items: [StrataItem]
    let caption: String?
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.id) { item in
                StrataControlRow(item: item)
                if item.id != items.last?.id {
                    Rectangle().fill(StrataPalette.rule.opacity(0.6)).frame(height: 1).padding(.leading, 14)
                }
            }
        }
        .background(StrataPalette.layer, in: RoundedRectangle(cornerRadius: t.radiusLarge, style: .continuous))
        if let caption {
            Text(caption).font(.system(size: t.typeScale[4], weight: .semibold)).foregroundStyle(StrataPalette.accent).padding(.top, 8)
        }
    }
}

struct StrataControlRow: View {
    let item: StrataItem
    @EnvironmentObject private var store: StrataStore
    @State private var sliding: Double?

    var body: some View {
        let t = store.theme
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let g = item.glyph, item.control == nil {
                    Image(systemName: g).font(.system(size: 15, weight: .bold)).foregroundStyle(item.emphasis ? StrataPalette.danger : StrataPalette.accent).frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: t.typeScale[3], weight: .semibold)).foregroundStyle(item.emphasis && item.control == nil ? StrataPalette.danger : StrataPalette.ink)
                    if let s = item.subtitle {
                        Text(s).font(.system(size: t.typeScale[5])).foregroundStyle(StrataPalette.inkFaint).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            if case let .slider(key, value, min, max, step, _) = item.control {
                Slider(value: Binding(get: { sliding ?? value }, set: { sliding = $0 }), in: min...max, step: step) { editing in
                    if !editing, let v = sliding {
                        store.perform(.setSetting(key: key, value: .number(value: v)))
                        sliding = nil
                    }
                }
                .tint(StrataPalette.accent)
            }
            if case let .swatches(key, selected, colors) = item.control {
                HStack(spacing: 10) {
                    ForEach(colors, id: \.self) { c in
                        Button { store.perform(.setSetting(key: key, value: .text(value: c))) } label: {
                            Circle().fill(Color(strataHex: c)).frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(StrataPalette.ink, lineWidth: c.lowercased() == selected.lowercased() ? 3 : 0))
                        }
                        .buttonStyle(StrataPress())
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.control == nil { store.perform(item.action) }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        let t = store.theme
        switch item.control {
        case let .toggle(key, on):
            Toggle("", isOn: Binding(get: { on }, set: { store.perform(.setSetting(key: key, value: .flag(on: $0))) }))
                .labelsHidden()
                .tint(StrataPalette.accent)
        case let .choice(key, selected, options):
            Menu {
                ForEach(options, id: \.value) { o in
                    Button { store.perform(.setSetting(key: key, value: .text(value: o.value))) } label: {
                        if o.value == selected { Label(o.label, systemImage: "checkmark") } else { Text(o.label) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(options.first(where: { $0.value == selected })?.label ?? selected).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: t.typeScale[4], weight: .bold))
                .foregroundStyle(StrataPalette.accent)
            }
        case .slider:
            if let m = item.meta {
                Text(sliding.map { String(format: "%.2f", $0) } ?? m).font(.system(size: t.typeScale[4], weight: .bold).monospacedDigit()).foregroundStyle(StrataPalette.inkDim)
            }
        default:
            if let m = item.meta {
                Text(m).font(.system(size: t.typeScale[4], weight: .medium)).foregroundStyle(StrataPalette.inkFaint)
            } else if item.control == nil, item.action != .none {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(StrataPalette.inkFaint)
            }
        }
    }
}
