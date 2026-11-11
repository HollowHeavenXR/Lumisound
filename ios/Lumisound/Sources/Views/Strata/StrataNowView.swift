import SwiftUI
import UIKit

// MARK: - StrataNowView
//
// Strata's player. Text (title line, artist — album, elapsed / remaining,
// up next) and the layout choice come from the Rust core (`strata_now`):
// square covers get the poster layout, 16:9 video thumbnails the cinema
// layout (wide art, type underneath). Deep tools (lyrics, EQ, effects,
// sleep timer) open the full player sheet.

struct StrataNowView: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var store: StrataStore
    @State private var drag: CGFloat = 0
    @State private var showTools = false
    @State private var artAspect: CGFloat = 1
    @State private var tab = "now"

    var body: some View {
        let t = store.theme
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [StrataPalette.glow.opacity(0.55), StrataPalette.ground, StrataPalette.ground], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    header
                    tabs
                    switch tab {
                    case "lyrics":
                        StrataLyricsPanel(progress: player.progress)
                    case "queue":
                        StrataScreenHost(route: .queue)
                            .padding(.horizontal, -t.gutter)
                    default:
                        StrataNowBody(width: geo.size.width - t.gutter * 2, artAspect: artAspect, showTools: $showTools)
                    }
                }
                .padding(.horizontal, t.gutter)
            }
            .offset(y: max(0, drag))
            .gesture(DragGesture().onChanged { drag = $0.translation.height }.onEnded { v in
                if v.translation.height > 140 { close() } else { withAnimation(.spring()) { drag = 0 } }
            })
        }
        .task(id: player.currentSong?.id) {
            guard let s = player.currentSong, let img = await ArtworkService.shared.loadThumbnail(for: s, pixelSize: 160) else { artAspect = 1; return }
            artAspect = img.size.height > 0 ? img.size.width / img.size.height : 1
        }
        .sheet(isPresented: $showTools) {
            NowPlayingView()
        }
    }

    private var header: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down").font(.system(size: 17, weight: .black)).foregroundStyle(StrataPalette.ink)
                    .frame(width: 40, height: 40).background(StrataPalette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(StrataPress())
            Spacer()
            Text("NOW").font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(3).foregroundStyle(StrataPalette.accent)
            Spacer()
            AirPlayRoutePicker(tint: UIColor(StrataPalette.inkDim), activeTint: UIColor(StrataPalette.accent))
                .frame(width: 40, height: 40)
                .background(StrataPalette.raised, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 8)
    }

    /// Now / Lyrics / Queue: three layers of the player.
    private var tabs: some View {
        let t = store.theme
        return HStack(spacing: 18) {
            ForEach([("now", "Now"), ("lyrics", "Lyrics"), ("queue", "Queue")], id: \.0) { key, label in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { tab = key }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    VStack(spacing: 4) {
                        Text(label.uppercased())
                            .font(.system(size: t.typeScale[5], weight: .heavy, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(tab == key ? StrataPalette.ink : StrataPalette.inkFaint)
                        Rectangle().fill(tab == key ? StrataPalette.accent : Color.clear).frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 10)
    }

    private func close() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { store.showNow = false }
        drag = 0
    }
}

struct StrataNowBody: View {
    let width: CGFloat
    let artAspect: CGFloat
    @Binding var showTools: Bool
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var store: StrataStore
    @ObservedObject private var progress: PlaybackProgress

    init(width: CGFloat, artAspect: CGFloat, showTools: Binding<Bool>) {
        self.width = width
        self.artAspect = artAspect
        _showTools = showTools
        _progress = ObservedObject(wrappedValue: AudioPlayerManager.shared?.progress ?? PlaybackProgress())
    }

    var body: some View {
        let t = store.theme
        let song = player.currentSong
        let nextIndex = player.currentIndex + 1
        let next = player.queue.indices.contains(nextIndex) ? player.queue[nextIndex] : nil
        let now = strataNow(title: song?.displayName ?? "", artist: song?.artistName ?? "", album: song?.album ?? "",
                            position: progress.position, duration: progress.duration, artAspect: Double(artAspect),
                            nextTitle: next?.displayName, nextArtist: next?.artistName)
        let wide = now.layout == "wide"
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 8)
            // Art: square poster tilted off the grid, or a full-width cinema frame.
            if wide {
                StrataWideArt(song: song, width: width)
            } else {
                StrataArt(song: song, size: min(width * 0.86, 360), radius: t.radiusLarge)
                    .rotationEffect(.degrees(-2))
                    .shadow(color: StrataPalette.glow.opacity(0.6), radius: 30, y: 16)
                    .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(now.title)
                    .font(.system(size: wide ? t.typeScale[1] : t.typeScale[0], weight: .black))
                    .tracking(-1)
                    .foregroundStyle(StrataPalette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                HStack {
                    Text(now.subtitle).font(.system(size: t.typeScale[3], weight: .semibold)).foregroundStyle(StrataPalette.inkDim).lineLimit(1)
                    Spacer()
                    if let s = song {
                        Button { library.toggleFavorite(songID: s.id) } label: {
                            Image(systemName: library.favoriteSongIDs.contains(s.id) ? "heart.fill" : "heart")
                                .font(.system(size: 20, weight: .bold)).foregroundStyle(StrataPalette.accent)
                        }
                        .buttonStyle(StrataPress())
                    }
                }
            }
            StrataScrubber(progress: now.progress, elapsed: now.elapsed, remaining: now.remaining) { f in
                player.seek(to: f * max(progress.duration, 0))
            }
            controls
            if let up = now.upNext {
                Button { store.showNow = false; store.open(.queue) } label: {
                    HStack(spacing: 8) {
                        Text("NEXT").font(.system(size: 10, weight: .heavy, design: .monospaced)).tracking(2).foregroundStyle(StrataPalette.accent)
                        Text(up).font(.system(size: t.typeScale[4], weight: .semibold)).foregroundStyle(StrataPalette.inkDim).lineLimit(1)
                        Spacer()
                        Image(systemName: "list.number").foregroundStyle(StrataPalette.inkFaint)
                    }
                    .padding(12)
                    .background(StrataPalette.layer, in: RoundedRectangle(cornerRadius: t.radius, style: .continuous))
                }
                .buttonStyle(StrataPress())
            }
            Spacer(minLength: 20)
        }
    }

    private var controls: some View {
        let t = store.theme
        return HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.system(size: 17, weight: .bold))
                    .foregroundStyle(player.shuffleEnabled ? StrataPalette.accent : StrataPalette.inkFaint)
            }
            Spacer()
            Button { player.skipToPrevious() } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 24, weight: .black)).foregroundStyle(StrataPalette.ink)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(StrataPalette.onAccent)
                    .frame(width: 84, height: 72)
                    .background(StrataPalette.accent, in: RoundedRectangle(cornerRadius: t.radiusLarge, style: .continuous))
            }
            Spacer()
            Button { player.userSkipToNext() } label: {
                Image(systemName: "forward.end.fill").font(.system(size: 24, weight: .black)).foregroundStyle(StrataPalette.ink)
            }
            Spacer()
            Button { showTools = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .bold)).foregroundStyle(StrataPalette.inkFaint)
            }
        }
        .buttonStyle(StrataPress())
    }
}

