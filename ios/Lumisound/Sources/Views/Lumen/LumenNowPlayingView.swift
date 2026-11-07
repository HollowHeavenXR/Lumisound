import SwiftUI
import UIKit

// MARK: - Now Playing

/// Lumen's full-screen player. Three stages share one screen — the cover,
/// synced lyrics, and Up Next — with the transport dock fixed beneath them.
/// Everything the classic player can do stays one tap away: Effects & EQ,
/// sleep timer, format info, transfer, and the full classic "Studio" player
/// (artwork styles, A-B repeat, bookmarks, practice mode) from the ••• menu.
struct LumenNowPlayingView: View {
    @Binding var isPresented: Bool

    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var sleepTimer: SleepTimerService
    @EnvironmentObject private var account: AccountService

    enum Stage: String { case artwork, lyrics, queue }

    @State private var stage: Stage = .artwork
    @State private var dismissOffset: CGFloat = 0
    @State private var artworkSwipe: CGFloat = 0
    @State private var lyrics: [LrcLine] = []
    @State private var lyricsLoading = false

    @State private var showEffects = false
    @State private var showSleepTimer = false
    @State private var showFormatInfo = false
    @State private var showTransfer = false
    @State private var showStudio = false
    @State private var route: LumenRoute?

    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                VStack(spacing: 0) {
                    topBar
                        .padding(.top, geo.safeAreaInsets.top + 4)
                    stageView(width: geo.size.width)
                        .frame(maxHeight: .infinity)
                    controls
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 12))
                }
                .padding(.horizontal, 24)
            }
            .ignoresSafeArea()
        }
        .offset(y: max(dismissOffset, 0))
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onChange(of: player.currentSong?.id) { _, newID in
            if newID == nil { close() } else { loadLyrics() }
        }
        .onAppear { loadLyrics() }
        .sheet(isPresented: $showEffects) {
            NavigationStack {
                EffectsView()
                    .navigationTitle("Effects & EQ")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showEffects = false } }
                    }
            }
            .environmentObject(player)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSleepTimer) {
            SleepTimerSheet()
                .environmentObject(sleepTimer)
                .environmentObject(sleepTimer.progress)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showFormatInfo) {
            FormatInfoSheet(song: player.currentSong, isUsingFallback: player.isUsingOpusPlayer)
                .environmentObject(library)
        }
        .sheet(isPresented: $showTransfer) {
            TransferPlaybackSheet()
                .environmentObject(account)
                .environmentObject(player)
        }
        .sheet(item: $route) { route in
            NavigationStack {
                LumenRouteDestination(route: route)
                    .lumenDestinations()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { self.route = nil } label: { Image(systemName: "chevron.down") }
                                .accessibilityLabel("Close")
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showStudio) {
            NowPlayingView()
                .overlay(alignment: .topTrailing) {
                    Button { showStudio = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 4)
                    .accessibilityLabel("Close Studio")
                }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            isPresented = false
            dismissOffset = 0
        }
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            LumenBackdrop(intensity: 1.6)
            if let song = player.currentSong {
                GeometryReader { geo in
                    ArtworkThumbnail(song: song, size: 200, showsScrim: false)
                        .scaleEffect(geo.size.width * 1.6 / 200)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.25)
                        .blur(radius: 90)
                        .opacity(0.5)
                        .id(song.id)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.8), value: song.id)
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.35), .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Top bar

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) else { return }
                dismissOffset = value.translation.height
            }
            .onEnded { value in
                if value.translation.height > 140 || value.predictedEndTranslation.height > 320 {
                    close()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dismissOffset = 0 }
                }
            }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            LumenIconButton(systemName: "chevron.down", size: 40, accessibilityLabel: "Close player") { close() }

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text("PLAYING FROM")
                    .font(LumenType.eyebrow(10))
                    .tracking(1.4)
                    .foregroundStyle(LumenPalette.textSecondary)
                Text(contextLabel)
                    .font(LumenType.headline(13))
                    .foregroundStyle(LumenPalette.textPrimary)
                    .lineLimit(1)
            }
            .onTapGesture { setStage(.queue) }

            Spacer(minLength: 0)

            moreMenu
        }
        .frame(height: 52)
        .contentShape(Rectangle())
        .gesture(dismissDrag)
    }

    private var contextLabel: String {
        if let id = player.currentPlaylistID, let playlist = library.playlists.first(where: { $0.id == id }) {
            return playlist.name
        }
        return "Your Library"
    }

    private var moreMenu: some View {
        LumiMenu {
            if let song = player.currentSong {
                LumiMenu {
                    ForEach(library.playlists) { playlist in
                        Button(playlist.name) {
                            library.addSong(id: song.id, toPlaylistID: playlist.id)
                            ToastCenter.shared.show("Added to \(playlist.name)", category: .success, icon: "text.badge.plus")
                        }
                    }
                } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }

                Button { route = .album(song.groupableAlbumName) } label: { Label("Go to Album", systemImage: "square.stack") }
                Button { route = .artist(song.artistName) } label: { Label("Go to Artist", systemImage: "music.mic") }
                shareLink(for: song)
                Divider()
            }
            Button { showEffects = true } label: { Label("Effects & EQ", systemImage: "slider.vertical.3") }
            Button { showSleepTimer = true } label: { Label("Sleep Timer", systemImage: "moon.zzz") }
            Button { showFormatInfo = true } label: { Label("Audio Format", systemImage: "waveform.badge.magnifyingglass") }
            Button { showTransfer = true } label: { Label("Transfer Playback", systemImage: "airplayaudio") }
            Toggle(isOn: Binding(get: { player.autoRadioEnabled }, set: { player.autoRadioEnabled = $0 })) {
                Label("Auto-Radio", systemImage: "dot.radiowaves.left.and.right")
            }
            Divider()
            Button { showStudio = true } label: { Label("Open Studio Player", systemImage: "wand.and.rays") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(LumenPalette.textPrimary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(LumenPalette.fill))
                .overlay(Circle().strokeBorder(LumenPalette.hairline, lineWidth: 1))
        }
        .accessibilityLabel("More options")
    }

    @ViewBuilder
    private func shareLink(for song: Song) -> some View {
        let text = song.artist.isEmpty ? song.title : "\(song.title) — \(song.artist)"
        if let uiImage = ArtworkService.shared.artwork(for: song) {
            let image = Image(uiImage: uiImage)
            ShareLink(item: image, preview: SharePreview(text, image: image)) { Label("Share", systemImage: "square.and.arrow.up") }
        } else {
            ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    // MARK: Stage

    private func setStage(_ new: Stage) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            stage = (stage == new) ? .artwork : new
        }
    }

    @ViewBuilder
    private func stageView(width: CGFloat) -> some View {
        if let song = player.currentSong {
            switch stage {
            case .artwork:
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    bigArtwork(song: song, width: width - 48)
                        .gesture(artworkGesture)
                        .simultaneousGesture(dismissDrag)
                    Spacer(minLength: 20)
                    titleRow(song: song)
                }
                .transition(.opacity)
            case .lyrics:
                VStack(spacing: 14) {
                    compactHeader(song: song)
                    LumenLyricsPanel(lines: lyrics, isLoading: lyricsLoading)
                }
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            case .queue:
                VStack(spacing: 14) {
                    compactHeader(song: song)
                    LumenQueuePanel()
                }
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func bigArtwork(song: Song, width: CGFloat) -> some View {
        let side = min(width, 420)
        return LumenArtwork(song: song, size: side, radius: 28)
            .id(song.id)
            .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .opacity))
            .scaleEffect(player.isPlaying ? 1 : 0.86)
            .shadow(color: LumenAmbience.shared.primary.opacity(player.isPlaying ? 0.45 : 0.2), radius: 40, y: 20)
            .offset(x: artworkSwipe)
            .rotationEffect(.degrees(Double(artworkSwipe) / 40))
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: player.isPlaying)
            .animation(.easeInOut(duration: 0.3), value: song.id)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Artwork for \(song.displayName). Swipe left or right to change track.")
    }

    private var artworkGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                artworkSwipe = value.translation.width * 0.6
            }
            .onEnded { value in
                let dx = value.translation.width
                if dx < -90 { haptic.impactOccurred(); player.skipToNext() }
                else if dx > 90 { haptic.impactOccurred(); player.skipToPrevious() }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { artworkSwipe = 0 }
            }
    }

    private func titleRow(song: Song) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(text: song.displayName, font: LumenType.title(24), color: LumenPalette.textPrimary)
                    .frame(height: 30)
                Button { route = .artist(song.artistName) } label: {
                    Text(song.artistName)
                        .font(LumenType.body(17))
                        .foregroundStyle(LumenPalette.textSecondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            favoriteButton(song: song, size: 44)
        }
        .id(song.id)
        .transition(.opacity)
    }

    private func compactHeader(song: Song) -> some View {
        HStack(spacing: 14) {
            LumenArtwork(song: song, size: 58, radius: 12)
                .onTapGesture { setStage(stage) }
            VStack(alignment: .leading, spacing: 3) {
                Text(song.displayName)
                    .font(LumenType.headline(17))
                    .foregroundStyle(LumenPalette.textPrimary)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(LumenType.body(14))
                    .foregroundStyle(LumenPalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            favoriteButton(song: song, size: 40)
        }
        .contentShape(Rectangle())
        .gesture(dismissDrag)
    }

    private func favoriteButton(song: Song, size: CGFloat) -> some View {
        let fav = library.isFavorite(songID: song.id)
        return Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            library.toggleFavorite(songID: song.id)
        } label: {
            Image(systemName: fav ? "heart.fill" : "heart")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(fav ? LumenPalette.ember : LumenPalette.textPrimary)
                .symbolEffect(.bounce, value: fav)
                .frame(width: size, height: size)
                .background(Circle().fill(LumenPalette.fill))
        }
        .buttonStyle(LumenPressStyle(scale: 0.85))
        .accessibilityLabel(fav ? "Remove from Favorites" : "Add to Favorites")
    }

    // MARK: Controls dock

    private var controls: some View {
        VStack(spacing: 18) {
            LumenScrubber()
                .padding(.top, 18)

            HStack {
                transportButton("shuffle", size: 20,
                                tint: player.shuffleEnabled ? LumenPalette.accent : LumenPalette.textSecondary,
                                label: player.shuffleEnabled ? "Shuffle on" : "Shuffle off") {
                    player.toggleShuffle()
                }
                Spacer()
                transportButton("backward.fill", size: 28, label: "Previous track") { player.skipToPrevious() }
                Spacer()
                Button {
                    haptic.impactOccurred()
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 78, height: 78)
                        .background(LumenPalette.glow, in: Circle())
                        .shadow(color: LumenPalette.accent.opacity(0.55), radius: 22, y: 8)
                }
                .buttonStyle(LumenPressStyle(scale: 0.9))
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Spacer()
                transportButton("forward.fill", size: 28, label: "Next track") { player.skipToNext() }
                Spacer()
                transportButton(player.repeatMode == .one ? "repeat.1" : "repeat", size: 20,
                                tint: player.repeatMode == .off ? LumenPalette.textSecondary : LumenPalette.accent,
                                label: "Repeat \(player.repeatMode.title)") {
                    player.cycleRepeatMode()
                }
            }

            LumenVolumeSlider()

            HStack {
                stageButton(.lyrics, icon: "quote.bubble", label: "Lyrics")
                Spacer()
                Button { showSleepTimer = true } label: {
                    SleepTimerButtonLabel(isActive: sleepTimer.isActive)
                }
                .accessibilityLabel("Sleep Timer")
                Spacer()
                AirPlayRoutePicker(tint: UIColor(LumenPalette.textSecondary), activeTint: UIColor(LumenPalette.accent))
                    .frame(width: 40, height: 40)
                    .accessibilityLabel("AirPlay")
                Spacer()
                Button { showEffects = true } label: {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LumenPalette.textSecondary)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Effects and EQ")
                Spacer()
                stageButton(.queue, icon: "list.bullet", label: "Up Next")
            }
        }
    }

    private func transportButton(_ systemName: String, size: CGFloat, tint: Color = LumenPalette.textPrimary,
                                 label: String, action: @escaping () -> Void) -> some View {
        Button {
            haptic.impactOccurred(intensity: 0.6)
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 50, height: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(LumenPressStyle(scale: 0.85))
        .accessibilityLabel(label)
    }

    private func stageButton(_ target: Stage, icon: String, label: String) -> some View {
        let active = stage == target
        return Button { setStage(target) } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? Color.white : LumenPalette.textSecondary)
                .frame(width: 40, height: 40)
                .background { if active { Circle().fill(LumenPalette.glow) } }
        }
        .buttonStyle(LumenPressStyle(scale: 0.88))
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: Lyrics loading
    //
    // Same sources and priority as the classic player's `loadLyrics()`:
    // user-synced file → sidecar .lrc → imported plain text → LRCLIB →
    // lyrics.ovh. The remote fetchers are the classic player's own
    // (stateless) functions, so both editions resolve identical lyrics.

    private func loadLyrics() {
        guard let song = player.currentSong else { lyrics = []; return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|")
        let stem = song.id.components(separatedBy: illegal).joined(separator: "_")

        if let content = try? String(contentsOf: documents.appendingPathComponent(stem + ".lrc"), encoding: .utf8) {
            lyrics = LrcParser.parse(content); return
        }
        if let url = song.url,
           let content = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("lrc"), encoding: .utf8) {
            lyrics = LrcParser.parse(content); return
        }
        if let content = try? String(contentsOf: documents.appendingPathComponent(stem + ".txt"), encoding: .utf8) {
            lyrics = content.components(separatedBy: .newlines)
                .map { LrcLine(time: 0, text: $0) }
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            return
        }

        lyrics = []
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let songID = song.id
        lyricsLoading = true
        Task {
            let fetcher = NowPlayingView()
            var lines = await fetcher.fetchLRCLIB(title: title, artist: artist, duration: song.duration)
            if lines?.isEmpty ?? true, player.currentSong?.id == songID {
                lines = await fetcher.fetchLyricsOVH(title: title, artist: artist)
            }
            guard player.currentSong?.id == songID else { return }
            lyrics = lines ?? []
            lyricsLoading = false
        }
    }
}

