import SwiftUI

// MARK: - Screen host
//
// Draws a `StrataScreen` the Rust core composed. Nothing here decides what
// a screen contains: sections arrive in order with a style, rows arrive
// with their text, artwork id and the action a tap performs.

struct StrataScreenHost: View {
    let route: StrataRoute
    @EnvironmentObject private var store: StrataStore
    @State private var screen: StrataScreen?

    var body: some View {
        ScrollView {
            if let screen {
                StrataScreenView(screen: screen)
                    .transition(.opacity)
            } else {
                StrataLoading()
            }
        }
        .scrollIndicators(.hidden)
        .background(StrataPalette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: TaskKey(route: route, revision: store.revision)) {
            let s = await store.screen(for: route)
            withAnimation(.easeOut(duration: 0.18)) { screen = s }
        }
    }

    private struct TaskKey: Equatable {
        let route: StrataRoute
        let revision: Int
    }
}

struct StrataScreenView: View {
    let screen: StrataScreen
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        LazyVStack(alignment: .leading, spacing: 34, pinnedViews: []) {
            StrataHead(screen: screen)
            ForEach(screen.sections, id: \.id) { section in
                StrataSectionView(section: section, route: screen.route)
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
                    _ = withAnimation(.easeInOut(duration: 0.28)) { store.path.removeLast() }
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

struct StrataSectionView: View {
    let section: StrataSection
    let route: StrataRoute
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        VStack(alignment: .leading, spacing: 14) {
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
            switch section.style {
            case .hero: StrataHeroSection(items: section.items)
            case .stack: StrataStackSection(items: section.items)
            case .ribbon: StrataRibbonSection(items: section.items)
            case .ledger: StrataLedgerSection(section: section, route: route)
            case .grid: StrataGridSection(section: section, route: route)
            case .chips: StrataChipsSection(items: section.items)
            case .stats: StrataStatsSection(items: section.items)
            case .note: StrataNoteSection(items: section.items)
            }
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

/// Numbered / dense rows, paged from Rust as they scroll in, with an
/// alphabet rail for name-sorted lists.
struct StrataLedgerSection: View {
    let section: StrataSection
    let route: StrataRoute
    @EnvironmentObject private var store: StrataStore
    @State private var extra: [StrataItem] = []
    @State private var loading = false

    var body: some View {
        let rows = section.items + extra
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 6) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                        StrataLedgerRow(item: item)
                            .id(item.id)
                            .onAppear {
                                if i == rows.count - 1 { loadMore(have: rows.count) }
                            }
                    }
                }
                if section.index.count > 3 {
                    StrataIndexRail(letters: section.index) { letter in
                        if let target = rows.first(where: { strataLetter($0.title) == letter }) {
                            proxy.scrollTo(target.id, anchor: .top)
                        } else {
                            loadMore(have: rows.count)
                        }
                    }
                }
            }
        }
    }

    private func loadMore(have: Int) {
        guard !loading, have < Int(section.total) else { return }
        loading = true
        Task {
            let more = await store.page(route: route, section: section.id, offset: have)
            extra.append(contentsOf: more)
            loading = false
        }
    }
}

func strataLetter(_ s: String) -> String {
    var t = s.lowercased()
    if t.hasPrefix("the ") { t.removeFirst(4) }
    guard let c = t.folding(options: .diacriticInsensitive, locale: nil).first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
    if c.isASCII, c.isLetter { return String(c).uppercased() }
    return c.isLetter ? "★" : "#"
}

struct StrataLedgerRow: View {
    let item: StrataItem
    @EnvironmentObject private var store: StrataStore
    @EnvironmentObject private var player: AudioPlayerManager

    var body: some View {
        let t = store.theme
        let playing = player.currentSong?.id == item.id
        Button { store.perform(item.action) } label: {
            HStack(spacing: 12) {
                if let n = item.number {
                    Text(String(format: "%02d", n))
                        .font(.system(size: t.typeScale[4], weight: .heavy, design: .monospaced))
                        .foregroundStyle(playing ? StrataPalette.accent : StrataPalette.inkFaint)
                        .frame(width: 26, alignment: .leading)
                }
                if item.art != nil || item.glyph != nil {
                    StrataArt(song: item.art.flatMap { store.song($0) }, size: 44, radius: 4, glyph: item.glyph)
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
        .contextMenu { StrataItemMenu(item: item) }
    }
}

struct StrataIndexRail: View {
    let letters: [String]
    let jump: (String) -> Void
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        VStack(spacing: 2) {
            ForEach(letters, id: \.self) { l in
                Button { jump(l) } label: {
                    Text(l).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(StrataPalette.accent)
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}

struct StrataGridSection: View {
    let section: StrataSection
    let route: StrataRoute
    @EnvironmentObject private var store: StrataStore
    @State private var extra: [StrataItem] = []
    @State private var loading = false

    var body: some View {
        let t = store.theme
        let rows = section.items + extra
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 20) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                Button { store.perform(item.action) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { g in
                            StrataArt(song: item.art.flatMap { store.song($0) }, size: g.size.width, radius: t.radius, glyph: item.glyph)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        Text(item.title).font(.system(size: t.typeScale[4], weight: .bold)).foregroundStyle(StrataPalette.ink).lineLimit(2)
                        if let s = item.subtitle {
                            Text(s).font(.system(size: t.typeScale[5])).foregroundStyle(StrataPalette.inkFaint).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(StrataPress())
                .onAppear { if i == rows.count - 1 { loadMore(have: rows.count) } }
            }
        }
    }

    private func loadMore(have: Int) {
        guard !loading, have < Int(section.total) else { return }
        loading = true
        Task {
            extra.append(contentsOf: await store.page(route: route, section: section.id, offset: have))
            loading = false
        }
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
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        if let s = item.secondary {
            Button { store.perform(s) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        }
        if case .play(let ids, let index, _) = item.action, ids.indices.contains(Int(index)) {
            let id = ids[Int(index)]
            Button { store.perform(.addToQueue(ids: [id])) } label: { Label("Add to queue", systemImage: "text.badge.plus") }
            Button { store.perform(.toggleFavorite(id: id)) } label: { Label("Favorite", systemImage: "heart") }
            if let song = store.song(id) {
                Button { store.perform(.open(route: .artist(name: song.artist))) } label: { Label("Go to artist", systemImage: "person") }
            }
        }
    }
}

struct StrataArt: View {
    let song: Song?
    var size: CGFloat
    var radius: CGFloat = 6
    var glyph: String? = nil

    var body: some View {
        Group {
            if let song {
                ArtworkThumbnail(song: song, size: size, showsScrim: false)
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
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