struct StrataWideArt: View {
    let song: Song?
    let width: CGFloat
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let h = width * 9 / 16
        Group {
            if let song {
                ArtworkThumbnail(song: song, size: width, showsScrim: false)
                    .frame(width: width, height: h)
            } else {
                StrataPalette.layer
            }
        }
        .frame(width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: store.theme.radiusLarge, style: .continuous))
        .shadow(color: StrataPalette.glow.opacity(0.5), radius: 26, y: 14)
    }
}

/// Thick ruler-style scrubber with tick marks.
struct StrataScrubber: View {
    let progress: Double
    let elapsed: String
    let remaining: String
    let seek: (Double) -> Void
    @State private var dragging: Double?
    @EnvironmentObject private var store: StrataStore

    var body: some View {
        let t = store.theme
        let p = dragging ?? progress
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<41, id: \.self) { i in
                            Rectangle().fill(StrataPalette.rule).frame(width: 1, height: i % 10 == 0 ? 14 : 7)
                            if i < 40 { Spacer(minLength: 0) }
                        }
                    }
                    .frame(height: 14)
                    Rectangle().fill(StrataPalette.accent).frame(width: max(2, g.size.width * p), height: 4)
                    Rectangle().fill(StrataPalette.ink).frame(width: 3, height: dragging == nil ? 18 : 26)
                        .offset(x: max(0, g.size.width * p - 1.5))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragging = min(1, max(0, v.location.x / g.size.width)) }
                    .onEnded { _ in
                        if let d = dragging { seek(d) }
                        dragging = nil
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    })
            }
            .frame(height: 28)
            HStack {
                Text(elapsed)
                Spacer()
                Text(remaining)
            }
            .font(.system(size: t.typeScale[5], weight: .bold, design: .monospaced))
            .foregroundStyle(StrataPalette.inkFaint)
        }
    }
}