extension LumenRoute: Identifiable {
    var id: Self { self }
}

// MARK: - Scrubber

struct LumenScrubber: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var progress: PlaybackProgress

    @State private var dragFraction: Double?

    var body: some View {
        let duration = max(progress.duration, 0.01)
        let liveFraction = min(max(progress.position / duration, 0), 1)
        let fraction = dragFraction ?? liveFraction
        let dragging = dragFraction != nil

        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(LumenPalette.glowHorizontal)
                        .frame(width: max(geo.size.width * fraction, dragging ? 8 : 4))
                        .shadow(color: LumenPalette.accent.opacity(0.7), radius: dragging ? 10 : 5)
                }
                .frame(height: dragging ? 12 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragFraction == nil { UISelectionFeedbackGenerator().selectionChanged() }
                            dragFraction = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                        }
                        .onEnded { _ in
                            if let f = dragFraction { player.seek(to: f * duration) }
                            dragFraction = nil
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: dragging)
            }
            .frame(height: 24)

            HStack {
                Text(LumenFormat.clock(fraction * duration))
                Spacer()
                Text("-" + LumenFormat.clock(max(duration - fraction * duration, 0)))
            }
            .font(LumenType.mono(12))
            .foregroundStyle(dragging ? LumenPalette.textPrimary : LumenPalette.textSecondary)
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(LumenFormat.clock(progress.position)) of \(LumenFormat.clock(progress.duration))")
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = 10
            switch direction {
            case .increment: player.seek(to: min(progress.position + step, progress.duration))
            case .decrement: player.seek(to: max(progress.position - step, 0))
            @unknown default: break
            }
        }
    }
}

// MARK: - Volume

struct LumenVolumeSlider: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LumenPalette.textTertiary)
            GeometryReader { geo in
                let fraction = CGFloat(min(max(player.audioSettings.volume, 0), 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Color.white.opacity(dragging ? 0.95 : 0.7))
                        .frame(width: geo.size.width * fraction)
                }
                .frame(height: dragging ? 8 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            player.audioSettings.volume = Float(min(max(value.location.x / max(geo.size.width, 1), 0), 1))
                        }
                        .onEnded { _ in dragging = false }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: dragging)
            }
            .frame(height: 20)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LumenPalette.textTertiary)
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(player.audioSettings.volume * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.audioSettings.volume = min(player.audioSettings.volume + 0.1, 1)
            case .decrement: player.audioSettings.volume = max(player.audioSettings.volume - 0.1, 0)
            @unknown default: break
            }
        }
    }
}

// MARK: - Sleep timer button label

/// Split out so the once-a-second countdown tick re-renders only this small
/// label, not all of `LumenNowPlayingView` — which also hosts the `moreMenu`
/// "•••" dropdown via the same struct's computed properties. See
/// `SleepTimerProgress`'s doc comment. `isActive` is passed in as a plain
/// `Bool` from the parent (which already reads `sleepTimer.isActive` safely —
/// that field doesn't tick) rather than observed here, so this view's own
/// `EnvironmentObject` subscription stays limited to the ticking value alone.
private struct SleepTimerButtonLabel: View {
    @EnvironmentObject private var sleepProgress: SleepTimerProgress
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isActive ? "moon.zzz.fill" : "moon.zzz")
            if isActive {
                Text(LumenFormat.clock(sleepProgress.remainingSeconds))
                    .font(LumenType.mono(12))
            }
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(isActive ? LumenPalette.accent : LumenPalette.textSecondary)
        .frame(height: 40)
    }
}

// MARK: - Lyrics panel

struct LumenLyricsPanel: View {
    let lines: [LrcLine]
    let isLoading: Bool

    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var progress: PlaybackProgress

    private var isSynced: Bool { lines.contains { $0.time > 0 } }

    private var activeIndex: Int? {
        guard isSynced else { return nil }
        return lines.lastIndex { $0.time <= progress.position + 0.25 }
    }

    var body: some View {
        if lines.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                if isLoading {
                    ProgressView().tint(LumenPalette.accent)
                    Text("Finding lyrics…")
                        .font(LumenType.body(15))
                        .foregroundStyle(LumenPalette.textSecondary)
                } else {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(LumenPalette.glow)
                    Text("No lyrics for this track")
                        .font(LumenType.headline(17))
                        .foregroundStyle(LumenPalette.textPrimary)
                    Text("Sync your own from the Studio player in the ••• menu.")
                        .font(LumenType.caption(13))
                        .foregroundStyle(LumenPalette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            let active = activeIndex
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(LumenType.title(isSynced ? 26 : 20))
                                .foregroundStyle(lineColor(index: index, active: active))
                                .blur(radius: isSynced && active != nil && index != active ? 0.6 : 0)
                                .scaleEffect(index == active ? 1.0 : 0.97, anchor: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                                .onTapGesture {
                                    if isSynced { player.seek(to: line.time) }
                                }
                                .animation(.easeInOut(duration: 0.3), value: active)
                        }
                    }
                    .padding(.vertical, 120)
                }
                .scrollIndicators(.hidden)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: active) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(new, anchor: .center) }
                }
                .onAppear {
                    if let active { proxy.scrollTo(active, anchor: .center) }
                }
            }
        }
    }

    private func lineColor(index: Int, active: Int?) -> Color {
        guard isSynced else { return LumenPalette.textPrimary.opacity(0.9) }
        guard let active else { return LumenPalette.textPrimary.opacity(0.35) }
        if index == active { return LumenPalette.textPrimary }
        return index < active ? LumenPalette.textPrimary.opacity(0.3) : LumenPalette.textPrimary.opacity(0.42)
    }
}

// MARK: - Queue panel

struct LumenQueuePanel: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager

    @State private var showSave = false
    @State private var saveName = ""

    private var upcoming: [(index: Int, song: Song)] {
        guard player.queue.indices.contains(player.currentIndex) else { return [] }
        return player.queue.enumerated()
            .filter { $0.offset > player.currentIndex }
            .map { (index: $0.offset, song: $0.element) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                LumenChip(title: "Shuffle", systemImage: "shuffle", isSelected: player.shuffleEnabled) { player.toggleShuffle() }
                LumenChip(title: player.repeatMode == .one ? "Repeat One" : "Repeat",
                          systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                          isSelected: player.repeatMode != .off) { player.cycleRepeatMode() }
                LumenChip(title: "Radio", systemImage: "dot.radiowaves.left.and.right",
                          isSelected: player.autoRadioEnabled) { player.autoRadioEnabled.toggle() }
                Spacer(minLength: 0)
            }

            HStack {
                Text("Up Next")
                    .font(LumenType.title(19))
                    .foregroundStyle(LumenPalette.textPrimary)
                Spacer()
                LumiMenu {
                    Button { showSave = true } label: { Label("Save Queue as Playlist", systemImage: "square.and.arrow.down") }
                    Button(role: .destructive) {
                        let offsets = IndexSet(upcoming.map(\.index))
                        if !offsets.isEmpty { player.removeFromQueue(at: offsets) }
                    } label: { Label("Clear Up Next", systemImage: "xmark.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LumenPalette.textSecondary)
                }
                .accessibilityLabel("Queue options")
            }

            if upcoming.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "list.bullet").font(.system(size: 30, weight: .semibold)).foregroundStyle(LumenPalette.glow)
                    Text(player.autoRadioEnabled ? "Auto-Radio will keep the music going." : "Nothing queued after this track.")
                        .font(LumenType.body(14))
                        .foregroundStyle(LumenPalette.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(upcoming, id: \.song.id) { item in
                        HStack(spacing: 12) {
                            LumenArtwork(song: item.song, size: 44, radius: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.song.displayName)
                                    .font(LumenType.headline(14))
                                    .foregroundStyle(LumenPalette.textPrimary)
                                    .lineLimit(1)
                                Text(item.song.artistName)
                                    .font(LumenType.caption(12))
                                    .foregroundStyle(LumenPalette.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if item.song.resolvedQueueSource == .manual {
                                Image(systemName: "person.fill.badge.plus")
                                    .font(.system(size: 11))
                                    .foregroundStyle(LumenPalette.accent)
                                    .accessibilityLabel("Queued by you")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.setQueue(player.queue, startIndex: item.index, autoplay: true, playlistID: player.currentPlaylistID)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                        .swipeActions {
                            Button(role: .destructive) { player.removeSong(id: item.song.id) } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                    }
                    .onMove { from, to in
                        let base = player.currentIndex + 1
                        let absolute = IndexSet(from.map { $0 + base })
                        player.moveQueueItem(from: absolute, to: to + base)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            }
        }
        .alert("Save Queue", isPresented: $showSave) {
            TextField("Playlist name", text: $saveName)
            Button("Cancel", role: .cancel) { saveName = "" }
            Button("Save") {
                let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !player.queue.isEmpty else { return }
                _ = library.createPlaylist(name: name, songIDs: player.queue.map(\.id))
                ToastCenter.shared.show("Saved \"\(name)\"", category: .success, icon: "checkmark.circle.fill")
                saveName = ""
            }
        }
    }
}
